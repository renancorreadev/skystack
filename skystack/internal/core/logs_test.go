package core

import "testing"

func TestParseLineSeverity(t *testing.T) {
	c := Container{Host: "local", Name: "api"}
	cases := []struct {
		name    string
		raw     string
		wantSev string
		wantMsg string
	}{
		{
			name:    "docker timestamp + nginx error",
			raw:     "2026-06-24T19:51:17.000000000Z 2026/06/24 [error] open() failed",
			wantSev: "ERROR",
		},
		{
			name:    "warn keyword",
			raw:     "2026-06-24T10:00:00Z something WARNING happened",
			wantSev: "WARN",
		},
		{
			name:    "json level field",
			raw:     `2026-06-24T10:00:00Z {"level":"error","msg":"boom"}`,
			wantSev: "ERROR",
		},
		{
			name:    "plain info line",
			raw:     "2026-06-24T10:00:00Z INFO server started",
			wantSev: "INFO",
		},
		{
			name:    "no severity",
			raw:     "2026-06-24T10:00:00Z just a line",
			wantSev: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			l := parseLine(c, tc.raw)
			if l.Severity != tc.wantSev {
				t.Errorf("severity = %q, want %q (msg=%q)", l.Severity, tc.wantSev, l.Message)
			}
			if !l.HasTime {
				t.Errorf("expected timestamp to be parsed from %q", tc.raw)
			}
		})
	}
}

func TestParseLineStreamTag(t *testing.T) {
	c := Container{Host: "local", Name: "api"}
	l := parseLine(c, "\x00stderr\x002026-06-24T10:00:00Z boom")
	if l.Stream != "stderr" {
		t.Errorf("stream = %q, want stderr", l.Stream)
	}
	if l.Message != "boom" {
		t.Errorf("message = %q, want boom", l.Message)
	}
}

func TestSeverityRank(t *testing.T) {
	if severityRank("ERROR") <= severityRank("WARN") {
		t.Fatal("ERROR should outrank WARN")
	}
	if severityRank("") != 0 {
		t.Fatal("empty severity should rank 0")
	}
}
