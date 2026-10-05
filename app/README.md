# SkyStack.app — native macOS front-end (Stage 6)

A SwiftUI app for SkyStack — modern and native (no Electron), in the spirit of
OrbStack. It consumes the Go core through the `skystack` CLI's JSON API
(`skystack api …`), so there's no second protocol or embedded Docker client to
maintain — the CLI *is* the backend, and the same JSON shapes become the daemon
API later.

## What's in it

- **OrbStack-grade 3-column shell** — sidebar (sections) → list → detail. A host
  picker (local · skyvm · ssh) drives everything. Sections, grouped like OrbStack:
  - **Docker**: Containers, Images, Volumes, Networks
  - **Linux**: Machines (create / shell / delete)
  - **General**: Commands (the console)
- **Resource management** — run a container (`+`), Start/Stop/Restart, delete via
  context menu, prune images/volumes/networks, run-from-image, delete image/
  volume/network — all wired to `skystack api …`.
- **Container detail tabs** — **Info · Stats · Logs · Terminal · Files**:
  - **Stats**: live CPU% / memory gauges + a CPU sparkline (`api stats` stream).
  - **Logs**: severity timeline + **✨ Analyze with AI** — sends the visible logs
    to **Claude Code** (`claude -p`, piped on stdin) and shows a root-cause
    analysis + next steps. User-initiated (a button); the data leaves the machine
    only on click. Needs the `claude` CLI (or set `CLAUDE_BIN`).
  - **Files**: browse the container filesystem, click a file to **view its
    content** (`api files` / `api filecontent`).
  - The **Terminal stays alive** when you switch tabs.
- **Logs that lead with a severity timeline** ⭐ — a stacked-by-severity volume
  histogram across the whole stream; **drag across it to zoom** a time window
  (the stream below filters to it). Plus per-severity filter chips with counts, a
  live text filter, follow-tail, and a colored severity rail per line.
- **Terminal — both, per the design** ⭐ — a resizable split with:
  - a **real PTY shell** (SwiftTerm) running `skystack exec <ref>` (bash→sh),
    themed dark with a custom font/caret, full ANSI + live resize;
  - a **command console** with **live syntax highlighting** of the typed command
    (subcommand / flags / strings / paths / the container), autocomplete chips,
    Up/Down history, and a highlighted transcript — runs `skystack …`.
  - a **Shell / Debug switch**: *Debug* opens a busybox toolbox sharing the
    target's namespaces (`skystack debug`), so you get real tools even in a
    distroless/read-only container — its filesystem is at `/proc/1/root`.
- **Compose Graph window** (menu bar) — open a compose file, see the service
  dependency graph with **drawn edges** between dependent services.
- **Menu bar item** — running/containers/hosts-up at a glance.

Polled every 2s from `skystack api hosts` + `skystack api ps`; logs stream from
`skystack api logs <ref> -f` as NDJSON.

## Run it

**Packaged app (self-contained — the `skystack` CLI is embedded):**

```bash
make app                 # → dist/SkyStack.app (builds CLI + app, signs, embeds an icon)
open dist/SkyStack.app    # first launch: right-click → Open (ad-hoc signed)
```

**Dev (from the build tree):**

```bash
# 1. Build the CLI the app talks to (once):
cd ../skystack && make build        # → skystack/bin/skystack

# 2. Run the app (it auto-finds the dev CLI by walking up the tree):
cd ../app && swift run SkyStackApp   # or: make run
```

If the CLI lives elsewhere, point the app at it:

```bash
SKYSTACK_BIN=/path/to/skystack swift run SkyStackApp
```

The app searches, in order: `$SKYSTACK_BIN`, Homebrew/`/usr/local`/`~/.local`
bins, then a dev build (`skystack/bin/skystack`) found by walking up from the
executable. If none is found it shows a friendly "CLI not found" screen.

## Architecture

```
SwiftUI app  ──Process──►  `skystack api …`  ──►  internal/core (Go)
  AppState (poll 2s)         hosts / ps (JSON)        Docker Engine API
  LogStreamModel  ◄──NDJSON── logs <ref> -f           (local · skyvm · ssh)
  actions ─────────────────► action start|stop|restart
```

- `Backend/SkyCLI.swift` — runs the binary, decodes JSON, streams logs (NDJSON
  reassembled from pipe chunks).
- `Backend/AppState.swift` — `@MainActor` store, 2s polling.
- `Views/*` — shell, sidebar, detail, and the `LogsView` timeline.

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (1.13) — xterm-compatible
  terminal emulator for the embedded PTY. (The only external dependency.)

Note: a real PTY needs an unsandboxed process. Run via `swift run` it's
unsandboxed already; a future `.app` bundle must disable the App Sandbox (or add
the right entitlement) for `skystack exec` to spawn.

## Packaging

`make app` builds **`dist/SkyStack.app`** — a self-contained bundle:
`Contents/MacOS/SkyStack` (SwiftUI) + `Contents/Resources/skystack` (the Go CLI)
+ a generated `AppIcon.icns`. It's **ad-hoc signed with the hardened runtime and
the App Sandbox off** (the embedded PTY needs to spawn `skystack exec`). The app
auto-uses the embedded CLI, so end users need neither the Swift nor Go toolchain.

For public distribution, re-sign with your Apple **Developer ID** and notarize
(the exact commands are printed at the end of `packaging/package-app.sh`).

## Next (Stage 6 cont.)

- Notarize for distribution (needs an Apple Developer ID — a user step).
- Polish: persist terminal sessions across tab switches; 16-color ANSI theme;
  layer the other logs innovations (structured fields, noise-collapse).
