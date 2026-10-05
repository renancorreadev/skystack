// Package certs manages the SkyStack local Certificate Authority used for
// HTTPS on *.sky.local. The CA is generated on the Mac, trusted in the macOS
// Keychain, and pushed (cert+key) into the guest VM, where the agent mints
// short-lived per-host leaf certificates in memory.
//
// The CA carries a name constraint limiting it to the sky.local domain, so even
// if its private key leaked it could not be used to forge certificates for any
// other site — a deliberate blast-radius limit for a system-trusted root.
package certs

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

// CAName is the CA's common name (also used to find it in the Keychain).
const CAName = "SkyStack Local CA"

// Domain is the only DNS domain this CA is permitted to certify.
const Domain = "sky.local"

// CertPath / KeyPath are the on-disk locations within the CA dir.
func CertPath(dir string) string { return filepath.Join(dir, "ca.crt") }
func KeyPath(dir string) string  { return filepath.Join(dir, "ca.key") }

// EnsureCA generates the local CA into dir if it does not already exist. It is
// idempotent: an existing, parseable CA is left untouched. Returns the cert path.
func EnsureCA(dir string) (string, error) {
	certPath, keyPath := CertPath(dir), KeyPath(dir)
	if _, err := os.Stat(certPath); err == nil {
		if _, err := os.Stat(keyPath); err == nil {
			return certPath, nil // already present
		}
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return "", err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: CAName, Organization: []string{"SkyStack"}},
		NotBefore:             now.Add(-1 * time.Hour),
		NotAfter:              now.AddDate(10, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
		// Limit this trusted root to sky.local only (blast-radius control).
		PermittedDNSDomains: []string{Domain},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return "", err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return "", err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return "", err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return "", err
	}
	return certPath, nil
}

// Bundle returns the concatenated cert+key PEM (the wire format pushed to the
// guest). EnsureCA must have run first.
func Bundle(dir string) ([]byte, error) {
	cert, err := os.ReadFile(CertPath(dir))
	if err != nil {
		return nil, fmt.Errorf("read CA cert: %w", err)
	}
	key, err := os.ReadFile(KeyPath(dir))
	if err != nil {
		return nil, fmt.Errorf("read CA key: %w", err)
	}
	return append(cert, key...), nil
}

// Exists reports whether a CA cert+key pair is present in dir.
func Exists(dir string) bool {
	if _, err := os.Stat(CertPath(dir)); err != nil {
		return false
	}
	_, err := os.Stat(KeyPath(dir))
	return err == nil
}
