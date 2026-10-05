package vm

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/skynance/skystack/internal/certs"
	"github.com/skynance/skystack/internal/config"
)

// BinDir is the stable, build-immune home for the signed SkyVM executable.
func BinDir() (string, error) {
	d, err := config.Dir()
	if err != nil {
		return "", err
	}
	b := filepath.Join(d, "bin")
	return b, os.MkdirAll(b, 0o755)
}

// BinaryInstalled reports whether the stable SkyVM binary is in place.
func BinaryInstalled() bool {
	b, err := BinDir()
	if err != nil {
		return false
	}
	return fileExists(filepath.Join(b, "SkyVM"))
}

// InstallBinary copies the SkyVM executable + its entitlements into a stable,
// signed location (~/.skystack/bin) that `swift build` never regenerates, signs
// the copy with the virtualization entitlement, and repoints runtime.json at it.
// This closes the long-standing robustness gap: the VM keeps working after the
// repo is rebuilt, moved, or deleted (autoReSign still finds the entitlements
// sitting next to the stable binary).
func InstallBinary() (string, error) {
	rt, err := LoadRuntime()
	if err != nil || rt == nil || rt.Binary == "" {
		// No runtime yet — try to detect one (build tree or installed image).
		r, serr := Setup(SetupOptions{})
		if serr != nil {
			return "", fmt.Errorf("no SkyVM configured — run `skystack vm setup` first (%w)", serr)
		}
		rt = r
	}

	bin, err := BinDir()
	if err != nil {
		return "", err
	}
	dstBin := filepath.Join(bin, "SkyVM")
	dstEnt := filepath.Join(bin, "SkyVM.entitlements")

	// If the runtime already points at the stable copy, just re-sign in place.
	src := rt.Binary
	ent := findEntitlements(src)
	if ent == "" {
		// Already-installed binary keeps its entitlements beside it.
		if fileExists(dstEnt) {
			ent = dstEnt
		} else {
			return "", fmt.Errorf("SkyVM.entitlements not found near %s", src)
		}
	}

	if filepath.Clean(src) != filepath.Clean(dstBin) {
		if err := copyFile(src, dstBin, 0o755); err != nil {
			return "", fmt.Errorf("copy SkyVM: %w", err)
		}
	}
	if filepath.Clean(ent) != filepath.Clean(dstEnt) {
		if err := copyFile(ent, dstEnt, 0o644); err != nil {
			return "", fmt.Errorf("copy entitlements: %w", err)
		}
	}
	if err := sign(dstBin, dstEnt); err != nil {
		return "", fmt.Errorf("sign stable SkyVM: %w", err)
	}

	rt.Binary = dstBin
	if err := rt.Save(); err != nil {
		return "", err
	}
	return dstBin, nil
}

// InstallFrom seeds a fresh machine from explicit artifacts (the .pkg payload):
// installs the guest image bundle, copies + signs the SkyVM binary into the
// stable location, and writes runtime.json — no build tree or prior config
// needed. Returns the stable binary path.
func InstallFrom(srcBinary, srcEnt, imageBundle string) (string, error) {
	if imageBundle != "" {
		if _, err := InstallImage(imageBundle); err != nil {
			return "", fmt.Errorf("install image: %w", err)
		}
	}
	assets, err := config.AssetsDir()
	if err != nil {
		return "", err
	}
	bin, err := BinDir()
	if err != nil {
		return "", err
	}
	dstBin := filepath.Join(bin, "SkyVM")
	dstEnt := filepath.Join(bin, "SkyVM.entitlements")
	if err := copyFile(srcBinary, dstBin, 0o755); err != nil {
		return "", fmt.Errorf("copy SkyVM: %w", err)
	}
	if err := copyFile(srcEnt, dstEnt, 0o644); err != nil {
		return "", fmt.Errorf("copy entitlements: %w", err)
	}
	if err := sign(dstBin, dstEnt); err != nil {
		return "", fmt.Errorf("sign stable SkyVM: %w", err)
	}
	home, _ := os.UserHomeDir()
	rt := &Runtime{Binary: dstBin, Assets: assets, Share: home}
	if err := rt.Validate(); err != nil {
		return "", err
	}
	if err := rt.Save(); err != nil {
		return "", err
	}
	return dstBin, nil
}

// findEntitlements walks up from the binary looking for SkyVM.entitlements
// (mirrors autoReSign's search).
func findEntitlements(binary string) string {
	for d := filepath.Dir(binary); ; {
		ent := filepath.Join(d, "SkyVM.entitlements")
		if fileExists(ent) {
			return ent
		}
		parent := filepath.Dir(d)
		if parent == d {
			return ""
		}
		d = parent
	}
}

// InstallHelperAsRoot performs the privileged setup directly, WITHOUT sudo —
// for the .pkg postinstall, which already runs as root. `username` owns the
// passwordless route rule; `caDir` is that user's ~/.skystack/ca (for CA trust).
// The terminal flow uses InstallHelper() (interactive sudo) instead.
func InstallHelperAsRoot(username, caDir string) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("InstallHelperAsRoot must run as root")
	}
	// 1) least-privilege sudoers drop-in (validated before install).
	content := fmt.Sprintf(`# SkyStack — passwordless route management for the container subnet only.
# Installed by the SkyStack installer; remove with 'skystack vm uninstall-helper'.
%[1]s ALL=(root) NOPASSWD: %[2]s -n add -net %[3]s *
%[1]s ALL=(root) NOPASSWD: %[2]s -n delete -net %[3]s
`, username, routeBin, ContainerSubnet)
	tmp, err := os.CreateTemp("", "skystack-sudoers-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()
	if out, err := exec.Command("visudo", "-cf", tmp.Name()).CombinedOutput(); err != nil {
		return fmt.Errorf("sudoers validation failed (not installed): %v: %s", err, out)
	}
	if err := exec.Command("install", "-m", "0440", "-o", "root", "-g", "wheel", tmp.Name(), helperPath).Run(); err != nil {
		return fmt.Errorf("install sudoers: %w", err)
	}

	// 2) /etc/resolver/<Domain> → our localhost DNS forwarder.
	if err := os.MkdirAll("/etc/resolver", 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(resolverPath, []byte(fmt.Sprintf("nameserver 127.0.0.1\nport %s\n", dnsPort)), 0o644); err != nil {
		return fmt.Errorf("install resolver: %w", err)
	}

	// 3) trust the local CA in the System keychain (if it has been generated).
	cert := certs.CertPath(caDir)
	if _, err := os.Stat(cert); err == nil {
		if out, err := exec.Command("security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k", systemKeychain, cert).CombinedOutput(); err != nil {
			return fmt.Errorf("trust CA: %v: %s", err, out)
		}
	}
	return nil
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Chmod(dst, mode)
}
