package vm

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/skynance/skystack/internal/config"
)

// imageFiles are the guest image artifacts a bundle must contain.
var imageFiles = []string{"vmlinux", "initramfs.gz", "rootfs.ext4"}

// bundleAllowed is the full set of files extracted from a bundle (image files
// plus optional metadata). Anything else is ignored.
var bundleAllowed = map[string]bool{
	"vmlinux": true, "initramfs.gz": true, "rootfs.ext4": true, "IMAGE_INFO.txt": true,
}

// InstallImage installs a pre-built guest image bundle (a .tar.gz of
// vmlinux + initramfs.gz + rootfs.ext4) into ~/.skystack/assets — with NO Docker
// and no image build required. src is a local file path or an http(s) URL; when
// a "<src>.sha256" sidecar is available the bundle is checksum-verified. If a
// runtime is already set up, its Assets are repointed at the installed image.
func InstallImage(src string) (string, error) {
	assets, err := config.AssetsDir()
	if err != nil {
		return "", err
	}

	bundlePath, expectedSHA, cleanup, err := fetchBundle(src)
	if err != nil {
		return "", err
	}
	defer cleanup()

	sum, err := fileSHA256(bundlePath)
	if err != nil {
		return "", err
	}
	if expectedSHA != "" && !strings.EqualFold(sum, expectedSHA) {
		return "", fmt.Errorf("checksum mismatch — bundle is %s, expected %s (corrupt or tampered download?)", sum, expectedSHA)
	}

	// Extract into a sibling temp dir (same filesystem → atomic swap), then
	// move it into place only once it's complete and validated.
	parent := filepath.Dir(assets)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return "", err
	}
	tmpDir, err := os.MkdirTemp(parent, ".assets-*")
	if err != nil {
		return "", err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(tmpDir)
		}
	}()

	if err := extractBundle(bundlePath, tmpDir); err != nil {
		return "", err
	}
	for _, f := range imageFiles {
		if _, err := os.Stat(filepath.Join(tmpDir, f)); err != nil {
			return "", fmt.Errorf("bundle is missing %s — is this a SkyVM image bundle?", f)
		}
	}

	// Swap into place: move any existing assets aside, rename temp → assets.
	old := assets + ".old"
	_ = os.RemoveAll(old)
	if _, err := os.Stat(assets); err == nil {
		if err := os.Rename(assets, old); err != nil {
			return "", err
		}
	}
	if err := os.Rename(tmpDir, assets); err != nil {
		_ = os.Rename(old, assets) // best-effort restore
		return "", err
	}
	committed = true
	_ = os.RemoveAll(old)

	// Repoint an already-configured runtime at the freshly installed image.
	if rt, err := LoadRuntime(); err == nil {
		rt.Assets = assets
		_ = rt.Save()
	}
	return assets, nil
}

// fetchBundle resolves src to a local path. For URLs it downloads to a temp file
// (and tries the "<url>.sha256" sidecar); for local paths it reads a sibling
// "<path>.sha256" if present. cleanup removes any temp download.
func fetchBundle(src string) (path, sha string, cleanup func(), err error) {
	cleanup = func() {}
	if strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://") {
		tmp, err := os.CreateTemp("", "skyvm-image-*.tar.gz")
		if err != nil {
			return "", "", cleanup, err
		}
		tmp.Close()
		if err := download(src, tmp.Name()); err != nil {
			os.Remove(tmp.Name())
			return "", "", cleanup, err
		}
		return tmp.Name(), fetchRemoteSHA(src + ".sha256"), func() { os.Remove(tmp.Name()) }, nil
	}
	abs, _ := filepath.Abs(src)
	if fi, err := os.Stat(abs); err != nil || fi.IsDir() {
		return "", "", cleanup, fmt.Errorf("image bundle not found: %s", src)
	}
	return abs, readSidecarSHA(abs + ".sha256"), cleanup, nil
}

// download streams a URL to dest. The user supplies the URL explicitly, so this
// is an authorized, on-demand transfer (no hidden/default endpoints).
func download(url, dest string) error {
	client := &http.Client{Timeout: 30 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: HTTP %d", url, resp.StatusCode)
	}
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, resp.Body)
	return err
}

// extractBundle unpacks the allowlisted files from a .tar.gz into dest. It never
// writes outside dest: only base-named, allowlisted regular files are extracted.
func extractBundle(bundle, dest string) error {
	f, err := os.Open(bundle)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("not a gzip bundle: %w", err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		name := filepath.Base(h.Name)
		if strings.Contains(h.Name, "..") || !bundleAllowed[name] {
			continue
		}
		out, err := os.Create(filepath.Join(dest, name))
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, tr); err != nil {
			out.Close()
			return err
		}
		out.Close()
	}
	return nil
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// readSidecarSHA returns the hex digest from a "<file>.sha256" file (shasum
// format: "<hex>  <name>"), or "" if absent/unreadable.
func readSidecarSHA(p string) string {
	data, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return firstField(string(data))
}

// fetchRemoteSHA fetches a ".sha256" sidecar over HTTP (best-effort).
func fetchRemoteSHA(url string) string {
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return ""
	}
	return firstField(string(data))
}

func firstField(s string) string {
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return ""
	}
	return strings.ToLower(fields[0])
}
