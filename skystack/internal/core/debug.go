package core

import (
	"context"
	"io"

	"github.com/docker/docker/api/types/container"
	imagetypes "github.com/docker/docker/api/types/image"
)

// DefaultDebugImage is the toolbox used by `skystack debug` when none is given.
// busybox is tiny (~5 MB) yet ships sh, vi, wget, ps, netstat, top, etc. — enough
// to debug a distroless/read-only target whose own filesystem is at /proc/1/root.
const DefaultDebugImage = "busybox:latest"

// DebugSpec configures a debug toolbox container that shares a target's
// namespaces so you can inspect its processes, network, and filesystem.
type DebugSpec struct {
	TargetID string
	Image    string
	Cmd      []string
	TTY      bool
}

// debugHostConfig joins the target container's PID and network namespaces (so the
// toolbox sees its processes and shares its network), grants SYS_PTRACE for
// process inspection, and auto-removes the toolbox on exit. The target's root
// filesystem is then reachable from the toolbox at /proc/1/root.
func debugHostConfig(targetID string) *container.HostConfig {
	ns := container.NetworkMode("container:" + targetID)
	return &container.HostConfig{
		PidMode:     container.PidMode("container:" + targetID),
		NetworkMode: ns,
		CapAdd:      []string{"SYS_PTRACE"},
		AutoRemove:  true,
	}
}

// EnsureImage makes sure ref is present locally, pulling it (and draining the
// progress stream to progress) only if it is missing.
func (e *Engine) EnsureImage(ctx context.Context, ref string, progress io.Writer) error {
	if _, _, err := e.Docker.ImageInspectWithRaw(ctx, ref); err == nil {
		return nil
	}
	rc, err := e.Docker.ImagePull(ctx, ref, imagetypes.PullOptions{})
	if err != nil {
		return err
	}
	defer rc.Close()
	if progress == nil {
		progress = io.Discard
	}
	_, err = io.Copy(progress, rc)
	return err
}

// CreateDebug creates (without starting) the debug toolbox container.
func (e *Engine) CreateDebug(ctx context.Context, spec DebugSpec) (string, error) {
	cfg := &container.Config{
		Image:        spec.Image,
		Cmd:          spec.Cmd,
		Tty:          spec.TTY,
		OpenStdin:    true,
		AttachStdin:  true,
		AttachStdout: true,
		AttachStderr: true,
		Env:          []string{"TERM=xterm-256color"},
	}
	resp, err := e.Docker.ContainerCreate(ctx, cfg, debugHostConfig(spec.TargetID), nil, nil, "")
	if err != nil {
		return "", err
	}
	return resp.ID, nil
}
