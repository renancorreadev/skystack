# SkyStack — current-state handoff (READ THIS FIRST)

OrbStack-class macOS platform, built in stages. 3 components, all building green.
APP INSTALADO: /Applications/SkyStack.app (estável, fora do iCloud — abrir por lá,
NÃO pelo dist/ que é evictado). Reinstalar após rebuild: `cd app && make app && cp -R dist/SkyStack.app /Applications/`.

Last updated: Session 21 (2026-07-01). Recent: host SSH terminal+admin (S20),
per-format log registry + GORM formatter + big-line demux fix + row-overlap fix (S18-21).

## Persistent installer (Session 16) — `make pkg` → dist/SkyStack-Installer.pkg
One native macOS `.pkg` (294MB) that sets EVERYTHING up to run persistently: app
→ /Applications, CLI → /usr/local/bin, SkyVM engine copied+signed to
~/.skystack/bin (build-immune), guest image installed, LaunchAgents for the VM
(`dev.skystack.vm`) AND the daemon (`dev.skystack.daemon`, KeepAlive) so both
auto-start at login + survive reboot, plus the privileged *.sky.local DNS /
container routing / CA trust (done in the pkg's own admin auth — no 2nd prompt).
Brain = `skystack install` / `skystack uninstall` (idempotent; modes
--user-only / --system-only --user/--home for the pkg's root-vs-user split).
`vm install-binary` = stable signed SkyVM copy on its own. Build:
`app/packaging/build-pkg.sh` (pkgbuild; postinstall does user-part via
`launchctl asuser` + root system-part). App: `useDaemon` defaults ON when the
socket is present (installed = daemon-on; SKYSTACK_DAEMON=0 forces off).
NOT auto-installed (needs admin) — user runs `open dist/SkyStack-Installer.pkg`.

## Multi-host daemon (Session 15) — internal/cli/daemon.go
`skystack daemon run|start|stop|status|call` — ONE process holding a **warm Docker
engine per host** (reused across every request/stream, reconnects on /_ping fail),
serving the api surface over a unix socket (~/.skystack/daemon.sock). Protocol:
1-request-per-conn JSON; unary=1 line, stream=NDJSON until the client closes (cancels
ctx). Same shapes/encoders as `api` → the app's decoders reuse unchanged. App opt-in:
`SKYSTACK_DAEMON=1` (+ socket present) → SkyCLI routes reads/streams through `daemon
call`, falling back to `api` on failure (mutations stay on `api`). Default OFF. LIVE:
warm reuse ~5× on repeat remote SSH queries (0.20s cold → 0.03s warm). Home for a
future in-process AI agent. NOT auto-started — user runs `skystack daemon start`.

## Components & build/run
- `skystack/` — Go CLI + core + JSON API (`skystack api …`). Build: `cd skystack && make build` → `bin/skystack`. Test: `go test ./...`. Module: `github.com/skynance/skystack`. Docker SDK PINNED to v27.5.1 (pre-split; do not bump — see errors.md).
- `vm-runtime/` — Swift **SkyVM** (local Linux VM w/ its own Docker, host `skyvm`) + guest `agent/` (Go, linux/arm64). Build: `swift build`; agent: `GOOS=linux GOARCH=arm64 go build ./...`. Image builder uses Docker (OrbStack) at BUILD-TIME only.
- `app/` — SwiftUI app (deps: **SwiftTerm**, and system **Charts**). Run: `cd app && make run`. Package: `make app` → signed `dist/SkyStack.app` (embeds the CLI + a `brand-icons` resource bundle).

## Hosts model
In the app's host picker: **`local`** = the Mac's Docker (OrbStack 29.4.0), **`skyvm`** = our VM (Docker 27.3.1), plus **remote SSH hosts** registered from `~/.ssh/config`. User's live remote: **`clone-and-dev`** (10.0.0.147, Docker 28.5.0, runs besuscan/bmonitor/kong/besu validator stacks — needs VPN; besu-vm/hostinger-vps were unreachable without VPN).

## Stages 0–10: ALL DONE (code). Milestone 2 (this era): AI, perf, UX, robustness.

## The app — feature map (20+ Swift files in app/Sources/SkyStackApp/)
- **Operator** (OperatorView.swift, Session 15): host-level AI section (General, wand.and.stars). Whole-host triage via `api host-context` (every container's state + problem logs) → Claude; parses MULTIPLE ```skyfix blocks into individually-applyable fixes; follow-up chat. Renders in DetailColumn.
- **Port-forward** (PortsCard in ContainerDetail.swift, Session 15): on-demand forward of a (remote SSH) container port to localhost via `api tunnel` (core.Tunnel: ssh -L for remote, published-port proxy for local/skyvm). `AppState.forwards`. Local/SkyVM ports get an Open button (already on localhost).
- **Deploy compose** (ComposeView.swift, Session 15): host picker + Deploy/Down → `api compose-up/down <host> <file>` (docker compose with DOCKER_HOST), streamed output.
- **⌘K Command palette** (CommandPalette.swift, Session 14): Raycast/OrbStack-style overlay, fuzzy search (fuzzyScore) across sections/hosts/containers/quick-actions; ↑/↓ nav, ⏎ run, esc close. Opened via `CommandGroup` keyboardShortcut ⌘K → `AppState.paletteOpen`. RootView overlays it + presents RemoteHostsSheet on `app.remoteSheetOpen`.
- **Offline states** (Session 14): `AppState.hostOffline` (post-load && host !up) drives an `OfflineState` panel ("⟨host⟩ is offline" + real error + Start SkyVM/Retry) in Content+Detail columns and HardwareView — replaces the misleading "No containers" when a host is unreachable. `ErrorBar` is now dismissable (✕ → clears cliError).
- **Hover consistency** (Session 14): `HoverRow` + shared `RowActionButton` give images/volumes/networks/machines the same hover bg + inline actions as ContainerRow (Delete; machines also Start/Stop). `AppState.machineDelete`.
- **Host SSH** (HostSSH.swift, Session 20): a terminal button beside the HostPicker (SSH hosts only) → `HostSSHControl` menu: Open SSH terminal (in-app PTY window via `TerminalWindowManager`+`TerminalRepresentable`), System info / Docker disk usage / prune (read-only via `cli.sshRun` → `SSHOutputSheet`), Restart Docker daemon… / Reboot machine… (confirm → `ssh -t … sudo …` in a PTY window). Backend: `api host-ssh <name>` → ssh argv from the registered `ssh://` endpoint. `TerminalWindowManager` is reusable for any binary+args.
- **Sidebar** (Navigation.swift, Sidebar.swift): groups Docker (Containers/Images/Volumes/Networks), Linux (Machines), General (Commands, **Hardware**, **Operator**). Brand + **HostPicker** (menu w/ "Connect to remote…") + **HostSSHControl** (beside it) + **VMControl** (Start/Stop/Restart SkyVM inline).
- **Containers** (Resources.swift): grouped by **compose stack** (collapsible `StackHeader` w/ bulk start/stop on hover), **`ServiceIcon`** real brand logos, hover inline actions (open/stop/restart/delete), host badge. Detail tabs: **Info · Stats · Logs · AI · Terminal · Files** (terminal+AI persist across tabs).
- **Logs** (LogsView.swift + LogSyntax.swift): severity timeline (drag-zoom), **syntax highlighting** (LogSyntax: strings/nums/IPs/URLs/key=val/JSON-keys/HTTP methods+status/levels), **ANSI interpretation** (GIN colors), search-match highlight, **pause/resume** (freeze+pending count), **dedup** (×N), **errors-only** toggle, **JSON expand** (chevron→pretty), **refresh/reload**, memoized (LogSyntax.cache + LogJSON.cache). **✨ Analyze** → AI tab. **Per-format rendering** (LogFormat.swift, Sessions 18-19): a pluggable **registry** of parsers (`parsers: [(String)->LogShape?]`, memoized via `classify`) recognizes **GIN, nginx/apache, NestJS, Postgres, Redis, RabbitMQ, Hyperledger Besu, Vault, NATS, Kafka/log4j**, + a generic-leveled catch-all. Uniform model: `.http(HTTPLog)` rendered rich (method pill, status badge 2xx/3xx/4xx/5xx, path, latency-by-slowness, IP) and `.leveled(LeveledLog{source,level,component,message,trailing})` rendered by ONE `LeveledLogContent` (source tag + component tag + message). **Add a service = write `parseX -> LeveledLog?` + one line.** `sev()` maps every service's level vocab. Severity inferred from structure. Severity inferred from structure (5xx→error, 4xx→warn) so the rail/chips/timeline reflect HTTP outcomes. Plain lines keep the generic LogSyntax highlighter. **⤢ Expand** → opens a REAL window (`LogsWindowManager`/`LogsWindowRoot`, AppKit NSWindow + `toggleFullScreen` = native macOS full-screen — a sheet can't go full-screen) with the full control bar, seeded from the tab's filters. Shared `LogsContent` view backs both the inline tab and the window. (Session 17 — first tried a sheet; user wanted true full-screen → switched to an NSWindow.)
- **AI** (AIView.swift): full-container analysis (logs+stats+inspect via `api context`), suggested-fix card (parses ```skyfix → Apply runs the skystack cmd), follow-up chat (claude `--resume <session_id>`), button-gated. Uses `claude` CLI (OAuth, keychain — no key handling by the app).
- **Inspect** (InspectView.swift): `InspectSheet` raw JSON (filter+copy) for any kind; `ConsumersSection` "used by" on volume/network.
- **Hardware** (HardwareView.swift): **Swift Charts** + native **Gauge** rings (CPU/Mem) + AreaMark sparkline history + BarMark top-consumers. **Interactive `UsageHistoryChart`** (Session 14): CPU+Mem over a real relative time axis ("120s…now") with a `.chartOverlay` hover tooltip (RuleMark + value readout). System header (OS/kernel/arch/docker), MiniStats (running/images/disk/net). Streams `api hwstats`. Renders in the **detail (wide) column**; content column shows a hint.
- **Images** (Resources.swift): ServiceIcon brand logos by tag.
- **Machines** (Resources.swift): distro icons/colors, Terminal.app shell, open-home-in-Finder.
- **RemoteHostsSheet** (RemoteHostsView.swift): lists `~/.ssh/config` aliases → one-click **Connect** (`ssh://<alias>`), Disconnect, manual entry.
- **ComposeView** (menu-bar window): compose graph.

## Performance architecture (Session 12-13) — IMPORTANT
- **Event-stream, not polling**: containers come from `api watch <host>` (docker events, debounced re-list, warm conn); hosts from `api watch-hosts` (1 persistent proc, warm engine per host, /_ping liveness, cached version, emit-on-change). AppState runs these as persistent streams; the 2s poll only backstops + slow-tier (10s) does vm+images/volumes/networks/machines. Most ticks do ~nothing.
- **SSH ControlMaster** (core/client.go): `GetConnectionHelperWithSSHOpts` injects ControlMaster=auto + ControlPath ~/.skystack/ssh/%C + ControlPersist=120 → warm SSH master shared across spawns. Cold ~1s → warm ~0.08s (12×).
- **Background pause**: app inactive → poll 2s→20s.
- **Backoff**: down host → watch respawn ≤ every 6s.
- **Log memoization**: LogSyntax/LogJSON caches.

## Robustness (Session 13) — fixes the reboot bug
- **Self-heal** (vm/setup.go autoReSign, service.go Start): SkyVM binary in .build/ loses its signature on rebuild → `vm start` now re-signs (finds SkyVM.entitlements) and retries automatically.
- **launchd auto-start**: `skystack vm install-daemon` writes ~/Library/LaunchAgents/dev.skystack.vm.plist (RunAtLoad→`vm start`). INSTALLED. Survives reboot.

## API surface (`skystack api …`, hidden)
hosts · **watch-hosts** (NDJSON, push-on-change) · ps [host] · **watch <host>** (containers NDJSON, event-push) · logs <ref> -f · stats <ref> · **hwstats <host>** (capacity+usage+top consumers) · action <a> <ref> · images/volumes/networks/machines [host] · files/filecontent <ref> [path] · run/rm/prune/create · compose -f · **context <ref>** (AI bundle) · **inspect <kind> <host> <id>** · **consumers <volume|network> <host> <name>** · **vm** (status JSON) · **ssh-hosts** · **framework <ref>** (lang detect via inspect Env/Cmd).
GOTCHA: `api rm/create` take a BARE id/name; `api action` resolves host/name ref.

## Remote connect (agentless)
`skystack connect <name> ssh://<alias>` reuses ~/.ssh/config (keys/HostName/Port/ProxyJump) via Docker's ssh connhelper. Registry.Add only needs `ssh://` prefix. Improved error msg when Docker unreachable. PROVEN live: clone-and-dev → 27 containers, live logs.

## Pending / next
- ALL roadmap pending items (3, 5–11) are now DONE.
  - Items 5-8 ✅ (Session 14): chart tooltips+time axis, hover consistency, ⌘K palette, richer error/empty states.
  - Items 3, 9, 10, 11 ✅ (Session 15): multi-host daemon, AI operator, deploy compose remote, on-demand port-forward.
- Possible future polish: wire the app to the daemon by DEFAULT (native Swift unix-socket client to drop even the `daemon call` spawn); launchd auto-start for the daemon; an in-process AI agent living in the daemon (now has the warm engines); compose deploy from a saved project list; forwards surfaced globally (sidebar/menu) not just per-container.
- User-action items still open (unchanged): Stage 5 HTTPS image rebuild + sudo; Stage 8 k8s image rebuild; .app Developer-ID notarization.
- 100%-robust binary: copy SkyVM → ~/.skystack/bin/ (self-heal covers the pain for now).
- Stage 5 HTTPS / Stage 8 k8s live: need image rebuild + sudo. Notarize the .app (Apple Dev ID).

## Verify everything
skystack `go build ./... && go test ./...` · agent `GOOS=linux GOARCH=arm64 go build ./...` · `cd vm-runtime && swift build` · `cd app && swift build` (0 warnings) · `make app`. Live: VM running via `skystack vm start`; remote via `clone-and-dev` (on VPN).
