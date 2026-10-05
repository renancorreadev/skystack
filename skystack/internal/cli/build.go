package cli

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
)

func newBuildCmd() *cobra.Command {
	var host, platform, tag string
	var push, load bool
	cmd := &cobra.Command{
		Use:   "build [context]",
		Short: "Build an image with buildx (multi-platform) on any host",
		Long: "A thin wrapper over `docker buildx build` that targets a chosen host and\n" +
			"makes multi-platform builds easy. SkyVM's Rosetta accelerates linux/amd64\n" +
			"on Apple Silicon. Example: skystack build -t app --platform linux/amd64,linux/arm64 --push .",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := "."
			if len(args) == 1 {
				ctx = args[0]
			}
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			h, err := reg.Get(host)
			if err != nil {
				return err
			}

			baseEnv := os.Environ()
			if dh := dockerHostEnv(h); dh != "" {
				baseEnv = append(baseEnv, "DOCKER_HOST="+dh)
			}

			argv := []string{"buildx", "build"}
			if platform != "" {
				argv = append(argv, "--platform", platform)
			}
			// Multi-platform builds need a container-driver builder; create one
			// (named "skystack") on demand and target it.
			if strings.Contains(platform, ",") {
				ensureBuildxBuilder(baseEnv)
				argv = append(argv, "--builder", "skystack")
			}
			if tag != "" {
				argv = append(argv, "-t", tag)
			}
			switch {
			case push:
				argv = append(argv, "--push")
			case load:
				argv = append(argv, "--load")
			}
			argv = append(argv, ctx)

			c := exec.Command("docker", argv...)
			c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
			c.Env = baseEnv
			if err := c.Run(); err != nil {
				return fmt.Errorf("buildx: %w", err)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&host, "host", config.LocalHost, "host to build on")
	cmd.Flags().StringVar(&platform, "platform", "", "target platforms, e.g. linux/amd64,linux/arm64")
	cmd.Flags().StringVarP(&tag, "tag", "t", "", "image name and tag")
	cmd.Flags().BoolVar(&push, "push", false, "push the result to a registry")
	cmd.Flags().BoolVar(&load, "load", false, "load the result into the engine (single platform)")
	return cmd
}

// ensureBuildxBuilder creates a container-driver buildx builder named "skystack"
// if it doesn't already exist (best-effort; build proceeds regardless).
func ensureBuildxBuilder(env []string) {
	inspect := exec.Command("docker", "buildx", "inspect", "skystack")
	inspect.Env = env
	if inspect.Run() == nil {
		return // already exists
	}
	create := exec.Command("docker", "buildx", "create", "--name", "skystack", "--driver", "docker-container")
	create.Env = env
	_ = create.Run()
}
