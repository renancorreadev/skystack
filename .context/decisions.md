# Key decisions

- **Languages**: Go for the core/CLI (Docker SDK, SSH, concurrency, logs are
  natural); Swift for the runtime/UI (native, no Electron). Per the brief.
- **Lead with MVP 1** (remote Docker manager): strongest differentiator,
  runnable today, becomes the backbone (core → future gRPC daemon, CLI surface).
- **Agentless remote** via Docker's `ssh://` connection helper (same as
  `docker context`). Nothing installed on servers; reuses ~/.ssh + agent +
  known_hosts. Remote-agent is a later premium tier.
- **Monolithic CLI now, daemon later**: `internal/core` is a clean library the
  CLI links directly; a gRPC daemon wraps it without restructuring.
- **Docker SDK pinned to v27 line** (`github.com/docker/docker@v27.5.1+incompatible`,
  `cli` same, `go-connections@v0.5.0`) — BEFORE the moby module split, so
  client/api/types/stdcopy resolve from one module. Newer (v28+) splits
  `docker/docker/api` into a module that declares path `moby/moby/api` and breaks.
- **Tunnels**: system `ssh -L` for remote (reuses SSH stack, robust), local TCP
  proxy to the published host port for local containers.
- **Container ref format**: `[host/]container`, missing host = `local`.
- **Logs**: parse beyond `docker logs` — strip RFC3339 prefix, tag stdout/stderr,
  detect JSON `level`/`severity` + free-text ERROR/WARN keywords for color + `-l`.
- **SkyVM enables Rosetta** (gated on availability) for linux/amd64 on Apple
  Silicon, matching OrbStack; QEMU/binfmt is the fallback (future).
- **HTTPS (Stage 5) terminates inside the guest**, not on the Mac. Rationale:
  the Mac reaches `guestIP:443` directly over Apple's vmnet bridge, so we avoid
  needing root for a <1024 port on macOS and avoid pf/launchd. `*.sky.local` DNS
  resolves to the guest (proxy ingress); the in-VM reverse proxy routes by
  SNI/Host to the container. Plain HTTP still works on :80 (port-aware).
- **Local CA is name-constrained to `sky.local`** (PermittedDNSDomains). It is a
  system-trusted root, so the constraint caps the blast radius if the key leaks —
  it can only certify sky.local, never arbitrary domains (verified in a unit
  test). CA generated on the Mac (~/.skystack/ca), trusted via
  `security add-trusted-cert` to the System keychain.
- **The macOS app talks to the Go core via the CLI's JSON API, not a new
  daemon/gRPC (Stage 6).** `skystack api {hosts,ps,logs,action}` emits JSON/NDJSON;
  the SwiftUI app shells out via `Process` and decodes. Reuses 100% of the core,
  no second protocol to maintain, and the JSON shapes are exactly what a future
  daemon/gRPC API would expose. Logs stream as NDJSON over a pipe. Chosen over
  (a) a gRPC daemon now (heavy: protobuf/codegen/daemon lifecycle before any UI)
  and (b) reimplementing Docker in Swift (duplicates the core).
- **App innovations chosen with the user (Stage 6):** logs lead with a
  **severity-timeline** (stacked histogram + drag-to-zoom); terminal is **both** a
  real PTY and a command console.
- **Terminal = real PTY via SwiftTerm, not a hand-rolled emulator.** SwiftTerm's
  `LocalProcessTerminalView` runs `skystack exec <ref>` in a pseudo-terminal — the
  CLI sees a TTY and enters interactive raw mode, so it's a genuine container
  shell (full ANSI + resize) reusing the existing exec path. The "syntax
  highlighting" lives in the **command console** (a live-highlighted input via a
  transparent-TextField-over-AttributedString overlay), since a real PTY echoes
  via the shell and can't be recolored. PTY needs an unsandboxed process →
  fine under `swift run`; a future `.app` must disable the App Sandbox.
- **Kubernetes = k3s inside the VM, gated + off by default (Stage 8).** k3s is a
  single binary baked into the guest image; the `skyvm-k8s` OpenRC service only
  starts when the kernel cmdline carries `skyvm.k8s=1` (set by `skystack k8s
  enable` → runtime.json → SkyVM `--k8s`). The API server is reached at a stable
  `127.0.0.1:6443` (SkyVM forwards to guest:6443; k3s' default cert already SANs
  127.0.0.1), and the kubeconfig is exported to the Mac over the virtiofs share.
  Heavy, so opt-in; bring-up needs an image rebuilt with k3s.
- **Linux machines = long-lived labelled containers in the VM (Stage 9).** A
  "machine" is a `sleep infinity` container from a distro base image, labelled
  `dev.skystack.machine`, with the Mac home bind-mounted at the same path
  (virtiofs makes it present in the guest). `machine shell` is just an interactive
  exec. Avoids per-machine micro-VMs while giving the OrbStack "your files travel"
  feel. SSH/systemd are future polish.
- **Compose graph parsed in Go from the file; lifecycle shells to `docker
  compose` (Stage 10).** `ParseCompose` (yaml.Node, tolerant of short/long forms)
  + `Layers()` topo-sort feed both the CLI `compose graph` and the app's
  service-graph window (via `api compose` JSON). up/down/ps just set DOCKER_HOST
  and exec the real `docker compose` — no reimplementation. `skystack build`
  is a thin buildx wrapper (Rosetta accelerates linux/amd64).
- **Docker is a build-time-only dependency (bootstrap sandbox), not runtime.**
  `image-builder/*.sh` use a throwaway Alpine arm64 container (the Mac's
  OrbStack/Docker) to assemble the guest image with `apk --root` + `mke2fs` —
  no Linux privileges, no runtime coupling. At runtime the engine is the in-VM
  `skyvm`; the Mac's Docker only ever appears as the optional `local` host.
- **Image distribution = Option A (chosen 2026-06-24):** ship the guest image as
  a pre-built release bundle so end users need NO Docker. `make package-image`
  → `dist/skyvm-image-<arch>.tar.gz` + `.sha256`; `skystack vm install-image
  <path|url>` installs it into ~/.skystack/assets (checksum-verified, safe
  extraction, atomic swap) with no Docker. `vm setup` auto-detects installed
  assets. The maintainer flow (`make build-image`) still uses Docker once to bake
  the image — analogous to how OrbStack/Docker Desktop ship their Linux prebuilt.
  Removing Docker even for maintainers (native Go builder: resolve .apk + write
  ext4/cpio in pure Go) is deferred as "Option C".
- **AI = Claude Code headless, full-container context, button-gated (Session 11).**
  The app feeds Claude a single `api context` bundle (inspect + a live stats
  sample + recent log tail) rather than logs alone — the inspect is what lets the
  model reason about restart policy, exit codes, Cmd, mounts, OOM (proven: it
  caught an echo'd DB error as a red-herring by reading Config.Cmd). Follow-up
  chat uses Claude Code's `--output-format json` + `--resume <session_id>` so
  conversation state lives in Claude Code, not re-sent each turn. Suggested fixes
  are constrained to a single `skystack` command in a ```skyfix fence (parsed →
  one-click Apply via the existing CLI, host-qualified ref, user sees the exact
  command). Analysis is button-gated (no auto-run) so opening the AI tab costs
  zero tokens until the user asks — and the tab stays mounted (like the terminal)
  so the conversation survives tab switches. Chosen over (a) a bespoke API client
  in the app (Claude Code already handles auth/sessions/tools) and (b) auto-
  running on tab open (surprise token spend).
- **UI review choices (Session 12).** (a) Per-host loading: clear lists + set
  `loadingResources` on host switch and ignore stale in-flight responses
  (guard host==selectedHost) — kills the flash of the previous host's rows.
  (b) VM lifecycle lives in a sidebar `VMControl` (not a separate window) and
  shells the existing `vm start|stop|restart` rather than a new daemon API —
  consistent with "CLI is the API". (c) Inspect is a single generic
  `api inspect <kind> <host> <id>` + one `InspectSheet`, not per-type viewers.
  (d) Machine "Terminal" opens the existing exec-based `machine shell` in
  Terminal.app via a throwaway `.command` (real ssh/sshd deferred — heavier,
  distro-specific). "Open home in Finder" reveals the Mac home because that's the
  folder shared into every machine over virtiofs.
- **CA key crosses to the guest over vsock (port 1026) and stays in memory** —
  never written to the guest's disk. Leaf certs are minted in-VM per SNI host
  and cached. Chosen over (a) putting the key on the virtiofs share (could be
  disabled) and (b) minting every leaf on the Mac and pushing (needs a
  container-watch + push protocol). vsock-push matches the existing control-
  channel pattern (docker 2375, netinfo 1024).
