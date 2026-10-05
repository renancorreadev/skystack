package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/ui"
)

func newComposeCmd() *cobra.Command {
	var file, host string
	cmd := &cobra.Command{
		Use:   "compose",
		Short: "Work with Compose projects (graph, up, down, ps) on any host",
		Long:  "Visualize and drive Docker Compose projects. `graph` renders the service\ndependency graph; up/down/ps run `docker compose` against the chosen host.",
	}
	cmd.PersistentFlags().StringVarP(&file, "file", "f", "", "compose file (default: auto-detect in cwd)")
	cmd.PersistentFlags().StringVar(&host, "host", config.LocalHost, "host to run the project on")
	cmd.AddCommand(
		newComposeGraphCmd(&file),
		newComposePassthroughCmd("up", "Create and start the project", &file, &host, "up", "-d"),
		newComposePassthroughCmd("down", "Stop and remove the project", &file, &host, "down"),
		newComposePassthroughCmd("ps", "List project containers", &file, &host, "ps"),
		newComposePassthroughCmd("logs", "Show project logs", &file, &host, "logs"),
	)
	return cmd
}

func newComposeGraphCmd(file *string) *cobra.Command {
	return &cobra.Command{
		Use:   "graph",
		Short: "Render the service dependency graph",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			path, err := resolveComposeFile(*file)
			if err != nil {
				return err
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			proj, err := core.ParseCompose(data, projectFromDir(path))
			if err != nil {
				return err
			}
			renderGraph(proj)
			return nil
		},
	}
}

// newComposePassthroughCmd shells out to `docker compose` with DOCKER_HOST set.
func newComposePassthroughCmd(use, short string, file, host *string, dockerArgs ...string) *cobra.Command {
	return &cobra.Command{
		Use:                use,
		Short:              short,
		DisableFlagParsing: true,
		RunE: func(cmd *cobra.Command, extra []string) error {
			path, err := resolveComposeFile(*file)
			if err != nil {
				return err
			}
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			h, err := reg.Get(*host)
			if err != nil {
				return err
			}
			argv := append([]string{"compose", "-f", path}, dockerArgs...)
			argv = append(argv, extra...)
			c := exec.Command("docker", argv...)
			c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
			c.Env = os.Environ()
			if dh := dockerHostEnv(h); dh != "" {
				c.Env = append(c.Env, "DOCKER_HOST="+dh)
			}
			return c.Run()
		},
	}
}

// dockerHostEnv returns the DOCKER_HOST value for a host ("" for local).
func dockerHostEnv(h *config.Host) string {
	if h.Docker != "" {
		return h.Docker
	}
	if h.SSH != "" {
		return h.SSH
	}
	return ""
}

var composeNames = []string{"compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"}

func resolveComposeFile(explicit string) (string, error) {
	if explicit != "" {
		if _, err := os.Stat(explicit); err != nil {
			return "", fmt.Errorf("compose file not found: %s", explicit)
		}
		return explicit, nil
	}
	for _, n := range composeNames {
		if _, err := os.Stat(n); err == nil {
			return n, nil
		}
	}
	return "", fmt.Errorf("no compose file in the current directory (looked for %s) — pass -f", strings.Join(composeNames, ", "))
}

func projectFromDir(path string) string {
	abs, _ := filepath.Abs(path)
	return filepath.Base(filepath.Dir(abs))
}

// renderGraph prints the project's services in dependency layers with edges.
func renderGraph(p *core.ComposeProject) {
	byName := map[string]core.ComposeService{}
	for _, s := range p.Services {
		byName[s.Name] = s
	}
	fmt.Printf("%s  (%d services)\n", ui.Bold("project: "+p.Name), len(p.Services))
	for i, layer := range p.Layers() {
		fmt.Printf("\n  %s\n", ui.Dim(fmt.Sprintf("layer %d", i+1)))
		for _, name := range layer {
			s := byName[name]
			src := s.Image
			if src == "" && s.Build != "" {
				src = "build " + s.Build
			}
			line := fmt.Sprintf("    %s %s", ui.StateDot("running"), ui.Bold(name))
			if src != "" {
				line += "  " + ui.Dim(src)
			}
			if len(s.Ports) > 0 {
				line += "  " + strings.Join(s.Ports, " ")
			}
			if len(s.DependsOn) > 0 {
				line += "  " + ui.Dim("→ "+strings.Join(s.DependsOn, ", "))
			}
			fmt.Println(line)
		}
	}
}
