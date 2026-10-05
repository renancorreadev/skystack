package vm

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

const launchLabel = "dev.skystack.vm"

func launchAgentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", launchLabel+".plist"), nil
}

// DaemonInstalled reports whether the auto-start LaunchAgent exists.
func DaemonInstalled() bool {
	p, err := launchAgentPath()
	if err != nil {
		return false
	}
	_, err = os.Stat(p)
	return err == nil
}

// InstallDaemon writes a launchd LaunchAgent that boots SkyVM at login (so it
// survives reboots) and loads it now. The agent runs THIS skystack binary's
// `vm start`; self-heal handles re-signing if a rebuild stripped the signature.
func InstallDaemon() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	exe, _ = filepath.Abs(exe)
	home, _ := os.UserHomeDir()
	logPath := filepath.Join(home, ".skystack", "vm-daemon.log")
	p, err := launchAgentPath()
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
    <string>vm</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, launchLabel, exe, logPath, logPath)
	if err := os.WriteFile(p, []byte(plist), 0o644); err != nil {
		return "", err
	}
	_ = exec.Command("launchctl", "unload", p).Run() // ignore "not loaded"
	if out, err := exec.Command("launchctl", "load", p).CombinedOutput(); err != nil {
		return p, fmt.Errorf("launchctl load: %v: %s", err, string(out))
	}
	return p, nil
}

// UninstallDaemon unloads and removes the LaunchAgent.
func UninstallDaemon() error {
	p, err := launchAgentPath()
	if err != nil {
		return err
	}
	_ = exec.Command("launchctl", "unload", p).Run()
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
