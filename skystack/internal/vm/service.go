package vm

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
)

// Service drives the SkyVM background daemon.
type Service struct {
	rt       *Runtime
	pidPath  string
	sockPath string
	logPath  string
}

// New loads the runtime config and prepares the service.
func New() (*Service, error) {
	rt, err := LoadRuntime()
	if err != nil {
		return nil, err
	}
	dir, err := config.Dir()
	if err != nil {
		return nil, err
	}
	sock, err := config.SkyVMSocketPath()
	if err != nil {
		return nil, err
	}
	return &Service{
		rt:       rt,
		pidPath:  filepath.Join(dir, "skyvm.pid"),
		sockPath: sock,
		logPath:  filepath.Join(dir, "skyvm.log"),
	}, nil
}

// Status describes the current runtime state.
type Status struct {
	Running       bool
	PID           int
	Socket        string
	SocketReady   bool
	DockerVersion string
	LogPath       string
}

// Status reports whether the VM process is alive and the engine reachable.
func (s *Service) Status(ctx context.Context) Status {
	st := Status{Socket: s.sockPath, LogPath: s.logPath}
	pid := s.readPID()
	if pid > 0 && processAlive(pid) {
		st.Running = true
		st.PID = pid
	}
	if st.Running {
		if v, err := s.ping(ctx); err == nil {
			st.SocketReady = true
			st.DockerVersion = v
		}
	}
	return st
}

// LogPath exposes the VM log file path for `skystack vm logs`.
func (s *Service) LogPath() string { return s.logPath }

// Start launches SkyVM detached and waits until the in-VM Docker answers.
func (s *Service) Start(ctx context.Context) error {
	if pid := s.readPID(); pid > 0 && processAlive(pid) {
		return fmt.Errorf("SkyVM is already running (pid %d)", pid)
	}
	if err := s.rt.Validate(); err != nil {
		return err
	}
	if err := ensureSigned(s.rt.Binary); err != nil {
		// Self-heal: a rebuild strips the ad-hoc signature. Re-sign and retry so
		// `vm start` keeps working after `swift build`/reboot without manual steps.
		if autoReSign(s.rt.Binary) != nil || ensureSigned(s.rt.Binary) != nil {
			return err
		}
	}
	// Generate the local HTTPS CA (if absent) before booting: SkyVM reads it
	// from ~/.skystack/ca and pushes it into the guest for the HTTPS proxy.
	// Best-effort — a CA failure must not block the VM from starting.
	_, _ = EnsureCA()

	_ = os.Remove(s.sockPath)
	// Clear stale net state so autoRoute waits for THIS boot's guest IP.
	if p, err := config.NetStatePath(); err == nil {
		_ = os.Remove(p)
	}
	logFile, err := os.Create(s.logPath)
	if err != nil {
		return fmt.Errorf("opening VM log: %w", err)
	}
	defer logFile.Close()

	args := []string{
		"--kernel", s.rt.KernelPath(),
		"--initrd", s.rt.InitramfsPath(),
		"--rootfs", s.rt.RootfsPath(),
		"--docker-socket", s.sockPath,
	}
	if s.rt.CPUs > 0 {
		args = append(args, "--cpus", strconv.Itoa(s.rt.CPUs))
	}
	if s.rt.MemoryGiB > 0 {
		args = append(args, "--memory-gib", strconv.Itoa(s.rt.MemoryGiB))
	}
	if s.rt.Share != "" {
		// Mirror the Mac directory into the guest at the same absolute path.
		args = append(args, "--share", s.rt.Share, "--share-mount", s.rt.Share)
	}
	if s.rt.Verbose {
		args = append(args, "--verbose")
	}
	if s.rt.K8s {
		args = append(args, "--k8s")
	}

	cmd := exec.Command(s.rt.Binary, args...)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	// Detach into its own session so it outlives the CLI invocation.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting SkyVM: %w", err)
	}
	// Capture the pid before Release(): Release invalidates cmd.Process.Pid (-1).
	pid := cmd.Process.Pid
	if err := s.writePID(pid); err != nil {
		return err
	}
	// Release the child so it keeps running after we return.
	_ = cmd.Process.Release()

	if err := s.waitReady(ctx, pid, 120*time.Second); err != nil {
		return err
	}
	// With the passwordless helper installed, make container IPs directly
	// reachable from the Mac automatically (the guest IP is DHCP-dynamic).
	if HelperInstalled() {
		s.autoRoute()
	}
	return nil
}

// autoRoute applies the container-subnet route to the current guest IP, waiting
// briefly for SkyVM to publish it. Best-effort; failures are non-fatal.
func (s *Service) autoRoute() {
	var ip string
	for i := 0; i < 16; i++ {
		if ns, err := LoadNetState(); err == nil && ns.IP != "" {
			ip = ns.IP
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if ip != "" {
		_ = ApplyRoute("add", ip)
	}
}

// Stop gracefully shuts the guest down (SIGINT → ACPI), escalating if needed.
func (s *Service) Stop(ctx context.Context) error {
	pid := s.readPID()
	if pid == 0 || !processAlive(pid) {
		s.cleanup()
		return fmt.Errorf("SkyVM is not running")
	}
	// Drop the now-stale container route (passwordless via the helper).
	if HelperInstalled() {
		_ = ApplyRoute("remove", "")
	}
	_ = syscall.Kill(pid, syscall.SIGINT)

	deadline := time.Now().Add(25 * time.Second)
	for time.Now().Before(deadline) {
		if !processAlive(pid) {
			s.cleanup()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(300 * time.Millisecond):
		}
	}
	// Escalate.
	_ = syscall.Kill(pid, syscall.SIGTERM)
	time.Sleep(2 * time.Second)
	if processAlive(pid) {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	s.cleanup()
	return nil
}

// waitReady polls the in-VM Docker engine until it answers or the process dies.
func (s *Service) waitReady(ctx context.Context, pid int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !processAlive(pid) {
			return fmt.Errorf("SkyVM exited during boot — see %s", s.logPath)
		}
		if _, err := s.ping(ctx); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return fmt.Errorf("timed out waiting for in-VM Docker (see %s)", s.logPath)
}

// ping connects to the VM's Docker socket and returns the server version.
func (s *Service) ping(ctx context.Context) (string, error) {
	host := &config.Host{Name: config.SkyVMHost, Docker: "unix://" + s.sockPath}
	eng, err := core.Connect(ctx, host)
	if err != nil {
		return "", err
	}
	defer eng.Close()
	cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return eng.Ping(cctx)
}

func (s *Service) readPID() int {
	data, err := os.ReadFile(s.pidPath)
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid
}

func (s *Service) writePID(pid int) error {
	return os.WriteFile(s.pidPath, []byte(strconv.Itoa(pid)), 0o600)
}

func (s *Service) cleanup() {
	_ = os.Remove(s.pidPath)
	_ = os.Remove(s.sockPath)
	if p, err := config.NetStatePath(); err == nil {
		_ = os.Remove(p)
	}
}

// processAlive reports whether a pid refers to a live process.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// ensureSigned verifies the SkyVM binary carries the virtualization entitlement,
// without which Virtualization.framework refuses to create a VM.
func ensureSigned(binary string) error {
	out, err := exec.Command("codesign", "-d", "--entitlements", "-", binary).CombinedOutput()
	if err == nil && strings.Contains(string(out), "com.apple.security.virtualization") {
		return nil
	}
	return fmt.Errorf("SkyVM binary at %s is not signed with the virtualization entitlement — run `skystack vm setup --sign`", binary)
}
