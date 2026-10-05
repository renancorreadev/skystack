package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/ui"
	"github.com/skynance/skystack/internal/vm"
)

func newK8sCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "k8s",
		Short: "Manage the in-VM single-node Kubernetes (k3s)",
		Long:  "Run a lightweight single-node Kubernetes (k3s) inside SkyVM. Enable it, then\nrestart the VM; the cluster's kubeconfig is exported to the Mac so `kubectl`\nworks against https://" + "127.0.0.1:6443" + ".",
	}
	cmd.AddCommand(newK8sEnableCmd(), newK8sDisableCmd(), newK8sStatusCmd(), newK8sKubeconfigCmd())
	return cmd
}

func newK8sEnableCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "enable",
		Short: "Enable Kubernetes (takes effect on the next VM start)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := vm.SetK8s(true); err != nil {
				return err
			}
			ui.Successf("Kubernetes enabled — apply with: skystack vm restart")
			fmt.Println("  (needs a guest image built with k3s — see vm-runtime/README)")
			return nil
		},
	}
}

func newK8sDisableCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "disable",
		Short: "Disable Kubernetes (takes effect on the next VM start)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := vm.SetK8s(false); err != nil {
				return err
			}
			ui.Successf("Kubernetes disabled — apply with: skystack vm restart")
			return nil
		},
	}
}

func newK8sStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show Kubernetes status",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !vm.K8sEnabled() {
				fmt.Printf("%s Kubernetes disabled — enable with `skystack k8s enable`\n", ui.StateDot("exited"))
				return nil
			}
			if vm.K8sReachable() {
				fmt.Printf("%s Kubernetes running — API at https://127.0.0.1:6443\n", ui.StateDot("running"))
				if p, err := vm.KubeconfigPath(); err == nil {
					fmt.Printf("  kubeconfig: %s\n  use it:     export KUBECONFIG=%s\n", p, p)
				}
			} else {
				fmt.Printf("%s Kubernetes enabled but not reachable — is the VM running? (skystack vm start)\n", ui.StateDot("paused"))
			}
			return nil
		},
	}
}

func newK8sKubeconfigCmd() *cobra.Command {
	var printPath bool
	cmd := &cobra.Command{
		Use:   "kubeconfig",
		Short: "Print the cluster kubeconfig (or its path with --path)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			p, err := vm.KubeconfigPath()
			if err != nil {
				return err
			}
			if printPath {
				fmt.Println(p)
				return nil
			}
			data, err := os.ReadFile(p)
			if err != nil {
				return fmt.Errorf("kubeconfig not found at %s — enable k8s and start the VM first", p)
			}
			_, err = os.Stdout.Write(data)
			return err
		},
	}
	cmd.Flags().BoolVar(&printPath, "path", false, "print the kubeconfig path instead of its contents")
	return cmd
}
