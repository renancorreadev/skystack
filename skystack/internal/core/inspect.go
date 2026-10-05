package core

import (
	"context"
	"sort"
	"strings"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/network"
)

// InspectImage returns the raw inspection for an image.
func (e *Engine) InspectImage(ctx context.Context, id string) (any, error) {
	info, _, err := e.Docker.ImageInspectWithRaw(ctx, id)
	return info, err
}

// InspectVolume returns the raw inspection for a volume.
func (e *Engine) InspectVolume(ctx context.Context, name string) (any, error) {
	return e.Docker.VolumeInspect(ctx, name)
}

// InspectNetwork returns the raw inspection for a network.
func (e *Engine) InspectNetwork(ctx context.Context, id string) (any, error) {
	return e.Docker.NetworkInspect(ctx, id, network.InspectOptions{})
}

// DetectFramework guesses a container's language/framework from its inspect
// config (Env markers + Cmd/Entrypoint keywords). Returns a brand-icon key
// (e.g. "nestjs", "django", "go") or "" when unknown. Best-effort and cheap —
// one inspect, no exec into the container.
func (e *Engine) DetectFramework(ctx context.Context, id string) (string, error) {
	info, err := e.Docker.ContainerInspect(ctx, id)
	if err != nil {
		return "", err
	}
	if info.Config == nil {
		return "", nil
	}
	env := strings.ToLower(strings.Join(info.Config.Env, "\n"))
	cmd := strings.ToLower(strings.Join(append(append([]string{}, info.Config.Entrypoint...), info.Config.Cmd...), " "))
	envHas := func(ks ...string) bool {
		for _, k := range ks {
			if strings.Contains(env, k) {
				return true
			}
		}
		return false
	}
	cmdHas := func(ks ...string) bool {
		for _, k := range ks {
			if strings.Contains(cmd, k) {
				return true
			}
		}
		return false
	}

	switch {
	case envHas("node_version") || cmdHas("node ", "npm", "yarn", "pnpm", "nest", "next"):
		switch {
		case cmdHas("nest"):
			return "nestjs", nil
		case cmdHas("next"):
			return "nextjs", nil
		case cmdHas("react-scripts", "serve -s", "serve build"):
			return "react", nil
		case cmdHas("nuxt", "vite"):
			return "vue", nil
		default:
			return "nodejs", nil
		}
	case envHas("python_version") || cmdHas("python", "gunicorn", "uvicorn", "manage.py", "flask"):
		switch {
		case cmdHas("manage.py", "django"):
			return "django", nil
		case cmdHas("flask"):
			return "flask", nil
		default:
			return "python", nil
		}
	case envHas("ruby_version") || cmdHas("ruby", "rails", "puma", "bundle exec"):
		if cmdHas("rails") {
			return "rails", nil
		}
		return "ruby", nil
	case envHas("java_version") || cmdHas("java ", "-jar"):
		return "java", nil
	case cmdHas("php", "php-fpm", "artisan"):
		if cmdHas("artisan") {
			return "laravel", nil
		}
		return "php", nil
	case envHas("dotnet_", "aspnetcore_") || cmdHas("dotnet "):
		return "dotnet", nil
	case envHas("golang_version", "gopath", "go_version"):
		return "go", nil
	default:
		// Best-effort Go guess: a single static binary entrypoint (no interpreter
		// matched above). The user's stack is Go-heavy; conservative by design.
		if isStaticBinary(info.Config.Entrypoint, info.Config.Cmd) {
			return "go", nil
		}
		return "", nil
	}
}

// isStaticBinary reports whether the start command is a single bare executable
// path (e.g. "/app", "./server") rather than a shell or interpreter — a weak
// signal for a compiled binary (most often Go in this project's world).
func isStaticBinary(entrypoint, cmd []string) bool {
	tokens := append(append([]string{}, entrypoint...), cmd...)
	if len(tokens) == 0 {
		return false
	}
	first := tokens[0]
	if !strings.HasPrefix(first, "/") && !strings.HasPrefix(first, "./") {
		return false
	}
	shells := []string{"/bin/sh", "/bin/bash", "sh", "bash", "/bin/ash", "/sbin/", "/docker-entrypoint"}
	for _, s := range shells {
		if strings.HasPrefix(first, s) {
			return false
		}
	}
	return true
}

// VolumeConsumers returns the names of containers that mount the given volume.
func (e *Engine) VolumeConsumers(ctx context.Context, name string) ([]string, error) {
	return e.consumers(ctx, "volume", name)
}

// NetworkConsumers returns the names of containers attached to the given network.
func (e *Engine) NetworkConsumers(ctx context.Context, name string) ([]string, error) {
	return e.consumers(ctx, "network", name)
}

// consumers lists containers (including stopped) matching a Docker filter key —
// e.g. volume=<name> or network=<name> — and returns their names.
func (e *Engine) consumers(ctx context.Context, key, val string) ([]string, error) {
	f := filters.NewArgs(filters.Arg(key, val))
	items, err := e.Docker.ContainerList(ctx, container.ListOptions{All: true, Filters: f})
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(items))
	for _, it := range items {
		name := ""
		if len(it.Names) > 0 {
			name = strings.TrimPrefix(it.Names[0], "/")
		}
		out = append(out, name)
	}
	sort.Strings(out)
	return out, nil
}
