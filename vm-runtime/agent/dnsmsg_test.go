package main

import (
	"encoding/binary"
	"net"
	"testing"
)

func TestParseQuestion(t *testing.T) {
	q := encodeQuery(0x1234, "Web.Sky.Local")
	name, qtype, err := parseQuestion(q)
	if err != nil {
		t.Fatal(err)
	}
	if name != "web.sky.local" { // lowercased
		t.Errorf("name = %q, want web.sky.local", name)
	}
	if qtype != dnsTypeA {
		t.Errorf("qtype = %d, want %d", qtype, dnsTypeA)
	}
}

func TestParseQuestionShort(t *testing.T) {
	if _, _, err := parseQuestion([]byte{0, 0, 0}); err == nil {
		t.Error("expected error for short message")
	}
}

func TestBuildAnswerA(t *testing.T) {
	q := encodeQuery(0xABCD, "api.sky.local")
	resp := buildAnswer(q, net.ParseIP("172.17.0.5"), false)

	// ID preserved, QR set, ANCOUNT=1
	if binary.BigEndian.Uint16(resp[0:2]) != 0xABCD {
		t.Error("ID not preserved")
	}
	if resp[2]&0x80 == 0 {
		t.Error("QR bit not set")
	}
	if binary.BigEndian.Uint16(resp[6:8]) != 1 {
		t.Fatalf("ANCOUNT = %d, want 1", binary.BigEndian.Uint16(resp[6:8]))
	}
	// Last 4 bytes are the A record IP.
	got := net.IPv4(resp[len(resp)-4], resp[len(resp)-3], resp[len(resp)-2], resp[len(resp)-1])
	if !got.Equal(net.ParseIP("172.17.0.5")) {
		t.Errorf("answer IP = %s, want 172.17.0.5", got)
	}
	// pointer to qname
	if resp[len(resp)-16] != 0xC0 || resp[len(resp)-15] != 0x0C {
		t.Error("answer should reference qname via 0xC00C pointer")
	}
}

func TestBuildAnswerNXDOMAIN(t *testing.T) {
	q := encodeQuery(1, "nope.sky.local")
	resp := buildAnswer(q, nil, true)
	if resp[3]&0x0F != 0x03 {
		t.Errorf("RCODE = %d, want 3 (NXDOMAIN)", resp[3]&0x0F)
	}
	if binary.BigEndian.Uint16(resp[6:8]) != 0 {
		t.Error("ANCOUNT should be 0 for NXDOMAIN")
	}
}
