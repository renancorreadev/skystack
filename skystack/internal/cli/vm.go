package cli

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/ui"
	"github.com/skynance/skystack/internal/vm"
)

func newVMCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "vm",
		Short: "Manage the local SkyVM Linux runtime (its own Docker engine)",
		Long:  "Run a lightweight local Linux VM with its own Docker engine, exposed as the\nbuilt-in `skyvm` host. No dependency on Docker Desktop.",
	}
	cmd.AddCommand(newVMSetupCmd(), newVMInstallImageCmd(), newVMInstallBinaryCmd(), newVMStartCmd(), newVMStopCmd(), newVMRestartCmd(), newVMStatusCmd(), newVMLogsCmd(), newVMRouteCmd(), newVMInstallHelperCmd(), newVMUninstallHelperCmd(), newVMTrustCACmd(), newVMUntrustCACmd(), newVMInstallDaemonCmd(), newVMUninstallDaemonCmd())
	return cmd
}

func newVMInstallBinaryCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install-binary",
		Short: "Copy + sign the SkyVM engine into a stable location (~/.skystack/bin)",
		Long: "Copy the SkyVM executable and its entitlements into ~/.skystack/bin and sign\n" +
			"the copy, then repoint runtime.json at it. This makes the VM survive repo\n" +
			"rebuilds, moves, or deletion (a `swift build` no longer strips the signature).",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			path, err := vm.InstallBinary()
			if err != nil {
				return err
			}
			ui.Successf("SkyVM engine installed to a stable location")
			fmt.Printf("  binary: %s\n", path)
			return nil
		},
	}
}

func newVMInstallDaemonCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install-daemon",
		Short: "Auto-start SkyVM at login (launchd) so it survives reboots",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			p, err := vm.InstallDaemon()
			if err != nil {
				return err
			}
			ui.Successf("SkyVM will auto-start at login")
			fmt.Printf("  agent: %s\n  remove with: skystack vm uninstall-daemon\n", p)
			return nil
		},
	}
}

func newVMUninstallDaemonCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall-daemon",
		Short: "Stop auto-starting SkyVM at login",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := vm.UninstallDaemon(); err != nil {
				return err
			}
			ui.Successf("SkyVM auto-start removed")
			return nil
		},
	}
}

func newVMInstallImageCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install-image <path-or-url>",
		Short: "Install a pre-built guest image — no Docker needed",
		Long: "Install a pre-built SkyVM guest image bundle (vmlinux + initramfs + rootfs)\n" +
			"into ~/.skystack/assets. No Docker or image build required — this is the\n" +
			"path for using SkyStack on a Mac without the build toolchain.\n\n" +
			"The bundle is a .tar.gz (local file or http(s) URL). When a <bundle>.sha256\n" +
			"sidecar is available it is verified. Afterwards run `skystack vm setup` to\n" +
			"register the SkyVM binary, then `skystack vm start`.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			stop := ui.Spinner("installing guest image")
			assets, err := vm.InstallImage(args[0])
			stop()
			if err != nil {
				return err
			}
			ui.Successf("guest image installed → %s", assets)
			if _, err := vm.LoadRuntime(); err != nil {
				fmt.Println("  next: skystack vm setup   (registers + signs the SkyVM binary)")
			} else {
				fmt.Println("  next: skystack vm start")
			}
			return nil
		},
	}
}

func newVMInstallHelperCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install-helper",
		Short: "Enable automatic container-IP routing (one-time sudo)",
		Long: "Set up seamless networking (one-time sudo). Installs:\n" +
			"  • a least-privilege sudoers rule (NOPASSWD only for /sbin/route on " + vm.ContainerSubnet + ")\n" +
			"  • /etc/resolver/" + vm.Domain + " so *." + vm.Domain + " resolves to container IPs\n" +
			"  • the SkyStack local CA, trusted in the Keychain, so https://*." + vm.Domain + " works\n" +
			"After this, `skystack vm start` auto-routes container IPs and DNS + HTTPS just work.\n" +
			"Undo any time with `skystack vm uninstall-helper`.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("Installing (sudo will ask for your password once):")
			fmt.Printf("  • sudoers NOPASSWD: /sbin/route add/delete -net %s\n", vm.ContainerSubnet)
			fmt.Printf("  • /etc/resolver/%s → 127.0.0.1 (DNS for *.%s)\n", vm.Domain, vm.Domain)
			fmt.Printf("  • trust the SkyStack local CA in the Keychain (HTTPS for *.%s)\n\n", vm.Domain)
			if err := vm.InstallHelper(); err != nil {
				return err
			}
			ui.Successf("helper installed — routing + *.%s DNS + HTTPS now automatic on `vm start`", vm.Domain)
			return nil
		},
	}
}

func newVMUninstallHelperCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall-helper",
		Short: "Remove the automatic-routing sudoers rule",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !vm.HelperInstalled() {
				ui.Successf("helper is not installed")
				return nil
			}
			if err := vm.UninstallHelper(); err != nil {
				return err
			}
			ui.Successf("helper removed")
			return nil
		},
	}
}

func newVMTrustCACmd() *cobra.Command {
	return &cobra.Command{
		Use:   "trust-ca",
		Short: "Trust the SkyStack local CA for https://*." + vm.Domain + " (sudo)",
		Long: "Generate (if needed) and trust the SkyStack local Certificate Authority in\n" +
			"the macOS system keychain, so browsers accept https://<name>." + vm.Domain + ".\n" +
			"The CA is name-constrained to " + vm.Domain + " only. Undo with `vm untrust-ca`.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if _, err := vm.EnsureCA(); err != nil {
				return err
			}
			fmt.Println("Trusting the SkyStack local CA (sudo may ask for your password):")
			if err := vm.TrustCA(); err != nil {
				return err
			}
			ui.Successf("CA trusted — https://<name>.%s now works (rebuild/restart the VM if it's running)", vm.Domain)
			return nil
		},
	}
}

func newVMUntrustCACmd() *cobra.Command {
	return &cobra.Command{
		Use:   "untrust-ca",
		Short: "Remove the SkyStack local CA from the Keychain",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !vm.CATrusted() {
				ui.Successf("CA is not trusted")
				return nil
			}
			if err := vm.UntrustCA(); err != nil {
				return err
			}
			ui.Successf("CA untrusted")
			return nil
		},
	}
}

func newVMRouteCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "route [add|remove]",
		Short: "Make container IPs directly reachable from the Mac (needs sudo)",
		Long:  "Add (or remove) a host route so you can reach container IPs directly —\n`curl http://172.17.0.2` with no port publishing. Uses sudo to change the\nroute table; re-run `add` after the VM restarts if its IP changed.",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			action := "add"
			if len(args) == 1 {
				action = args[0]
			}
			if action != "add" && action != "remove" {
				return fmt.Errorf("expected 'add' or 'remove', got %q", action)
			}

			ns, err := vm.LoadNetState()
			if err != nil || ns.IP == "" {
				return fmt.Errorf("guest IP unknown — is the VM running? (start it with `skystack vm start`)")
			}
			fmt.Printf("sudo %s\n", strings.Join(vm.RouteCommand(action, ns.IP), " "))
			if err := vm.ApplyRoute(action, ns.IP); err != nil {
				return err
			}
			if action == "add" {
				ui.Successf("container IPs (%s) routed via the VM (%s) — try: curl http://<container-ip>", vm.ContainerSubnet, ns.IP)
				if !vm.HelperInstalled() {
					fmt.Println("  tip: `skystack vm install-helper` makes this automatic on every `vm start`")
				}
			} else {
				ui.Successf("route removed")
			}
			return nil
		},
	}
	return cmd
}

func newVMSetupCmd() *cobra.Command {
	var opts vm.SetupOptions
	cmd := &cobra.Command{
		Use:   "setup",
		Short: "Register the SkyVM binary + image and sign it for use",
		Long:  "Locate the SkyVM runtime (auto-detected from a nearby vm-runtime directory,\nor via --runtime/--binary/--assets), optionally sign it, and record it so\n`skystack vm start` and the `skyvm` host can use it.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			rt, err := vm.Setup(opts)
			if err != nil {
				return err
			}
			ui.Successf("SkyVM runtime ready")
			share := rt.Share
			if share == "" {
				share = "(disabled)"
			}
			fmt.Printf("  binary: %s\n  assets: %s\n  sizing: %d vCPU / %d GiB\n  share:  %s\n", rt.Binary, rt.Assets, orDefault(rt.CPUs, 4), orDefault(rt.MemoryGiB, 4), share)
			fmt.Println("\nstart it with:  skystack vm start")
			return nil
		},
	}
	f := cmd.Flags()
	f.StringVar(&opts.RuntimeDir, "runtime", "", "path to the vm-runtime directory (auto-detected if omitted)")
	f.StringVar(&opts.Binary, "binary", "", "explicit path to the SkyVM executable")
	f.StringVar(&opts.Assets, "assets", "", "explicit path to the image assets directory")
	f.IntVar(&opts.CPUs, "cpus", 4, "vCPUs for the guest")
	f.IntVar(&opts.MemoryGiB, "memory-gib", 4, "memory (GiB) for the guest")
	f.StringVar(&opts.Share, "share", "", "Mac dir to mirror into the VM (default: home; use - to disable)")
	f.BoolVar(&opts.Verbose, "verbose", false, "verbose guest boot logging")
	f.BoolVar(&opts.Sign, "sign", true, "ad-hoc sign the binary with the virtualization entitlement")
	return cmd
}

func newVMStartCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "start",
		Short: "Boot the local VM and wait until its Docker engine is ready",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			svc, err := vm.New()
			if err != nil {
				return err
			}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
			defer cancel()

			stop := ui.Spinner("booting SkyVM (kernel → OpenRC → Docker)")
			err = svc.Start(ctx)
			stop()
			if err != nil {
				return err
			}
			st := svc.Status(ctx)
			ui.Successf("SkyVM running — Docker %s ready on host `skyvm`", st.DockerVersion)
			if vm.HelperInstalled() && routePresent() {
				fmt.Printf("  routing: container IPs reachable directly (%s)\n", vm.ContainerSubnet)
			}
			fmt.Println("  try:  skystack ps skyvm   ·   skystack ps -A")
			return nil
		},
	}
}

func newVMStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop",
		Short: "Gracefully shut down the local VM",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			svc, err := vm.New()
			if err != nil {
				return err
			}
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
			defer cancel()
			stop := ui.Spinner("stopping SkyVM")
			err = svc.Stop(ctx)
			stop()
			if err != nil {
				return err
			}
			ui.Successf("SkyVM stopped")
			return nil
		},
	}
}

func newVMRestartCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "restart",
		Short: "Restart the local VM",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			svc, err := vm.New()
			if err != nil {
				return err
			}
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
			defer cancel()
			if st := svc.Status(ctx); st.Running {
				stop := ui.Spinner("stopping SkyVM")
				_ = svc.Stop(ctx)
				stop()
			}
			stop := ui.Spinner("booting SkyVM")
			err = svc.Start(ctx)
			stop()
			if err != nil {
				return err
			}
			ui.Successf("SkyVM restarted")
			return nil
		},
	}
}

func newVMStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show the local VM's status",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			svc, err := vm.New()
			if err != nil {
				return err
			}
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			st := svc.Status(ctx)

			switch {
			case st.Running && st.SocketReady:
				fmt.Printf("%s SkyVM running — Docker %s (pid %d)\n", ui.StateDot("running"), st.DockerVersion, st.PID)
			case st.Running:
				fmt.Printf("%s SkyVM booting (pid %d, engine not ready yet)\n", ui.StateDot("paused"), st.PID)
			default:
				fmt.Printf("%s SkyVM stopped\n", ui.StateDot("exited"))
			}
			fmt.Printf("  socket: %s\n  log:    %s\n", st.Socket, st.LogPath)
			if ns, err := vm.LoadNetState(); err == nil && ns.IP != "" && st.Running {
				routed := ""
				if routePresent() {
					routed = "  (container IPs routed ✓)"
				}
				fmt.Printf("  ip:     %s%s\n", ns.IP, routed)
			}
			if st.SocketReady {
				if ports := forwardedPorts(ctx); len(ports) > 0 {
					labels := make([]string, len(ports))
					for i, p := range ports {
						labels[i] = "localhost:" + p
					}
					fmt.Printf("  ports:  %s\n", strings.Join(labels, "  "))
				}
			}
			switch {
			case vm.CATrusted():
				fmt.Printf("  https:  https://<name>.%s  (CA trusted ✓)\n", vm.Domain)
			case vm.CAExists():
				fmt.Printf("  https:  CA generated, not trusted — run `skystack vm trust-ca`\n")
			}
			return nil
		},
	}
}

// routePresent reports whether the container subnet is routed on the Mac.
func routePresent() bool {
	out, err := exec.Command("netstat", "-rn", "-f", "inet").Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "172.16/12") || strings.Contains(string(out), "172.16.0.0/12")
}

// forwardedPorts lists the published host ports of containers in the VM — these
// are the ports SkyVM auto-forwards to the Mac's localhost.
func forwardedPorts(ctx context.Context) []string {
	reg, err := loadRegistry()
	if err != nil {
		return nil
	}
	host, err := reg.Get(config.SkyVMHost)
	if err != nil {
		return nil
	}
	eng, err := core.Connect(ctx, host)
	if err != nil {
		return nil
	}
	defer eng.Close()
	containers, err := eng.List(ctx, false)
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	for _, c := range containers {
		for _, p := range c.Ports { // "9090→80"
			if pub, _, ok := strings.Cut(p, "→"); ok {
				seen[pub] = true
			}
		}
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

func newVMLogsCmd() *cobra.Command {
	var follow bool
	cmd := &cobra.Command{
		Use:   "logs",
		Short: "Show the VM boot/console log",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			svc, err := vm.New()
			if err != nil {
				return err
			}
			path := svc.LogPath()
			if _, err := os.Stat(path); err != nil {
				return fmt.Errorf("no VM log yet at %s", path)
			}
			tail := exec.Command("tail", "-n", "200")
			if follow {
				tail = exec.Command("tail", "-n", "200", "-f", path)
			} else {
				tail.Args = append(tail.Args, path)
			}
			tail.Stdout = os.Stdout
			tail.Stderr = os.Stderr
			return tail.Run()
		},
	}
	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "follow the log")
	return cmd
}

func orDefault(v, d int) int {
	if v == 0 {
		return d
	}
	return v
}
