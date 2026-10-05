package main

import (
	"bytes"
	"encoding/json"
	"net"
	"sort"
	"strings"
)

// NetState is the guest network snapshot streamed to the host: the guest's
// primary IP and the set of published (host-bound) TCP ports.
type NetState struct {
	IP    string `json:"ip"`
	Ports []int  `json:"ports"`
}

// Equal compares two snapshots (Ports assumed sorted).
func (s NetState) Equal(o NetState) bool {
	if s.IP != o.IP || len(s.Ports) != len(o.Ports) {
		return false
	}
	for i := range s.Ports {
		if s.Ports[i] != o.Ports[i] {
			return false
		}
	}
	return true
}

// parsePublishedPorts extracts the sorted, unique set of published TCP host
// ports from a Docker `GET /containers/json` HTTP response (headers + body).
func parsePublishedPorts(httpResponse []byte) []int {
	idx := bytes.Index(httpResponse, []byte("\r\n\r\n"))
	if idx < 0 {
		return nil
	}
	body := httpResponse[idx+4:]

	var containers []struct {
		Ports []struct {
			PublicPort int    `json:"PublicPort"`
			Type       string `json:"Type"`
		} `json:"Ports"`
	}
	if err := json.Unmarshal(body, &containers); err != nil {
		return nil
	}

	seen := map[int]bool{}
	for _, c := range containers {
		for _, p := range c.Ports {
			if p.PublicPort > 0 && p.Type == "tcp" {
				seen[p.PublicPort] = true
			}
		}
	}
	out := make([]int, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Ints(out)
	return out
}

// dockerBody returns the body of a Docker HTTP response (after the headers).
func dockerBody(httpResponse []byte) []byte {
	if i := bytes.Index(httpResponse, []byte("\r\n\r\n")); i >= 0 {
		return httpResponse[i+4:]
	}
	return nil
}

// parseContainerDomains maps container names (and Compose service.project) to
// their first container IP, suffixed with the local domain. Keys are lowercased.
func parseContainerDomains(httpResponse []byte) map[string]net.IP {
	body := dockerBody(httpResponse)
	if body == nil {
		return nil
	}
	var containers []struct {
		Names           []string          `json:"Names"`
		Labels          map[string]string `json:"Labels"`
		NetworkSettings struct {
			Networks map[string]struct {
				IPAddress string `json:"IPAddress"`
			} `json:"Networks"`
		} `json:"NetworkSettings"`
	}
	if err := json.Unmarshal(body, &containers); err != nil {
		return nil
	}

	out := map[string]net.IP{}
	for _, c := range containers {
		var ip net.IP
		for _, n := range c.NetworkSettings.Networks {
			if n.IPAddress != "" {
				ip = net.ParseIP(n.IPAddress)
				break
			}
		}
		if ip == nil {
			continue
		}
		for _, name := range c.Names {
			name = strings.TrimPrefix(name, "/")
			if name != "" {
				out[strings.ToLower(name)+DomainSuffix] = ip
			}
		}
		svc, proj := c.Labels["com.docker.compose.service"], c.Labels["com.docker.compose.project"]
		if svc != "" && proj != "" {
			out[strings.ToLower(svc+"."+proj)+DomainSuffix] = ip
		}
	}
	return out
}
