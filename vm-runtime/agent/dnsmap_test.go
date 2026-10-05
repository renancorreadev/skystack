package main

import (
	"net"
	"testing"
)

func TestParseContainerDomains(t *testing.T) {
	body := `[
	  {"Names":["/web"],"Labels":{},"NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.17.0.2"}}}},
	  {"Names":["/core-api"],
	   "Labels":{"com.docker.compose.service":"api","com.docker.compose.project":"core"},
	   "NetworkSettings":{"Networks":{"core_default":{"IPAddress":"172.18.0.3"}}}},
	  {"Names":["/no-ip"],"Labels":{},"NetworkSettings":{"Networks":{}}}
	]`
	resp := "HTTP/1.1 200 OK\r\n\r\n" + body

	got := parseContainerDomains([]byte(resp))
	want := map[string]string{
		"web.sky.local":      "172.17.0.2",
		"core-api.sky.local": "172.18.0.3",
		"api.core.sky.local": "172.18.0.3", // compose service.project
	}
	if len(got) != len(want) {
		t.Fatalf("got %d entries, want %d: %v", len(got), len(want), got)
	}
	for name, ipStr := range want {
		if ip, ok := got[name]; !ok || !ip.Equal(net.ParseIP(ipStr)) {
			t.Errorf("%s = %v, want %s", name, got[name], ipStr)
		}
	}
	if _, ok := got["no-ip.sky.local"]; ok {
		t.Error("container with no IP should be skipped")
	}
}
