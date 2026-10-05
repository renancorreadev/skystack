//go:build linux

// Command skyvm-agent runs inside the SkyStack guest VM. It bridges the guest's
// Docker socket to the host over vsock, so the Mac can talk to the in-VM Docker
// engine before any IP networking exists.
//
//	host (SkyVM)  --vsock connect(cid=3, port)-->  skyvm-agent  --unix-->  dockerd
//
// Usage: skyvm-agent [--port 2375] [--docker /var/run/docker.sock]
package main

import (
	"flag"
	"log"
	"time"

	"github.com/mdlayher/vsock"
)

func main() {
	port := flag.Uint("port", 2375, "vsock port for the Docker socket proxy")
	netinfoPort := flag.Uint("netinfo-port", 1024, "vsock port for the network-info control channel")
	caPort := flag.Uint("ca-port", 1026, "vsock port the host pushes the local CA on")
	dockerSock := flag.String("docker", "/var/run/docker.sock", "path to the Docker unix socket")
	iface := flag.String("iface", "eth0", "guest network interface to report")
	flag.Parse()

	log.SetPrefix("skyvm-agent: ")
	log.SetFlags(log.Ltime)

	// Stream guest IP + published ports to the host for port forwarding.
	go serveNetInfo(uint32(*netinfoPort), *dockerSock, *iface, 1500*time.Millisecond)
	// Resolve *.sky.local → this guest (the reverse proxy ingress).
	go serveDNS(*dockerSock, *iface, 2*time.Second)
	// Receive the local CA from the host, then serve the HTTPS reverse proxy.
	caStore := &caStore{}
	go serveCA(uint32(*caPort), caStore)
	go serveProxy(*dockerSock, caStore, 2*time.Second)

	ln, err := vsock.Listen(uint32(*port), nil)
	if err != nil {
		log.Fatalf("vsock listen on port %d: %v", *port, err)
	}
	defer ln.Close()
	log.Printf("listening on vsock port %d → %s", *port, *dockerSock)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		go handle(conn, *dockerSock)
	}
}
