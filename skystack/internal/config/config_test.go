package config

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestParseRef(t *testing.T) {
	cases := []struct {
		ref      string
		wantHost string
		wantCtr  string
	}{
		{"api", "local", "api"},
		{"prod/api", "prod", "api"},
		{"staging/web-1", "staging", "web-1"},
	}
	for _, c := range cases {
		h, ctr := ParseRef(c.ref)
		if h != c.wantHost || ctr != c.wantCtr {
			t.Errorf("ParseRef(%q) = (%q,%q), want (%q,%q)", c.ref, h, ctr, c.wantHost, c.wantCtr)
		}
	}
}

func TestSkyVMBuiltinHost(t *testing.T) {
	reg, err := Load(filepath.Join(t.TempDir(), "hosts.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	h, err := reg.Get(SkyVMHost)
	if err != nil {
		t.Fatalf("skyvm host should always resolve: %v", err)
	}
	if !h.IsSkyVM() {
		t.Error("expected IsSkyVM() to be true")
	}
	if h.IsLocal() {
		t.Error("skyvm host should not be local")
	}
	if !strings.HasPrefix(h.Docker, "unix://") || !strings.HasSuffix(h.Docker, "skyvm-docker.sock") {
		t.Errorf("unexpected skyvm docker endpoint: %q", h.Docker)
	}

	host, ctr := ParseRef("skyvm/web")
	if host != SkyVMHost || ctr != "web" {
		t.Errorf("ParseRef(skyvm/web) = (%q,%q)", host, ctr)
	}
}

func TestRegistryRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hosts.yaml")
	reg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}

	// local is always resolvable without registration.
	if h, err := reg.Get("local"); err != nil || !h.IsLocal() {
		t.Fatalf("local host: %v (isLocal=%v)", err, h.IsLocal())
	}

	// reserved name rejected.
	if err := reg.Add("local", "ssh://x@y", ""); err == nil {
		t.Error("expected error adding reserved 'local'")
	}
	// non-ssh URL rejected.
	if err := reg.Add("prod", "tcp://x", ""); err == nil {
		t.Error("expected error for non-ssh URL")
	}
	// happy path.
	if err := reg.Add("prod", "ssh://ubuntu@1.2.3.4", "production"); err != nil {
		t.Fatal(err)
	}
	if err := reg.Save(); err != nil {
		t.Fatal(err)
	}

	// reload and verify persistence + Name backfill.
	reg2, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	h, err := reg2.Get("prod")
	if err != nil {
		t.Fatal(err)
	}
	if h.SSH != "ssh://ubuntu@1.2.3.4" || h.Name != "prod" || h.IsLocal() {
		t.Fatalf("unexpected host after reload: %+v", h)
	}

	// All() returns local first.
	all := reg2.All()
	// local is always first; prod must be present. (skyvm may also appear if the
	// VM runtime happens to be installed on this machine — don't assume length.)
	if len(all) < 2 || all[0].Name != "local" {
		t.Fatalf("All() should start with local: %+v", all)
	}
	foundProd := false
	for _, h := range all {
		if h.Name == "prod" {
			foundProd = true
		}
	}
	if !foundProd {
		t.Fatalf("prod missing from All(): %+v", all)
	}

	// unknown host errors.
	if _, err := reg2.Get("nope"); err == nil {
		t.Error("expected error for unknown host")
	}
}
