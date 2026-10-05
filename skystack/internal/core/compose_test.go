package core

import (
	"strings"
	"testing"
)

const sampleCompose = `
name: shop
services:
  web:
    image: nginx
    ports: ["8080:80"]
    depends_on: [api]
  api:
    build: ./api
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_started
    ports:
      - published: 3000
        target: 3000
  db:
    image: postgres:16
  cache:
    image: redis
`

func TestParseComposeAndLayers(t *testing.T) {
	p, err := ParseCompose([]byte(sampleCompose), "fallback")
	if err != nil {
		t.Fatal(err)
	}
	if p.Name != "shop" {
		t.Errorf("project name = %q, want shop", p.Name)
	}
	if len(p.Services) != 4 {
		t.Fatalf("got %d services, want 4", len(p.Services))
	}

	byName := map[string]ComposeService{}
	for _, s := range p.Services {
		byName[s.Name] = s
	}
	if byName["web"].Image != "nginx" || len(byName["web"].Ports) != 1 || byName["web"].Ports[0] != "8080:80" {
		t.Errorf("web parsed wrong: %+v", byName["web"])
	}
	if byName["api"].Build != "./api" {
		t.Errorf("api build = %q, want ./api", byName["api"].Build)
	}
	// Long-form depends_on map → [cache db] (sorted).
	if got := strings.Join(byName["api"].DependsOn, ","); got != "cache,db" {
		t.Errorf("api depends_on = %q, want cache,db", got)
	}
	// Long-form port → "3000:3000".
	if len(byName["api"].Ports) != 1 || byName["api"].Ports[0] != "3000:3000" {
		t.Errorf("api ports = %v, want [3000:3000]", byName["api"].Ports)
	}

	// db + cache have no deps → layer 0; api depends on them → layer 1; web → layer 2.
	layers := p.Layers()
	if len(layers) != 3 {
		t.Fatalf("got %d layers, want 3: %v", len(layers), layers)
	}
	if strings.Join(layers[0], ",") != "cache,db" {
		t.Errorf("layer 0 = %v, want [cache db]", layers[0])
	}
	if strings.Join(layers[2], ",") != "web" {
		t.Errorf("layer 2 = %v, want [web]", layers[2])
	}
}
