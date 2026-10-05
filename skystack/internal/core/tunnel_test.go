package core

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParsePorts(t *testing.T) {
	cases := []struct {
		in      string
		local   int
		cont    int
		wantErr bool
	}{
		{"8080:80", 8080, 80, false},
		{"80", 80, 80, false},
		{" 9090 : 90 ", 9090, 90, false},
		{"abc:80", 0, 0, true},
		{"8080:xyz", 0, 0, true},
	}
	for _, c := range cases {
		got, err := ParsePorts(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("ParsePorts(%q): expected error, got %+v", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParsePorts(%q): unexpected error %v", c.in, err)
			continue
		}
		if got.LocalPort != c.local || got.ContainerPort != c.cont {
			t.Errorf("ParsePorts(%q) = %+v, want local=%d cont=%d", c.in, got, c.local, c.cont)
		}
	}
}

func TestParseSSHURL(t *testing.T) {
	user, host, port := parseSSHURL("ssh://ubuntu@1.2.3.4:2222")
	if user != "ubuntu" || host != "1.2.3.4" || port != "2222" {
		t.Fatalf("got %q %q %q", user, host, port)
	}
	user, host, port = parseSSHURL("ssh://example.com")
	if user != "" || host != "example.com" || port != "22" {
		t.Fatalf("default port: got %q %q %q", user, host, port)
	}
}

// TestProxyTCP verifies the local tunnel proxy forwards an HTTP request end to
// end, isolated from Docker and macOS published-port behavior.
func TestProxyTCP(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "hello from backend")
	}))
	defer backend.Close()
	backendAddr := backend.Listener.Addr().String()

	localPort := freePort(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		_ = proxyTCP(ctx, localPort, func() (net.Conn, error) {
			return net.Dial("tcp", backendAddr)
		})
	}()

	// Wait for the listener to come up.
	url := fmt.Sprintf("http://127.0.0.1:%d/", localPort)
	waitListening(t, localPort)

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		t.Fatalf("GET through proxy: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(body) != "hello from backend" {
		t.Fatalf("proxy returned status=%d body=%q", resp.StatusCode, string(body))
	}
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func waitListening(t *testing.T, port int) {
	t.Helper()
	for i := 0; i < 50; i++ {
		c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond)
		if err == nil {
			c.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("proxy did not start listening on %d", port)
}
