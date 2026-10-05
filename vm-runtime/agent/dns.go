//go:build linux

package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

// serveDNS answers A queries for *.sky.local. Every known name resolves to THIS
// guest's IP (the reverse proxy's ingress on :80/:443), which the proxy then
// routes by Host/SNI to the right container. The name set is refreshed from
// Docker in the background; unknown names get NXDOMAIN.
func serveDNS(dockerSock, iface string, poll time.Duration) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 53})
	if err != nil {
		log.Printf("dns: listen :53 failed: %v", err)
		return
	}
	defer conn.Close()
	log.Printf("dns serving *%s on :53 → proxy ingress", DomainSuffix)

	var (
		mu      sync.RWMutex
		domains = map[string]net.IP{}
	)
	go func() {
		for {
			d := containerDomains(dockerSock)
			mu.Lock()
			domains = d
			mu.Unlock()
			time.Sleep(poll)
		}
	}()

	buf := make([]byte, 512)
	for {
		n, client, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		query := make([]byte, n)
		copy(query, buf[:n])
		go func() {
			name, qtype, err := parseQuestion(query)
			var ip net.IP
			known := false
			if err == nil && strings.HasSuffix(name, K8sDomainSuffix) {
				// Any *.k8s.sky.local → this guest (the Kubernetes ingress).
				known = true
				if qtype == dnsTypeA {
					if gip := primaryIP(iface); gip != "" {
						ip = net.ParseIP(gip)
					}
				}
			} else if err == nil && strings.HasSuffix(name, DomainSuffix) {
				mu.RLock()
				containerIP, ok := domains[name]
				mu.RUnlock()
				known = ok
				if known && qtype == dnsTypeA {
					// Resolve to the proxy ingress (this guest). Fall back to the
					// raw container IP if the guest IP isn't up yet.
					if gip := primaryIP(iface); gip != "" {
						ip = net.ParseIP(gip)
					} else {
						ip = containerIP
					}
				}
				// qtype != A on a known name → ip stays nil → NODATA.
			}
			_, _ = conn.WriteToUDP(buildAnswer(query, ip, !known), client)
		}()
	}
}

// containerDomains builds the {<name>.sky.local → ip, <service>.<project>.sky.local
// → ip} map from the local Docker engine.
func containerDomains(dockerSock string) map[string]net.IP {
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
	return parseContainerDomains(data)
}
