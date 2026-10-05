package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

// testCABundle builds a self-signed CA and returns it as a concatenated
// cert+key PEM bundle (the wire format the host pushes over vsock).
func testCABundle(t *testing.T) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "SkyStack Test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	var out []byte
	out = append(out, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})...)
	out = append(out, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})...)
	return out
}

func TestParseCABundleAndMint(t *testing.T) {
	bundle := testCABundle(t)
	ca, err := parseCABundle(bundle)
	if err != nil {
		t.Fatalf("parseCABundle: %v", err)
	}

	leaf, err := ca.leafFor("web.sky.local")
	if err != nil {
		t.Fatalf("leafFor: %v", err)
	}
	parsed, err := x509.ParseCertificate(leaf.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.DNSNames) != 1 || parsed.DNSNames[0] != "web.sky.local" {
		t.Fatalf("leaf DNSNames = %v", parsed.DNSNames)
	}

	// The leaf must verify against the CA.
	roots := x509.NewCertPool()
	roots.AddCert(ca.cert)
	if _, err := parsed.Verify(x509.VerifyOptions{Roots: roots, DNSName: "web.sky.local"}); err != nil {
		t.Fatalf("leaf does not chain to CA: %v", err)
	}

	// Second call must return the cached identical certificate.
	leaf2, _ := ca.leafFor("web.sky.local")
	if leaf2 != leaf {
		t.Fatalf("leafFor did not cache")
	}
}

func TestParseCABundleRejectsNonCA(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "leaf"}, NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
	der, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	keyDER, _ := x509.MarshalECPrivateKey(key)
	var bundle []byte
	bundle = append(bundle, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})...)
	bundle = append(bundle, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})...)
	if _, err := parseCABundle(bundle); err == nil {
		t.Fatal("expected non-CA certificate to be rejected")
	}
}
