//go:build linux

package main

import (
	"io"
	"log"
	"sync"
	"time"

	"github.com/mdlayher/vsock"
)

// caStore holds the local CA signer once the host pushes it over vsock. It is
// shared between serveCA (writer) and the HTTPS proxy (reader). The CA private
// key lives ONLY here, in memory — it is never written to the guest's disk.
type caStore struct {
	mu     sync.RWMutex
	signer *caSigner
}

func (s *caStore) set(sg *caSigner) {
	s.mu.Lock()
	s.signer = sg
	s.mu.Unlock()
}

func (s *caStore) get() *caSigner {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.signer
}

// serveCA listens on a vsock port for the host (SkyVM) to push the SkyStack
// local CA as concatenated cert+key PEM. Each successful delivery installs the
// in-memory signer the HTTPS proxy uses to mint per-host leaf certificates.
func serveCA(port uint32, store *caStore) {
	ln, err := vsock.Listen(port, nil)
	if err != nil {
		log.Printf("ca: vsock listen on port %d failed: %v", port, err)
		return
	}
	defer ln.Close()
	log.Printf("ca channel on vsock port %d", port)

	for {
		conn, err := ln.Accept()
		if err != nil {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		func() {
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
			data, err := io.ReadAll(conn)
			if err != nil || len(data) == 0 {
				log.Printf("ca: read bundle: %v", err)
				return
			}
			sg, err := parseCABundle(data)
			if err != nil {
				log.Printf("ca: parse bundle: %v", err)
				return
			}
			store.set(sg)
			log.Printf("ca: loaded local CA %q — HTTPS proxy ready", sg.cert.Subject.CommonName)
		}()
	}
}
