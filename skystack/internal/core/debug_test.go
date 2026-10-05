package core

import "testing"

func TestDebugHostConfig(t *testing.T) {
	hc := debugHostConfig("abc123")
	if string(hc.PidMode) != "container:abc123" {
		t.Errorf("PidMode = %q", hc.PidMode)
	}
	if string(hc.NetworkMode) != "container:abc123" {
		t.Errorf("NetworkMode = %q", hc.NetworkMode)
	}
	if !hc.AutoRemove {
		t.Error("AutoRemove should be true so the toolbox cleans up on exit")
	}
	found := false
	for _, c := range hc.CapAdd {
		if c == "SYS_PTRACE" {
			found = true
		}
	}
	if !found {
		t.Errorf("CapAdd should grant SYS_PTRACE, got %v", hc.CapAdd)
	}
}
