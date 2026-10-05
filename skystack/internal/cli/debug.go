package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/pkg/stdcopy"
	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/skynance/skystack/internal/core"
)

func newDebugCmd() *cobra.Command {
	var image, shell string
	var tty bool
	cmd := &cobra.Command{
		Use:   "debug [host/]<container> [command...]",
		Short: "Open a debug shell with a full toolbox into any container (even distroless)",
		Long: "Attach a disposable toolbox container that shares the target's PID and\n" +
			"network namespaces, so you get a shell with real tools even when the target\n" +
			"is distroless or read-only. The target's own filesystem is at /proc/1/root\n" +
			"(the shell starts there); its processes and network are visible too.\n" +
			"The toolbox auto-removes on exit.",
		Args: cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			if c.State != "running" {
				return fmt.Errorf("container %q is %s — it must be running to debug", c.Name, c.State)
			}

			fmt.Fprintf(os.Stderr, "preparing debug toolbox (%s)…\n", image)
			if err := eng.EnsureImage(ctx, image, os.Stderr); err != nil {
				return fmt.Errorf("pulling %s: %w", image, err)
			}

			// User command, or a shell that lands in the target's root filesystem.
			cmdv := args[1:]
			if len(cmdv) == 0 {
				cmdv = []string{"sh", "-c", fmt.Sprintf("cd /proc/1/root 2>/dev/null; exec %s", shell)}
			}

			useTTY := tty && term.IsTerminal(int(os.Stdin.Fd()))
			id, err := eng.CreateDebug(ctx, core.DebugSpec{TargetID: c.ID, Image: image, Cmd: cmdv, TTY: useTTY})
			if err != nil {
				return err
			}
			return attachDebug(ctx, eng, id, useTTY)
		},
	}
	cmd.Flags().StringVar(&image, "image", core.DefaultDebugImage, "toolbox image (e.g. nicolaka/netshoot)")
	cmd.Flags().StringVar(&shell, "shell", "sh", "shell to launch inside the toolbox")
	cmd.Flags().BoolVarP(&tty, "tty", "t", true, "allocate a pseudo-TTY")
	cmd.Flags().SetInterspersed(false)
	return cmd
}

// attachDebug attaches to the created toolbox container, starts it, and pumps
// I/O — interactively (raw TTY + resize) or one-shot (demuxed). AutoRemove cleans
// up the container on exit.
func attachDebug(ctx context.Context, eng *core.Engine, id string, useTTY bool) error {
	cli := eng.Docker
	att, err := cli.ContainerAttach(ctx, id, container.AttachOptions{
		Stream: true, Stdin: true, Stdout: true, Stderr: true,
	})
	if err != nil {
		return err
	}
	defer att.Close()

	if err := cli.ContainerStart(ctx, id, container.StartOptions{}); err != nil {
		return err
	}

	if !useTTY {
		go func() { _, _ = io.Copy(att.Conn, os.Stdin); _ = att.CloseWrite() }()
		_, err = stdcopy.StdCopy(os.Stdout, os.Stderr, att.Reader)
		return err
	}

	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return err
	}
	defer term.Restore(fd, oldState)

	resize := func() {
		if w, h, err := term.GetSize(int(os.Stdout.Fd())); err == nil {
			_ = cli.ContainerResize(ctx, id, container.ResizeOptions{Height: uint(h), Width: uint(w)})
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
	return err
}
