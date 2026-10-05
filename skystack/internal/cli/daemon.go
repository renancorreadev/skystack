package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
)

// The daemon is the single multi-host control process: one long-lived program
// that holds a warm Docker engine per host (reused across every request and
// stream) and serves the JSON API surface over a unix socket. It replaces the
// per-call `skystack api …` spawns — so the app's frequent polls and watches
// share warm connections (and SSH masters) instead of reconnecting each time.
// It is also the natural home for a future in-process AI agent that needs those
// same warm engines.

// MARK: paths

func skystackDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(home, ".skystack")
	return d, os.MkdirAll(d, 0o755)
}

func daemonSocketPath() (string, error) {
	d, err := skystackDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "daemon.sock"), nil
}

func daemonPIDPath() (string, error) {
	d, err := skystackDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "daemon.pid"), nil
}

// MARK: server

type daemonServer struct {
	mu       sync.Mutex
	engines  map[string]*core.Engine
	versions map[string]string
}

func newDaemonServer() *daemonServer {
	return &daemonServer{engines: map[string]*core.Engine{}, versions: map[string]string{}}
}

// engine returns a warm engine for host, connecting and caching on demand and
// transparently reconnecting if the cached one has gone stale (cheap /_ping).
func (s *daemonServer) engine(ctx context.Context, host string) (*core.Engine, error) {
	s.mu.Lock()
	eng := s.engines[host]
	s.mu.Unlock()
	if eng != nil {
		actx, c := context.WithTimeout(ctx, 8*time.Second)
		alive := eng.Alive(actx)
		c()
		if alive {
			return eng, nil
		}
		s.drop(host)
	}
	reg, err := loadRegistry()
	if err != nil {
		return nil, err
	}
	h, err := reg.Get(host)
	if err != nil {
		return nil, err
	}
	e, err := core.Connect(ctx, h)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.engines[host] = e
	s.mu.Unlock()
	return e, nil
}

func (s *daemonServer) drop(host string) {
	s.mu.Lock()
	if e := s.engines[host]; e != nil {
		e.Close()
	}
	delete(s.engines, host)
	delete(s.versions, host)
	s.mu.Unlock()
}

func (s *daemonServer) closeAll() {
	s.mu.Lock()
	for _, e := range s.engines {
		e.Close()
	}
	s.engines = map[string]*core.Engine{}
	s.mu.Unlock()
}

// target resolves a "[host/]container" ref against the warm pool (without
// closing the pooled engine, which the pool owns).
func (s *daemonServer) target(ctx context.Context, ref string) (*core.Engine, core.Container, error) {
	hostName, name := config.ParseRef(ref)
	eng, err := s.engine(ctx, hostName)
	if err != nil {
		return nil, core.Container{}, err
	}
	c, err := eng.Resolve(ctx, name)
	if err != nil {
		return nil, core.Container{}, err
	}
	return eng, c, nil
}

// probeHosts reports each registered host's reachability + cached version, using
// the warm pool. Mirrors `api hosts`/`watch-hosts` but shares the engine cache.
func (s *daemonServer) probeHosts(ctx context.Context) []apiHost {
	reg, err := loadRegistry()
	if err != nil {
		return nil
	}
	hosts := reg.All()
	rows := make([]apiHost, len(hosts))
	var wg sync.WaitGroup
	for i, h := range hosts {
		rows[i] = apiHost{Name: h.Name, Kind: hostKind(h), Description: h.Description}
		wg.Add(1)
		go func(i int, h *config.Host) {
			defer wg.Done()
			if h.IsSkyVM() && !skyVMSocketPresent(h) {
				s.drop(h.Name)
				return
			}
			eng, err := s.engine(ctx, h.Name)
			if err != nil {
				rows[i].Error = err.Error()
				return
			}
			actx, c := context.WithTimeout(ctx, 8*time.Second)
			alive := eng.Alive(actx)
			c()
			if !alive {
				s.drop(h.Name)
				rows[i].Error = "unreachable"
				return
			}
			rows[i].Up = true
			rows[i].Engine = s.version(ctx, h.Name, eng)
		}(i, h)
	}
	wg.Wait()
	return rows
}

// version returns the host's engine version, fetched once and cached (static).
func (s *daemonServer) version(ctx context.Context, host string, eng *core.Engine) string {
	s.mu.Lock()
	v := s.versions[host]
	s.mu.Unlock()
	if v != "" {
		return v
	}
	vctx, c := context.WithTimeout(ctx, 8*time.Second)
	defer c()
	if got, err := eng.Ping(vctx); err == nil {
		s.mu.Lock()
		s.versions[host] = got
		s.mu.Unlock()
		return got
	}
	return ""
}

// run accepts connections on the unix socket until ctx is cancelled.
func (s *daemonServer) run(ctx context.Context, sockPath string) error {
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", sockPath, err)
	}
	defer ln.Close()
	defer os.Remove(sockPath)
	defer s.closeAll()
	go func() { <-ctx.Done(); ln.Close() }()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go s.handle(ctx, conn)
	}
}

// handle serves one request per connection. Unary methods write a single JSON
// line; streaming methods write NDJSON frames until the client closes the
// connection (which cancels the request context).
func (s *daemonServer) handle(parent context.Context, conn net.Conn) {
	defer conn.Close()
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return
	}
	var req daemonRequest
	if err := json.Unmarshal(bytes.TrimSpace(line), &req); err != nil {
		_ = json.NewEncoder(conn).Encode(map[string]string{"error": "bad request: " + err.Error()})
		return
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	// Cancel the request as soon as the client closes its end.
	go func() {
		buf := make([]byte, 256)
		for {
			if _, err := conn.Read(buf); err != nil {
				cancel()
				return
			}
		}
	}()
	if err := s.dispatch(ctx, conn, req); err != nil && ctx.Err() == nil {
		_ = json.NewEncoder(conn).Encode(map[string]string{"error": err.Error()})
	}
}

type daemonRequest struct {
	ID     int      `json:"id,omitempty"`
	Method string   `json:"method"`
	Args   []string `json:"args,omitempty"`
}

func toAPIContainers(cs []core.Container) []apiContainer {
	out := make([]apiContainer, 0, len(cs))
	for _, c := range cs {
		out = append(out, apiContainer{
			Host: c.Host, ID: c.ID, Name: c.Name, Image: c.Image,
			State: c.State, Status: c.Status, Ports: c.Ports,
			Compose: c.Compose, Service: c.Service,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (s *daemonServer) dispatch(ctx context.Context, conn net.Conn, req daemonRequest) error {
	enc := json.NewEncoder(conn)
	arg := func(i int) string {
		if i < len(req.Args) {
			return req.Args[i]
		}
		return ""
	}
	switch req.Method {
	case "hosts":
		return enc.Encode(s.probeHosts(ctx))
	case "ps":
		host := config.LocalHost
		if arg(0) != "" {
			host = arg(0)
		}
		eng, err := s.engine(ctx, host)
		if err != nil {
			return err
		}
		cs, err := eng.List(ctx, true)
		if err != nil {
			return err
		}
		return enc.Encode(toAPIContainers(cs))
	case "images":
		eng, err := s.engine(ctx, hostArg(arg(0), config.LocalHost))
		if err != nil {
			return err
		}
		v, err := eng.ListImages(ctx)
		if err != nil {
			return err
		}
		return enc.Encode(v)
	case "volumes":
		eng, err := s.engine(ctx, hostArg(arg(0), config.LocalHost))
		if err != nil {
			return err
		}
		v, err := eng.ListVolumes(ctx)
		if err != nil {
			return err
		}
		return enc.Encode(v)
	case "networks":
		eng, err := s.engine(ctx, hostArg(arg(0), config.LocalHost))
		if err != nil {
			return err
		}
		v, err := eng.ListNetworks(ctx)
		if err != nil {
			return err
		}
		return enc.Encode(v)
	case "machines":
		eng, err := s.engine(ctx, hostArg(arg(0), config.SkyVMHost))
		if err != nil {
			return err
		}
		ms, err := eng.ListMachines(ctx)
		if err != nil {
			return err
		}
		out := make([]map[string]any, 0, len(ms))
		for _, m := range ms {
			out = append(out, map[string]any{"name": m.Name, "distro": m.Distro, "image": m.Image, "state": m.State, "status": m.Status})
		}
		return enc.Encode(out)
	case "action":
		if len(req.Args) < 2 {
			return fmt.Errorf("action needs <action> <ref>")
		}
		eng, c, err := s.target(ctx, arg(1))
		if err != nil {
			return err
		}
		switch arg(0) {
		case "start":
			err = eng.Start(ctx, c.ID)
		case "stop":
			err = eng.Stop(ctx, c.ID)
		case "restart":
			err = eng.Restart(ctx, c.ID)
		default:
			return fmt.Errorf("unknown action %q", arg(0))
		}
		if err != nil {
			return err
		}
		return enc.Encode(map[string]any{"ok": true, "action": arg(0), "container": c.Name})
	case "context":
		eng, c, err := s.target(ctx, arg(0))
		if err != nil {
			return err
		}
		return enc.Encode(buildContainerContext(ctx, eng, c))
	case "host-context":
		eng, err := s.engine(ctx, arg(0))
		if err != nil {
			return err
		}
		out, err := buildHostContext(ctx, eng)
		if err != nil {
			return err
		}
		return enc.Encode(out)
	case "watch":
		eng, err := s.engine(ctx, arg(0))
		if err != nil {
			return err
		}
		return eng.WatchContainers(ctx, true, func(cs []core.Container) {
			_ = enc.Encode(map[string]any{"containers": toAPIContainers(cs)})
		})
	case "watch-hosts":
		return s.streamWatchHosts(ctx, enc)
	case "logs":
		tail := "300"
		if arg(1) != "" {
			tail = arg(1)
		}
		eng, c, err := s.target(ctx, arg(0))
		if err != nil {
			return err
		}
		return eng.StreamLogs(ctx, c, core.LogOptions{Follow: true, Tail: tail}, func(l core.LogLine) {
			rec := apiLog{Host: l.Host, Container: l.Container, Stream: l.Stream, Severity: l.Severity, Message: l.Message}
			if l.HasTime {
				rec.Time = l.Time.Format(time.RFC3339Nano)
			}
			_ = enc.Encode(rec)
		})
	case "stats":
		eng, c, err := s.target(ctx, arg(0))
		if err != nil {
			return err
		}
		return eng.StreamStats(ctx, c.ID, func(st core.StatsSample) { _ = enc.Encode(st) })
	case "hwstats":
		eng, err := s.engine(ctx, arg(0))
		if err != nil {
			return err
		}
		return eng.StreamHardware(ctx, func(h core.HardwareSample) { _ = enc.Encode(h) })
	default:
		return fmt.Errorf("unknown method %q", req.Method)
	}
}

func hostArg(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func (s *daemonServer) streamWatchHosts(ctx context.Context, enc *json.Encoder) error {
	last := ""
	emit := func() error {
		rows := s.probeHosts(ctx)
		b, _ := json.Marshal(map[string]any{"hosts": rows})
		if string(b) == last {
			return nil
		}
		last = string(b)
		return enc.Encode(map[string]any{"hosts": rows})
	}
	if err := emit(); err != nil {
		return err
	}
	t := time.NewTicker(4 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			if err := emit(); err != nil {
				return err
			}
		}
	}
}

// MARK: client

func daemonDial() (net.Conn, error) {
	p, err := daemonSocketPath()
	if err != nil {
		return nil, err
	}
	return net.Dial("unix", p)
}

// daemonCall sends one request and copies the daemon's response to w. For
// streaming methods it copies frames until ctx is cancelled (Ctrl-C).
func daemonCall(ctx context.Context, method string, args []string, w io.Writer) error {
	conn, err := daemonDial()
	if err != nil {
		return fmt.Errorf("daemon not running — start it with `skystack daemon start` (%v)", err)
	}
	defer conn.Close()
	b, _ := json.Marshal(daemonRequest{Method: method, Args: args})
	if _, err := conn.Write(append(b, '\n')); err != nil {
		return err
	}
	go func() { <-ctx.Done(); conn.Close() }()
	_, err = io.Copy(w, conn)
	if ctx.Err() != nil {
		return nil
	}
	return err
}

func daemonRunning() bool {
	conn, err := daemonDial()
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// MARK: CLI

func newDaemonCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "daemon",
		Short: "Run the SkyStack multi-host daemon (one warm process for all hosts)",
		Long:  "The daemon holds a warm Docker engine per host and serves the JSON API\nover a unix socket, so the app shares warm connections instead of spawning a\nprocess per call.",
	}
	cmd.AddCommand(newDaemonRunCmd(), newDaemonStartCmd(), newDaemonStopCmd(), newDaemonStatusCmd(),
		newDaemonCallCmd(), newDaemonInstallCmd(), newDaemonUninstallCmd())
	return cmd
}

const daemonLaunchLabel = "dev.skystack.daemon"

func daemonAgentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", daemonLaunchLabel+".plist"), nil
}

func daemonAgentInstalled() bool {
	p, err := daemonAgentPath()
	if err != nil {
		return false
	}
	_, err = os.Stat(p)
	return err == nil
}

// installDaemonAgent writes a launchd LaunchAgent that keeps the daemon running
// (RunAtLoad + KeepAlive) in the user's login session, surviving reboots.
func installDaemonAgent() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	exe, _ = filepath.Abs(exe)
	dir, _ := skystackDir()
	logPath := filepath.Join(dir, "daemon.log")
	p, err := daemonAgentPath()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return "", err
	}
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>daemon</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, daemonLaunchLabel, exe, logPath, logPath)
	if err := os.WriteFile(p, []byte(plist), 0o644); err != nil {
		return "", err
	}
	_ = exec.Command("launchctl", "unload", p).Run()
	if out, err := exec.Command("launchctl", "load", p).CombinedOutput(); err != nil {
		return p, fmt.Errorf("launchctl load: %v: %s", err, string(out))
	}
	return p, nil
}

func uninstallDaemonAgent() error {
	p, err := daemonAgentPath()
	if err != nil {
		return err
	}
	_ = exec.Command("launchctl", "unload", p).Run()
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func newDaemonInstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install",
		Short: "Install a LaunchAgent so the daemon auto-starts at login (survives reboot)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			p, err := installDaemonAgent()
			if err != nil {
				return err
			}
			fmt.Printf("daemon auto-start installed: %s\n", p)
			return nil
		},
	}
}

func newDaemonUninstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall",
		Short: "Remove the daemon's auto-start LaunchAgent",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !daemonAgentInstalled() {
				fmt.Println("daemon auto-start is not installed")
				return nil
			}
			if err := uninstallDaemonAgent(); err != nil {
				return err
			}
			fmt.Println("daemon auto-start removed")
			return nil
		},
	}
}

func newDaemonRunCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Run the daemon in the foreground",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			sock, err := daemonSocketPath()
			if err != nil {
				return err
			}
			if daemonRunning() {
				return fmt.Errorf("daemon already running on %s", sock)
			}
			ctx, cancel := signalContext()
			defer cancel()
			fmt.Fprintf(os.Stderr, "skystack daemon listening on %s\n", sock)
			return newDaemonServer().run(ctx, sock)
		},
	}
}

func newDaemonStartCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "start",
		Short: "Start the daemon in the background",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if daemonRunning() {
				fmt.Println("daemon already running")
				return nil
			}
			exe, err := os.Executable()
			if err != nil {
				return err
			}
			dir, _ := skystackDir()
			logf, _ := os.OpenFile(filepath.Join(dir, "daemon.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
			c := exec.Command(exe, "daemon", "run")
			c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
			if logf != nil {
				c.Stdout, c.Stderr = logf, logf
			}
			if err := c.Start(); err != nil {
				return err
			}
			// Capture the pid BEFORE Release(): Release() invalidates the handle
			// and sets Pid=-1 (a documented gotcha in this codebase).
			pid := c.Process.Pid
			pidPath, _ := daemonPIDPath()
			_ = os.WriteFile(pidPath, []byte(strconv.Itoa(pid)), 0o644)
			_ = c.Process.Release()
			// Wait briefly for the socket to come up.
			for i := 0; i < 50; i++ {
				if daemonRunning() {
					fmt.Printf("daemon started (pid %d)\n", pid)
					return nil
				}
				time.Sleep(40 * time.Millisecond)
			}
			return fmt.Errorf("daemon did not come up — see %s/daemon.log", dir)
		},
	}
}

func newDaemonStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop",
		Short: "Stop the background daemon",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			pidPath, _ := daemonPIDPath()
			b, err := os.ReadFile(pidPath)
			if err != nil {
				return fmt.Errorf("no daemon pid file (is it running?)")
			}
			pid, err := strconv.Atoi(string(bytes.TrimSpace(b)))
			if err != nil {
				return err
			}
			if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
				return fmt.Errorf("stop pid %d: %w", pid, err)
			}
			_ = os.Remove(pidPath)
			fmt.Printf("daemon stopped (pid %d)\n", pid)
			return nil
		},
	}
}

func newDaemonStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show whether the daemon is running and the hosts it sees",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			sock, _ := daemonSocketPath()
			if !daemonRunning() {
				fmt.Printf("daemon: stopped (socket %s)\n", sock)
				return nil
			}
			fmt.Printf("daemon: running (socket %s)\n", sock)
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			var buf bytes.Buffer
			if err := daemonCall(ctx, "hosts", nil, &buf); err != nil {
				return err
			}
			var hosts []apiHost
			if err := json.Unmarshal(buf.Bytes(), &hosts); err == nil {
				for _, h := range hosts {
					state := "down"
					if h.Up {
						state = "up " + h.Engine
					}
					fmt.Printf("  %-16s %s\n", h.Name, state)
				}
			}
			return nil
		},
	}
}

func newDaemonCallCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "call <method> [args...]",
		Short:  "Send one request to the daemon and stream its response (debug/app transport)",
		Args:   cobra.MinimumNArgs(1),
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			return daemonCall(ctx, args[0], args[1:], os.Stdout)
		},
	}
	return cmd
}
