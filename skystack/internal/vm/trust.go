package vm

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/skynance/skystack/internal/certs"
	"github.com/skynance/skystack/internal/config"
)

// systemKeychain is where a system-wide trusted root must live for Safari/Chrome
// to honor it. Writing trust settings there requires admin (sudo) rights.
const systemKeychain = "/Library/Keychains/System.keychain"

// EnsureCA generates the local HTTPS CA if it does not exist yet. No privileges
// required — it only writes under ~/.skystack/ca.
func EnsureCA() (string, error) {
	dir, err := config.CADir()
	if err != nil {
		return "", err
	}
	return certs.EnsureCA(dir)
}

// CAExists reports whether the local CA cert+key has been generated.
func CAExists() bool {
	dir, err := config.CADir()
	if err != nil {
		return false
	}
	return certs.Exists(dir)
}

// CATrusted reports whether the SkyStack CA is present in the system keychain.
func CATrusted() bool {
	dir, err := config.CADir()
	if err != nil || !certs.Exists(dir) {
		return false
	}
	// `find-certificate -c <name>` exits 0 only if a matching cert is present.
	return exec.Command("security", "find-certificate", "-c", certs.CAName, systemKeychain).Run() == nil
}

// TrustCA adds the local CA to the macOS system keychain as a trusted root, so
// browsers accept https://*.sky.local. Uses one sudo invocation (the install
// flow already prompts for a password, so this reuses the cached credential).
func TrustCA() error {
	dir, err := config.CADir()
	if err != nil {
		return err
	}
	if _, err := certs.EnsureCA(dir); err != nil {
		return err
	}
	cert := certs.CertPath(dir)
	if _, err := os.Stat(cert); err != nil {
		return fmt.Errorf("CA certificate missing at %s", cert)
	}
	// -d: admin (system) cert store · -r trustRoot: trust as a root for SSL.
	return runSudo("security", "add-trusted-cert", "-d", "-r", "trustRoot",
		"-k", systemKeychain, cert)
}

// UntrustCA removes the local CA from the system keychain (best-effort).
func UntrustCA() error {
	dir, err := config.CADir()
	if err != nil {
		return err
	}
	cert := certs.CertPath(dir)
	if _, err := os.Stat(cert); err != nil {
		return nil // nothing trusted (no cert on disk)
	}
	if !CATrusted() {
		return nil
	}
	return runSudo("security", "remove-trusted-cert", "-d", cert)
}
