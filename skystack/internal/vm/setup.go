package vm

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/skynance/skystack/internal/config"
)

// SetupOptions configures `skystack vm setup`.
type SetupOptions struct {
	RuntimeDir string // path to the vm-runtime directory (auto-detected if empty)
	Binary     string // explicit SkyVM binary (overrides RuntimeDir derivation)
	Assets     string // explicit assets dir (overrides RuntimeDir derivation)
	CPUs       int
	MemoryGiB  int
	Share      string // Mac dir to mirror into the guest; "" → user home; "-" → disable
	Verbose    bool
	Sign       bool // ad-hoc sign the binary with the virtualization entitlement
}

// Setup locates the SkyVM binary and image assets, optionally signs the binary,
// validates everything, and persists the runtime config.
func Setup(opts SetupOptions) (*Runtime, error) {
	dir := opts.RuntimeDir
	if dir == "" {
		dir = detectRuntimeDir()
	}

	binary := opts.Binary
	if binary == "" && dir != "" {
		binary = filepath.Join(dir, ".build", "release", "SkyVM")
	}
	assets := opts.Assets
	if assets == "" {
		// Prefer a freshly built tree; else an image installed via
		// `vm install-image` (~/.skystack/assets) — the Docker-free path.
		if dir != "" && hasImage(filepath.Join(dir, "assets")) {
			assets = filepath.Join(dir, "assets")
		} else if a, err := config.AssetsDir(); err == nil && hasImage(a) {
			assets = a
		} else if dir != "" {
			assets = filepath.Join(dir, "assets") // Validate() will give a helpful error
		}
	}
	if binary == "" || assets == "" {
		return nil, fmt.Errorf("could not locate the SkyVM runtime — install a pre-built image with `skystack vm install-image <bundle>`, or pass --runtime/--binary/--assets")
	}
	binary, _ = filepath.Abs(binary)
	assets, _ = filepath.Abs(assets)

	if opts.Sign {
		ent := filepath.Join(dir, "SkyVM.entitlements")
		if _, err := os.Stat(ent); err != nil {
			return nil, fmt.Errorf("entitlements file not found at %s (needed for --sign)", ent)
		}
		if err := sign(binary, ent); err != nil {
			return nil, fmt.Errorf("signing SkyVM: %w", err)
		}
	}

	share := opts.Share
	switch share {
	case "":
		share, _ = os.UserHomeDir() // mirror the Mac home by default
	case "-":
		share = "" // explicitly disabled
	default:
		share, _ = filepath.Abs(share)
		if !fileExistsDir(share) {
			return nil, fmt.Errorf("share directory not found: %s", share)
		}
	}

	rt := &Runtime{
		Binary:    binary,
		Assets:    assets,
		CPUs:      opts.CPUs,
		MemoryGiB: opts.MemoryGiB,
		Share:     share,
		Verbose:   opts.Verbose,
	}
	if err := rt.Validate(); err != nil {
		return nil, err
	}
	if err := rt.Save(); err != nil {
		return nil, err
	}
	return rt, nil
}

// detectRuntimeDir walks up from the cwd looking for a vm-runtime directory.
func detectRuntimeDir() string {
	cwd, err := os.Getwd()
	if err != nil {
		return ""
	}
	for d := cwd; ; d = filepath.Dir(d) {
		// cwd is itself the vm-runtime dir
		if filepath.Base(d) == "vm-runtime" && fileExists(filepath.Join(d, "Package.swift")) {
			return d
		}
		// a vm-runtime subdirectory
		cand := filepath.Join(d, "vm-runtime")
		if fileExists(filepath.Join(cand, "Package.swift")) {
			return cand
		}
		parent := filepath.Dir(d)
		if parent == d {
			return ""
		}
	}
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

// hasImage reports whether dir holds a complete guest image.
func hasImage(dir string) bool {
	for _, f := range imageFiles {
		if !fileExists(filepath.Join(dir, f)) {
			return false
		}
	}
	return true
}

func fileExistsDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func sign(binary, entitlements string) error {
	cmd := exec.Command("codesign", "--entitlements", entitlements, "--sign", "-", "--force", binary)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%v: %s", err, string(out))
	}
	return nil
}

// autoReSign re-applies the ad-hoc virtualization signature by locating
// SkyVM.entitlements near the binary — self-healing after a rebuild strips it
// (the binary lives under .build/, which any `swift build` regenerates unsigned).
func autoReSign(binary string) error {
	for d := filepath.Dir(binary); ; {
		ent := filepath.Join(d, "SkyVM.entitlements")
		if fileExists(ent) {
			return sign(binary, ent)
		}
		parent := filepath.Dir(d)
		if parent == d {
			return fmt.Errorf("SkyVM.entitlements not found near %s", binary)
		}
		d = parent
	}
}
