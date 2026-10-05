// Package vm manages the local SkyVM Linux runtime as a background daemon: where
// its binary and image assets live, and its start/stop/status lifecycle. The
// CLI's `skystack vm …` commands and the built-in `skyvm` host are built on it.
package vm

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/skynance/skystack/internal/config"
)

// ErrNotInstalled is returned when the runtime hasn't been set up yet.
var ErrNotInstalled = errors.New("local VM runtime is not set up — run `skystack vm setup`")

// Runtime records where the SkyVM binary and image assets live, plus resource
// sizing. Persisted at ~/.skystack/runtime.json.
type Runtime struct {
	// Binary is the absolute path to the signed SkyVM executable.
	Binary string `json:"binary"`
	// Assets is the directory holding vmlinux, initramfs.gz and rootfs.ext4.
	Assets string `json:"assets"`
	// CPUs / MemoryGiB size the guest. Zero means SkyVM's own defaults.
	CPUs      int `json:"cpus,omitempty"`
	MemoryGiB int `json:"memoryGiB,omitempty"`
	// Share is a Mac directory mirrored into the guest at the SAME path over
	// VirtioFS, so `docker run -v <macpath>:<ctr>` resolves transparently.
	// Empty disables sharing. Defaults to the user's home at setup time.
	Share string `json:"share,omitempty"`
	// Verbose surfaces full kernel boot output in the VM log.
	Verbose bool `json:"verbose,omitempty"`
	// K8s enables the in-VM single-node Kubernetes (k3s) on the next start.
	K8s bool `json:"k8s,omitempty"`
}

// LoadRuntime reads the persisted runtime config.
func LoadRuntime() (*Runtime, error) {
	p, err := config.RuntimeConfigPath()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		return nil, ErrNotInstalled
	}
	if err != nil {
		return nil, err
	}
	var rt Runtime
	if err := json.Unmarshal(data, &rt); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", p, err)
	}
	return &rt, nil
}

// Save persists the runtime config (0600).
func (rt *Runtime) Save() error {
	p, err := config.RuntimeConfigPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(rt, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o600)
}

// KernelPath / InitramfsPath / RootfsPath resolve the image files in Assets.
func (rt *Runtime) KernelPath() string    { return filepath.Join(rt.Assets, "vmlinux") }
func (rt *Runtime) InitramfsPath() string { return filepath.Join(rt.Assets, "initramfs.gz") }
func (rt *Runtime) RootfsPath() string    { return filepath.Join(rt.Assets, "rootfs.ext4") }

// Validate checks the configured binary and image files all exist.
func (rt *Runtime) Validate() error {
	for label, path := range map[string]string{
		"SkyVM binary": rt.Binary,
		"kernel":       rt.KernelPath(),
		"initramfs":    rt.InitramfsPath(),
		"rootfs":       rt.RootfsPath(),
	} {
		if _, err := os.Stat(path); err != nil {
			return fmt.Errorf("%s not found at %s (rebuild with `make build-image` / re-run `skystack vm setup`)", label, path)
		}
	}
	return nil
}
