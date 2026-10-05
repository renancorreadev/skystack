package main

import (
	"reflect"
	"testing"
)

func TestParsePublishedPorts(t *testing.T) {
	body := `[
	  {"Id":"a","Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},
	                     {"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]},
	  {"Id":"b","Ports":[{"PrivatePort":5432,"PublicPort":5432,"Type":"tcp"},
	                     {"PrivatePort":53,"PublicPort":1053,"Type":"udp"}]},
	  {"Id":"c","Ports":[{"PrivatePort":9000,"Type":"tcp"}]}
	]`
	resp := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + body

	got := parsePublishedPorts([]byte(resp))
	want := []int{5432, 8080} // 8080 deduped, udp 1053 excluded, unpublished 9000 excluded
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parsePublishedPorts() = %v, want %v", got, want)
	}
}

func TestParsePublishedPortsEmpty(t *testing.T) {
	resp := "HTTP/1.1 200 OK\r\n\r\n[]"
	if got := parsePublishedPorts([]byte(resp)); len(got) != 0 {
		t.Fatalf("expected no ports, got %v", got)
	}
	if got := parsePublishedPorts([]byte("garbage")); got != nil {
		t.Fatalf("expected nil for malformed response, got %v", got)
	}
}

func TestNetStateEqual(t *testing.T) {
	a := NetState{IP: "192.168.64.10", Ports: []int{80, 443}}
	b := NetState{IP: "192.168.64.10", Ports: []int{80, 443}}
	c := NetState{IP: "192.168.64.10", Ports: []int{80}}
	d := NetState{IP: "192.168.64.11", Ports: []int{80, 443}}
	if !a.Equal(b) {
		t.Error("a should equal b")
	}
	if a.Equal(c) || a.Equal(d) {
		t.Error("a should differ from c and d")
	}
}
