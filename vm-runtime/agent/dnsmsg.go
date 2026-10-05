package main

import (
	"encoding/binary"
	"errors"
	"net"
	"strings"
)

// DomainSuffix is the local TLD served for containers (e.g. web.sky.local).
const DomainSuffix = ".sky.local"

// K8sDomainSuffix is served for Kubernetes ingress/services — any
// <name>.k8s.sky.local resolves to this guest (the cluster ingress).
const K8sDomainSuffix = ".k8s.sky.local"

// dnsTypeA is the A (IPv4) record type.
const dnsTypeA = 1

// parseQuestion extracts the lowercased QNAME (no trailing dot) and QTYPE from a
// DNS query. It rejects compression in the question (clients never use it).
func parseQuestion(msg []byte) (name string, qtype uint16, err error) {
	if len(msg) < 12 {
		return "", 0, errors.New("short dns message")
	}
	if binary.BigEndian.Uint16(msg[4:6]) < 1 {
		return "", 0, errors.New("no question")
	}
	off := 12
	var labels []string
	for {
		if off >= len(msg) {
			return "", 0, errors.New("truncated qname")
		}
		l := int(msg[off])
		off++
		if l == 0 {
			break
		}
		if l&0xC0 != 0 {
			return "", 0, errors.New("compressed qname")
		}
		if off+l > len(msg) {
			return "", 0, errors.New("truncated label")
		}
		labels = append(labels, string(msg[off:off+l]))
		off += l
	}
	if off+4 > len(msg) {
		return "", 0, errors.New("truncated question")
	}
	qtype = binary.BigEndian.Uint16(msg[off : off+2])
	return strings.ToLower(strings.Join(labels, ".")), qtype, nil
}

// questionEnd returns the offset just past the (single) question section, or -1.
func questionEnd(msg []byte) int {
	if len(msg) < 12 {
		return -1
	}
	off := 12
	for {
		if off >= len(msg) {
			return -1
		}
		l := int(msg[off])
		off++
		if l == 0 {
			break
		}
		if l&0xC0 != 0 || off+l > len(msg) {
			return -1
		}
		off += l
	}
	if off+4 > len(msg) {
		return -1
	}
	return off + 4 // QTYPE + QCLASS
}

// buildAnswer returns a response to a query. With a non-nil ip it returns one A
// record. With a nil ip it returns NXDOMAIN when nxdomain is true (name unknown),
// otherwise an empty NOERROR (NODATA — the name exists but has no record of this
// type, e.g. AAAA for an A-only host; returning NXDOMAIN there makes resolvers
// stall). It keeps only header+question+answer (dropping the client's EDNS OPT)
// and references the question name via a compression pointer to offset 12.
func buildAnswer(query []byte, ip net.IP, nxdomain bool) []byte {
	qEnd := questionEnd(query)
	if qEnd < 0 {
		qEnd = len(query)
	}
	resp := make([]byte, qEnd)
	copy(resp, query[:qEnd])
	resp[2] = query[2] | 0x80                  // QR=1, preserve Opcode/RD
	resp[3] = 0x80                             // RA=1, RCODE=0
	binary.BigEndian.PutUint16(resp[6:8], 0)   // ANCOUNT
	binary.BigEndian.PutUint16(resp[8:10], 0)  // NSCOUNT
	binary.BigEndian.PutUint16(resp[10:12], 0) // ARCOUNT (drop EDNS OPT)

	v4 := ip.To4()
	if v4 == nil {
		if nxdomain {
			resp[3] = 0x83 // RCODE=3 (NXDOMAIN)
		}
		// else: NOERROR with ANCOUNT=0 (NODATA)
		return resp
	}
	binary.BigEndian.PutUint16(resp[6:8], 1) // ANCOUNT=1
	answer := []byte{
		0xC0, 0x0C, // NAME → pointer to offset 12
		0x00, 0x01, // TYPE A
		0x00, 0x01, // CLASS IN
		0x00, 0x00, 0x00, 0x05, // TTL 5s
		0x00, 0x04, // RDLENGTH 4
		v4[0], v4[1], v4[2], v4[3],
	}
	return append(resp, answer...)
}

// encodeQuery builds a minimal A query for name (test helper / not used in prod).
func encodeQuery(id uint16, name string) []byte {
	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[0:2], id)
	msg[2] = 0x01 // RD=1
	binary.BigEndian.PutUint16(msg[4:6], 1)
	for _, label := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		msg = append(msg, byte(len(label)))
		msg = append(msg, []byte(label)...)
	}
	msg = append(msg, 0x00)       // end of QNAME
	msg = append(msg, 0x00, 0x01) // QTYPE A
	msg = append(msg, 0x00, 0x01) // QCLASS IN
	return msg
}
