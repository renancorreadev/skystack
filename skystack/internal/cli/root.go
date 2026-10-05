// Package cli wires the SkyStack core into a cobra command tree. Every command
// resolves a target host/container through the shared helpers here, so local
// and remote engines are handled identically.
package cli

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
)

// version is overridden at build time via -ldflags.
var version = "dev"

// NewRoot builds the top-level skystack command.
func NewRoot() *cobra.Command {
	root := &cobra.Command{
		Use:           "skystack",
		Short:         "SkyStack — one pane for local and remote Docker",
		Long:          "SkyStack unifies local and remote Docker hosts behind a single CLI:\nlist, log, exec, inspect, tunnel and manage containers anywhere over SSH.",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(
		newConnectCmd(),
		newDisconnectCmd(),
		newHostsCmd(),
		newPsCmd(),
		newLogsCmd(),
		newExecCmd(),
		newDebugCmd(),
		newInspectCmd(),
		newLifecycleCmd("start", "Start a stopped container"),
		newLifecycleCmd("stop", "Stop a running container"),
		newLifecycleCmd("restart", "Restart a container"),
		newTunnelCmd(),
		newVMCmd(),
		newK8sCmd(),
		newMachineCmd(),
		newComposeCmd(),
		newBuildCmd(),
		newAPICmd(),
		newDaemonCmd(),
		newInstallCmd(),
		newUninstallCmd(),
	)
	return root
}

// loadRegistry opens the host registry from its default location.
func loadRegistry() (*config.Registry, error) {
	path, err := config.DefaultPath()
	if err != nil {
		return nil, err
	}
	return config.Load(path)
}

// engineFor connects to a host by name.
func engineFor(ctx context.Context, name string) (*core.Engine, error) {
	reg, err := loadRegistry()
	if err != nil {
		return nil, err
	}
	host, err := reg.Get(name)
	if err != nil {
		return nil, err
	}
	return core.Connect(ctx, host)
}

// resolveTarget parses a "[host/]container" ref, connects to its host, and
// resolves the container, returning both for the caller to use and close.
func resolveTarget(ctx context.Context, ref string) (*core.Engine, core.Container, error) {
	hostName, name := config.ParseRef(ref)
	eng, err := engineFor(ctx, hostName)
	if err != nil {
		return nil, core.Container{}, err
	}
	c, err := eng.Resolve(ctx, name)
	if err != nil {
		eng.Close()
		return nil, core.Container{}, err
	}
	return eng, c, nil
}

// signalContext returns a context cancelled on Ctrl-C / SIGTERM.
func signalContext() (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-ch
		cancel()
	}()
	return ctx, cancel
}
