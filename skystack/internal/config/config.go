// Package config manages the SkyStack host registry: the set of Docker hosts
// (local + remote over SSH) that the CLI and core daemon operate against.
//
// The registry lives at ~/.skystack/hosts.yaml. The "local" host is implicit
// and always available; it is never written to the file.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// LocalHost is the reserved name for the machine's own Docker engine.
const LocalHost = "local"

// LocalHost / SkyVMHost are the reserved, built-in host names.
const (
	SkyVMHost = "skyvm"
)

// Host describes a single Docker endpoint.
type Host struct {
	// Name is the short identifier used in container refs like "prod/api".
	Name string `yaml:"-"`
	// SSH is a docker SSH URL (ssh://user@host[:port]) for remote hosts.
	// Empty means the local engine (unix socket / DOCKER_HOST).
	SSH string `yaml:"ssh,omitempty"`
	// Docker is an explicit Docker endpoint URL (e.g. unix:///path, tcp://host).
	// Used by the built-in skyvm host to reach the in-VM engine. Takes
	// precedence over SSH/local when set.
	Docker string `yaml:"docker,omitempty"`
	// Description is an optional human label shown in `skystack hosts`.
	Description string `yaml:"description,omitempty"`
}

// IsLocal reports whether the host targets the local engine (DOCKER_HOST/socket).
func (h Host) IsLocal() bool { return h.SSH == "" && h.Docker == "" }

// IsSkyVM reports whether this is the built-in local Linux VM host.
func (h Host) IsSkyVM() bool { return h.Name == SkyVMHost }

// Registry is the persisted set of named hosts.
type Registry struct {
	Hosts map[string]*Host `yaml:"hosts"`
	path  string
}

// Dir returns the SkyStack state directory (~/.skystack).
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".skystack"), nil
}

// DefaultPath returns ~/.skystack/hosts.yaml.
func DefaultPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "hosts.yaml"), nil
}

// SkyVMSocketPath returns the unix socket the running SkyVM exposes the in-VM
// Docker engine on (~/.skystack/skyvm-docker.sock).
func SkyVMSocketPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "skyvm-docker.sock"), nil
}

// AssetsDir returns ~/.skystack/assets, where a pre-built guest image
// (vmlinux + initramfs.gz + rootfs.ext4) is installed via `vm install-image`.
// This lets a Mac with no vm-runtime build tree (and no Docker) run the VM.
func AssetsDir() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "assets"), nil
}

// CADir returns ~/.skystack/ca, holding the local HTTPS Certificate Authority
// (ca.crt + ca.key) used for *.sky.local TLS.
func CADir() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "ca"), nil
}

// RuntimeConfigPath returns ~/.skystack/runtime.json (present once the local VM
// runtime has been set up via `skystack vm setup`).
func RuntimeConfigPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "runtime.json"), nil
}

// NetStatePath returns ~/.skystack/skyvm-net.json, where the running SkyVM
// publishes the guest's (DHCP-assigned) IP and forwarded ports.
func NetStatePath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "skyvm-net.json"), nil
}

// skyVMHost builds the built-in skyvm host pointing at the VM's docker socket.
func skyVMHost() (*Host, error) {
	sock, err := SkyVMSocketPath()
	if err != nil {
		return nil, err
	}
	return &Host{Name: SkyVMHost, Docker: "unix://" + sock, Description: "local Linux VM"}, nil
}

// skyVMInstalled reports whether the VM runtime has been set up.
func skyVMInstalled() bool {
	p, err := RuntimeConfigPath()
	if err != nil {
		return false
	}
	_, err = os.Stat(p)
	return err == nil
}

// Load reads the registry from path, creating an empty one if missing.
func Load(path string) (*Registry, error) {
	r := &Registry{Hosts: map[string]*Host{}, path: path}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return r, nil
	}
	if err != nil {
		return nil, err
	}
	if err := yaml.Unmarshal(data, r); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	if r.Hosts == nil {
		r.Hosts = map[string]*Host{}
	}
	for name, h := range r.Hosts {
		h.Name = name
	}
	r.path = path
	return r, nil
}

// Save writes the registry back to disk (0600, since it can hold SSH targets).
func (r *Registry) Save() error {
	if err := os.MkdirAll(filepath.Dir(r.path), 0o700); err != nil {
		return err
	}
	data, err := yaml.Marshal(r)
	if err != nil {
		return err
	}
	return os.WriteFile(r.path, data, 0o600)
}

// Get resolves a host by name. "local" (or empty) returns the implicit local
// host without requiring it to be registered.
func (r *Registry) Get(name string) (*Host, error) {
	if name == "" || name == LocalHost {
		return &Host{Name: LocalHost}, nil
	}
	if name == SkyVMHost {
		return skyVMHost()
	}
	h, ok := r.Hosts[name]
	if !ok {
		return nil, fmt.Errorf("unknown host %q (run `skystack connect %s ssh://user@host` to add it)", name, name)
	}
	return h, nil
}

// Add registers (or overwrites) a remote host.
func (r *Registry) Add(name, sshURL, desc string) error {
	if name == LocalHost {
		return fmt.Errorf("%q is reserved for the local engine", LocalHost)
	}
	if !strings.HasPrefix(sshURL, "ssh://") {
		return fmt.Errorf("host URL must start with ssh:// (got %q)", sshURL)
	}
	r.Hosts[name] = &Host{Name: name, SSH: sshURL, Description: desc}
	return nil
}

// Remove deletes a host from the registry.
func (r *Registry) Remove(name string) error {
	if _, ok := r.Hosts[name]; !ok {
		return fmt.Errorf("unknown host %q", name)
	}
	delete(r.Hosts, name)
	return nil
}

// All returns every host: local first, then the skyvm runtime (if installed),
// then registered remotes sorted by name.
func (r *Registry) All() []*Host {
	out := []*Host{{Name: LocalHost}}
	if skyVMInstalled() {
		if h, err := skyVMHost(); err == nil {
			out = append(out, h)
		}
	}
	names := make([]string, 0, len(r.Hosts))
	for n := range r.Hosts {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		out = append(out, r.Hosts[n])
	}
	return out
}

// ParseRef splits a container reference of the form "[host/]container" into its
// host and container parts. A missing host defaults to "local".
func ParseRef(ref string) (host, container string) {
	if i := strings.Index(ref, "/"); i >= 0 {
		return ref[:i], ref[i+1:]
	}
	return LocalHost, ref
}
