package cli

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/ui"
)

func newLogsCmd() *cobra.Command {
	var (
		follow bool
		tail   string
		since  string
		grep   string
		level  string
	)
	cmd := &cobra.Command{
		Use:   "logs [host/]<container>",
		Short: "Stream container logs with severity highlighting and regex filtering",
		Long:  "Stream and enrich container logs: dimmed timestamps, colored ERROR/WARN/INFO tags,\nJSON log-level detection, and an optional --grep regex filter. Works on any host.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()

			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()

			opts := core.LogOptions{Follow: follow, Tail: tail, Since: since}
			if grep != "" {
				re, err := regexp.Compile(grep)
				if err != nil {
					return fmt.Errorf("invalid --grep regex: %w", err)
				}
				opts.Grep = re
			}
			if level != "" {
				opts.MinLevel = strings.ToUpper(level)
			}

			showSource := c.Host != "local"
			return eng.StreamLogs(ctx, c, opts, func(l core.LogLine) {
				fmt.Println(ui.LogLine(l, showSource))
			})
		},
	}
	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "follow log output")
	cmd.Flags().StringVarP(&tail, "tail", "n", "200", "number of lines from the end (or 'all')")
	cmd.Flags().StringVar(&since, "since", "", "show logs since duration (e.g. 10m) or timestamp")
	cmd.Flags().StringVarP(&grep, "grep", "g", "", "only show lines matching this regex")
	cmd.Flags().StringVarP(&level, "level", "l", "", "minimum detected severity (debug|info|warn|error)")
	return cmd
}
