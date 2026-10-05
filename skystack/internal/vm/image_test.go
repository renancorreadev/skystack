package vm

import (
	"archive/tar"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"
)

// makeBundle writes a .tar.gz containing the given name→content files and
// returns its path.
func makeBundle(t *testing.T, dir string, files map[string]string) string {
	t.Helper()
	path := filepath.Join(dir, "bundle.tar.gz")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	tw.Close()
	gz.Close()
	return path
}

func TestInstallImageRoundTrip(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	src := t.TempDir()
	bundle := makeBundle(t, src, map[string]string{
		"vmlinux":        "KERNEL",
		"initramfs.gz":   "INITRD",
		"rootfs.ext4":    "ROOTFS",
		"IMAGE_INFO.txt": "meta",
		"evil/../etc":    "should-be-skipped",
	})

	assets, err := InstallImage(bundle)
	if err != nil {
		t.Fatalf("InstallImage: %v", err)
	}
	for name, want := range map[string]string{"vmlinux": "KERNEL", "initramfs.gz": "INITRD", "rootfs.ext4": "ROOTFS"} {
		got, err := os.ReadFile(filepath.Join(assets, name))
		if err != nil || string(got) != want {
			t.Fatalf("%s = %q (err %v), want %q", name, got, err, want)
		}
	}
	// The path-traversal entry must not have escaped the assets dir.
	if _, err := os.Stat(filepath.Join(assets, "etc")); err == nil {
		t.Fatal("path-traversal entry was extracted")
	}

	// Re-installing over an existing image must succeed (atomic swap).
	if _, err := InstallImage(bundle); err != nil {
		t.Fatalf("re-install: %v", err)
	}
}

func TestInstallImageChecksumMismatch(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	src := t.TempDir()
	bundle := makeBundle(t, src, map[string]string{
		"vmlinux": "K", "initramfs.gz": "I", "rootfs.ext4": "R",
	})
	if err := os.WriteFile(bundle+".sha256", []byte("deadbeef  bundle.tar.gz\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := InstallImage(bundle); err == nil {
		t.Fatal("expected checksum mismatch to fail the install")
	}
}

func TestInstallImageRejectsIncompleteBundle(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	src := t.TempDir()
	bundle := makeBundle(t, src, map[string]string{"vmlinux": "K"}) // missing initramfs + rootfs
	if _, err := InstallImage(bundle); err == nil {
		t.Fatal("expected install to reject a bundle missing image files")
	}
}
