package cli

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// SSHHost is one concrete alias discovered in ~/.ssh/config.
type SSHHost struct {
	Alias    string `json:"alias"`
	HostName string `json:"hostName,omitempty"`
	User     string `json:"user,omitempty"`
	Port     string `json:"port,omitempty"`
}

// parseSSHHosts reads the user's SSH config (following Include globs) and returns
// the concrete Host aliases — skipping wildcard patterns. The Docker ssh://
// helper resolves these aliases itself, so `ssh://<alias>` reuses the whole
// config (HostName, User, Port, IdentityFile, ProxyJump…).
func parseSSHHosts() ([]SSHHost, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	cfg := filepath.Join(home, ".ssh", "config")
	order := []string{}
	hosts := map[string]*SSHHost{}
	seen := map[string]bool{}
	parseSSHFile(cfg, home, hosts, &order, seen)

	out := make([]SSHHost, 0, len(order))
	for _, a := range order {
		out = append(out, *hosts[a])
	}
	return out, nil
}

func parseSSHFile(path, home string, hosts map[string]*SSHHost, order *[]string, seen map[string]bool) {
	if seen[path] {
		return
	}
	seen[path] = true
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	var current []*SSHHost // aliases the current options apply to
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		line := strings.TrimSpace(scan.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val := splitSSHLine(line)
		switch strings.ToLower(key) {
		case "host":
			current = nil
			for _, pat := range strings.Fields(val) {
				if strings.ContainsAny(pat, "*?!") {
					continue
				}
				h, ok := hosts[pat]
				if !ok {
					h = &SSHHost{Alias: pat}
					hosts[pat] = h
					*order = append(*order, pat)
				}
				current = append(current, h)
			}
		case "hostname":
			for _, h := range current {
				h.HostName = val
			}
		case "user":
			for _, h := range current {
				h.User = val
			}
		case "port":
			for _, h := range current {
				h.Port = val
			}
		case "include":
			for _, pattern := range strings.Fields(val) {
				if !filepath.IsAbs(pattern) {
					pattern = filepath.Join(home, ".ssh", pattern)
				}
				matches, _ := filepath.Glob(pattern)
				for _, m := range matches {
					parseSSHFile(m, home, hosts, order, seen)
				}
			}
		}
	}
}

// splitSSHLine splits an SSH config line into keyword + value, tolerating both
// "Key value" and "Key=value" forms.
func splitSSHLine(line string) (string, string) {
	if i := strings.IndexAny(line, " \t="); i >= 0 {
		key := strings.TrimRight(line[:i], " \t=")
		val := strings.TrimLeft(line[i:], " \t=")
		return key, strings.TrimSpace(val)
	}
	return line, ""
}
