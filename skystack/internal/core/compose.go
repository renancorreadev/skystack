package core

import (
	"fmt"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// ComposeService is one service in a Compose project, with just the fields the
// SkyStack UX cares about: its image/build, published ports, and dependencies.
type ComposeService struct {
	Name      string   `json:"name"`
	Image     string   `json:"image,omitempty"`
	Build     string   `json:"build,omitempty"`
	Ports     []string `json:"ports,omitempty"`
	DependsOn []string `json:"dependsOn,omitempty"`
}

// ComposeProject is a parsed Compose file: its services and their dependency
// edges, plus a topological layering for graph display.
type ComposeProject struct {
	Name     string           `json:"name"`
	Services []ComposeService `json:"services"`
}

// ParseCompose parses a docker-compose.yml into a project graph. It tolerates
// both short and long forms of depends_on, ports, and build.
func ParseCompose(data []byte, name string) (*ComposeProject, error) {
	var raw struct {
		Name     string               `yaml:"name"`
		Services map[string]yaml.Node `yaml:"services"`
	}
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parsing compose file: %w", err)
	}
	if len(raw.Services) == 0 {
		return nil, fmt.Errorf("no services found in compose file")
	}
	if raw.Name != "" {
		name = raw.Name
	}

	proj := &ComposeProject{Name: name}
	for svcName, node := range raw.Services {
		svc := ComposeService{Name: svcName}
		var s struct {
			Image     string    `yaml:"image"`
			Build     yaml.Node `yaml:"build"`
			Ports     yaml.Node `yaml:"ports"`
			DependsOn yaml.Node `yaml:"depends_on"`
		}
		if err := node.Decode(&s); err != nil {
			return nil, fmt.Errorf("service %q: %w", svcName, err)
		}
		svc.Image = s.Image
		svc.Build = buildContext(s.Build)
		svc.Ports = scalarPorts(s.Ports)
		svc.DependsOn = dependsList(s.DependsOn)
		proj.Services = append(proj.Services, svc)
	}
	sort.Slice(proj.Services, func(i, j int) bool { return proj.Services[i].Name < proj.Services[j].Name })
	return proj, nil
}

// buildContext extracts the build context from `build: ./x` or `build: {context: ./x}`.
func buildContext(n yaml.Node) string {
	switch n.Kind {
	case yaml.ScalarNode:
		return n.Value
	case yaml.MappingNode:
		for i := 0; i+1 < len(n.Content); i += 2 {
			if n.Content[i].Value == "context" {
				return n.Content[i+1].Value
			}
		}
	}
	return ""
}

// scalarPorts pulls short-form "h:c" strings (and the published part of long-form).
func scalarPorts(n yaml.Node) []string {
	if n.Kind != yaml.SequenceNode {
		return nil
	}
	var out []string
	for _, item := range n.Content {
		switch item.Kind {
		case yaml.ScalarNode:
			out = append(out, item.Value)
		case yaml.MappingNode:
			var published, target string
			for i := 0; i+1 < len(item.Content); i += 2 {
				switch item.Content[i].Value {
				case "published":
					published = item.Content[i+1].Value
				case "target":
					target = item.Content[i+1].Value
				}
			}
			if target != "" {
				out = append(out, strings.TrimSuffix(published+":"+target, ":"))
			}
		}
	}
	return out
}

// dependsList handles both `depends_on: [a, b]` and the map long form.
func dependsList(n yaml.Node) []string {
	var out []string
	switch n.Kind {
	case yaml.SequenceNode:
		for _, item := range n.Content {
			if item.Kind == yaml.ScalarNode {
				out = append(out, item.Value)
			}
		}
	case yaml.MappingNode:
		for i := 0; i < len(n.Content); i += 2 {
			out = append(out, n.Content[i].Value)
		}
	}
	sort.Strings(out)
	return out
}

// Layers returns the services arranged in dependency order: layer 0 has services
// that depend on nothing (within the project), each later layer depends only on
// earlier ones. Cycles are broken by placing remaining nodes in a final layer.
func (p *ComposeProject) Layers() [][]string {
	deps := map[string][]string{}
	exists := map[string]bool{}
	for _, s := range p.Services {
		exists[s.Name] = true
	}
	for _, s := range p.Services {
		for _, d := range s.DependsOn {
			if exists[d] {
				deps[s.Name] = append(deps[s.Name], d)
			}
		}
	}

	placed := map[string]bool{}
	var layers [][]string
	for len(placed) < len(p.Services) {
		var layer []string
		for _, s := range p.Services {
			if placed[s.Name] {
				continue
			}
			ready := true
			for _, d := range deps[s.Name] {
				if !placed[d] {
					ready = false
					break
				}
			}
			if ready {
				layer = append(layer, s.Name)
			}
		}
		if len(layer) == 0 { // cycle — dump the rest into one layer
			for _, s := range p.Services {
				if !placed[s.Name] {
					layer = append(layer, s.Name)
				}
			}
		}
		sort.Strings(layer)
		for _, n := range layer {
			placed[n] = true
		}
		layers = append(layers, layer)
	}
	return layers
}
