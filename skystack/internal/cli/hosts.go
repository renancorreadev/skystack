package cli

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/ui"
)

func newConnectCmd() *cobra.Command {
	var desc string
	cmd := &cobra.Command{
		Use:   "connect <name> <ssh://user@host[:port]>",
		Short: "Register a remote Docker host (agentless, over SSH)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			name, sshURL := args[0], args[1]
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			if err := reg.Add(name, sshURL, desc); err != nil {
				return err
			}
			// Verify reachability before saving so we fail fast on bad creds.
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			eng, err := core.Connect(ctx, reg.Hosts[name])
			if err != nil {
				return fmt.Errorf("connecting to %s: %w", sshURL, err)
			}
			defer eng.Close()
			ver, err := eng.Ping(ctx)
			if err != nil {
				return fmt.Errorf("could not reach Docker on %s: %w\n"+
					"check that: the host is reachable (try `ssh %s`), Docker is running there, "+
					"and your SSH user can use the Docker socket (in the `docker` group or root)",
					sshURL, err, strings.TrimPrefix(sshURL, "ssh://"))
			}
			if err := reg.Save(); err != nil {
				return err
			}
			ui.Successf("connected %q → %s (Docker %s)", name, sshURL, ver)
			return nil
		},
	}
	cmd.Flags().StringVarP(&desc, "description", "d", "", "optional label for the host")
	return cmd
}

func newDisconnectCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "disconnect <name>",
		Short: "Remove a registered remote host",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			if err := reg.Remove(args[0]); err != nil {
				return err
			}
			if err := reg.Save(); err != nil {
				return err
			}
			ui.Successf("removed host %q", args[0])
			return nil
		},
	}
}

func newHostsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "hosts",
		Short: "List configured hosts and their reachability",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			hosts := reg.All()
			rows := make([][]string, 0, len(hosts))
			for _, h := range hosts {
				ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
				status, target := probe(ctx, h)
				cancel()
				rows = append(rows, []string{h.Name, target, status, h.Description})
			}
			fmt.Print(ui.Table([]string{"host", "endpoint", "status", "description"}, rows))
			return nil
		},
	}
}

func probe(ctx context.Context, h *config.Host) (status, target string) {
	switch {
	case h.IsSkyVM():
		target = "SkyVM (local Linux VM)"
	case h.Docker != "":
		target = h.Docker
	case h.IsLocal():
		target = "local engine"
	default:
		target = h.SSH
	}
	eng, err := core.Connect(ctx, h)
	if err != nil {
		return ui.StateDot("dead") + " unreachable", target
	}
	defer eng.Close()
	ver, err := eng.Ping(ctx)
	if err != nil {
		return ui.StateDot("dead") + " unreachable", target
	}
	return ui.StateDot("running") + " up (Docker " + ver + ")", target
}
