package core

import (
	"context"

	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/api/types/volume"
)

// CreateVolume creates a named volume.
func (e *Engine) CreateVolume(ctx context.Context, name string) error {
	_, err := e.Docker.VolumeCreate(ctx, volume.CreateOptions{Name: name})
	return err
}

// CreateNetwork creates a bridge network by name.
func (e *Engine) CreateNetwork(ctx context.Context, name string) error {
	_, err := e.Docker.NetworkCreate(ctx, name, network.CreateOptions{Driver: "bridge"})
	return err
}
