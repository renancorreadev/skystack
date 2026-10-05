package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// shortSockDir returns a short temp dir so unix socket paths stay under the
// macOS 104-char sun_path limit (t.TempDir() paths are too long).
func shortSockDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "sky")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// TestHandleProxiesToUnixSocket verifies the agent forwards a client connection
// to a backend unix socket and relays bytes both ways.
func TestHandleProxiesToUnixSocket(t *testing.T) {
	sockPath := filepath.Join(shortSockDir(t), "d.sock")
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	// Backend echoes "PONG" after receiving "PING".
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		buf := make([]byte, 4)
		if _, err := c.Read(buf); err != nil {
			return
		}
		if string(buf) == "PING" {
			c.Write([]byte("PONG"))
		}
	}()

	clientSide, agentSide := net.Pipe()
	defer clientSide.Close()
	go handle(agentSide, sockPath)

	clientSide.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := clientSide.Write([]byte("PING")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 4)
	if _, err := clientSide.Read(reply); err != nil {
		t.Fatal(err)
	}
	if string(reply) != "PONG" {
		t.Fatalf("got %q, want PONG", reply)
	}
}

func TestDialWithRetrySucceedsOnceSocketAppears(t *testing.T) {
	sockPath := filepath.Join(shortSockDir(t), "l.sock")

	// Create the socket after a short delay; dialWithRetry should wait for it.
	go func() {
		time.Sleep(300 * time.Millisecond)
		ln, err := net.Listen("unix", sockPath)
		if err == nil {
			// keep it open for the test duration
			t.Cleanup(func() { ln.Close() })
			go func() {
				c, _ := ln.Accept()
				if c != nil {
					c.Close()
				}
			}()
		}
	}()

	conn, err := dialWithRetry(sockPath, 3*time.Second)
	if err != nil {
		t.Fatalf("expected dial to succeed once socket appears: %v", err)
	}
	conn.Close()
}

func TestDialWithRetryTimesOut(t *testing.T) {
	_, err := dialWithRetry(filepath.Join(shortSockDir(t), "n.sock"), 400*time.Millisecond)
	if err == nil {
		t.Fatal("expected timeout error for nonexistent socket")
	}
	_ = os.Stdout
}
