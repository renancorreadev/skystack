package core

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/pkg/stdcopy"
)

// Container is a host-agnostic, UI-friendly view of a Docker container.
type Container struct {
	Host    string
	ID      string
	Name    string
	Image   string
	State   string // running, exited, paused, ...
	Status  string // human status string ("Up 3 minutes")
	Ports   []string
	Compose string // docker-compose project label, if any
	Service string // docker-compose service label, if any
}

// List returns the containers on this engine. When all is false only running
// containers are returned.
func (e *Engine) List(ctx context.Context, all bool) ([]Container, error) {
	items, err := e.Docker.ContainerList(ctx, container.ListOptions{All: all})
	if err != nil {
		return nil, err
	}
	out := make([]Container, 0, len(items))
	for _, c := range items {
		name := ""
		if len(c.Names) > 0 {
			name = strings.TrimPrefix(c.Names[0], "/")
		}
		ports := map[string]struct{}{}
		for _, p := range c.Ports {
			if p.PublicPort != 0 {
				ports[fmt.Sprintf("%d→%d", p.PublicPort, p.PrivatePort)] = struct{}{}
			}
		}
		out = append(out, Container{
			Host:    e.Host.Name,
			ID:      c.ID,
			Name:    name,
			Image:   c.Image,
			State:   c.State,
			Status:  c.Status,
			Ports:   sortedKeys(ports),
			Compose: c.Labels["com.docker.compose.project"],
			Service: c.Labels["com.docker.compose.service"],
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Resolve finds a single container on this engine by name, ID, or unique prefix.
func (e *Engine) Resolve(ctx context.Context, ref string) (Container, error) {
	all, err := e.List(ctx, true)
	if err != nil {
		return Container{}, err
	}
	var matches []Container
	for _, c := range all {
		if c.Name == ref || c.ID == ref || strings.HasPrefix(c.ID, ref) || c.Service == ref {
			matches = append(matches, c)
		}
	}
	switch len(matches) {
	case 0:
		return Container{}, fmt.Errorf("no container matching %q on host %q", ref, e.Host.Name)
	case 1:
		return matches[0], nil
	default:
		names := make([]string, len(matches))
		for i, m := range matches {
			names[i] = m.Name
		}
		return Container{}, fmt.Errorf("%q is ambiguous on host %q: %s", ref, e.Host.Name, strings.Join(names, ", "))
	}
}

// Inspect returns the raw JSON inspection for a container.
func (e *Engine) Inspect(ctx context.Context, id string) (any, error) {
	return e.Docker.ContainerInspect(ctx, id)
}

// Lifecycle actions.

func (e *Engine) Start(ctx context.Context, id string) error {
	return e.Docker.ContainerStart(ctx, id, container.StartOptions{})
}

func (e *Engine) Stop(ctx context.Context, id string) error {
	return e.Docker.ContainerStop(ctx, id, container.StopOptions{})
}

func (e *Engine) Restart(ctx context.Context, id string) error {
	return e.Docker.ContainerRestart(ctx, id, container.StopOptions{})
}

// ExecConfig describes a command to run inside a container.
type ExecConfig struct {
	Cmd    []string
	TTY    bool
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

// ExecSimple runs a non-interactive command and streams its output. For an
// interactive TTY session see the exec command in the CLI layer, which manages
// terminal raw mode and resize.
func (e *Engine) ExecSimple(ctx context.Context, id string, cfg ExecConfig) error {
	created, err := e.Docker.ContainerExecCreate(ctx, id, container.ExecOptions{
		Cmd:          cfg.Cmd,
		Tty:          cfg.TTY,
		AttachStdin:  cfg.Stdin != nil,
		AttachStdout: true,
		AttachStderr: true,
	})
	if err != nil {
		return err
	}
	att, err := e.Docker.ContainerExecAttach(ctx, created.ID, container.ExecAttachOptions{Tty: cfg.TTY})
	if err != nil {
		return err
	}
	defer att.Close()

	if cfg.Stdin != nil {
		go func() {
			_, _ = io.Copy(att.Conn, cfg.Stdin)
			_ = att.CloseWrite()
		}()
	}
	if cfg.TTY {
		_, err = io.Copy(cfg.Stdout, att.Reader)
	} else {
		_, err = stdcopy.StdCopy(cfg.Stdout, cfg.Stderr, att.Reader)
	}
	return err
}

func sortedKeys(m map[string]struct{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
