package core

import (
	"context"
	"sort"
	"strings"

	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/api/types/volume"
)

// Image is a UI-friendly view of a Docker image.
type Image struct {
	ID       string   `json:"id"`
	Tags     []string `json:"tags"`
	Size     int64    `json:"size"`
	Created  int64    `json:"created"`
	Dangling bool     `json:"dangling"`
}

// ListImages returns images on this engine, newest first.
func (e *Engine) ListImages(ctx context.Context) ([]Image, error) {
	items, err := e.Docker.ImageList(ctx, image.ListOptions{All: false})
	if err != nil {
		return nil, err
	}
	out := make([]Image, 0, len(items))
	for _, im := range items {
		tags := im.RepoTags
		dangling := false
		if len(tags) == 0 || (len(tags) == 1 && tags[0] == "<none>:<none>") {
			tags = nil
			dangling = true
		}
		id := strings.TrimPrefix(im.ID, "sha256:")
		if len(id) > 12 {
			id = id[:12]
		}
		out = append(out, Image{ID: id, Tags: tags, Size: im.Size, Created: im.Created, Dangling: dangling})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created > out[j].Created })
	return out, nil
}

// Volume is a UI-friendly view of a Docker volume.
type Volume struct {
	Name       string `json:"name"`
	Driver     string `json:"driver"`
	Mountpoint string `json:"mountpoint"`
	CreatedAt  string `json:"createdAt,omitempty"`
}

// ListVolumes returns volumes on this engine.
func (e *Engine) ListVolumes(ctx context.Context) ([]Volume, error) {
	resp, err := e.Docker.VolumeList(ctx, volume.ListOptions{})
	if err != nil {
		return nil, err
	}
	out := make([]Volume, 0, len(resp.Volumes))
	for _, v := range resp.Volumes {
		out = append(out, Volume{Name: v.Name, Driver: v.Driver, Mountpoint: v.Mountpoint, CreatedAt: v.CreatedAt})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Network is a UI-friendly view of a Docker network.
type Network struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Driver  string `json:"driver"`
	Scope   string `json:"scope"`
	Subnet  string `json:"subnet,omitempty"`
	Builtin bool   `json:"builtin"`
}

// ListNetworks returns networks on this engine.
func (e *Engine) ListNetworks(ctx context.Context) ([]Network, error) {
	items, err := e.Docker.NetworkList(ctx, network.ListOptions{})
	if err != nil {
		return nil, err
	}
	out := make([]Network, 0, len(items))
	for _, n := range items {
		subnet := ""
		if len(n.IPAM.Config) > 0 {
			subnet = n.IPAM.Config[0].Subnet
		}
		id := n.ID
		if len(id) > 12 {
			id = id[:12]
		}
		builtin := n.Name == "bridge" || n.Name == "host" || n.Name == "none"
		out = append(out, Network{ID: id, Name: n.Name, Driver: n.Driver, Scope: n.Scope, Subnet: subnet, Builtin: builtin})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}
