package main

import (
	"io"
	"log"
	"net"
	"os"
	"sync"
	"time"
)

// handle proxies one inbound connection to the Docker unix socket. dockerd may
// not be up yet on the first connection, so we retry the dial briefly.
func handle(client net.Conn, dockerSock string) {
	defer client.Close()

	backend, err := dialWithRetry(dockerSock, 5*time.Second)
	if err != nil {
		log.Printf("dial docker: %v", err)
		return
	}
	defer backend.Close()

	proxy(client, backend)
}

// dialWithRetry dials a unix socket, retrying until within elapses. Used because
// the agent can start before dockerd has created its socket.
func dialWithRetry(path string, within time.Duration) (net.Conn, error) {
	deadline := time.Now().Add(within)
	for {
		conn, err := net.Dial("unix", path)
		if err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) {
			return nil, err
		}
		_, _ = os.Stat(path)
		time.Sleep(150 * time.Millisecond)
	}
}

// proxy copies bytes in both directions, half-closing each side independently
// so a finished direction does NOT tear down the other. This is essential for
// Docker's hijacked streams (run/attach/exec, logs -f): the client stops sending
// while the server keeps streaming output, and vice versa.
func proxy(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go halfCopy(&wg, a, b) // b → a
	go halfCopy(&wg, b, a) // a → b
	wg.Wait()
}

// halfCopy streams src→dst, then signals EOF to dst's reader via a write-only
// close (flushing pending bytes) without disturbing the opposite direction.
func halfCopy(wg *sync.WaitGroup, dst, src net.Conn) {
	defer wg.Done()
	_, _ = io.Copy(dst, src)
	if cw, ok := dst.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
	}
}
