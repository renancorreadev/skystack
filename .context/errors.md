# Known errors & fixes (don't repeat)

## Logs grandes corrompidos ("mojibake") — streamTagger prefixava por-Write
`core/logs.go` demuxava stdout/stderr via `stdcopy.StdCopy` + um `streamTagger`
que prefixava `\x00stdout\x00` a CADA Write. Uma linha grande (ex: JSON enorme de
um INSERT do GORM) é quebrada em vários frames do docker → o StdCopy chama Write
várias vezes pra UMA linha → o marcador era **injetado no meio da linha**,
corrompendo o conteúdo. **Fix**: `streamTagger` agora é stateful (`inLine *bool`),
emitindo o marcador só no INÍCIO de cada linha (após `\n`), nunca em continuações
de frame. (Session 21.)

## Parser de log HTTP guloso classificava SQL/app como HTTP
`LogFormat.parseHTTP` (app) achava "POST"/`/path` em QUALQUER lugar da linha → uma
linha SQL do GORM com "POST" no JSON + `[2.003ms]` virava um falso `[POST]` row,
destruindo o conteúdo. **Fix**: caso genérico (sem flavor GIN/nginx) exige que a
linha COMECE com o método (`^(GET|POST|…)\s`) + tenha path. Também adicionei um
formatter GORM (`[Nms] [rows:N] <sql>` → `[SQL]`). (Session 21.)

## Tunnel/port-forward: skyvm went down the SSH path and failed (exit 255)
`core.Engine.Tunnel` dispatched on `Host.IsLocal()` → everything non-local
(including **skyvm**, which has a unix-socket Docker but NO SSH) went to
`tunnelSSH` and failed ("ssh tunnel failed: exit status 255"). **Fix**: dispatch
on `Host.SSH != ""` (SSH path only for real SSH hosts); otherwise `tunnelLocal`
(proxy the published host port — local AND skyvm both surface published ports on
the Mac's localhost via SkyVM's PortForwarder). (Session 15, internal/core/tunnel.go.)

## App: SwiftPM executable builds but no window appears (`swift run`)
A bare SwiftPM SwiftUI app launches as a background accessory and never brings
its window forward — looks like "builds but won't start". **Fix**: an
`AppDelegate` via `@NSApplicationDelegateAdaptor` that calls
`NSApp.setActivationPolicy(.regular)` + `NSApp.activate(...)` in
`applicationDidFinishLaunching`. Verify a window exists headlessly with
`CGWindowListCopyWindowInfo` (no Screen Recording permission needed for owner
name/bounds; `screencapture` IS blocked without it).

## App: container delete "No such container: skyvm/<name>"
`skystack api rm <kind> <host> <id>` takes a BARE id/name and does NOT resolve a
`host/name` ref (unlike `api action`, which does). Passing `container.ref`
(`skyvm/nginx`) fails. **Fix**: pass `container.name`. (AppState.deleteContainer.)


## codesign on ~/Desktop: "resource fork, Finder information... not allowed"
`~/Desktop` (and `~/Documents`) are iCloud-managed; the fileprovider continuously
re-stamps `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` xattrs, so even
after `xattr -cr`, `codesign --verify --strict` fails on the freshly built `.app`.
**Fix**: assemble + sign + verify the bundle in a non-iCloud temp dir (`mktemp -d`
→ /var/folders), then `cp -R` it into `dist/`. (app/packaging/package-app.sh.)

## Packaging SwiftPM resources: copy only OUR bundle, not SwiftTerm's
After adding `resources:` to the SwiftPM target (brand icons), the resource
bundle (`SkyStackApp_SkyStackApp.bundle`) must be copied into the .app's
Contents/Resources so it resolves at runtime. Copying ALL `.build/release/*.bundle`
also grabs `SwiftTerm_SwiftTerm.bundle`, whose read-only `Shaders.metal` makes the
subsequent `xattr -cr` fail ("Permission denied") → packaging aborts. SwiftTerm's
bundle isn't needed at runtime. **Fix**: copy only `SkyStackApp_SkyStackApp.bundle`
+ `chmod -R u+w` it before signing. (package-app.sh.) Also: don't use
`Bundle.module` (fatalErrors if the bundle is absent) — locate the bundle via
Bundle.main.resourceURL/executableURL candidates and return nil to fall back.

## Após reboot: SkyVM não inicia ("not signed with the virtualization entitlement")
Sintoma: após reiniciar o Mac, `vm start` falha com "SkyVM binary ... is not signed
with the virtualization entitlement — run `skystack vm setup --sign`", e todos os
hosts ficam down (skyvm parado; remotos perdem o ControlMaster/VPN). Causa: o
binário SkyVM mora em `vm-runtime/.build/release/SkyVM` (artefato de build) — um
`swift build`/clean no vm-runtime re-gera o binário SEM a assinatura ad-hoc +
entitlement. **Fix imediato:** `skystack vm setup --sign` (re-assina) + limpar
órfãos (`rm ~/.skystack/skyvm-docker.sock skyvm-net.json skyvm.pid`) + `vm start`.
**Fix robusto (TODO):** copiar o SkyVM p/ um local estável assinado (ex:
~/.skystack/bin/SkyVM) que builds não tocam, + LaunchAgent launchd p/ auto-start
no login (sobrevive reboot). A VM NÃO é um serviço gerenciado hoje → morre no reboot.

## codesign entitlements: "AMFIUnserializeXML: syntax error"
An XML **comment** inside the `.entitlements` plist makes the entitlements parser
(AMFI) reject it during signing. **Fix**: no comments in `*.entitlements` — keep
the explanation in the script/README. (Bit us on SkyStack.entitlements.)

## Docker SDK module split (build fails: "declares path moby/moby/api")
`go mod tidy` greedily resolves `github.com/docker/docker/api` /`/client` to the
post-split submodules, which declare a different module path and break the build.
**Fix**: pin the pre-split monolith —
`go get github.com/docker/docker@v27.5.1+incompatible github.com/docker/cli@v27.5.1+incompatible github.com/docker/go-connections@v0.5.0`.

## `sockets.DialPipe` undefined
A too-new `go-connections` removed `DialPipe`, which docker v27 client needs.
**Fix**: pin `github.com/docker/go-connections@v0.5.0`.

## `container.PortRangeProto` undefined
In docker v27 the ports map is keyed by `nat.Port`, not a container type.
**Fix**: `import "github.com/docker/go-connections/nat"`; use `nat.Port("80/tcp")`.

## Local tunnel returned HTTP 000 / hung 5s (macOS Docker Desktop)
Docker Desktop publishes ports on BOTH `0.0.0.0` and `[::]`, but its **IPv4**
proxy can stall while IPv6 serves. `curl localhost` succeeds via happy-eyeballs;
a hard `net.Dial("tcp","127.0.0.1:PORT")` hangs.
**Fix**: dial `localhost:PORT` so Go's dual-stack fast-fallback uses the working
stack. (`internal/core/tunnel.go` → `tunnelLocal`). Verified by curl -4 (000 @4s)
vs curl -6 (200 @58ms).

## cobra parsed inner command flags (`exec ctr nginx -v` → "unknown flag v")
**Fix**: `cmd.Flags().SetInterspersed(false)` on `exec`; skystack flags go
before the container name (docker convention), rest pass through.

## golang.org/x/term needed Go 1.25 toolchain
Pinned to `golang.org/x/term@v0.27.0`; otel transitive dep still pulls a 1.25
toolchain, which Go auto-fetches — acceptable.

## STAGE 2 (VM boot) — hard-won gotchas

### Kernel won't boot: Alpine arm64 vmlinuz is EFI zboot, not a raw Image
Apple's VZLinuxBootLoader needs an UNCOMPRESSED arm64 `Image` (magic `ARMd` at
offset 0x38). Alpine's `vmlinuz-virt` is EFI **zboot** (`MZ`+`zimg`@4+`gzip`@0x18,
a self-decompressing EFI stub Apple can't run). **Fix**: parse the zboot header
(payload offset@8, size@12, compression@0x18), extract + gunzip → raw Image.
Done by python3 in guest-build.sh / rebuild-initramfs.sh. Verify `ARMd` at 0x38.

### initramfs busybox mount → misleading "No such file or directory" (ENOENT)
Two layered causes, found via verbose init:
1. `/tmp` didn't exist in the initramfs → all stderr redirects silently failed,
   hiding the real error. Don't redirect to /tmp in initramfs.
2. The REAL cause: `EXT4-fs (vda): Cannot load crc32c driver`. The rootfs was
   created with e2fsprogs 1.47's default `metadata_csum` feature, which needs the
   crc32c crypto module; the kernel can't auto-load it (no /sbin/modprobe in the
   minimal initramfs) and the error was hidden by `quiet` on the cmdline.
**Fixes**: (a) `mke2fs -O ^metadata_csum`; (b) pre-`modprobe crc32c_generic` in
init; (c) drop `quiet`, add `ignore_loglevel` to see kernel errors during bring-up.
Also added `skymount` (tiny Go `syscall.Mount`) to bypass busybox mount's helper
logic and get clean errnos.

### Mac↔guest Docker socket returns EOF: vsock transport not loaded in guest
The host (SkyVM) connects to the guest agent over vsock, but `vsock.Listen` in
the guest fails unless `vmw_vsock_virtio_transport` is loaded — OpenRC still
reported the agent `[ok]` because it backgrounds. **Fix**: `modprobe
vmw_vsock_virtio_transport` in the agent service's `start_pre()`.

### Module loading in initramfs: Alpine .ko are compressed
Kernel-initiated `request_module` fails in the initramfs (no modprobe helper).
Explicitly modprobe needed modules in init; virtio_blk/ext4 are effectively
available, but crypto (crc32c) and vsock must be handled explicitly (see above).

## VM "exited during boot" but it's actually healthy — os.Process.Release()
`os.Process.Release()` invalidates the handle and sets `Pid = -1`. If you read
`cmd.Process.Pid` AFTER calling Release(), you get -1. We passed that to a
liveness check → it reported the (healthy) VM as dead. **Fix**: capture
`pid := cmd.Process.Pid` BEFORE `cmd.Process.Release()`. (internal/vm/service.go)

## Guest log spammed with "can't open /dev/ttyAMA0"
The inittab had a getty on ttyAMA0, but Apple Virtualization's console is hvc0,
so the ttyAMA0 getty respawns and fails forever. **Fix**: keep only the hvc0
getty in /etc/inittab (guest-build.sh).

## config.All() depends on real ~/.skystack/runtime.json → flaky test
Including the built-in `skyvm` host in All() when runtime.json exists made a
registry test environment-dependent. **Fix**: tests must not assume exact host
count; assert local-first + expected host present.

## Attached `docker run`/exec output empty over the vsock bridge
Docker uses hijacked bidirectional streams for run/attach/exec/logs -f. The
bridge (agent proxy + Mac VsockForwarder) closed BOTH directions when EITHER hit
EOF, discarding buffered output. **Fix**: half-close per direction —
`CloseWrite()` (Go) / `shutdown(fd, SHUT_WR)` (Swift) on the destination when its
source EOFs, and only fully close when BOTH directions finish. (agent/proxy.go,
VsockForwarder.swift)

## SkyVM killed by SIGPIPE → looked like "timed out" + zombie
After the half-close change, the forwarder can `write()` to a socket the peer
already closed → EPIPE → SIGPIPE → process death (SkyVM only ignored SIGINT).
Because skystack launched it Setsid+Released and didn't reap, the dead process
became a ZOMBIE, so `kill(pid,0)` still returned 0 → liveness check said "alive"
→ readiness ping timed out instead of reporting "exited". **Fix**: `signal(SIGPIPE,
SIG_IGN)` in SkyVM main. (Any socket server must ignore SIGPIPE.)

## Direct container-IP access broke after VM restart (DOCKER-USER empty)
The `skyvm-route` service inserted its `DOCKER-USER -i eth0 -d 172.16/12 ACCEPT`
rule once at boot, but Docker REBUILDS/flushes DOCKER-USER during startup, so on
some boots the rule was lost (POSTROUTING RETURN survived; DOCKER-USER didn't) →
Mac→container forwarding blocked → curl times out. **Fix**: re-apply the
idempotent rules in a 20s background loop in the service.

## autoRoute used a stale guest IP after restart
skyvm-net.json persists across stop/start; on the next start, autoRoute could
read the OLD guest IP before the new SkyVM overwrote it (DHCP can reassign).
**Fix**: clear skyvm-net.json on start (before launch) and on stop cleanup.

## Helper / sudo: route needs root; use a scoped sudoers.d drop-in
Adding the Mac route needs sudo. `skystack vm install-helper` writes
/etc/sudoers.d/skystack with NOPASSWD limited to `/sbin/route … 172.16.0.0/12`
only (validated with `visudo -cf` before install — a malformed sudoers.d file
breaks sudo). After install, `vm start/stop` route passwordlessly. Mac route
syntax: `route -n add -net 172.16.0.0/12 <guestIP>` / `route -n delete -net …`.

## Swift: two benign `Sendable` warnings in VMRunner.swift
Virtualization ObjC types cross the VM dispatch queue. Present in Apple's own
sample code; benign under Swift 5.9. `@preconcurrency import` reduces but does
not eliminate them. Not a build error.
