package core

import "testing"

func TestResolveDistro(t *testing.T) {
	cases := map[string]string{
		"ubuntu":             "ubuntu:24.04",
		"ALPINE":             "alpine:3.21",
		"ghcr.io/foo/bar:v1": "ghcr.io/foo/bar:v1", // raw image ref passes through
		"alpine:edge":        "alpine:edge",
	}
	for in, want := range cases {
		got, err := ResolveDistro(in)
		if err != nil || got != want {
			t.Errorf("ResolveDistro(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := ResolveDistro("plan9"); err == nil {
		t.Error("expected an error for an unknown distro with no image form")
	}
}
