package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/docker/docker/api/types/container"
	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/skynance/skystack/internal/core"
)

func newExecCmd() *cobra.Command {
	var interactive, tty bool
	cmd := &cobra.Command{
		Use:                "exec [host/]<container> <command> [args...]",
		Short:              "Run a command inside a container (interactive shell supported)",
		Args:               cobra.MinimumNArgs(2),
		DisableFlagParsing: false,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()

			command := args[1:]
			stdinIsTTY := term.IsTerminal(int(os.Stdin.Fd()))
			useTTY := tty && stdinIsTTY

			if !useTTY {
				return eng.ExecSimple(ctx, c.ID, core.ExecConfig{
					Cmd:    command,
					Stdin:  stdinReader(interactive),
					Stdout: os.Stdout,
					Stderr: os.Stderr,
				})
			}
			return runInteractive(ctx, eng, c.ID, command)
		},
	}
	cmd.Flags().BoolVarP(&interactive, "interactive", "i", true, "keep stdin open")
	cmd.Flags().BoolVarP(&tty, "tty", "t", true, "allocate a pseudo-TTY")
	// Stop parsing skystack flags at the first positional (the container), so
	// flags belonging to the inner command (e.g. `nginx -v`) pass through.
	// Convention mirrors docker: skystack flags go before the container name.
	cmd.Flags().SetInterspersed(false)
	return cmd
}

func stdinReader(interactive bool) io.Reader {
	if interactive {
		return os.Stdin
	}
	return nil
}

// runInteractive drives a full TTY exec session: raw mode, output streaming,
// and live terminal resize forwarding.
func runInteractive(ctx context.Context, eng *core.Engine, id string, command []string) error {
	cli := eng.Docker
	created, err := cli.ContainerExecCreate(ctx, id, container.ExecOptions{
		Cmd:          command,
		Tty:          true,
		AttachStdin:  true,
		AttachStdout: true,
		AttachStderr: true,
	})
	if err != nil {
		return err
	}
	att, err := cli.ContainerExecAttach(ctx, created.ID, container.ExecAttachOptions{Tty: true})
	if err != nil {
		return err
	}
	defer att.Close()

	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return err
	}
	defer term.Restore(fd, oldState)

	resize := func() {
		if w, h, err := term.GetSize(int(os.Stdout.Fd())); err == nil {
			_ = cli.ContainerExecResize(ctx, created.ID, container.ResizeOptions{Height: uint(h), Width: uint(w)})
		}
	}
	resize()
	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	defer signal.Stop(winch)
	go func() {
		for range winch {
			resize()
		}
	}()

	go func() { _, _ = io.Copy(att.Conn, os.Stdin); _ = att.CloseWrite() }()
	_, err = io.Copy(os.Stdout, att.Reader)

	if inspect, ierr := cli.ContainerExecInspect(ctx, created.ID); ierr == nil && inspect.ExitCode != 0 {
		term.Restore(fd, oldState)
		return fmt.Errorf("command exited with code %d", inspect.ExitCode)
	}
	return err
}
