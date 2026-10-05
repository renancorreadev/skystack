package core

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/docker/docker/api/types/container"
)

// MachineLabel marks a container as a SkyStack "machine" — a persistent Linux
// environment (à la OrbStack machines / WSL), not an app container.
const MachineLabel = "dev.skystack.machine"

// DistroImages maps a friendly distro name to its base image.
var DistroImages = map[string]string{
	"ubuntu": "ubuntu:24.04",
	"debian": "debian:12",
	"alpine": "alpine:3.21",
	"fedora": "fedora:41",
	"arch":   "archlinux:latest",
	"rocky":  "rockylinux:9",
}

// DefaultDistro is used when `machine create` gets no --distro.
const DefaultDistro = "ubuntu"

// Distros returns the supported distro names, sorted.
func Distros() []string {
	out := make([]string, 0, len(DistroImages))
	for d := range DistroImages {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

// Machine is a persistent Linux environment.
type Machine struct {
	Name   string
	Distro string
	Image  string
	State  string
	Status string
}

// ResolveDistro maps a distro name (or a raw image ref) to an image.
func ResolveDistro(distro string) (string, error) {
	if img, ok := DistroImages[strings.ToLower(distro)]; ok {
		return img, nil
	}
	if strings.Contains(distro, ":") || strings.Contains(distro, "/") {
		return distro, nil // treat as a raw image reference
	}
	return "", fmt.Errorf("unknown distro %q (try one of: %s, or pass an image ref)", distro, strings.Join(Distros(), ", "))
}

// CreateMachine pulls the distro image (if needed) and starts a long-lived
// container named after the machine. homeBind, when non-empty, bind-mounts the
// Mac home into the machine at the same path (your files travel with you).
func (e *Engine) CreateMachine(ctx context.Context, name, distro, homeBind string, progress io.Writer) error {
	image, err := ResolveDistro(distro)
	if err != nil {
		return err
	}
	if err := e.EnsureImage(ctx, image, progress); err != nil {
		return fmt.Errorf("pulling %s: %w", image, err)
	}
	cfg := &container.Config{
		Image:     image,
		Hostname:  name,
		Cmd:       []string{"sleep", "infinity"},
		Tty:       true,
		OpenStdin: true,
		Labels:    map[string]string{MachineLabel: strings.ToLower(distro)},
	}
	host := &container.HostConfig{
		RestartPolicy: container.RestartPolicy{Name: "unless-stopped"},
	}
	if homeBind != "" {
		host.Binds = []string{homeBind + ":" + homeBind}
	}
	resp, err := e.Docker.ContainerCreate(ctx, cfg, host, nil, nil, name)
	if err != nil {
		return err
	}
	return e.Docker.ContainerStart(ctx, resp.ID, container.StartOptions{})
}

// ListMachines returns the machines on this engine.
func (e *Engine) ListMachines(ctx context.Context) ([]Machine, error) {
	items, err := e.Docker.ContainerList(ctx, container.ListOptions{All: true})
	if err != nil {
		return nil, err
	}
	var out []Machine
	for _, c := range items {
		distro, ok := c.Labels[MachineLabel]
		if !ok {
			continue
		}
		name := ""
		if len(c.Names) > 0 {
			name = strings.TrimPrefix(c.Names[0], "/")
		}
		out = append(out, Machine{Name: name, Distro: distro, Image: c.Image, State: c.State, Status: c.Status})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// RemoveMachine force-removes a machine container.
func (e *Engine) RemoveMachine(ctx context.Context, name string) error {
	return e.Docker.ContainerRemove(ctx, name, container.RemoveOptions{Force: true})
}
