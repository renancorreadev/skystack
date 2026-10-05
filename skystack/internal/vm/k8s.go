package vm

import (
	"net"
	"path/filepath"
	"time"

	"github.com/skynance/skystack/internal/config"
)

// k8sAPIAddr is the stable localhost endpoint SkyVM forwards to the in-VM k3s
// API server (guest:6443). k3s' default cert includes 127.0.0.1, so kubeconfig
// pointing here Just Works regardless of the guest's dynamic IP.
const k8sAPIAddr = "127.0.0.1:6443"

// KubeconfigPath is where the guest exports the cluster kubeconfig (over the
// virtiofs share), ready for `export KUBECONFIG=…`.
func KubeconfigPath() (string, error) {
	dir, err := config.Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "k3s.yaml"), nil
}

// SetK8s flips the persisted Kubernetes toggle; it takes effect on the next
// `vm start`.
func SetK8s(enabled bool) error {
	rt, err := LoadRuntime()
	if err != nil {
		return err
	}
	rt.K8s = enabled
	return rt.Save()
}

// K8sEnabled reports the persisted toggle.
func K8sEnabled() bool {
	rt, err := LoadRuntime()
	return err == nil && rt.K8s
}

// K8sReachable reports whether the forwarded API server answers right now.
func K8sReachable() bool {
	conn, err := net.DialTimeout("tcp", k8sAPIAddr, 1500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
