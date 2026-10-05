package vm

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/user"

	"github.com/skynance/skystack/internal/config"
)

// ContainerSubnet is the range routed to the guest for direct container-IP
// access. It covers Docker's default IPAM pools (172.16.0.0 – 172.31.255.255).
const ContainerSubnet = "172.16.0.0/12"

// helperPath is the least-privilege sudoers drop-in that grants passwordless
// route management for ContainerSubnet only.
const helperPath = "/etc/sudoers.d/skystack"

// routeBin is the absolute path matched in the sudoers rule.
const routeBin = "/sbin/route"

// Domain is the local TLD for container hostnames (e.g. web.sky.local).
const Domain = "sky.local"

// resolverPath / dnsPort wire macOS at our localhost DNS forwarder for *.sky.local.
const resolverPath = "/etc/resolver/" + Domain
const dnsPort = "5354"

// NetState is the guest network snapshot published by the running SkyVM.
type NetState struct {
	IP    string `json:"ip"`
	Ports []int  `json:"ports"`
}

// LoadNetState reads the guest network state file, if present.
func LoadNetState() (*NetState, error) {
	p, err := config.NetStatePath()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	var ns NetState
	if err := json.Unmarshal(data, &ns); err != nil {
		return nil, err
	}
	return &ns, nil
}

// RouteCommand returns the privileged route command for add/remove. Separated so
// the CLI can both run it and show it to the user.
func RouteCommand(action, guestIP string) []string {
	if action == "remove" {
		return []string{routeBin, "-n", "delete", "-net", ContainerSubnet}
	}
	return []string{routeBin, "-n", "add", "-net", ContainerSubnet, guestIP}
}

// HelperInstalled reports whether the passwordless route helper is present.
func HelperInstalled() bool {
	_, err := os.Stat(helperPath)
	return err == nil
}

// ApplyRoute adds or removes the container-subnet route. With the helper it runs
// passwordlessly (sudo -n) and "add" first clears any stale route; without it,
// a single interactive sudo prompt is used.
func ApplyRoute(action, guestIP string) error {
	pw := HelperInstalled()
	if action == "remove" {
		return runRoute(RouteCommand("remove", ""), pw)
	}
	if pw {
		_ = runRoute(RouteCommand("remove", ""), true) // clear stale route, no prompt
	}
	if err := runRoute(RouteCommand("add", guestIP), pw); err != nil {
		return fmt.Errorf("route add failed: %w", err)
	}
	return nil
}

func runRoute(args []string, passwordless bool) error {
	sudoArgs := make([]string, 0, len(args)+2)
	if passwordless {
		sudoArgs = append(sudoArgs, "-n")
	}
	sudoArgs = append(sudoArgs, args...)
	cmd := exec.Command("sudo", sudoArgs...)
	if !passwordless {
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	}
	return cmd.Run()
}

// sudoersContent builds the least-privilege drop-in for the current user.
func sudoersContent() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	return fmt.Sprintf(`# SkyStack — passwordless route management for the container subnet only.
# Installed by 'skystack vm install-helper'; remove with 'skystack vm uninstall-helper'.
%[1]s ALL=(root) NOPASSWD: %[2]s -n add -net %[3]s *
%[1]s ALL=(root) NOPASSWD: %[2]s -n delete -net %[3]s
`, u.Username, routeBin, ContainerSubnet), nil
}

// InstallHelper validates and installs the sudoers drop-in (one sudo prompt).
func InstallHelper() error {
	content, err := sudoersContent()
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp("", "skystack-sudoers-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()

	// Never install a sudoers file that doesn't parse — a bad file breaks sudo.
	if out, err := exec.Command("visudo", "-cf", tmp.Name()).CombinedOutput(); err != nil {
		return fmt.Errorf("sudoers validation failed (not installed): %v: %s", err, out)
	}
	if err := sudoInstall(tmp.Name(), helperPath, "0440"); err != nil {
		return err
	}
	// Also point macOS at our DNS forwarder for *.sky.local (one-time setup;
	// the resolver target 127.0.0.1:dnsPort is stable, so it never needs to
	// change even though the guest IP is dynamic).
	if err := installResolver(); err != nil {
		return err
	}
	// Trust the local HTTPS CA so https://*.sky.local works in browsers. The
	// sudo credential is already cached from the steps above, so this rarely
	// prompts again.
	return TrustCA()
}

// installResolver writes /etc/resolver/<Domain> → 127.0.0.1:dnsPort.
func installResolver() error {
	if err := runSudo("install", "-d", "-m", "0755", "/etc/resolver"); err != nil {
		return err
	}
	tmp, err := os.CreateTemp("", "skystack-resolver-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := fmt.Fprintf(tmp, "nameserver 127.0.0.1\nport %s\n", dnsPort); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()
	return sudoInstall(tmp.Name(), resolverPath, "0644")
}

// UninstallHelper removes the sudoers drop-in, the resolver file, and the
// trusted CA.
func UninstallHelper() error {
	_ = UntrustCA() // best-effort; keep going even if the cert is already gone
	return runSudo("rm", "-f", helperPath, resolverPath)
}

func sudoInstall(src, dest, mode string) error {
	return runSudo("install", "-m", mode, "-o", "root", "-g", "wheel", src, dest)
}

func runSudo(args ...string) error {
	cmd := exec.Command("sudo", args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}
