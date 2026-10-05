package cli

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/vm"
)

// newInstallCmd wires SkyStack to run persistently on this Mac: a stable signed
// SkyVM engine, LaunchAgents that start the VM + multi-host daemon at login (and
// survive reboot), and — by default — the privileged *.sky.local DNS / routing /
// CA-trust setup. Idempotent. The .pkg installer calls it with --user-only (as
// the console user) and --system-only (as root); a terminal user just runs it.
func newInstallCmd() *cobra.Command {
	var image, skyvmBinary, skyvmEnt string
	var withHelper, userOnly, systemOnly bool
	var targetUser, targetHome string
	cmd := &cobra.Command{
		Use:   "install",
		Short: "Install SkyStack to run persistently on this Mac (auto-start + setup)",
		Long: "Make SkyStack start automatically at login and survive reboots:\n" +
			"  • copy the SkyVM engine to a stable, signed location (~/.skystack/bin)\n" +
			"  • install LaunchAgents for the SkyVM and the multi-host daemon\n" +
			"  • (default) set up *." + vm.Domain + " DNS, container-IP routing, and trust the local CA\n\n" +
			"Idempotent — safe to re-run. Undo with `skystack uninstall`.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if systemOnly {
				return runSystemInstall(targetUser, targetHome)
			}
			if err := runUserInstall(image, skyvmBinary, skyvmEnt); err != nil {
				return err
			}
			if userOnly {
				return nil
			}
			if withHelper {
				fmt.Println("• setting up *." + vm.Domain + " DNS + routing + CA trust (sudo)…")
				if _, err := vm.EnsureCA(); err != nil {
					return err
				}
				if err := vm.InstallHelper(); err != nil {
					return err
				}
			}
			fmt.Println("\n✓ SkyStack installed. The SkyVM and daemon will start at login.")
			return nil
		},
	}
	cmd.Flags().StringVar(&image, "image", "", "guest image bundle (.tar.gz) or directory to install first")
	cmd.Flags().StringVar(&skyvmBinary, "skyvm-binary", "", "SkyVM executable to seed from (fresh install; used by the .pkg)")
	cmd.Flags().StringVar(&skyvmEnt, "skyvm-entitlements", "", "SkyVM.entitlements for the seed binary (defaults beside it)")
	cmd.Flags().BoolVar(&withHelper, "with-helper", true, "set up *."+vm.Domain+" DNS, routing, and trust the CA (one sudo prompt)")
	cmd.Flags().BoolVar(&userOnly, "user-only", false, "only the per-user steps (binary + agents) — used by the installer")
	cmd.Flags().BoolVar(&systemOnly, "system-only", false, "only the privileged steps; must run as root — used by the installer")
	cmd.Flags().StringVar(&targetUser, "user", "", "with --system-only: the user who owns the route rule + CA")
	cmd.Flags().StringVar(&targetHome, "home", "", "with --system-only: that user's home directory")
	return cmd
}

// runUserInstall does the unprivileged, per-user steps. When skyvmBinary is set
// (a fresh install from the .pkg payload) it seeds from those artifacts; else it
// uses the existing runtime.json / a local build tree.
func runUserInstall(image, skyvmBinary, skyvmEnt string) error {
	fmt.Println("• installing the SkyVM engine to ~/.skystack/bin (stable + signed)")
	if skyvmBinary != "" {
		if skyvmEnt == "" {
			skyvmEnt = filepath.Join(filepath.Dir(skyvmBinary), "SkyVM.entitlements")
		}
		if _, err := vm.InstallFrom(skyvmBinary, skyvmEnt, image); err != nil {
			return fmt.Errorf("seed SkyVM engine: %w", err)
		}
	} else {
		if image != "" {
			fmt.Printf("  installing guest image from %s\n", image)
			if _, err := vm.InstallImage(image); err != nil {
				return fmt.Errorf("install image: %w", err)
			}
		}
		if _, err := vm.InstallBinary(); err != nil {
			return fmt.Errorf("install SkyVM engine: %w", err)
		}
	}
	fmt.Println("• installing the SkyVM auto-start LaunchAgent")
	if _, err := vm.InstallDaemon(); err != nil {
		return fmt.Errorf("install SkyVM agent: %w", err)
	}
	fmt.Println("• installing the daemon auto-start LaunchAgent")
	if _, err := installDaemonAgent(); err != nil {
		return fmt.Errorf("install daemon agent: %w", err)
	}
	// Generate the local CA now so the privileged step can trust it.
	_, _ = vm.EnsureCA()
	return nil
}

// runSystemInstall does the privileged steps directly as root (no sudo). Used by
// the .pkg postinstall; `username`/`home` identify the real console user.
func runSystemInstall(username, home string) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("--system-only must run as root")
	}
	if username == "" {
		return fmt.Errorf("--system-only requires --user <name>")
	}
	if home == "" {
		home = filepath.Join("/Users", username)
	}
	caDir := filepath.Join(home, ".skystack", "ca")
	fmt.Printf("• privileged setup for %s (sudoers + resolver + CA trust)\n", username)
	return vm.InstallHelperAsRoot(username, caDir)
}

// newUninstallCmd reverses `install`: removes the LaunchAgents and the privileged
// setup. The app, CLI binary, and ~/.skystack data are left in place.
func newUninstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall",
		Short: "Remove SkyStack's LaunchAgents and privileged setup",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("• removing the daemon LaunchAgent")
			_ = uninstallDaemonAgent()
			fmt.Println("• removing the SkyVM LaunchAgent")
			_ = vm.UninstallDaemon()
			fmt.Println("• removing the privileged setup (sudo)")
			_ = vm.UninstallHelper()
			fmt.Println("\n✓ uninstalled. The app, CLI, and ~/.skystack data are left in place.")
			return nil
		},
	}
}
