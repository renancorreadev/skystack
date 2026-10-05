package cli

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/ui"
)

func newPsCmd() *cobra.Command {
	var all, everywhere bool
	cmd := &cobra.Command{
		Use:   "ps [host]",
		Short: "List containers on one host, or across all hosts with --all-hosts",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := loadRegistry()
			if err != nil {
				return err
			}

			var hosts []*config.Host
			switch {
			case everywhere:
				hosts = reg.All()
			case len(args) == 1:
				h, err := reg.Get(args[0])
				if err != nil {
					return err
				}
				hosts = []*config.Host{h}
			default:
				h, _ := reg.Get(config.LocalHost)
				hosts = []*config.Host{h}
			}

			containers := gather(hosts, all)
			showHost := everywhere || (len(hosts) == 1 && !hosts[0].IsLocal())

			headers := []string{"", "host", "name", "image", "status", "ports", "compose"}
			if !showHost {
				headers = []string{"", "name", "image", "status", "ports", "compose"}
			}
			rows := make([][]string, 0, len(containers))
			for _, c := range containers {
				compose := c.Compose
				if c.Service != "" {
					compose = c.Compose + "/" + c.Service
				}
				row := []string{
					ui.StateDot(c.State),
					c.Name,
					shortImage(c.Image),
					c.Status,
					strings.Join(c.Ports, " "),
					compose,
				}
				if showHost {
					row = append([]string{ui.StateDot(c.State), c.Host}, row[1:]...)
				}
				rows = append(rows, row)
			}
			if len(rows) == 0 {
				fmt.Println("no containers")
				return nil
			}
			fmt.Print(ui.Table(headers, rows))
			return nil
		},
	}
	cmd.Flags().BoolVarP(&all, "all", "a", false, "include stopped containers")
	cmd.Flags().BoolVarP(&everywhere, "all-hosts", "A", false, "aggregate every configured host")
	return cmd
}

// gather lists containers from many hosts concurrently, tolerating individual
// host failures (an unreachable host is reported to stderr, not fatal).
func gather(hosts []*config.Host, all bool) []core.Container {
	var (
		mu  sync.Mutex
		out []core.Container
		wg  sync.WaitGroup
	)
	for _, h := range hosts {
		wg.Add(1)
		go func(h *config.Host) {
			defer wg.Done()
			// The skyvm host is only meaningful when the VM is up; skip it
			// silently otherwise so `ps -A` stays clean.
			if h.IsSkyVM() && !skyVMSocketPresent(h) {
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := core.Connect(ctx, h)
			if err != nil {
				ui.Errorf("%s: %v", h.Name, err)
				return
			}
			defer eng.Close()
			cs, err := eng.List(ctx, all)
			if err != nil {
				ui.Errorf("%s: %v", h.Name, err)
				return
			}
			mu.Lock()
			out = append(out, cs...)
			mu.Unlock()
		}(h)
	}
	wg.Wait()
	return out
}

// skyVMSocketPresent reports whether the skyvm host's unix socket exists.
func skyVMSocketPresent(h *config.Host) bool {
	path := strings.TrimPrefix(h.Docker, "unix://")
	if path == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
}

func shortImage(img string) string {
	if i := strings.LastIndex(img, "@"); i >= 0 {
		img = img[:i]
	}
	if i := strings.LastIndex(img, "/"); i >= 0 {
		img = img[i+1:]
	}
	return img
}
