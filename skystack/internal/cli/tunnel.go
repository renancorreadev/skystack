package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/core"
)

func newTunnelCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "tunnel [host/]<container> <localPort:containerPort>",
		Short: "Forward a container port to localhost (over SSH for remote hosts)",
		Long:  "Expose a container's port on your Mac as http://localhost:<localPort>.\nRemote hosts are reached with an SSH forward to the container's internal IP;\nlocal containers are proxied via their published host port.",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()

			spec, err := core.ParsePorts(args[1])
			if err != nil {
				return err
			}
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()

			logf := func(format string, a ...any) { fmt.Printf(format+"\n", a...) }
			fmt.Println("press Ctrl-C to close the tunnel")
			return eng.Tunnel(ctx, c, spec, logf)
		},
	}
}
