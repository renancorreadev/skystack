package core

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/docker/go-connections/nat"
)

// TunnelSpec describes a local→container port forward.
type TunnelSpec struct {
	LocalPort     int
	ContainerPort int
}

// ParsePorts parses "8080:80" (or just "80", meaning same local/container port).
func ParsePorts(s string) (TunnelSpec, error) {
	parts := strings.SplitN(s, ":", 2)
	cp, err := strconv.Atoi(strings.TrimSpace(parts[len(parts)-1]))
	if err != nil {
		return TunnelSpec{}, fmt.Errorf("invalid container port in %q", s)
	}
	lp := cp
	if len(parts) == 2 {
		if lp, err = strconv.Atoi(strings.TrimSpace(parts[0])); err != nil {
			return TunnelSpec{}, fmt.Errorf("invalid local port in %q", s)
		}
	}
	return TunnelSpec{LocalPort: lp, ContainerPort: cp}, nil
}

// containerIP returns the first usable IP of a container from its inspection.
func (e *Engine) containerIP(ctx context.Context, id string) (string, error) {
	info, err := e.Docker.ContainerInspect(ctx, id)
	if err != nil {
		return "", err
	}
	if info.NetworkSettings == nil {
		return "", fmt.Errorf("container has no network settings")
	}
	if ip := info.NetworkSettings.IPAddress; ip != "" {
		return ip, nil
	}
	for _, n := range info.NetworkSettings.Networks {
		if n.IPAddress != "" {
			return n.IPAddress, nil
		}
	}
	return "", fmt.Errorf("container has no IP address (is it running?)")
}

// publishedPort returns the host port a container's private port is published to.
func (e *Engine) publishedPort(ctx context.Context, id string, containerPort int) (int, bool, error) {
	info, err := e.Docker.ContainerInspect(ctx, id)
	if err != nil {
		return 0, false, err
	}
	want := nat.Port(fmt.Sprintf("%d/tcp", containerPort))
	if info.NetworkSettings != nil {
		if binds, ok := info.NetworkSettings.Ports[want]; ok && len(binds) > 0 {
			p, _ := strconv.Atoi(binds[0].HostPort)
			return p, true, nil
		}
	}
	return 0, false, nil
}

// Tunnel forwards 127.0.0.1:spec.LocalPort to the container's port. It blocks
// until ctx is cancelled.
//
//   - SSH hosts: a system `ssh -L` forward to the container's internal IP. This
//     reuses the same SSH access Docker's connection helper relies on, so the
//     user's agent, ~/.ssh/config and known_hosts all apply unchanged.
//   - Local + SkyVM hosts: the container's published host port is proxied
//     directly. The local engine and SkyVM both surface published ports on the
//     Mac's localhost (SkyVM's PortForwarder mirrors guest ports), so the proxy
//     reaches them without SSH; container IPs aren't routable for a raw forward.
func (e *Engine) Tunnel(ctx context.Context, c Container, spec TunnelSpec, logf func(string, ...any)) error {
	if e.Host.SSH != "" {
		return e.tunnelSSH(ctx, c, spec, logf)
	}
	return e.tunnelLocal(ctx, c, spec, logf)
}

func (e *Engine) tunnelLocal(ctx context.Context, c Container, spec TunnelSpec, logf func(string, ...any)) error {
	hostPort, ok, err := e.publishedPort(ctx, c.ID, spec.ContainerPort)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("container %q does not publish port %d; on the local engine SkyStack can only tunnel published ports (publish it with -p, or use a remote host)", c.Name, spec.ContainerPort)
	}
	// Dial "localhost" (not a hard 127.0.0.1) so Go's dual-stack fast-fallback
	// picks a working stack. Docker Desktop on macOS publishes on both 0.0.0.0
	// and [::], but its IPv4 proxy can stall while IPv6 serves — happy-eyeballs
	// transparently routes around that.
	target := fmt.Sprintf("localhost:%d", hostPort)
	logf("local tunnel %s/%s :%d → http://localhost:%d", c.Host, c.Name, spec.ContainerPort, spec.LocalPort)
	return proxyTCP(ctx, spec.LocalPort, func() (net.Conn, error) {
		return net.Dial("tcp", target)
	})
}

func (e *Engine) tunnelSSH(ctx context.Context, c Container, spec TunnelSpec, logf func(string, ...any)) error {
	ip, err := e.containerIP(ctx, c.ID)
	if err != nil {
		return err
	}
	user, host, port := parseSSHURL(e.Host.SSH)
	dest := net.JoinHostPort(host, port)
	if user != "" {
		dest = user + "@" + dest
	}

	forward := fmt.Sprintf("%d:%s:%d", spec.LocalPort, ip, spec.ContainerPort)
	args := []string{
		"-N", // no remote command, just forward
		"-o", "ExitOnForwardFailure=yes",
		"-o", "ServerAliveInterval=15",
		"-L", forward,
		dest,
	}
	logf("ssh tunnel %s/%s (%s:%d) → http://localhost:%d", c.Host, c.Name, ip, spec.ContainerPort, spec.LocalPort)

	cmd := exec.CommandContext(ctx, "ssh", args...)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil && ctx.Err() == nil {
		return fmt.Errorf("ssh tunnel failed: %w", err)
	}
	return ctx.Err()
}

// proxyTCP accepts connections on 127.0.0.1:localPort and proxies each to a new
// connection from dial.
func proxyTCP(ctx context.Context, localPort int, dial func() (net.Conn, error)) error {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", localPort))
	if err != nil {
		return err
	}
	go func() { <-ctx.Done(); ln.Close() }()

	for {
		local, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go func() {
			defer local.Close()
			remote, err := dial()
			if err != nil {
				return
			}
			defer remote.Close()
			done := make(chan struct{}, 2)
			go func() { io.Copy(remote, local); done <- struct{}{} }()
			go func() { io.Copy(local, remote); done <- struct{}{} }()
			<-done
		}()
	}
}

func parseSSHURL(raw string) (user, host, port string) {
	port = "22"
	u, err := url.Parse(raw)
	if err != nil {
		return "", raw, port
	}
	if u.User != nil {
		user = u.User.Username()
	}
	host = u.Hostname()
	if u.Port() != "" {
		port = u.Port()
	}
	return user, host, port
}
