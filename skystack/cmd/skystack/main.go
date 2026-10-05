// Command skystack is the SkyStack CLI: one pane for local and remote Docker.
package main

import (
	"os"

	"github.com/skynance/skystack/internal/cli"
	"github.com/skynance/skystack/internal/ui"
)

func main() {
	if err := cli.NewRoot().Execute(); err != nil {
		ui.Errorf("%v", err)
		os.Exit(1)
	}
}
