package core

import (
	"context"
	"io"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/go-connections/nat"
)

// RunSpec describes a container to run from an image.
type RunSpec struct {
	Image string
	Name  string
	Ports []string // "host:container" mappings
	Env   []string
}

// RunContainer pulls (if needed) and starts a container, returning its ID.
func (e *Engine) RunContainer(ctx context.Context, spec RunSpec, progress io.Writer) (string, error) {
	if err := e.EnsureImage(ctx, spec.Image, progress); err != nil {
		return "", err
	}
	exposed, bindings, err := nat.ParsePortSpecs(spec.Ports)
	if err != nil {
		return "", err
	}
	cfg := &container.Config{Image: spec.Image, ExposedPorts: exposed, Env: spec.Env}
	host := &container.HostConfig{PortBindings: bindings}
	resp, err := e.Docker.ContainerCreate(ctx, cfg, host, nil, nil, spec.Name)
	if err != nil {
		return "", err
	}
	if err := e.Docker.ContainerStart(ctx, resp.ID, container.StartOptions{}); err != nil {
		return "", err
	}
	return resp.ID, nil
}

// RemoveContainer force-removes a container by id/name.
func (e *Engine) RemoveContainer(ctx context.Context, id string) error {
	return e.Docker.ContainerRemove(ctx, id, container.RemoveOptions{Force: true})
}

// RemoveImage removes an image (force handles in-use/tagged images).
func (e *Engine) RemoveImage(ctx context.Context, id string) error {
	_, err := e.Docker.ImageRemove(ctx, id, image.RemoveOptions{Force: true, PruneChildren: true})
	return err
}

// RemoveVolume removes a volume.
func (e *Engine) RemoveVolume(ctx context.Context, name string) error {
	return e.Docker.VolumeRemove(ctx, name, true)
}

// RemoveNetwork removes a network.
func (e *Engine) RemoveNetwork(ctx context.Context, id string) error {
	return e.Docker.NetworkRemove(ctx, id)
}

// Prune reclaims space for the given kind: "images", "volumes", "containers",
// or "networks". Returns bytes reclaimed where the API reports it.
func (e *Engine) Prune(ctx context.Context, kind string) (uint64, error) {
	f := filters.NewArgs()
	switch kind {
	case "images":
		r, err := e.Docker.ImagesPrune(ctx, f)
		return r.SpaceReclaimed, err
	case "containers":
		r, err := e.Docker.ContainersPrune(ctx, f)
		return r.SpaceReclaimed, err
	case "volumes":
		r, err := e.Docker.VolumesPrune(ctx, f)
		return r.SpaceReclaimed, err
	case "networks":
		_, err := e.Docker.NetworksPrune(ctx, f)
		return 0, err
	}
	return 0, nil
}
