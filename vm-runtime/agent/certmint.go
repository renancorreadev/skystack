package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"sync"
	"time"
)

// caSigner mints short-lived per-hostname leaf certificates signed by the
// SkyStack local CA. The CA private key it holds is delivered over vsock and
// kept ONLY in memory — it is never written to the guest's disk.
type caSigner struct {
	cert *x509.Certificate
	key  crypto.Signer

	mu    sync.Mutex
	cache map[string]*tls.Certificate
}

// parseCABundle loads a CA from concatenated PEM (a CERTIFICATE block plus a
// private-key block, in any order). Supports EC and PKCS#8 keys.
func parseCABundle(bundle []byte) (*caSigner, error) {
	var cert *x509.Certificate
	var key crypto.Signer
	rest := bundle
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		switch block.Type {
		case "CERTIFICATE":
			c, err := x509.ParseCertificate(block.Bytes)
			if err != nil {
				return nil, fmt.Errorf("parse CA certificate: %w", err)
			}
			cert = c
		case "EC PRIVATE KEY":
			k, err := x509.ParseECPrivateKey(block.Bytes)
			if err != nil {
				return nil, fmt.Errorf("parse EC key: %w", err)
			}
			key = k
		case "PRIVATE KEY":
			k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
			if err != nil {
				return nil, fmt.Errorf("parse PKCS#8 key: %w", err)
			}
			signer, ok := k.(crypto.Signer)
			if !ok {
				return nil, errors.New("CA key is not a signer")
			}
			key = signer
		case "RSA PRIVATE KEY":
			k, err := x509.ParsePKCS1PrivateKey(block.Bytes)
			if err != nil {
				return nil, fmt.Errorf("parse RSA key: %w", err)
			}
			key = k
		}
	}
	if cert == nil || key == nil {
		return nil, errors.New("CA bundle missing certificate or private key")
	}
	if !cert.IsCA {
		return nil, errors.New("provided certificate is not a CA")
	}
	return &caSigner{cert: cert, key: key, cache: map[string]*tls.Certificate{}}, nil
}

// leafFor returns (minting and caching on first use) a leaf certificate for the
// given hostname, signed by the CA. Leaves are valid for ~13 months to satisfy
// macOS' maximum-leaf-lifetime rule for TLS server certs.
func (c *caSigner) leafFor(host string) (*tls.Certificate, error) {
	if host == "" {
		return nil, errors.New("empty SNI host")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if t, ok := c.cache[host]; ok {
		return t, nil
	}

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		NotBefore:    now.Add(-1 * time.Hour),
		NotAfter:     now.Add(390 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.cert, &priv.PublicKey, c.key)
	if err != nil {
		return nil, err
	}
	leaf := &tls.Certificate{
		Certificate: [][]byte{der}, // root is trusted locally → no need to send it
		PrivateKey:  priv,
	}
	c.cache[host] = leaf
	return leaf, nil
}
