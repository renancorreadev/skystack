package cli

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/ui"
)

func newMachineCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "machine",
		Aliases: []string{"m"},
		Short:   "Run persistent Linux environments (Ubuntu, Debian, Fedora, …)",
		Long:    "Spin up lightweight Linux machines that share SkyVM's kernel — like OrbStack\nmachines or WSL. Your Mac home is mounted in, so your files travel with you.",
	}
	cmd.AddCommand(newMachineCreateCmd(), newMachineListCmd(), newMachineShellCmd(), newMachineDeleteCmd(), newMachineLifecycleCmd("start", "Start a stopped machine"), newMachineLifecycleCmd("stop", "Stop a running machine"))
	return cmd
}

// machineHost is the default host machines live on (our Linux runtime).
const machineHost = config.SkyVMHost

func newMachineCreateCmd() *cobra.Command {
	var distro, host string
	var noMount bool
	cmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create and start a Linux machine",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := args[0]
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()

			homeBind := ""
			if !noMount {
				homeBind, _ = os.UserHomeDir()
			}
			image, _ := core.ResolveDistro(distro)
			stop := ui.Spinner(fmt.Sprintf("creating %s machine %q (%s)", distro, name, image))
			err = eng.CreateMachine(ctx, name, distro, homeBind, os.Stderr)
			stop()
			if err != nil {
				return err
			}
			ui.Successf("machine %q ready — enter it with: skystack machine shell %s", name, name)
			return nil
		},
	}
	cmd.Flags().StringVarP(&distro, "distro", "d", core.DefaultDistro, "distro: "+strings.Join(core.Distros(), ", ")+" (or an image ref)")
	cmd.Flags().StringVar(&host, "host", machineHost, "host to create the machine on")
	cmd.Flags().BoolVar(&noMount, "no-mount", false, "don't mount the Mac home into the machine")
	return cmd
}

func newMachineListCmd() *cobra.Command {
	var host string
	cmd := &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls"},
		Short:   "List Linux machines",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			machines, err := eng.ListMachines(ctx)
			if err != nil {
				return err
			}
			if len(machines) == 0 {
				fmt.Println("no machines — create one with `skystack machine create <name>`")
				return nil
			}
			rows := make([][]string, 0, len(machines))
			for _, m := range machines {
				rows = append(rows, []string{ui.StateDot(m.State), m.Name, m.Distro, m.Status})
			}
			fmt.Print(ui.Table([]string{"", "name", "distro", "status"}, rows))
			return nil
		},
	}
	cmd.Flags().StringVar(&host, "host", machineHost, "host the machines live on")
	return cmd
}

func newMachineShellCmd() *cobra.Command {
	var host string
	cmd := &cobra.Command{
		Use:   "shell <name> [command...]",
		Short: "Open a shell (or run a command) inside a machine",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			eng, c, err := resolveTarget(ctx, host+"/"+args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			command := args[1:]
			// A one-shot command with no TTY (scripts/pipes) runs non-interactively.
			if len(command) > 0 && !term.IsTerminal(int(os.Stdin.Fd())) {
				return eng.ExecSimple(ctx, c.ID, core.ExecConfig{Cmd: command, Stdout: os.Stdout, Stderr: os.Stderr})
			}
			if len(command) == 0 {
				command = []string{"sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"}
			}
			return runInteractive(ctx, eng, c.ID, command)
		},
	}
	cmd.Flags().StringVar(&host, "host", machineHost, "host the machine lives on")
	cmd.Flags().SetInterspersed(false)
	return cmd
}

func newMachineDeleteCmd() *cobra.Command {
	var host string
	cmd := &cobra.Command{
		Use:     "delete <name>",
		Aliases: []string{"rm"},
		Short:   "Delete a machine (removes its container)",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			if err := eng.RemoveMachine(ctx, args[0]); err != nil {
				return err
			}
			ui.Successf("machine %q deleted", args[0])
			return nil
		},
	}
	cmd.Flags().StringVar(&host, "host", machineHost, "host the machine lives on")
	return cmd
}

func newMachineLifecycleCmd(action, short string) *cobra.Command {
	var host string
	cmd := &cobra.Command{
		Use:   action + " <name>",
		Short: short,
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			eng, c, err := resolveTarget(ctx, host+"/"+args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			switch action {
			case "start":
				err = eng.Start(ctx, c.ID)
			case "stop":
				err = eng.Stop(ctx, c.ID)
			}
			if err != nil {
				return err
			}
			ui.Successf("machine %q %sed", args[0], action)
			return nil
		},
	}
	cmd.Flags().StringVar(&host, "host", machineHost, "host the machine lives on")
	return cmd
}
