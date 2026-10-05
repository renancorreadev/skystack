# SkyStack CLI + core (`skystack`)

The control plane for SkyStack — **one pane for local and remote Docker**. A
single Go binary that talks to your local Docker engine and any number of remote
hosts over SSH, with identical commands for both.

This is **MVP 1** from the architecture brief: the agentless Remote Docker
Manager that becomes the backbone (`core` package = the future daemon, `cli` =
the user surface) for the rest of the platform.

## Why

Docker Desktop / OrbStack are excellent at *local* containers. The gap is
**operational work across local + remote**: tailing logs on a prod VPS,
exec-ing into a container on an Oracle VM, forwarding a remote service to
`localhost`. SkyStack makes local and remote feel like one machine.

## Install

```bash
make install        # → $GOPATH/bin/skystack
# or
make build          # → ./bin/skystack
```

Requires Go 1.24+ (the build auto-fetches the toolchain it needs) and a running
Docker engine for local commands.

## Quick start

```bash
# Local engine works with zero config:
skystack ps                       # running containers (local)
skystack ps -a                    # include stopped
skystack logs <name> -f           # live logs, severity-highlighted
skystack logs <name> -l error     # only WARN/ERROR (detected severity)
skystack exec <name> sh           # interactive shell (TTY + live resize)

# Add a remote host once, agentless, over SSH:
skystack connect prod ssh://ubuntu@1.2.3.4
skystack connect oracle ssh://opc@vm.example.com:22 -d "Oracle prod"

# Then operate on it with host/container refs:
skystack ps -A                    # every host in one table
skystack ps prod                  # just prod
skystack logs prod/kong -f -g 5xx # follow + regex filter on a remote container
skystack exec prod/api bash
skystack restart prod/worker
skystack tunnel prod/api 8080:80  # remote container port → http://localhost:8080
```

Container refs are `[host/]container`. No host prefix = `local`.

### Local VM engine (`skyvm`) — your own Docker, no Docker Desktop

```bash
skystack vm setup                 # locate + sign the SkyVM runtime (see ../vm-runtime)
skystack vm start                 # boot the VM, wait until its Docker is ready
skystack ps skyvm                 # containers in the VM
skystack logs skyvm/api -f        # ...same commands as any other host
skystack ps -A                    # local + skyvm + remotes, unified
skystack vm status                # running? engine version? pid/socket/log
skystack vm stop                  # graceful shutdown
```

`skyvm` is a built-in host backed by a lightweight local Linux VM with its own
Docker engine (managed as a background daemon). See [`../vm-runtime`](../vm-runtime).

## Commands

| Command | What it does |
|---------|--------------|
| `connect <name> <ssh://…>` | Register a remote host (verifies reachability first) |
| `disconnect <name>` | Remove a host |
| `hosts` | List hosts + live reachability / Docker version |
| `ps [host]` / `ps -A` | List containers on one host or **all hosts unified** |
| `logs [host/]<ctr>` | Stream logs: `-f` follow, `-g` regex, `-l` min severity, `--since`, `-n` tail |
| `exec [host/]<ctr> <cmd>` | Run a command; full interactive TTY with `-it` |
| `inspect [host/]<ctr>` | Full JSON inspection |
| `start` / `stop` / `restart` | Lifecycle, on any host |
| `tunnel [host/]<ctr> L:R` | Forward a container port to `localhost` |
| `vm setup\|start\|stop\|restart\|status\|logs` | Manage the local SkyVM runtime (the `skyvm` host) |
| `vm route [add\|remove]` | Route container IPs to the Mac (reach `172.17.x` with no `-p`) |
| `vm install-helper` / `uninstall-helper` | Enable/disable passwordless auto-routing (scoped sudoers rule) |

## How it works

```
cmd/skystack            thin main → cobra command tree
internal/cli            command wiring; resolves [host/]container refs
internal/core           the control plane (becomes the gRPC daemon later)
  client.go             builds a Docker API client per host (local or ssh://)
  docker.go             ps / inspect / lifecycle / exec
  logs.go               stream + parse + enrich + severity + JSON detection
  tunnel.go             ssh -L for remote, dual-stack proxy for local
internal/config         ~/.skystack/hosts.yaml registry (0600)
internal/ui             tables + colored, severity-aware log formatting
```

- **Remote hosts are agentless.** SkyStack uses Docker's own SSH connection
  helper — the same mechanism as `docker context … ssh://`. Nothing is installed
  on the server; your `~/.ssh/config`, agent, and `known_hosts` all apply. A
  remote-agent for richer telemetry is a later, optional tier.
- **Tunnels** use the system `ssh -L` for remote hosts (forwarding to the
  container's internal IP from `inspect`), and a local TCP proxy to the
  published host port for local containers. The local proxy dials `localhost`
  so Go's dual-stack fast-fallback routes around Docker Desktop's stalling IPv4
  published-port proxy on macOS.
- **Logs** are parsed beyond plain `docker logs`: the docker RFC3339 prefix is
  stripped, stdout/stderr are tagged, JSON `level`/`severity` fields and
  free-text `ERROR`/`WARN`/… keywords are detected for coloring and `-l`
  filtering.

## Tests

```bash
make test     # config registry, port/ssh parsing, log severity, live TCP proxy
```

`TestProxyTCP` exercises the tunnel proxy end-to-end against an in-process HTTP
server, so it runs anywhere without Docker.

## Roadmap (next slices)

1. `gRPC` daemon wrapping `internal/core` so a SwiftUI app and the CLI share one
   backend.
2. `compose` awareness: detect projects, show the service graph.
3. Remote-agent tier (logs indexing, metrics, journald) over mTLS.
4. Wire into the `vm-runtime` (../vm-runtime) for a fully local lightweight
   engine.
