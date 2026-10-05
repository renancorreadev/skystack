# SkyStack

> An ultra-light macOS platform that unifies **local Docker**, **remote
> containers over SSH**, advanced **logs**, command execution, debug shell and
> tunnels into one native experience — and grows into its own lightweight Linux
> VM runtime.

This repo is the buildable foundation of that vision, derived from the
architecture brief in the project notes. It is split into two tracks that
progress in parallel:

| Track | Dir | Status | What it is |
|-------|-----|--------|------------|
| **Stage 1 — Remote Docker Manager** | [`skystack/`](skystack/) | ✅ working & tested | Go core + `skystack` CLI: one pane for local + remote Docker (ps, logs, exec, inspect, lifecycle, tunnel) |
| **Stage 2 — Local VM runtime** | [`vm-runtime/`](vm-runtime/) | ✅ **boots & runs Docker** | Swift `SkyVM` over Apple Virtualization.framework: minimal Alpine arm64 VM with Docker+containerd, engine exposed on the Mac over vsock |

We're building the **full OrbStack** in stages (roadmap below). The strategy:
lead with the differentiator (remote containers + better logs, runnable against
any Docker host), then stand up our **own** lightweight VM + engine so SkyStack
stops depending on Docker Desktop. Both are now real and verified:

```console
# The local VM is a first-class host managed by the CLI — no Docker Desktop.
$ skystack vm setup && skystack vm start
✓ SkyVM running — Docker 27.3.1 ready on host `skyvm`
$ skystack ps skyvm                 # containers in our VM
$ skystack logs skyvm/api -f        # same commands as any host
$ skystack ps -A                    # local + skyvm + remotes, unified
$ skystack vm stop                  # graceful shutdown
```

The `skyvm` host is backed by a lightweight local Linux VM (Alpine arm64, kernel
6.12) running its own Docker engine, managed as a background daemon and exposed
over vsock. `skystack vm setup/start/stop/status/logs` drive its lifecycle.

### Getting the VM image — no Docker required to *use* SkyStack

The VM runs a **guest image** (`vmlinux` + `initramfs.gz` + `rootfs.ext4`) — the
VM's own OS, with Docker baked inside. This is *not* a Docker image; once the VM
boots, your `docker run`/`docker build` commands run **inside** it, against the
`skyvm` engine — no Docker Desktop or OrbStack on the Mac at runtime.

There are two flows, and only the maintainer one needs Docker:

| Who | Flow | Needs Docker? |
|-----|------|---------------|
| **User** | `skystack vm install-image <bundle.tar.gz \| url>` → `vm setup` → `vm start` | **No** |
| **Maintainer** | `cd vm-runtime && make build-image && make package-image` → publish `dist/` | Yes (once, to bake the image) |

```console
# User: install a pre-built image bundle (local file or URL), then run. No Docker.
$ skystack vm install-image https://example.com/skyvm-image-arm64.tar.gz
✓ guest image installed → ~/.skystack/assets
$ skystack vm setup && skystack vm start
```

The maintainer uses Docker only as a throwaway **build sandbox** (an Alpine
arm64 container that runs `apk --root` + `mke2fs` to assemble the image without
privileges) — the same way OrbStack/Docker Desktop build *their* Linux images
and ship them to you prebuilt. `make package-image` emits a `.tar.gz` + `.sha256`
that installs anywhere with `vm install-image`.

Your Mac home is mirrored into the VM over **VirtioFS** at the same path, bind
mounts and published ports work transparently, and containers can reach the Mac:

```console
$ docker run -d -p 8080:80 -v "$HOME/site:/usr/share/nginx/html" nginx
$ curl localhost:8080                       # auto-forwarded from the VM container
$ docker run --rm --add-host host.docker.internal:host-gateway \
      alpine wget -qO- http://host.docker.internal:3000   # container → the Mac
```

Published ports are forwarded to `localhost` automatically (added/removed as
containers come and go); `skystack vm status` lists them. And with a one-time
`skystack vm install-helper`, container IPs are reachable directly — no `-p` —
*.sky.local resolves system-wide, and `https://<name>.sky.local` is trusted:

```console
$ skystack vm install-helper          # one-time: scoped routing + DNS + trusted local CA
$ docker run -d --name web nginx       # no published port
$ curl http://172.17.0.2               # reach the container IP directly from the Mac
$ curl http://web.sky.local            # name → in-VM reverse proxy → container
$ curl https://web.sky.local           # HTTPS, cert trusted in the Keychain
```

HTTPS is terminated by a reverse proxy **inside the VM**: `*.sky.local` DNS
points at the guest, which routes by SNI/Host to the right container and serves
a per-host leaf certificate minted from the **SkyStack local CA**. The CA is
generated on the Mac (`~/.skystack/ca`), trusted in the system Keychain, and
**name-constrained to `sky.local`** — so even if its key leaked it can't forge
certificates for any other domain. Its private key is delivered to the guest
over vsock and held only in memory there (never written to the guest's disk).
Manage trust independently with `skystack vm trust-ca` / `vm untrust-ca`.

Beyond containers, SkyStack runs **Linux machines**, a **single-node Kubernetes**,
and visualizes **Compose** projects:

```console
$ skystack machine create dev --distro ubuntu   # a persistent Ubuntu env (Mac home mounted in)
$ skystack machine shell dev                     # drop into it
$ skystack debug web                             # toolbox shell into ANY container, even distroless
$ skystack k8s enable && skystack vm restart     # single-node k3s; kubeconfig → 127.0.0.1:6443
$ skystack compose graph                         # render a compose project's service graph
$ skystack build -t app --platform linux/amd64,linux/arm64 .   # multi-arch build (Rosetta)
```

> Kubernetes runs **k3s inside the VM**; it's off by default and the cluster
> needs a guest image built with k3s baked in (`make build-image` after this
> change), then `skystack k8s enable` + `vm restart`. The lifecycle, kubeconfig
> forwarding (`127.0.0.1:6443`), and `*.k8s.sky.local` DNS are all wired.

## Roadmap (building the full OrbStack, in stages)

| # | Stage | Status |
|---|-------|--------|
| 0 | Foundation (Go core+CLI, SkyVM scaffold) | ✅ done |
| 1 | Remote Docker Manager (local+remote, logs, exec, tunnel) | ✅ done |
| 2 | **Own VM runtime: boots Linux + Docker, socket→Mac, native `skyvm` host** | ✅ done |
| 3 | Networking + filesystem | ✅ VirtioFS mounts · auto port-forward · host.docker.internal · direct container-IP routing |
| 4 | DNS + local domains (`*.sky.local`) | ✅ `web.sky.local` / `<svc>.<project>.sky.local` → container IP |
| 5 | Local HTTPS (auto cert + Keychain trust, reverse proxy) | ✅ `https://web.sky.local` — in-VM reverse proxy, per-host certs from a name-constrained local CA trusted in the Keychain |
| 6 | Native macOS app (SwiftUI menu bar + explorer + log viewer) | ✅ [`app/`](app/) — shell + container browser + **severity-timeline logs** (drag-to-zoom) + **terminal** (real PTY shell + syntax-highlighted command console) over a CLI JSON API; ships as a self-contained signed `SkyStack.app` (`make app`) with the CLI embedded. (Developer-ID notarization = a user step.) |
| 7 | Debug Shell (toolbox in distroless/read-only, local + remote) | ✅ `skystack debug <ctr>` — a busybox toolbox sharing the target's PID+net namespaces; its rootfs at `/proc/1/root`, its processes/network visible. In the app: a Shell/Debug switch in the terminal. Works on any host (local · skyvm · ssh) |
| 8 | Kubernetes single-node (`*.k8s.sky.local`, LoadBalancer/Ingress) | ✅ `skystack k8s enable` → k3s in the VM; kubeconfig forwarded to `127.0.0.1:6443`; `*.k8s.sky.local` resolves to the cluster. (Cluster bring-up needs a k3s-baked image — see below.) |
| 9 | Linux machines (multi-distro, shared kernel) | ✅ `skystack machine create dev --distro ubuntu` — persistent Ubuntu/Debian/Fedora/Alpine/Arch/Rocky envs sharing SkyVM's kernel, your Mac home mounted in; `machine shell`/`list`/`delete` |
| 10 | Build/Compose UX (buildx multi-platform, service graph) | ✅ `skystack build --platform …` (buildx, Rosetta-accelerated amd64); `skystack compose graph/up/down/ps` + a **service-graph window** in the app |

## Try it now (MVP 1)

```bash
cd skystack
make build
./bin/skystack ps                         # local containers
./bin/skystack connect prod ssh://you@server
./bin/skystack ps -A                       # local + remote, unified
./bin/skystack logs prod/api -f -l error   # follow, severity-filtered
./bin/skystack tunnel prod/api 8080:80     # remote port → localhost:8080
```

See [`skystack/README.md`](skystack/README.md) for the full command reference.

## Build the runtime (MVP 2)

```bash
cd vm-runtime
swift build
swift run SkyVM --kernel <vmlinux> --rootfs <disk.img> --validate-only
```

See [`vm-runtime/README.md`](vm-runtime/README.md) for entitlement/signing and
how to source a kernel + rootfs.

## Architecture (where this is going)

```
macOS native app (SwiftUI/AppKit)        ── later: consumes the core over gRPC
        │
   core-daemon (Go)  ◄── skystack/internal/core   (today: linked into the CLI)
        ├── DockerService     local + remote Docker Engine API
        ├── RemoteHostService agentless SSH host registry
        ├── LogsService       parse / enrich / severity / filter
        ├── ExecService       interactive TTY
        └── TunnelService     ssh -L (remote) / dual-stack proxy (local)
        │
   vm-runtime (Swift)  ◄── vm-runtime/   minimal Linux VM via Virtualization.framework
        └── Docker/containerd inside, socket forwarded to the Mac
```

### Design decisions locked so far
- **Go for the core** (Docker SDK, SSH, concurrency, logs are natural in Go);
  **Swift for the runtime/UI** (native, no Electron) — per the brief's stack.
- **Agentless first**: remote hosts use Docker's `ssh://` connection helper, so
  there's nothing to install on servers. A premium remote-agent is a later tier.
- **Docker SDK pinned to the pre-split v27 line** (`github.com/docker/docker`),
  before the moby module split, so the client/api/stdcopy live in one module.
- **Tunnels dial `localhost`, not `127.0.0.1`**, to dodge Docker Desktop's
  stalling IPv4 published-port proxy on macOS via Go's dual-stack fallback.

## Repo layout

```
skystack/      Go module: CLI + core (MVP 1) — also exposes `skystack api …` (JSON)
vm-runtime/    Swift package: SkyVM local runtime (MVP 2)
app/           Swift package: SkyStack.app SwiftUI front-end (MVP 6)
```
