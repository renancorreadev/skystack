//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"time"

	"github.com/mdlayher/vsock"
)

// serveNetInfo streams guest network state (IP + published ports) to the host
// over vsock, so the host can set up localhost→guest port forwards. It sends an
// update on connect and whenever the published-port set changes.
func serveNetInfo(port uint32, dockerSock string, iface string, poll time.Duration) {
	ln, err := vsock.Listen(port, nil)
	if err != nil {
		log.Fatalf("vsock listen on netinfo port %d: %v", port, err)
	}
	defer ln.Close()
	log.Printf("netinfo on vsock port %d (iface %s)", port, iface)

	for {
		conn, err := ln.Accept()
		if err != nil {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		go streamNetInfo(conn, dockerSock, iface, poll)
	}
}

func streamNetInfo(conn net.Conn, dockerSock, iface string, poll time.Duration) {
	defer conn.Close()
	enc := json.NewEncoder(conn) // Encode appends '\n' → newline-delimited JSON
	var last NetState
	first := true
	for {
		st := NetState{IP: primaryIP(iface), Ports: fetchPublishedPorts(dockerSock)}
		if first || !st.Equal(last) {
			if err := enc.Encode(st); err != nil {
				return
			}
			last, first = st, false
		}
		time.Sleep(poll)
	}
}

// primaryIP returns the first IPv4 address on the given interface.
func primaryIP(iface string) string {
	ifi, err := net.InterfaceByName(iface)
	if err != nil {
		return ""
	}
	addrs, _ := ifi.Addrs()
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok {
			if ip4 := ipn.IP.To4(); ip4 != nil {
				return ip4.String()
			}
		}
	}
	return ""
}

// fetchPublishedPorts queries the local Docker engine for published TCP ports.
func fetchPublishedPorts(dockerSock string) []int {
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
	return parsePublishedPorts(data)
}
