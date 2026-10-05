package certs

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"testing"
	"time"
)

func TestEnsureCAIdempotentAndConstrained(t *testing.T) {
	dir := t.TempDir()
	if _, err := EnsureCA(dir); err != nil {
		t.Fatalf("EnsureCA: %v", err)
	}
	if !Exists(dir) {
		t.Fatal("CA should exist after EnsureCA")
	}
	// Idempotent: second call leaves the key file byte-identical.
	before, _ := os.ReadFile(KeyPath(dir))
	if _, err := EnsureCA(dir); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(KeyPath(dir))
	if string(before) != string(after) {
		t.Fatal("EnsureCA regenerated an existing CA")
	}
	// Key file must be private (0600).
	if fi, _ := os.Stat(KeyPath(dir)); fi.Mode().Perm() != 0o600 {
		t.Fatalf("CA key perms = %v, want 0600", fi.Mode().Perm())
	}

	ca := parseCA(t, dir)
	if !ca.IsCA {
		t.Fatal("certificate is not a CA")
	}
	if len(ca.PermittedDNSDomains) != 1 || ca.PermittedDNSDomains[0] != Domain {
		t.Fatalf("name constraints = %v, want [%s]", ca.PermittedDNSDomains, Domain)
	}
}

// TestNameConstraintEnforced proves the constraint actually limits the CA: a
// leaf for sky.local verifies, but one for an outside domain does not.
func TestNameConstraintEnforced(t *testing.T) {
	dir := t.TempDir()
	if _, err := EnsureCA(dir); err != nil {
		t.Fatal(err)
	}
	ca := parseCA(t, dir)
	caKey := parseCAKey(t, dir)
	roots := x509.NewCertPool()
	roots.AddCert(ca)

	if _, err := signLeaf(t, ca, caKey, "web.sky.local").Verify(x509.VerifyOptions{Roots: roots, DNSName: "web.sky.local"}); err != nil {
		t.Fatalf("in-domain leaf should verify: %v", err)
	}
	if _, err := signLeaf(t, ca, caKey, "evil.example.com").Verify(x509.VerifyOptions{Roots: roots, DNSName: "evil.example.com"}); err == nil {
		t.Fatal("out-of-domain leaf must be rejected by the name constraint")
	}
}

func TestBundleRoundTrips(t *testing.T) {
	dir := t.TempDir()
	if _, err := EnsureCA(dir); err != nil {
		t.Fatal(err)
	}
	bundle, err := Bundle(dir)
	if err != nil {
		t.Fatal(err)
	}
	var sawCert, sawKey bool
	rest := bundle
	for {
		var b *pem.Block
		b, rest = pem.Decode(rest)
		if b == nil {
			break
		}
		switch b.Type {
		case "CERTIFICATE":
			sawCert = true
		case "EC PRIVATE KEY":
			sawKey = true
		}
	}
	if !sawCert || !sawKey {
		t.Fatalf("bundle missing parts: cert=%v key=%v", sawCert, sawKey)
	}
}

func parseCA(t *testing.T, dir string) *x509.Certificate {
	t.Helper()
	data, _ := os.ReadFile(CertPath(dir))
	block, _ := pem.Decode(data)
	c, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func parseCAKey(t *testing.T, dir string) *ecdsa.PrivateKey {
	t.Helper()
	data, _ := os.ReadFile(KeyPath(dir))
	block, _ := pem.Decode(data)
	k, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func signLeaf(t *testing.T, ca *x509.Certificate, caKey *ecdsa.PrivateKey, name string) *x509.Certificate {
	t.Helper()
	leafKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	return leaf
}
