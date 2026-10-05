package cli

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/ui"
)

// newLifecycleCmd builds start/stop/restart, which share a shape: resolve a
// target on any host and invoke one engine method.
func newLifecycleCmd(action, short string) *cobra.Command {
	return &cobra.Command{
		Use:   action + " [host/]<container>",
		Short: short,
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := context.Background()
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()

			var op func(context.Context, string) error
			switch action {
			case "start":
				op = eng.Start
			case "stop":
				op = eng.Stop
			case "restart":
				op = eng.Restart
			default:
				return fmt.Errorf("unknown action %q", action)
			}
			if err := op(ctx, c.ID); err != nil {
				return err
			}
			ui.Successf("%s %s/%s", action, hostLabel(c), c.Name)
			return nil
		},
	}
}

func hostLabel(c core.Container) string {
	if c.Host == "" {
		return "local"
	}
	return c.Host
}
