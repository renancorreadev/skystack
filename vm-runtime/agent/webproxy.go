//go:build linux

package main

import (
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"strings"
	"sync"
	"time"
)

// serveProxy runs the local reverse proxy that makes <name>.sky.local work over
// both HTTP (:80) and HTTPS (:443). DNS points every *.sky.local name at THIS
// guest's IP, so all ingress lands here; the proxy then routes by Host/SNI to
// the matching container's HTTP port. TLS is terminated with per-host leaf
// certificates minted on the fly from the CA in `store`.
func serveProxy(dockerSock string, store *caStore, poll time.Duration) {
	reg := &proxyRegistry{}
	go reg.poll(dockerSock, poll)

	rp := &httputil.ReverseProxy{
		Director: func(r *http.Request) {
			r.URL.Scheme = "http"
			if route, ok := reg.lookup(hostOnly(r.Host)); ok {
				r.URL.Host = fmt.Sprintf("%s:%d", route.IP.String(), route.Port)
				if r.Header.Get("X-Forwarded-Host") == "" {
					r.Header.Set("X-Forwarded-Host", r.Host)
				}
				r.Header.Set("X-Forwarded-Proto", proto(r))
			} else {
				r.URL.Host = "127.0.0.1:1" // unroutable → ErrorHandler returns 502
			}
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "skystack: no route to "+hostOnly(r.Host)+"\n", http.StatusBadGateway)
		},
		FlushInterval: 100 * time.Millisecond,
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := reg.lookup(hostOnly(r.Host)); !ok {
			http.Error(w, "skystack: unknown host "+hostOnly(r.Host)+" (no such container)\n", http.StatusBadGateway)
			return
		}
		rp.ServeHTTP(w, r)
	})

	// HTTP :80 — keep plain http://<name>.sky.local working, port-aware.
	go func() {
		srv := &http.Server{Addr: ":80", Handler: handler, ReadHeaderTimeout: 10 * time.Second}
		if err := srv.ListenAndServe(); err != nil {
			log.Printf("proxy: http :80: %v", err)
		}
	}()

	// HTTPS :443 — terminate TLS with leaf certs minted per SNI host.
	go func() {
		tlsCfg := &tls.Config{
			MinVersion:     tls.VersionTLS12,
			GetCertificate: store.getCertificate,
		}
		ln, err := tls.Listen("tcp", ":443", tlsCfg)
		if err != nil {
			log.Printf("proxy: https :443 listen: %v", err)
			return
		}
		log.Printf("https proxy on :443 (*.sky.local)")
		srv := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second}
		if err := srv.Serve(ln); err != nil {
			log.Printf("proxy: https :443: %v", err)
		}
	}()
}

// getCertificate is the tls.Config callback: it mints (and caches) a leaf cert
// for the requested SNI host, or fails if the CA hasn't been delivered yet.
func (s *caStore) getCertificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	sg := s.get()
	if sg == nil {
		return nil, errors.New("skystack CA not loaded yet")
	}
	name := strings.ToLower(strings.TrimSuffix(hello.ServerName, "."))
	if name == "" {
		return nil, errors.New("no SNI server name")
	}
	return sg.leafFor(name)
}

// proxyRegistry holds the live name→container-target map, refreshed from Docker.
type proxyRegistry struct {
	mu     sync.RWMutex
	routes map[string]Route
}

func (r *proxyRegistry) poll(dockerSock string, poll time.Duration) {
	for {
		routes := containerRoutes(dockerSock)
		r.mu.Lock()
		r.routes = routes
		r.mu.Unlock()
		time.Sleep(poll)
	}
}

func (r *proxyRegistry) lookup(host string) (Route, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	rt, ok := r.routes[strings.ToLower(host)]
	return rt, ok
}

// containerRoutes queries the local Docker engine for the name→target map.
func containerRoutes(dockerSock string) map[string]Route {
	conn, err := net.DialTimeout("unix", dockerSock, 2*time.Second)
	if err != nil {
		return nil
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprint(conn, "GET /v1.43/containers/json HTTP/1.0\r\nHost: docker\r\n\r\n")
	data, err := io.ReadAll(conn)
	if err != nil {
		return nil
	}
	return parseContainerRoutes(data)
}

// hostOnly strips any :port from a Host header and lowercases it.
func hostOnly(h string) string {
	if host, _, err := net.SplitHostPort(h); err == nil {
		return strings.ToLower(host)
	}
	return strings.ToLower(h)
}

// proto reports the scheme the client used, for the X-Forwarded-Proto header.
func proto(r *http.Request) string {
	if r.TLS != nil {
		return "https"
	}
	return "http"
}
