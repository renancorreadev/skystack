// Package core is the SkyStack control plane: it talks to one or many Docker
// engines (local over the unix socket, remote over SSH) through a single
// uniform API. The CLI and, later, the gRPC daemon are thin layers on top.
package core

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"

	"github.com/docker/cli/cli/connhelper"
	"github.com/docker/docker/client"

	"github.com/skynance/skystack/internal/config"
)

// Engine wraps a Docker API client bound to a specific host.
type Engine struct {
	Host   *config.Host
	Docker *client.Client
}

// Connect builds a Docker client for the given host. Local hosts use the
// standard environment (DOCKER_HOST / unix socket). Remote hosts dial the
// engine over SSH using Docker's connection helper, so no daemon needs to be
// installed on the Mac side and no port has to be exposed on the server.
func Connect(ctx context.Context, h *config.Host) (*Engine, error) {
	opts := []client.Opt{client.WithAPIVersionNegotiation()}

	switch {
	case h.Docker != "":
		// Explicit endpoint (e.g. the skyvm host's unix:///…/skyvm-docker.sock).
		opts = append(opts, client.WithHost(h.Docker))
	case h.IsLocal():
		opts = append(opts, client.FromEnv)
	default:
		// Reuse one multiplexed SSH master connection across the many short-lived
		// `skystack api` calls (the app polls often). ControlPath is fixed per
		// host, so separate processes share the master; ControlPersist keeps it
		// warm between polls — turning ~6 SSH handshakes/2s into one.
		helper, err := connhelper.GetConnectionHelperWithSSHOpts(h.SSH, sshControlOpts())
		if err != nil {
			return nil, fmt.Errorf("ssh connection helper for %s: %w", h.SSH, err)
		}
		httpClient := &http.Client{
			Transport: &http.Transport{DialContext: helper.Dialer},
		}
		opts = append(opts,
			client.WithHTTPClient(httpClient),
			client.WithHost(helper.Host),
			client.WithDialContext(helper.Dialer),
		)
	}

	cli, err := client.NewClientWithOpts(opts...)
	if err != nil {
		return nil, err
	}
	return &Engine{Host: h, Docker: cli}, nil
}

// sshControlOpts returns ssh flags that enable connection multiplexing so the
// app's frequent polling reuses a single warm SSH master per host instead of
// re-handshaking every call. ControlPath uses %C (a short hash) under
// ~/.skystack/ssh to stay within the unix-socket path limit.
func sshControlOpts() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	dir := filepath.Join(home, ".skystack", "ssh")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil
	}
	return []string{
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=" + filepath.Join(dir, "%C"),
		"-o", "ControlPersist=120",
		"-o", "ConnectTimeout=12",
		"-o", "ServerAliveInterval=30",
	}
}

// Close releases the underlying client.
func (e *Engine) Close() error {
	if e.Docker != nil {
		return e.Docker.Close()
	}
	return nil
}

// Ping verifies the engine is reachable and returns its reported version.
func (e *Engine) Ping(ctx context.Context) (string, error) {
	v, err := e.Docker.ServerVersion(ctx)
	if err != nil {
		return "", err
	}
	return v.Version, nil
}

// Alive is a cheap liveness check (the /_ping endpoint) — used by the persistent
// hosts watcher to test reachability without re-fetching the (static) version.
func (e *Engine) Alive(ctx context.Context) bool {
	_, err := e.Docker.Ping(ctx)
	return err == nil
}
