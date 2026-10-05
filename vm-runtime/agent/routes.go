package main

import (
	"encoding/json"
	"net"
	"sort"
	"strings"
)

// Route is a reverse-proxy target: the container's IP and the TCP port the
// proxy forwards plain HTTP to (its lowest sensible exposed port).
type Route struct {
	IP   net.IP
	Port int
}

// parseContainerRoutes maps container hostnames (and Compose service.project)
// to their reverse-proxy target. It mirrors parseContainerDomains' naming so the
// DNS server and the proxy agree on which names exist, but additionally picks the
// container's HTTP port. Keys are lowercased and suffixed with the local domain.
func parseContainerRoutes(httpResponse []byte) map[string]Route {
	body := dockerBody(httpResponse)
	if body == nil {
		return nil
	}
	var containers []struct {
		Names  []string          `json:"Names"`
		Labels map[string]string `json:"Labels"`
		Ports  []struct {
			PrivatePort int    `json:"PrivatePort"`
			Type        string `json:"Type"`
		} `json:"Ports"`
		NetworkSettings struct {
			Networks map[string]struct {
				IPAddress string `json:"IPAddress"`
			} `json:"Networks"`
		} `json:"NetworkSettings"`
	}
	if err := json.Unmarshal(body, &containers); err != nil {
		return nil
	}

	out := map[string]Route{}
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
		ports := make([]int, 0, len(c.Ports))
		for _, p := range c.Ports {
			if p.Type == "tcp" && p.PrivatePort > 0 {
				ports = append(ports, p.PrivatePort)
			}
		}
		r := Route{IP: ip, Port: pickHTTPPort(ports)}
		for _, name := range c.Names {
			name = strings.TrimPrefix(name, "/")
			if name != "" {
				out[strings.ToLower(name)+DomainSuffix] = r
			}
		}
		svc, proj := c.Labels["com.docker.compose.service"], c.Labels["com.docker.compose.project"]
		if svc != "" && proj != "" {
			out[strings.ToLower(svc+"."+proj)+DomainSuffix] = r
		}
	}
	return out
}

// pickHTTPPort chooses which exposed container port the proxy forwards to:
// prefer well-known HTTP ports, else the lowest exposed port, else 80.
func pickHTTPPort(exposed []int) int {
	if len(exposed) == 0 {
		return 80
	}
	set := map[int]bool{}
	for _, p := range exposed {
		set[p] = true
	}
	for _, pref := range []int{80, 8080, 8000, 3000, 5000} {
		if set[pref] {
			return pref
		}
	}
	sort.Ints(exposed)
	return exposed[0]
}
