# SkyStack — session summary

## Goal
Build an OrbStack-class macOS platform, starting from the architecture brief.
Two parallel tracks, chosen by the user:
- **MVP 1** Remote Docker Manager — Go core + `skystack` CLI (primary stack)
- **MVP 2** Local VM runtime — Swift `SkyVM` over Virtualization.framework

## Session 1 (2026-06-24) — foundation built & verified
Created from an empty `~/Desktop/rocket`.

### Delivered
- `skystack/` Go module (module path `github.com/skynance/skystack`):
  - `internal/config` — `~/.skystack/hosts.yaml` host registry, `[host/]ctr` refs
  - `internal/core` — Docker client factory (local + `ssh://`), ps/inspect/
    lifecycle/exec, logs stream+enrich+severity, tunnel (ssh -L / local proxy)
  - `internal/ui` — tables + colored severity-aware log formatting
  - `internal/cli` — cobra commands: connect/disconnect/hosts/ps/logs/exec/
    inspect/start/stop/restart/tunnel
  - `cmd/skystack/main.go` — entrypoint; Makefile; README
- `vm-runtime/` Swift package `SkyVM`:
  - VMConfiguration (kernel boot, virtio block/net-NAT, virtiofs, vsock,
    balloon, entropy, Rosetta), VMRunner lifecycle, main (args + run loop)
  - entitlements file, README

### Verified working (live, against Docker 29.4.0)
- `hosts`, `ps`, `ps -a`, `exec` (flag passthrough), `logs` (severity auto-tag),
  `logs -l warn` (severity filter), error paths, **local tunnel → HTTP 200**
- Go tests pass: proxy end-to-end, port/ssh/ref parsing, log severity, registry
- `swift build` compiles; SkyVM arg/error paths smoke-tested

## Session 2 (2026-06-24) — Stage 2: own VM runtime boots Docker ✅
Decided to build the FULL OrbStack in stages; user picked Stage 2 (runtime) first.

### Delivered & VERIFIED working
- `vm-runtime/image-builder/` — produces a bootable guest image with no
  privileges: Alpine arm64 rootfs via `apk --root`, `mke2fs -d` ext4 (no
  metadata_csum), EFI-zboot kernel extraction → raw Image, custom initramfs
  (virtio + crypto modules, switch_root). `build.sh` (full) + `rebuild-initramfs.sh`
  (fast iteration) + shared `initramfs-init.sh`.
- `vm-runtime/agent/` — `skyvm-agent` (linux/arm64): vsock⇄/var/run/docker.sock
  bridge. Proxy logic unit-tested on darwin (build-tagged main.go for linux).
- `vm-runtime/skymount/` — tiny `syscall.Mount` helper for the initramfs.
- SkyVM host: `VsockForwarder.swift` exposes guest vsock 2375 as a Mac unix
  socket; `VMRunner.connectVsock`; main wires `--docker-socket`. Makefile with
  `build-image`/`sign`/`run-vm`. Ad-hoc codesign with virtualization entitlement.

### END-TO-END PROVEN (live)
- SkyVM boots Alpine 6.12.94 arm64 → OpenRC → **Docker 27.3.1 + containerd + agent**
- Mac: `DOCKER_HOST=unix://~/.skystack/skyvm-docker.sock docker version` →
  `Server v27.3.1 (linux/arm64)`. `skystack ps` works against it too.
- `docker run hello-world` PULLS over guest NAT and runs; image persists in ext4.
- So: SkyStack now has its OWN engine in its OWN VM — no Docker Desktop needed.

### To run it
`cd vm-runtime && make build-image && make run-vm` (boots + exposes the socket).
Set `DOCKER_HOST=unix://$HOME/.skystack/skyvm-docker.sock` to use it.

## Session 3 (2026-06-24) — SkyVM as a native first-class host ✅
User: "quero algo profissional e performático" + integrar SkyVM como host nativo.

### Delivered & VERIFIED
- `skyvm` is now a **built-in host** (like `local`): `skystack ps skyvm`,
  `logs skyvm/api`, `exec skyvm/web`, `ps -A` includes it. config.Host gained a
  `Docker` endpoint field; core.Connect dials `unix://…` for it.
- `internal/vm` package: Runtime config (`~/.skystack/runtime.json`) + Service
  managing SkyVM as a **background daemon** — Start (detached, Setsid, PID file,
  wait-until-Docker-ready), Stop (graceful SIGINT→SIGTERM→SIGKILL, cleanup),
  Status, Setup (auto-detect vm-runtime dir + ad-hoc sign).
- `skystack vm setup|start|stop|restart|status|logs`. Spinner UI for boot/stop.
- SkyVM: **quiet boot by default**, `--verbose` for ignore_loglevel. Removed the
  ttyAMA0 getty (Apple uses hvc0) → no more log spam.

### Live verification
`vm setup` (auto-detect+sign) → `vm start` ("✓ Docker 27.3.1 ready on host
skyvm") → `ps skyvm` shows an nginx container run in the VM → `logs skyvm/web`,
`exec skyvm/web` work → `hosts` lists local+skyvm both up → `vm stop` graceful.

### Bug fixed this session
`os.Process.Release()` sets Pid=-1; we read cmd.Process.Pid AFTER Release →
waitReady got -1 → false "exited during boot" while VM was actually healthy.
Fix: capture pid before Release. (Recorded in errors.md.)

## Session 4 (2026-06-24) — Stage 3a: VirtioFS bind mounts + bridge fix ✅

### Delivered & VERIFIED
- **VirtioFS file sharing**: the Mac home is mirrored into the guest at the SAME
  path over virtiofs, so `docker run -v <macpath>:<ctr>` works transparently.
  - Guest: `skyvm-share` OpenRC service reads `skyvm.share=<path>` from
    /proc/cmdline, modprobe virtiofs, mounts tag `skyshare` (runs before docker).
  - SkyVM: `--share-mount` appends `skyvm.share=` to the kernel cmdline.
  - skystack: `vm.Runtime.Share` (default = home); `vm setup --share`; Start
    passes `--share/--share-mount` (mirror same path).
  - Verified: container reads marker.txt from Mac AND writes back to the Mac.
- **Fixed a real bridge bug** (present since Session 2): attached docker
  run/exec/attach output was EMPTY because the vsock bridge closed both
  directions on first EOF. Now half-closes per direction (CloseWrite /
  shutdown SHUT_WR). Also added `signal(SIGPIPE, SIG_IGN)` to SkyVM (the
  half-close exposed a SIGPIPE-kills-process bug → see errors.md).
  Verified: `docker run alpine echo X` now prints X; `skystack exec skyvm/web`
  returns output; `skystack logs skyvm/web` streams.

### Stage 3 remaining (next): networking
- Container IPs reachable from the Mac; automatic port-forward to localhost;
  host.docker.internal. (Apple NAT already gives the guest a 192.168.64.x IP.)

## Session 5 (2026-06-24) — Stage 3 networking (core) ✅
User: "prossiga pra etapa 3 vamos implementar tudo core primeiro".

### Recon finding
Apple NAT gives the guest 192.168.64.x; the Mac (gateway 192.168.64.1, iface
bridge101) reaches the guest's published ports DIRECTLY (~5ms). So the port-fwd
data path is direct (Mac→guestIP:port); only control flows over vsock.

### Delivered & VERIFIED
- **Automatic port forwarding** to localhost (dynamic add/remove):
  - Guest agent: 2nd vsock port (1024) streams newline-JSON {ip, ports} —
    polls docker.sock for published tcp ports, reports eth0 IP. Pure parser
    (`parsePublishedPorts`) unit-tested.
  - SkyVM `PortForwarder`: connects to netinfo vsock, reconciles
    `127.0.0.1:P → guestIP:P` TCP proxies (SIGPIPE-safe half-close pump).
  - Verified: `docker run -p 8080:80` in VM → `curl localhost:8080` HTTP 200;
    stop it → forward removed; new `-p 9090` → forward appears (~1s).
- **host.docker.internal → the Mac**: guest `skyvm-netcfg` service writes
  dockerd `host-gateway-ip` = default gateway. Verified: container resolves
  host.docker.internal→192.168.64.1 and fetched a file from a Mac HTTP server.
- `skystack vm status` now lists forwarded `localhost:<port>`s.

### Direct container-IP routing — DONE (Session 6)
`curl http://172.17.0.2` works directly from the Mac (no -p). Pieces:
- Guest `skyvm-route` service: DOCKER-USER allow eth0→172.16/12 + POSTROUTING
  no-masquerade (preserves container src IP). RE-APPLIES in a 20s background
  loop because Docker rebuilds/flushes DOCKER-USER during startup (one-shot
  insert gets lost — that was the bug).
- SkyVM publishes guest IP → ~/.skystack/skyvm-net.json (cleared on start/stop
  to avoid stale-IP races).
- `skystack vm route add|remove`: sudo route for 172.16.0.0/12 via guest IP.
- `skystack vm install-helper`: least-privilege sudoers.d drop-in (NOPASSWD only
  for /sbin/route on 172.16/12, validated via visudo). Then `vm start`
  auto-routes (passwordless) and `vm stop` removes the route. Verified full
  automatic cycle. Helper at /etc/sudoers.d/skystack; remove via uninstall-helper.

## Session 7 (2026-06-24) — Stage 4: local domains *.sky.local 🟡
- Guest agent: DNS server on UDP :53 resolving <name>.sky.local and
  <service>.<project>.sky.local → container IP (queries local Docker). Minimal
  hand-rolled DNS codec (dnsmsg.go) + parser (parseContainerDomains), unit-tested.
  GOTCHA: buildAnswer must keep only header+question+answer and drop the client's
  EDNS OPT (else "malformed packet"); set ARCOUNT/NSCOUNT=0.
- SkyVM: DnsForwarder UDP 127.0.0.1:5354 → guestIP:53 (stable target); shared
  GuestInfo holder (PortForwarder writes guest IP, DnsForwarder reads).
- skystack install-helper now ALSO writes /etc/resolver/sky.local (nameserver
  127.0.0.1 port 5354); uninstall-helper removes it. Domain const = sky.local.
- VERIFIED: dig @127.0.0.1 -p 5354 web.sky.local → container IP; api → its IP;
  unknown → NXDOMAIN.
- DONE: user re-ran install-helper → /etc/resolver/sky.local written. Verified
  `curl http://web.sky.local` → 200 system-wide, fast (~10-28ms) after the AAAA
  NODATA fix (was 5s when AAAA returned NXDOMAIN). Stage 4 COMPLETE.
  Resolver write needs the password (not in the NOPASSWD route rule).
- NOTE: saw a one-off guest KERNEL crash (NULL deref/RCU stall) on one boot;
  did NOT reproduce on restart — treat as flaky Alpine-6.12-on-vz, watch for it.

## Session 8 (2026-06-24) — Stage 5: local HTTPS ✅ (code complete; needs image rebuild)
User: "prossiga etapa 5 (HTTPS local)".

### Architecture decision
TLS terminates **inside the guest** (in skyvm-agent), NOT on the Mac. The big win:
the Mac reaches `guestIP:443` directly over Apple's vmnet bridge, so NO privileged
Mac port (443<1024 needs root) and NO extra route are needed. DNS `*.sky.local`
now resolves to the **guest IP** (proxy ingress) instead of the container IP; the
in-VM reverse proxy routes by SNI/Host → container:port.

### Delivered & VERIFIED (compile + unit tests; not yet booted)
- **Guest agent** (`vm-runtime/agent`):
  - `routes.go` + `routes_test.go`: `parseContainerRoutes` (name→{IP,Port}, picks
    the container's HTTP port: prefer 80/8080/8000/3000/5000 else lowest else 80).
  - `certmint.go` + `certmint_test.go`: `parseCABundle` (concatenated cert+key PEM)
    + `caSigner.leafFor` — mints+caches per-host ECDSA leaf certs (390d) signed by
    the CA. CA key is held ONLY in memory.
  - `ca.go`: `serveCA` — vsock :1026 listener; host pushes the CA bundle, agent
    loads it into a shared in-memory `caStore`.
  - `webproxy.go`: reverse proxy on **:80** (keeps plain http working, port-aware)
    and **:443** (TLS via `GetCertificate`→leafFor by SNI). Routes by Host/SNI;
    502 for unknown names. Polls Docker every 2s for the route map.
  - `dns.go`: now answers known `*.sky.local` A queries with the guest eth0 IP
    (proxy ingress); falls back to container IP if eth0 not up. Unknown → NXDOMAIN.
  - `main.go`: wires serveCA + serveProxy; passes iface to serveDNS. New
    `--ca-port` (default 1026).
- **skystack CLI**:
  - `internal/certs` (EnsureCA + Bundle + Exists) — CA is ECDSA P-256, 10y, IsCA,
    **PermittedDNSDomains=["sky.local"]** (blast-radius limit). `ca_test.go` proves
    the name constraint actually rejects an out-of-domain leaf at verify time.
  - `internal/vm/trust.go`: TrustCA/UntrustCA/CATrusted/CAExists via
    `security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain`.
  - `service.go`: `EnsureCA()` at `vm start` (so the file exists for SkyVM to push).
  - `cli/vm.go`: `vm trust-ca` / `vm untrust-ca`; `install-helper` now also trusts
    the CA (and `uninstall-helper` untrusts it); `vm status` shows an `https:` line.
  - `config.CADir()` → ~/.skystack/ca.
- **SkyVM (Swift)**: `CAForwarder.swift` reads ~/.skystack/ca/{ca.crt,ca.key},
  connects guest vsock 1026 (retries ~5min while booting), writes the bundle,
  half-closes, waits for the agent's EOF-ack. Wired in `main.swift`.

### TO ACTIVATE (user action — interactive/disruptive, left for the user)
1. `cd vm-runtime && make build-image` (rebuilds the rootfs with the new agent;
   uses OrbStack to build — that's its purpose, fine to use, just don't stop it).
2. `skystack vm setup` (re-signs the rebuilt SkyVM) — or `make sign`.
3. `skystack vm install-helper`  (or `skystack vm trust-ca`) — sudo: trusts the CA.
4. `skystack vm restart`.
5. Test: `docker run -d --name web nginx` then `curl https://web.sky.local`.

### Session 8 (cont.) — Option A: ship the VM image, no Docker for users ✅
User asked why we still use OrbStack while building an OrbStack. Clarified: Docker
is a BUILD-TIME-ONLY bootstrap sandbox (assembles the guest *VM image*, which is
NOT a Docker image); at runtime the engine is the in-VM `skyvm`. Chose **Option A**
— distribute the prebuilt image so users need no Docker.
- `vm-runtime/image-builder/package.sh` + `make package-image`: bundles
  ./assets → `dist/skyvm-image-<arch>.tar.gz` + `.sha256` (no Docker; assets must
  already exist from `make build-image`).
- `internal/vm/image.go`: `InstallImage(path|url)` — downloads (file/http),
  verifies sha256, safe-extracts (allowlist + path-traversal guard) into
  ~/.skystack/assets with an atomic swap, repoints runtime.json. `image_test.go`
  covers round-trip, traversal, checksum-mismatch, incomplete bundle.
- `config.AssetsDir()` = ~/.skystack/assets; `setup.go` auto-detects an installed
  image there (Docker-free path) when no build tree is present.
- CLI: `skystack vm install-image <path-or-url>`. README documents the
  maintainer-vs-user split. Verified e2e via the built binary (temp HOME).
- NOTE: the SkyVM *binary* (Swift) still comes from the build tree / future app
  bundle (Stage 6) — not part of the image bundle. Option A removes Docker for
  the image specifically; the Swift toolchain gap closes when the app ships.

## Session 9 (2026-06-24) — Stage 6: native macOS app (first cut) 🟡
User: "vamos" + app moderno/bonito como OrbStack; terminal customizado com syntax
highlight; logs devem inovar. Alinhado via AskUserQuestion:
- LOGS: liderar com **timeline de severidade** (histograma + drag-to-zoom).
- TERMINAL: **os dois** (PTY real + console de comandos) — mas no PRÓXIMO passo.
- 1º corte: casca bonita + navegador + logs inovadores (terminal depois).

### Arch decision
SwiftUI nativo consumindo o core Go via **CLI em modo JSON** (`skystack api …`),
não um daemon novo. O app faz `Process` → decodifica JSON; logs streamam por
NDJSON nos pipes. Vira a "API" que depois promovo a daemon/gRPC.

### Delivered & VERIFIED (compila limpo; GUI não lançada p/ não abrir janela)
- **CLI**: `internal/cli/api.go` — `skystack api` (hidden): `hosts` (kind/up/
  engine, concorrente), `ps` (-a/-A, JSON), `logs <ref> -f` (NDJSON
  {time,host,container,stream,severity,message}), `action start|stop|restart`.
  Verificado ao vivo: hosts→local(29.4.0)+skyvm(27.3.1).
- **app/** SwiftPM (tools 5.9, macOS 14), 10 arquivos Swift, sem deps externas:
  - Backend: `SkyCLI` (acha o binário: $SKYSTACK_BIN → brew/local → walk-up do
    executável p/ skystack/bin/skystack; run via Process+continuation; stream de
    logs por AsyncStream+LineBuffer NDJSON). `Models` Codable (Host/Container/
    RawLog/LogLine, Severity, parser RFC3339Nano tolerante a ns). `AppState`
    @MainActor, polling 2s.
  - Views: `RootView` (NavigationSplitView + estados erro/binary-missing),
    `Sidebar` (hosts→containers, state dots, brand), `ContainerDetail`
    (header+ações Start/Stop/Restart+abas Logs/Overview), `MenuBarView`
    (contadores), **`LogsView`** = a estrela: `SeverityTimeline` (Canvas,
    barras empilhadas por severidade, **drag-to-zoom** com dim fora da janela),
    chips de filtro por severidade c/ contagem, filtro de texto, follow-tail,
    stream com rail colorido por severidade + clock. `Theme` (cores).
- README do app + roadmap (Stage 6 🟡 parcial).

### Como rodar (usuário)
`cd skystack && make build` → `cd ../app && swift run SkyStackApp`
(ou `SKYSTACK_BIN=… swift run SkyStackApp`). GUI não foi lançada por mim de
propósito (abriria janela na tela do usuário). Distribuição como .app
assinado/notarizado fica p/ depois (fecha a lacuna do toolchain Swift, junto com
`vm install-image`).

### Session 9 (cont.) — Stage 6: terminal (PTY + console) ✅
"os dois" do AskUserQuestion. Adicionado ao `app/`:
- Dep externa (primeira do app): **SwiftTerm 1.13** (emulador xterm). Inspecionei
  a API real na checkout antes de escrever (LocalProcessTerminalView.startProcess,
  processDelegate, font/nativeFore/nativeBack/caretColor).
- `Views/TerminalPane.swift`: `TerminalRepresentable` (NSViewRepresentable sobre
  LocalProcessTerminalView) roda `skystack exec <ref> sh -c 'bash||sh'` num PTY
  REAL → o CLI vê TTY no slave e entra no modo interativo (raw + resize). Tema
  escuro (fonte mono, fg/bg/caret). Env preservado (HOME!) + TERM=xterm-256color.
  `PTYTerminal` com header + overlay "session ended / Restart" (recria via .id).
- `Views/CommandHighlighter.swift`: tokenizer → roles coloridos (subcommand/flag/
  string/path/container), `attributed()` p/ AttributedString, `splitArgs()`.
- `Views/CommandConsole.swift`: input com **syntax highlight ao vivo** (truque do
  overlay: Text(attributed) embaixo + TextField .foregroundStyle(.clear) por cima,
  mono alinha 1:1, caret pelo tint), prompt `skystack ❯`, chips de autocomplete,
  histórico Up/Down (.onKeyPress), transcript com comando colorido + saída mono.
  Roda via `SkyCLI.runText` (nunca lança; erro aparece inline).
- `ContainerDetail`: aba **Terminal** = VSplitView (PTY em cima / Console embaixo).
- VERIFICADO a espinha dorsal sem GUI: subi alpine descartável no skyvm e rodei o
  EXATO `skystack exec skyvm/… sh -c …` → retornou saída + alpine 3.24.1 + root,
  e limpei. (PTY interativo usa o mesmo docker exec c/ TTY, já provado antes.)
  App compila limpo (sem warnings). GUI não lançada (abriria janela).
- SANDBOX: PTY exige processo não-sandboxed. `swift run` já é; futuro .app precisa
  desligar o App Sandbox p/ `skystack exec` spawnar.

### Session 9 (cont.) — Stage 6: package SkyStack.app ✅
Empacotado como bundle nativo auto-suficiente:
- `app/packaging/`: `Info.plist`, `SkyStack.entitlements` (**app-sandbox=false**;
  SEM comentários XML — AMFI rejeita), `make-icon.swift` (ícone gerado:
  rounded-rect com 3 camadas brancas), `package-app.sh` (+ `make app`).
- Bundle: `Contents/MacOS/SkyStack` (SwiftUI) + `Contents/Resources/skystack`
  (CLI Go EMBUTIDA) + `AppIcon.icns`. `SkyCLI.resolveBinary` agora prefere a CLI
  do bundle → app não precisa de toolchain Go/Swift no usuário.
- Assinatura **ad-hoc + hardened runtime** (--options runtime), sandbox off (PTY
  precisa spawnar). 18 MB, arm64. Verificado: codesign --verify "satisfies its
  Designated Requirement"; CLI embutida roda (`api hosts`→local,skyvm).
- GOTCHA: ~/Desktop é gerenciado pelo iCloud (fileprovider re-stampa
  com.apple.FinderInfo → codesign --strict falha). Solução: montar/assinar/
  verificar num tempdir (/var/folders, fora do iCloud) e só então copiar p/ dist/.
  (Registrado em errors.md.)
- Notarização Developer-ID = passo do usuário (comandos impressos no script).

## Session 10 (2026-06-25) — Stage 7: Debug Shell ✅
OrbStack-style debug shell: um toolbox descartável que COMPARTILHA os namespaces
do alvo, dando ferramentas mesmo num container distroless/read-only.
- `core/debug.go`: `DefaultDebugImage=busybox:latest`; `debugHostConfig` (PidMode
  + NetworkMode = `container:<target>`, CapAdd SYS_PTRACE, AutoRemove);
  `EnsureImage` (pull se faltar); `CreateDebug`. Teste de debugHostConfig.
- `cli/debug.go`: `skystack debug [host/]<ctr> [cmd...]` — exige alvo running,
  garante o toolbox, cria container nos namespaces do alvo, TTY interativo
  (raw+resize) OU one-shot (StdCopy). Shell default cai em `/proc/1/root` (root
  do alvo). Wire em root.go.
- VERIFICADO ao vivo no skyvm: alvo nginx:alpine → `debug … ls /proc/1/root` lista
  o ROOT do nginx (docker-entrypoint.sh…); `debug … ps` mostra `nginx: master` como
  PID 1 + workers (PID ns compartilhado). Toolbox busybox != alvo. Limpo.
- App: `TerminalRepresentable` agora recebe `args` genéricos; `PTYTerminal` ganhou
  switch **Shell/Debug** no header (Shell=`exec`, Debug=`debug`), recria via .id.
  Compila limpo. Regenerei o SkyStack.app (CLI embutida agora tem `debug`).

### Session 10 (cont.) — Stages 8, 9, 10 ✅ (todas as stages do roadmap)
**Stage 8 Kubernetes (k3s):** code-complete, gated, bring-up = user step.
- runtime.json `K8s bool`; `service.go` passa `--k8s`; SkyVM `--k8s` → cmdline
  `skyvm.k8s=1` + `K8sForwarder` (localhost:6443→guest:6443, cert SAN 127.0.0.1).
- guest-build.sh baixa k3s v1.31.5+k3s1 (arm64) + serviço OpenRC `skyvm-k8s`
  (só inicia com skyvm.k8s=1; `--disable traefik`; exporta kubeconfig p/ o Mac via
  o share). Agente DNS resolve `*.k8s.sky.local` → guest. `skystack k8s
  enable/disable/status/kubeconfig`. NÃO bootei (precisa rebuild imagem c/ k3s).
**Stage 9 Linux machines:** ✅ VERIFICADO ao vivo no skyvm.
- core/machine.go (DistroImages ubuntu/debian/alpine/fedora/arch/rocky;
  CreateMachine = pull+run `sleep infinity` + bind da home do Mac; List/Remove).
  cli/machine.go: `machine create/list/shell/delete/start/stop` (default host
  skyvm; shell reaproveita runInteractive, one-shot cai em ExecSimple sem TTY).
  Teste ResolveDistro. LIVE: criei ubuntu 24.04, shell mostrou o SO, home do Mac
  montada em /Users/renancorrea ✓.
**Stage 10 Build/Compose:** ✅ core/CLI/API verificados; view no app.
- core/compose.go: ParseCompose (yaml.Node — depends_on/ports/build short+long
  form) + Layers() (topo-layering). Teste. cli/compose.go: `compose graph` (render
  em camadas) + up/down/ps/logs (shell `docker compose` c/ DOCKER_HOST por host).
  cli/build.go: wrapper buildx multi-plataforma. `api compose` → JSON do grafo.
  ui.Bold/Dim. App: ComposeView (janela "Compose Graph" via menu bar, NSOpenPanel,
  cards em camadas). LIVE: `compose graph` e `api compose` num sample → camadas
  [cache,db]→[api]→[web] ✓.
- .app regenerado (CLI embutida agora tem debug/k8s/machine/compose/build).
- GOTCHAs novos em errors.md (iCloud FinderInfo no codesign; sem comentário no
  .entitlements). Os 4 componentes: build+test verdes.

## Session 11 (2026-06-25) — IA expandida (Milestone 2) ✅
User escolheu (AskUserQuestion) "IA expandida": análise de container inteiro
(logs+stats+inspect), chat de follow-up, e sugerir→aplicar fix.

### Delivered & VERIFIED ao vivo (skyvm rodando, Docker 27.3.1)
- **Go CLI**: `internal/core/stats.go` ganhou `SnapshotStats` (lê 2 frames p/ CPU%
  real, one-shot). `internal/cli/api.go`: `api inspect <ref>` (raw docker inspect)
  + `api context <ref>` = bundle JSON {name,image,state,status,host,inspect,stats,
  logs(tail 200, severity-tagged)} numa única chamada. Build+test verdes.
- **App Swift**: `SkyCLI.analyzeJSON(prompt,input,resume)` roda `claude -p …
  --output-format json`, decodifica {result,session_id,is_error}; `--resume` p/
  follow-up manter contexto da sessão. `containerContextRaw(ref)` busca o bundle.
- **AIView.swift reescrito**: `AIChat` (@MainActor ObservableObject) — conversa
  multi-turno, parse do bloco ```skyfix → `FixSuggestion` (comando skystack), e
  `ContainerAIView` (aba IA): intro com botão "Analyze container" (GATED — não
  auto-roda, zero tokens até clicar), transcript (bolhas user / MarkdownText
  assistant), **fix card com Apply fix** (roda o comando via CLI, mostra saída),
  e **composer de follow-up**. `LogAnalysisView` agora é um sheet fino sobre
  `ContainerAIView(seedLogs:autoStart:true)` (mantém o entry-point do botão
  Analyze dos logs, escopado à janela filtrada).
- **ContainerDetail**: nova aba **AI** (entre Stats e Terminal), montada no ZStack
  como o terminal → conversa persiste entre trocas de aba. Picker 360→430.
- `.app` regenerado (CLI embutida agora tem api context/inspect; assinado, verificado).

### Prova e2e (container crash-loop deliberado no skyvm)
Criei `aibroken` (--restart on-failure, `exit 1`, stderr "FATAL cannot connect to
db"). IA: leu o inspect (RestartCount, OOMKilled=false), **pegou que o erro de DB
era red-herring** (echo literal, não conexão real — só visível via inspect Cmd),
sugeriu `skystack stop` (não restart, que re-loopa). Parser extraiu o comando →
Apply rodou → container foi `restarting`→`exited`. Follow-up via --resume manteve
contexto ("keep it stopped for debugging…"). Limpei o aibroken.

### GOTCHA (artefato de teste, não bug do app)
fish shell NÃO faz word-split de `$var` como bash → `skystack $ARGS` passou
"stop skyvm/aibroken" como UM arg. O app passa `fix.args` como array correto pro
Process — provado rodando `skystack stop skyvm/aibroken` com args separados.

## Session 12 (2026-06-25) — Revisão de UI (4 batches) ✅
User: "prosseguir para próximas etapas da revisão da ui e outras partes" → escolheu
(AskUserQuestion, multi) os 4 lotes. Fiz auditoria de UI (código limpo, bons
componentes compartilhados) e implementei tudo.

### Go backend (api surface +3)
- `core/inspect.go`: InspectImage/InspectVolume/InspectNetwork + VolumeConsumers/
  NetworkConsumers (ContainerList com filtro volume=/network=).
- `api inspect <kind> <host> <id>` (container|image|volume|network, raw JSON;
  container resolve por nome). `api consumers <volume|network> <host> <name>` →
  JSON []nomes. `api vm` → status JSON {configured,running,ready,version,pid,ip,
  routed,ports,caTrusted}. Build+test verdes; testados ao vivo.

### Batch A — Polish & consistência
- `ResourceList` ganhou loading + empty-state com CTA (`EmptyState`): "No
  containers → [Run a container]", volumes/networks/machines → [New …]. Empty
  text agora cita o host.
- **Loading por-host**: AppState.loadingResources + selectHost limpa as listas na
  hora e marca loading → some o "flash" de dados do host anterior; refreshResources
  ignora resposta stale (guard host==selectedHost).
- `DetailIdentity` compartilhado (StateDot+título+subtítulo+ações) usado por
  ContainerDetail e MachineDetail.
- accessibilityLabel em todos os botões só-ícone (+/lixeira).

### Batch B — VM lifecycle na UI
- `VMControl` no sidebar (sob o HostPicker): mostra SkyVM booting/ready/stopped;
  botão **Start** (verde) quando parada, menu **Restart/Stop** quando pronta,
  spinner "Working…" enquanto vmBusy. AppState.vmAction roda `vm start|stop|restart`
  via runText + refresh. (Não derrubei a VM em teste; api vm validado ao vivo.)

### Batch C — Inspect UI + relações
- `InspectView.swift`: `InspectSheet` (JSON cru, filtro de linhas, copy) aberto de
  ContainerDetail (menu Inspect), Image/Volume/Network detail (botão Inspect).
  `ConsumersSection` ("Used by" → nomes de containers, clicável p/ ir ao container)
  em Volume/Network detail via api consumers.

### Batch D — Machines pro nível
- `distroColor`/`distroIcon` (ubuntu/debian/alpine/fedora/arch/rocky) na lista e no
  detalhe. MachineDetail: botão **Terminal** (abre shell real no Terminal.app via
  .command descartável + `open -a Terminal`), menu **Open home in Finder** (revela
  ~ do Mac, que é o share) + Copy name + Delete. machine shell agora passa --host.

### Verificação
go build/test ✓ · swift build 0 warnings ✓ · api vm/inspect/consumers ao vivo ✓ ·
.app repackaged (CLI embutida com os 3 comandos novos) + assinado/verificado ✓.

## Session 12 (cont.) — One-click remote connect from ~/.ssh/config ✅
User: "como conecto em containers de uma VPS? tem como botão prático que carregue
os hosts do ssh config?" Sim — o conector remoto usa o connhelper ssh:// do Docker,
que já resolve o ~/.ssh/config; `ssh://<alias>` reaproveita HostName/User/Port/
IdentityFile/ProxyJump. Registry.Add só exige prefixo ssh:// (não precisa user@).
- `internal/cli/sshconfig.go`: parseSSHHosts() — parser próprio do ~/.ssh/config
  (segue Include globs, pula wildcards, tolera Key=value). `api ssh-hosts` → JSON
  [{alias,hostName,user,port,registered}] (registered = já está no hosts.yaml).
- App: `SSHHostEntry` model; SkyCLI.sshHosts()/connect(name,url)/disconnect(name).
  `RemoteHostsView.swift` (RemoteHostsSheet): lista os aliases do ssh config c/
  botão **Connect** (url=ssh://alias) por linha, estado "Connected ✓"/Disconnect,
  erro inline, + entrada manual (name + ssh://user@host). Sucesso → app.selectHost
  + dismiss (vai direto pros containers do host). HostPicker menu ganhou item
  **"Connect to remote…"**.
- VERIFICADO ao vivo: `api ssh-hosts` parseou os 9 aliases REAIS do usuário
  (hostinger-vps, besu-vm, blockscout-prod, etc.) com HostName/User. .app
  repackaged (CLI embutida tem api ssh-hosts). NÃO testei connect real ainda
  (alcança a infra remota do usuário + escreve no hosts.yaml — pedir consentimento
  e qual host). O caminho SSH remoto nunca foi live-tested (Session 1 não tinha
  host remoto); agora o usuário tem.
- TESTE connect real (besu-vm, com aval): o alias/chave resolveram certo, mas o TCP
  pra 144.22.179.183:22 deu "Operation timed out" — a VPS está inacessível agora
  (down/firewall/rede), NÃO é bug. Isso revelou e CORRIGI um bug de UX: o connect
  dizia "reachable over SSH but Docker did not respond" mesmo quando o SSH nem
  conectava (core.Connect só monta o helper, não testa SSH). Nova mensagem:
  "could not reach Docker on <url>: … check host reachable / Docker running /
  user in docker group". (internal/cli/hosts.go).
- ✅✅ CAMINHO REMOTO PROVADO AO VIVO (1ª vez!): com o usuário na VPN, conectei em
  `clone-and-dev` (10.0.0.147) → `connect clone-and-dev ssh://clone-and-dev` →
  "✓ connected (Docker 28.5.0)". `hosts` lista local+skyvm+clone-and-dev todos up.
  `api ps clone-and-dev` → 27 containers REAIS (besuscan-*, bmonitor-*, postgres,
  rabbitmq, redis, questdb, nats…). `api logs clone-and-dev/besuscan-api` streamou
  logs GIN ao vivo (HTTP 404s em tempo real) — tudo over SSH, agentless, reusando
  o ssh config. api ssh-hosts marca clone-and-dev registered=true. O host fica
  registrado no hosts.yaml (desejado — aparece no host picker do app).
  NOTA: besu-vm(Oracle) e hostinger-vps seguem com :22 timeout (fora da VPN/rede);
  os 10.0.0.x e DigitalOcean abrem quando o usuário está na VPN.

## Session 12 (cont.) — DECISÃO: container view é POR-HOST, não agregado
Cheguei a começar uma view "All hosts" (agrega containers de todos os hosts numa
lista com badge), mas o usuário testou e PREFERIU o comportamento por-host atual
("selecionei o host abaixo da logo e só apareceu containers dessa vm, muito
melhor"). REVERTIDO por completo (AppState/SkyCLI voltaram ao estado limpo). NÃO
re-tentar agregação. O conectar/desconectar de VMs já é fácil pelo picker →
"Connect to remote…" → RemoteHostsSheet (lista aliases do ssh config). Mantido.

## Session 12 (cont.) — Containers agrupados por stack + ícones por serviço ✅
User quer a listagem nível OrbStack: agrupar por projeto compose + ícone por
container. (Os labels com.docker.compose.project já vêm no api ps — confirmado:
clone-and-dev tem besuscan/kong/bmonitor/besu/etc.)
- `Views/ServiceIcon.swift`: `serviceVisual(image,name)` — mapa curado OFFLINE
  (sem baixar logo): visualByImage (postgres/redis/rabbitmq/nats/questdb/nginx/
  kong/elastic/mongo/besu-clients/grafana/minio/…, tokens PRECISOS p/ "besu:"/
  "hyperledger/besu" não pegar "besuscan") → visualByName (api/frontend/worker/
  indexer/migration/…) → fallback determinístico (shippingbox + hashedColor).
  `ServiceIcon` view = quadrado arredondado tint (cor cheia se running, cinza se
  parado).
- `ContainersList` reescrita: agrupa por compose project em SwiftUI.Section
  colapsáveis (@State collapsed), `StackHeader` (chevron + stack icon + nome +
  N running/total + ações em massa **Start/Stop/Restart all**); containers sem
  compose vão p/ seção "Standalone". `ContainerRow` agora usa ServiceIcon (estado
  pela cor do ícone, sem StateDot). `AppState.performAll(action, [Container])`.
  GOTCHA: o app tem `enum Section` (Navigation.swift) → tem que usar
  `SwiftUI.Section` na List (igual Sidebar).
- VERIFICADO: build limpo, .app repackaged, mapa de ícones conferido nos 27
  containers reais do clone-and-dev (sem falso-match besu). GUI não lançada
  (usuário vê via `make run`/abrir o .app).

## Session 12 (cont.) — Logos REAIS de marca (offline) ✅
User quis ícones reais (não SF-symbols): baixar logos dos containers famosos +
detectar framework (Go/NestJS/React).
- `packaging/fetch-icons.sh`: baixa 42 logos de devicon(MIT)+iconify-logos(CC0),
  converte SVG→PNG (rsvg-convert, 128px) p/ Sources/SkyStackApp/Resources/
  brand-icons/. Cobre go/nodejs/react/vue/angular/nestjs/nextjs/svelte/python/
  django/flask/ruby/rails/spring/java/php/laravel/dotnet/rust/elixir/deno/bun +
  postgresql/mysql/mariadb/mongodb/redis/rabbitmq/nats/kafka/elasticsearch/nginx/
  apache/traefik/kong/grafana/prometheus/vault/kubernetes/docker/ethereum. (~340KB.)
- Package.swift: `resources:[.copy("Resources/brand-icons")]`.
- ServiceIcon.swift: `brandKey(image,name)` (brandByImage produtos → brandByName
  frameworks) → `BrandIconCache` carrega o PNG (localizador próprio, NÃO
  Bundle.module que dá fatalError) → render do logo (cinza+0.5 se parado). Sem
  match → fallback SF-symbol (serviceVisual + visualByName por papel).
- package-app.sh copia SÓ o SkyStackApp_*.bundle pro .app (SwiftTerm bundle quebra
  xattr — ver errors.md).
- VERIFICADO: build limpo, .app repackaged c/ 42 logos + assinatura válida
  (não-strict; --strict falha por iCloud FinderInfo = esperado). Mapeamento nos 27
  containers reais: postgres/redis/rabbitmq/nats/kong/besu→logo real; apps
  customizados (besuscan-api/frontend/worker)→ícone SF por papel.
## Session 12 (cont.) — Detecção de framework por inspect (lazy) ✅
Fecha a lacuna dos apps customizados. SIMPLES e lazy:
- `core.DetectFramework(ctx,id)`: 1 inspect, lê Config.Env (*_VERSION) + Cmd/
  Entrypoint → retorna brand key (nodejs/nestjs/nextjs/react/vue/python/django/
  flask/ruby/rails/java/php/laravel/dotnet/go) ou "". Go = heurística `isStaticBinary`
  (entrypoint é um binário só, sem interpretador) — conservador, stack do user é
  Go-heavy. `api framework <ref>`.
- App: SkyCLI.framework(ref); AppState.frameworks[id] + detectFramework (cache,
  fwRequested set, só 1x). ContainerRow.onAppear dispara detect SÓ se
  brandKey(image,name)==nil (não inspeciona postgres/redis/etc. que já têm logo).
  ServiceIcon/brandKey ganharam param framework (que JÁ é uma brand key).
- VERIFICADO ao vivo: besuscan-api→go, besuscan-frontend→nodejs, besuscan-indexer→
  go, bmonitor-backend→go, vfinance-api→go; postgres/besu→"" (já têm logo por
  imagem). .app repackaged (CLI embutida detecta), assinatura válida, go test ok.

## Session 12 (cont.) — Logs turbinados (syntax + pause + dedup) ✅
- `Views/LogSyntax.swift`: `attributed(msg,query)` — realça strings/números/IPs/
  URLs-paths/key=val/JSON-keys/HTTP-methods/status(2xx-5xx por cor)/bool/levels via
  passes de NSRegularExpression (try?, mapeia NSRange→AttributedString por
  offsetByCharacters). `stripANSI` remove escapes `\u{1B}[…m` (lixo do GIN).
  Realce de match da busca = fundo amarelo.
- Pause/Resume no LogStreamModel: paused congela a lista (lê em paz), novas linhas
  vão p/ buffer `pending`+pendingCount; togglePause() faz flush no resume. Stream
  segue rodando. Botão laranja com badge de N novas; follow desabilita quando pausado.
- Dedup (toggle): `displayLines` agrupa linhas consecutivas idênticas em DisplayLine
  com count → badge ×N. Mata spam (ex: GIN 404 em loop). LogStreamList agora recebe
  [DisplayLine]+query; LogRow usa LogSyntax + badge ×N + context menu Copy line/msg
  (copia limpo, sem ANSI).
- VERIFICADO: build limpo, .app repackaged + assinatura válida, ANSI strip +
  tokens conferidos numa linha real do besuscan-api (404→laranja, IP→teal, GET→roxo).
  Mudança só no app Swift (CLI inalterada).

## Session 12 (cont.) — Logs: ANSI real + só-erros + JSON expand ✅
- **ANSI interpretado de verdade**: LogSyntax.ansiColored parseia SGR (\u{1B}[…m),
  paleta 16 cores, fg/bg/bold → mostra as cores que o app pretendia (GIN/zap/pino).
  attributed() escolhe: tem ANSI→interpreta; senão→syntax highlight. stripANSI só
  no fallback/copy. Busca realça por cima em ambos.
- **Só erros (1 clique)**: botão ⚠ no controls alterna enabled entre todas e
  [.error,.warn] (errorsOnly computed; tint laranja quando ativo).
- **JSON expand**: LogRow detecta msg que é objeto JSON ({…}), mostra chevron →
  expande pretty-printed (JSONSerialization .prettyPrinted+.sortedKeys) colorido
  via LogSyntax, num card indentado; collapse volta p/ 1 linha. Context menu ganhou
  "Copy JSON (pretty)". VERIFICADO ao vivo: bmonitor-backend emite zerolog JSON →
  expande certinho. (parse guardado por prefixo "{" → barato.)
- VERIFICADO: build limpo, .app repackaged + assinatura válida. Só app Swift.

## Session 12 (cont.) — Polish elegante da UI (estilo OrbStack) 🟡
- ContainerRow: **ações inline no hover** (Open localhost, Start/Stop/Restart,
  Delete) + realce sutil de fundo no hover + ícone 30px + spacing maior; quando não
  hover mostra o pill de portas; busy→spinner. (assinatura OrbStack)
- StackHeader: ações em massa **reveladas no hover** (menos clutter) + StateDot no
  header.
- ContentColumn: `.navigationSubtitle` → "N running · M total" p/ containers, "N"
  p/ outros (estilo "8 running" do OrbStack).
- Build limpo, .app repackaged, assinatura válida. Só app Swift.
- PENDENTE (se quiser continuar o polish): rows de images/volumes/networks/machines
  com mesmo hover bg p/ consistência; refino do detail pane; Brand do sidebar.

## Session 12 (cont.) — Performance: quick wins ✅
Gargalo: app fazia ~6 spawns de `skystack api …` a cada 2s, e p/ host remoto CADA
spawn abria conexão SSH nova (~1s). 4 fixes:
1. **SSH ControlMaster** (core/client.go): GetConnectionHelperWithSSHOpts injeta
   `-o ControlMaster=auto -o ControlPath=~/.skystack/ssh/%C -o ControlPersist=120
   -o ConnectTimeout=12 -o ServerAliveInterval=30`. ControlPath fixo → spawns
   separados compartilham o master; ControlPersist mantém quente entre polls.
   MEDIDO: cold ~1.05s → warm ~0.08s (12×).
2. **Polling em camadas** (AppState): refresh faz containers+hosts todo tick;
   images/volumes/networks/machines só a cada 5º tick (~10s). section didSet →
   refreshOthers imediato na troca de seção. refreshResources (full) ainda usado
   por selectHost/ações. MEDIDO: poll completo warm 509ms → poll em camadas
   (hosts+ps) 148ms (~29%).
3. **Pausa em background** (AppState): observers NSApplication didBecome/Resign
   Active → appActive; intervalo 2s ativo / 20s inativo (refreshAndInterval num
   hop só, sem warning).
4. **Memoização de logs**: LogSyntax.cache (base colorida por mensagem, overlay de
   busca em cópia) + LogJSON.pretty (cache do parse JSON). Evita rodar N regex/
   JSONSerialization por linha a cada scroll. Caps em 4000 entradas.
- VERIFICADO: go build/test ok, swift 0 warnings, .app repackaged (CLI embutida
  com ControlMaster, warm 164ms), assinatura válida.
- KEYSTONE futuro (não feito): daemon persistente + event-stream (docker events /
  stats --stream) = conexões quentes multiplexadas + base p/ agente de IA/watch.

## Session 12 (cont.) — Event-stream + ícones de imagens + Hardware Monitor ✅
**1. Event-stream (daemon pragmático):** `core.WatchContainers` streama
`docker events` (type=container), re-lista com debounce 300ms, mantém a conexão
QUENTE; `api watch <host>` emite `{containers:[...]}` NDJSON. App: SkyCLI.
watchContainers(host) AsyncStream<[Container]>; AppState usa o watch como fonte
PRIMÁRIA (ensureContainerWatch + applyContainers), poll só de fallback; hosts/vm/
others viraram tier lento (5º tick). Resultado: a maioria dos ticks NÃO spawna
nada — updates de container são push instantâneo via eventos. VERIFICADO ao vivo
(watchtest apareceu/sumiu na hora). selectHost re-aponta o watch.
**2. Ícones nas imagens:** ImagesList usa ServiceIcon (logo de marca por tag,
size 28) no lugar do glifo genérico.
**3. Hardware Monitor:** nova seção sidebar "Hardware" (General, abaixo de
Commands, ícone cpu). `core.StreamHardware` + `api hwstats <host>`: capacidade via
docker info (NCPU/MemTotal) + uso agregado (soma dos stats one-shot dos running,
bounded 8 concorrentes); CPU% = delta do total de CPU dos containers / delta do
system CPU entre ticks. App: HardwareView (HardwareModel streaming) com MetricCard
(gauge bar + valor + HWSparkline gradiente) p/ CPU e Memória, MiniStat p/
containers + net rate (rx/tx calculado por delta). VERIFICADO ao vivo no
clone-and-dev: mem 2.81/12.53GB (22%), CPU 10.3% (frame 2), 22/27 running.
- TODOS verificados: go build/test, agent linux, swift 0 warnings, .app repackaged
  (embutida com watch+hwstats), assinatura válida.
- NOTA perf: o `api hosts` (slow tier) ainda conecta em cada host p/ versão; com o
  watch + tiers, o custo por tick caiu drasticamente. Daemon multi-host único (1
  processo, socket server) segue como consolidação futura.

## Session 12 (cont.) — Hosts event-stream (fecha o gargalo do api hosts) ✅
Antes o `api hosts` (slow tier, 10s) spawn-ava um processo e conectava em CADA
host p/ versão. Agora: `core.Engine.Alive` (liveness barato via docker /_ping) +
`api watch-hosts` = UM processo persistente que mantém um engine QUENTE por host,
faz Ping a cada 4s, cacheia a versão (estática), e emite `{hosts:[...]}` NDJSON
**só quando muda** (re-lê o registry todo ciclo → reflete connect/disconnect em
≤4s). App: SkyCLI.watchHosts() AsyncStream<[Host]>; AppState.startHostsWatch no
init + applyHosts (resolve selectedHost na 1ª emissão); refresh() não chama mais
`api hosts` (só fallback one-shot se o watch cair). VERIFICADO ao vivo: 1 frame
(local 29.4.0, skyvm 27.3.1, clone-and-dev 28.5.0), 0 churn em estado estável.
- RESULTADO líquido: em estado estável, fast ticks fazem ~NADA; hosts e containers
  são push de 2 processos persistentes com conexões quentes; só vm(local)+others
  rodam no slow tier (10s). .app repackaged (CLI embutida com watch-hosts),
  assinatura válida.

## Session 12 (cont.) — Hardware Monitor: fix layout + muito mais métricas ✅
User: "Live hardware monitor for clone-and-dev não aparece nada, preciso de mais
métricas". Causa: o dashboard estava espremido na coluna do MEIO (content), e o
painel LARGO (detail) mostrava só o placeholder "Live hardware monitor for…" (o
texto que o user viu). Fixes:
- **Movido p/ o painel direito (largo)**: DetailColumn `.hardware` = HardwareView;
  ContentColumn vira um hint "Live metrics for <host> →". LazyVGrid 2-col cabe bem.
- **Header de sistema aparece NA HORA** (host, OS, kernel, arch, Docker version) —
  nunca fica vazio; métricas preenchem ~1-2s depois.
- **Mais métricas** no `core.StreamHardware`/HardwareSample: os/kernel/arch/
  serverVersion/images (de docker info, refresh 10s), **disco** (docker df em
  GOROUTINE de background — df é lento sobre SSH, não pode bloquear o 1º frame),
  e **TOP consumidores** CPU/mem (per-container cpu% = cpuDelta_i/sysDelta*100,
  top 5). App: cards CPU/Mem (gauge+sparkline) + MiniStats (running/images/disk/
  net↓↑) + 2 TopList com barras relativas.
- VERIFICADO ao vivo clone-and-dev: Ubuntu 24.04.3, kernel 6.17-oracle, x86_64,
  docker 28.5.0, 29 images, disco 11.2GB, CPU 2.7%, top = validator_3/2/1.
  Embedded skyvm: Alpine 3.21, 6 images. .app repackaged + assinatura válida.
- GOTCHA: Go 1.25 tem `min` builtin — não declarar `func min` no pacote (sombreia).

## Session 12 (cont.) — Hardware Monitor com Swift Charts (Apple nativo) ✅
User quis gráficos modernos/detalhistas da Apple. Reescrevi HardwareView com
**Swift Charts** (import Charts, macOS 14) + **Gauge** nativo:
- MetricHero (CPU/Mem): `Gauge(.accessoryCircularCapacity)` (anel) + valor + 
  `AreaHistory` (Chart AreaMark+LineMark, .catmullRom suavizado, gradiente, eixos
  hidden, domínio 0-100).
- FIX semântico: CPU% já é host-wide (cpuPct=sumDelta/sysDelta*100) → fração do
  gauge = cpu/100 (antes dividia por cpus*100 = barra minúscula errada).
- TopChart (top CPU/mem): `Chart{BarMark}` horizontal (y=name, x=metric, gradiente,
  cornerRadius, annotation com o valor no fim da barra, xScale folgada 1.25×).
- MiniStats 4-col (running/images/disk/net). Header de sistema imediato.
- Build limpo 0 warnings, .app repackaged, assinatura válida.

## Session 13 (2026-06-26) — Robustez de reboot + backoff (itens 1,2,4) ✅
Bug do user: após reboot, todos hosts down e skyvm NÃO inicia. Causa: SkyVM em
.build/release/ perdeu a assinatura+entitlement (rebuild des-assina). Fixes:
1. **Self-heal** (vm/setup.go autoReSign + service.go Start): se ensureSigned
   falha, acha SkyVM.entitlements perto do binário, re-assina e re-tenta. VERIFICADO:
   removi a assinatura → `vm start` re-assinou e bootou sozinho.
2. **Auto-start launchd** (vm/daemon.go + cli `vm install-daemon`/`uninstall-daemon`):
   LaunchAgent ~/Library/LaunchAgents/dev.skystack.vm.plist (RunAtLoad → `vm start`
   no login). INSTALADO+carregado (launchctl list mostra dev.skystack.vm). Com o
   self-heal, sobrevive reboot mesmo após rebuild.
4. **Backoff no app** (AppState.ensureContainerWatch): host down → re-spawn do watch
   no máx ~a cada 6s (3 ticks) em vez de todo tick.
- .app repackaged (CLI embutida com self-heal + install-daemon), assinatura válida.
- PENDENTE item 3 (daemon único multi-host, socket server) — grande, ficou p/
  sessão dedicada (contexto acabou). Depois: itens 5-11 (tooltip charts, hover
  consistente, ⌘K palette, IA operadora, deploy compose, etc.).
- LIMITAÇÃO: binário SkyVM ainda em .build/ (self-heal cobre); fix 100% robusto =
  copiar p/ ~/.skystack/bin/SkyVM (não feito; self-heal já resolve a dor).

## Session 14 (2026-06-29) — Polish de UI (itens 5,6,7,8) ✅
User (AskUserQuestion) escolheu o lote "Polish de UI" dos pendentes. Verifiquei os
4 componentes verdes primeiro (go build/test, agent linux/arm64, swift build app +
vm-runtime). Tudo só no app Swift (CLI Go inalterada). Os 4:

### Item 6 — Hover consistente em todas as resource rows
- `HoverRow` (Resources.swift): wrapper que dá o MESMO tratamento do ContainerRow —
  fundo arredondado sutil no hover (`Color.primary.opacity(0.06)`) + ações inline
  reveladas no hover (closure recebe o estado `hover` → troca info estática por
  ações). `RowActionButton` compartilhado (size 11, 20×20, secondary) extraído;
  ContainerRow.rowIcon refatorado p/ usá-lo (consistência real, DRY).
- Aplicado a **images** (hover→Delete, troca o tamanho), **volumes** (hover→Delete),
  **networks** (hover→Delete só se `!builtin`), **machines** (hover→Start/Stop +
  Delete + context menu novo). Novo `AppState.machineDelete(name)` (MachineDetail
  refatorado p/ usá-lo).

### Item 5 — Tooltips interativos + eixo de tempo nos charts do Hardware
- `UsageHistoryChart` (HardwareView.swift): chart grande CPU+Mem (2 séries, 0–100%)
  abaixo dos heroes, com **eixo de tempo relativo** (`AxisMarks(values:.stride(by:30))`
  → "120s … now") e **tooltip via `.chartOverlay`** (`onContinuousHover` + `proxy.
  plotFrame`/`proxy.value(atX:)` acha o ponto mais próximo → RuleMark tracejada +
  PointMarks + leitura "Ns ago · CPU x% · Mem y%"). `HistorySample` deriva `t`
  (segundos atrás, ≤0) do índice × intervalo. Exposto `HardwareModel.interval`.
  Heroes mantêm o sparkline `AreaHistory` (glance rápido); o novo chart é o detalhe.

### Item 8 — Estados de erro/vazio mais ricos
- **Host offline ≠ vazio**: novos computeds em AppState (`selectedHostReachable`,
  `selectedHostError`, `hostOffline` = pós-load && !up, `vmStartAction`). Novo
  `OfflineState` (RootView): "⟨host⟩ is offline" + erro real + botões **Start SkyVM**
  (só p/ skyvm não-ready) e **Retry**. Renderizado no ContentColumn E DetailColumn
  p/ seções de recurso (não Commands/Hardware) quando `hostOffline`; HardwareView
  ganhou branch offline (antes girava "Reading hardware…" p/ sempre num host down).
- `ErrorBar` agora **dispensável** (botão ✕ → zera cliError) + texto selecionável.

### Item 7 — ⌘K command palette
- `CommandPalette.swift` (novo): overlay estilo Raycast/OrbStack. Campo de busca
  auto-focado, **fuzzy match** (`fuzzyScore`: substring > subsequência, bônus p/
  hits adjacentes + início), navegação ↑/↓ (`onKeyPress`), ⏎ roda, esc fecha,
  hover/clique seleciona, ScrollViewReader rola até a seleção. Itens construídos ao
  vivo do AppState (rank por categoria qd query vazia): **seções** (Go to …),
  **hosts** (Switch to …), **ações** (Connect to remote…, VM start/stop/restart,
  Prune images/volumes/networks), **containers** (jump + Start/Stop/Restart por
  container). Wire: `AppState.paletteOpen`/`remoteSheetOpen`; `SkyStackApp` adiciona
  `CommandGroup(after:.toolbar)` com `Button("Command Palette").keyboardShortcut("k",
  .command)`; RootView faz overlay do palette + `.sheet(isPresented:$app.remoteSheetOpen)
  { RemoteHostsSheet() }`.

### Verificação
swift build app limpo (0 warnings nos arquivos tocados: Resources/AppState/RootView/
HardwareView/CommandPalette/SkyStackApp). **.app repackaged** (`make app`) — release
build 0 erros, ad-hoc signed, "satisfies its Designated Requirement", instalado em
app/dist/SkyStack.app. GUI NÃO lançada (abriria janela na tela do user) — convenção
das sessões anteriores; user testa via `make run` ou abrindo o .app. Restam item 3
(daemon único, grande) e itens 9 (IA operadora), 10/11 (deploy compose remoto +
port-forward sob demanda).

## Session 15 (2026-06-30) — Itens 3, 9, 10, 11 (todos os pendentes restantes) ✅
User: "siga os 3". Fiz na ordem contido→grande, build+test+LIVE a cada um. User
estava na VPN → testei contra hosts SSH remotos REAIS (clone-and-dev, blockskout-
staging) além da skyvm.

### Itens 10/11 — deploy compose remoto + port-forward sob demanda
- **Go (api.go)**: `api tunnel <ref> <local:ctr>` (NDJSON: emite linha `ready` então
  bloqueia até morrer; remoto=ssh -L, local/skyvm=proxy da porta publicada),
  `api compose-up <host> <file>` / `api compose-down` (shell `docker compose` com
  DOCKER_HOST do host, streama saída). **BUG corrigido** em core/tunnel.go: dispatch
  do Tunnel mandava tudo não-local pro SSH; skyvm (socket unix, sem SSH) quebrava.
  Agora: SSH só se `Host.SSH != ""`, senão proxy local (cobre local+skyvm).
- **App**: `PortsCard` em ContainerDetail (Overview) — local/skyvm: botão Open
  (localhost:hostPort); remoto SSH: **Forward** → cria forward → "localhost:N"
  Open+Stop. `AppState.forwards`/startForward/stopForward (processo `api tunnel`
  mantido vivo, cancel mata). ComposeView ganhou **host picker + Deploy/Down** +
  painel de saída streamada. SkyCLI.composeUp/Down/startTunnel.
- LIVE: tunnel skyvm/fwdtest → curl localhost HTTP 200; compose-up/down deploy real
  na skyvm (cria rede+container, depois remove); networks remoto via daemon.

### Item 9 — IA operadora (triagem do host inteiro)
- **Go**: `api host-context <host>` — engine ver + contagens + cada container
  (state/status/ports) + **log tail dos problemáticos** (não-running/unhealthy/
  restarting, cap 12 containers). Extraí builders compartilhados `buildContainerContext`
  /`buildHostContext` (DRY com `api context`/`host-context`).
- **App**: nova seção sidebar **Operator** (General, ícone wand.and.stars) →
  `OperatorView`+`OperatorChat` (host-scoped). Parser de **MÚLTIPLOS** blocos
  ```skyfix (um `skystack …` cada) → lista de fixes aplicáveis individualmente.
  Reusa AIMessage/FixSuggestion/MarkdownText. Render no DetailColumn (.id(host)).
- LIVE e2e (com Claude real): criei 2 crash-loopers + 1 exited na skyvm → operador
  diagnosticou os 3, sugeriu **stop** (não restart) pro crash-loop com conflito de
  porta, e **omitiu** fix pro de migração (não resolve em 1 cmd) — exatamente o
  comportamento seguro pedido. 2 blocos skyfix bem-formados parseados.

### Item 3 — DAEMON ÚNICO MULTI-HOST ✅ (o grande, antes adiado)
- **internal/cli/daemon.go** (novo): `daemonServer` com **pool de engines quentes**
  por host (reusadas entre toda request/stream, reconecta se /_ping falha). Servidor
  **socket unix** (~/.skystack/daemon.sock), protocolo JSON 1-request-por-conn:
  unário=1 linha JSON, stream=NDJSON até o cliente fechar a conn (cancela o ctx).
  Métodos espelham a superfície api: hosts, ps, images/volumes/networks/machines,
  action, context, host-context, watch, watch-hosts, logs, stats, hwstats. Mesmos
  shapes/encoders do `api` → decoders do app reusados sem mudança.
- **CLI**: `skystack daemon run|start|stop|status|call`. start=detached (Setsid,
  pidfile; capturei pid ANTES de Release() — gotcha do Pid=-1). `daemon call` =
  cliente de teste/transporte (dial socket, manda request, copia resposta).
- **App opt-in**: SkyCLI.useDaemon (env `SKYSTACK_DAEMON=1` + socket existe) roteia
  leituras/streams por `daemon call` em vez de `api`; **fallback pro api** nas
  unárias se o daemon cair (runRead/decodeRead). Mutações ficam no api (sem risco
  de dupla-execução). Default OFF → comportamento inalterado.
- LIVE: daemon start/status; call hosts/ps/images/hwstats/logs/watch/watch-hosts/
  host-context — todos OK. **Reuso quente comprovado**: 1ª query remota (clone-and-dev,
  SSH) 0.20s cold → 0.03-0.04s nas seguintes (~5×). Fallback: daemon parado → api
  assume. Parei o daemon ao fim (não foi pedido pra ficar rodando).

### Verificação geral
go build/test/vet verdes; agent linux ok; swift build app 0 warnings; **.app
repackaged** (CLI embutida com daemon/tunnel/compose-up/host-context — confirmado),
assinado, "satisfies its Designated Requirement". GUI não lançada (convenção).
TODOS os pendentes do roadmap (3,5-11) agora DONE.

## Session 16 (2026-06-30) — Instalador .pkg persistente (auto-start de tudo) ✅
User: "instalador pra todos serviços rodar no Mac, persistente — sem subir serviço
Go nem iniciar a skyvm manual". Escolheu (AskUserQuestion): **.pkg nativo** +
**setup privilegiado incluído** (postinstall do pkg roda como root → uma só
autorização, sem 2º prompt).

### Lacunas fechadas (Go)
- **Binário SkyVM estável** (`internal/vm/install.go`): `InstallBinary()` copia
  SkyVM + entitlements p/ `~/.skystack/bin`, **assina lá** e repointa runtime.json
  → sobrevive a rebuild/move/delete do repo (fecha o TODO de robustez 100%).
  `InstallFrom(srcBin,srcEnt,image)` semeia máquina NOVA do payload do pkg.
  `InstallHelperAsRoot(user,caDir)` faz sudoers+resolver+CA trust **direto como
  root** (sem sudo) pro postinstall. CLI: `vm install-binary`.
- **LaunchAgent do daemon** (`cli/daemon.go`): `daemon install`/`uninstall` →
  `dev.skystack.daemon.plist` (RunAtLoad + **KeepAlive** → `daemon run`). Persiste
  no login, reinicia se cair. (O LaunchAgent da VM `dev.skystack.vm` já existia.)
- **Orquestrador** (`cli/install.go`): `skystack install`/`uninstall` idempotente.
  Modos: default (terminal, sudo interativo), `--user-only` (binário+agents, sem
  root), `--system-only --user <name> --home <h>` (só privilegiado, root). Flags
  `--image`, `--skyvm-binary/-entitlements`, `--with-helper` (default true).
- **App**: `useDaemon` agora liga por padrão quando o socket existe (instalado =
  daemon-on); `SKYSTACK_DAEMON=0` força off, `=1` força on. Fallback pro api segue.

### O .pkg (`app/packaging/build-pkg.sh`, `make pkg`)
Payload (root): `/Applications/SkyStack.app` · `/usr/local/bin/skystack` ·
`/usr/local/libexec/skystack/SkyVM(+.entitlements)` ·
`/usr/local/share/skystack/skyvm-image-arm64.tar.gz` (288MB). **postinstall**
(root): detecta o console user → roda a parte de-usuário via `launchctl asuser
<uid> sudo -u <user> skystack install --user-only --skyvm-binary … --image …`,
depois a parte privilegiada `skystack install --system-only --user … --home …`.
`pkgbuild` → **`dist/SkyStack-Installer.pkg` (294MB)**. Resultado: 1 duplo-clique →
app em /Applications, CLI no PATH, VM+daemon sobem no login (sobrevivem reboot),
*.sky.local DNS + rota + CA prontos. Reverter: `skystack uninstall`.

### Verificação
- `vm install-binary` testado ISOLADO (HOME temp): copiou+assinou (entitlement de
  virtualização ✓) + repointou runtime.json, **zero efeito no setup real**.
- `daemon install` round-trip ao vivo: agent carregou (launchctl PID), daemon subiu
  via o agent (socket bound, log "listening"), `daemon uninstall` limpou tudo.
- `.pkg` (294MB) montado e inspecionado (pkgutil/expand): payload + postinstall
  corretos; assinatura do .app-fonte intacta. **NÃO instalei** (destrutivo, precisa
  admin — decisão do user). go build/test/vet + swift (app+vm-runtime) verdes.
- GOTCHA: iCloud criou `AppState 2.swift` (cópia de conflito, quebrava o build) —
  removido; varri o repo por `* N.swift`/`* N.go`.

### Como instalar (passo do user)
`open app/dist/SkyStack-Installer.pkg` (unsigned → botão direito → Abrir, ou
`sudo installer -pkg … -target /`). Pra distribuir: `productsign` + notarizar.

## Session 17 (2026-06-30) — Logs em janela expandida ✅
User quis "expandir os logs" levando a barra de cima (search, Analyze/Claude,
filtros, pause/start) pra uma tela cheia. Refatorei `LogsView.swift`:
- Extraí **`LogsContent`** (timeline + barra de controles + lista) compartilhado;
  os filtros (`enabled`/`query`/`dedup`) viraram @Binding e o `LogStreamModel` é
  @ObservedObject → a aba inline e a janela expandida usam o MESMO buffer, filtros
  e zoom (sem re-stream).
- **`LogsView`** (aba) ficou slim e apresenta `ExpandedLogsView` via `.sheet`
  (re-injeta `app` pois sheet não herda @EnvironmentObject de forma confiável).
- **Tela cheia DE VERDADE** (correção): 1ª tentativa foi `.sheet` (modal, NÃO vai
  fullscreen) → user reclamou. Troquei por `LogsWindowManager` (AppKit **NSWindow**
  + `toggleFullScreen` = fullscreen nativo do macOS) hospedando `LogsWindowRoot`
  (stream próprio, fresh tail, filtros seedados da aba). `.fullScreenPrimary` no
  collectionBehavior; controllers retidos num array estático, limpos no willClose
  (`MainActor.assumeIsolated` p/ 0 warnings).
- Novos botões na barra: **⤢ Expand** (abre a janela fullscreen) e **↻ Reload**
  (`model.reload()` = stop+clear+re-tail). Build 0 warnings; **.app repackaged +
  reaberto**.

## Session 18 (2026-06-30) — Formatação de logs POR FORMATO ✅
User: logs de GIN/NestJS/etc. têm formatos diferentes e o GIN tava ilegível;
quer formatação profissional por sistema de log. Novo `Views/LogFormat.swift`:
- **Parser** `LogFormat.classify(msg)` (memoizado, cap 4000) → `LogShape`:
  `.http(HTTPLog)` (GIN/nginx/genérico) | `.nest(NestLog)` | `.plain`. Extração
  RESILIENTE: detecta prefixo `[GIN]`/`[Nest]`/access-log, remove ip+latência ANTES
  de achar status (senão "10.0.0.103" vira status), pega method/path/status/lat/ip
  por sub-regex tolerantes. Confiança: só vira HTTP com flavor OU method+path+
  (status|lat) → prosa comum cai em PLAIN.
- **Render estruturado**: `HTTPLogContent` (tag GIN/nginx + **pill de método**
  colorido + **badge de status** por classe 2xx/3xx/4xx/5xx + path destacado +
  latência colorida por lentidão >300ms/>1s + ip dim) e `NestLogContent`
  (tag [Context] roxo + msg via LogSyntax + timing +Nms laranja). `LogRow.message
  Content` ramifica por shape; PLAIN mantém o LogSyntax genérico.
- **Severidade inferida** (`LogLine.level`): sem level explícito → 5xx=erro, 4xx=
  warn, Nest carrega o seu → rail/chips/timeline refletem o resultado HTTP.
- VALIDADO num script Swift isolado com os exemplos REAIS do user (GIN mangled,
  nginx-ish, canônico) + NestJS + access-log + prosa: todos extraíram certo, zero
  falso-positivo. Build 0 warnings; **.app repackaged + reaberto**.
- Formatos cobertos: GIN, NestJS, nginx/apache combined, HTTP genérico (morgan/
  express caem no genérico). JSON continua no expand existente. Próximos possíveis:
  logfmt (key=val já tem highlight), zap/zerolog-console, Rails, Caddy.
- **Fix de responsividade da barra**: os 4 chips ERROR/WARN/INFO/DEBUG (com
  contadores) quebravam linha. Colapsei num único **`SeverityFilterMenu`** (dropdown
  com toggles por nível + contadores + presets All/Errors&warnings/Errors-only;
  label = bolinhas coloridas dos níveis ativos ou "All levels"). Removi o botão ⚠
  redundante (virou preset). `levelCounts` computa as contagens 1×O(n). Liberou
  ~270px da barra. SeverityChip removido.

## Session 19 (2026-06-30) — Registry de formatação multi-serviço ✅
User quer logs alinhados pra TODOS os serviços famosos (Postgres, Redis, RabbitMQ,
Hyperledger Besu, Vault, etc.) com estrutura profissional e fácil manutenção.
Reescrevi `LogFormat.swift` como **registry plugável**:
- **Modelo uniforme**: `LogShape = .http(HTTPLog) | .leveled(LeveledLog) | .plain`.
  `LeveledLog{source, level, component, message, trailing}` cobre TODO log baseado
  em nível com UM renderizador (`LeveledLogContent`: badge de source + tag de
  component teal + message com LogSyntax + trailing). HTTP segue rico
  (`HTTPLogContent`). Unifiquei NestJS no leveled.
- **Lista `parsers: [(String)->LogShape?]`** ordenada (específico→genérico). Cada
  serviço = `static func parseX(_:)->LeveledLog?` + 1 linha. Cobertos: **NestJS,
  GIN, nginx/apache, Postgres, Redis, RabbitMQ, Besu, Vault, NATS, Kafka/log4j**, +
  um **genérico-com-nível** (logrus/zap/zerolog-console, com guard de timestamp pra
  não pegar prosa). `sev()` mapeia o vocabulário de nível de todos (LOG/NOTICE/INF/
  WRN/FTL/CRIT/levelchar do redis `.-*#`/etc.). `shortLogger()` encurta o
  logger do Besu (org.hyperledger…EthScheduler → EthScheduler).
- **Severidade inferida** já lê o leveled.level → rail/chips/timeline corretos por
  serviço (PG FATAL=erro, redis #=warn…).
- **Adicionar serviço novo** = escrever `parseX` (regex tolerante via `caps`) +
  append na lista. Zero mudança no renderer.
- VALIDADO num script Swift com amostras reais de cada um (PG/redis/rabbit/besu/
  vault/nats/kafka/nest) + prosa/logfmt → todos certos, zero falso-positivo. Build
  0 warnings; **.app repackaged + reaberto**.
- Próximos triviais de encaixar: MongoDB(JSON já no expand), Traefik, Caddy,
  Elasticsearch, MySQL/MariaDB, syslog estrito, logrus key=val (já tem highlight).

## Session 20 (2026-06-30) — Terminal SSH do HOST + ações de admin ✅
User: botão ao lado do host picker pra abrir o terminal da VM SSH (o host, não o
container) + ações pra interagir com a VM (restart, etc.).
- **Go**: `api host-ssh <name>` → JSON `{ok,target,args,reason}`. Deriva o argv ssh
  do endpoint `ssh://` registrado (alias/user/port via url.Parse → honra ~/.ssh/
  config). Hosts não-SSH (local/skyvm) → ok:false. LIVE: clone-and-dev → args
  ["clone-and-dev"]; skyvm → ok:false.
- **App** (`Views/HostSSH.swift` novo): `HostSSHControl` = botão (ícone terminal) ao
  lado do HostPicker, SÓ p/ hosts kind=="ssh" (Sidebar agora põe HostPicker +
  HostSSHControl numa HStack). Menu: **Open SSH terminal** (janela in-app PTY) ·
  System info · Docker disk usage · Docker prune (read-only via `cli.sshRun` →
  `SSHOutputSheet`) · **Restart Docker daemon…** · **Reboot machine…** (com
  confirmação; via janela PTY com `ssh -t … sudo …` p/ a senha). `TerminalWindow
  Manager`/`TerminalWindowRoot` (novo, genérico) hospeda `TerminalRepresentable`
  (reusa o PTY do container) numa NSWindow fullscreen-capable. `SkyCLI.hostSSH` +
  `sshRun` (roda /usr/bin/ssh, captura saída). `SSHTarget` model.
- VALIDADO ao vivo: `ssh clone-and-dev 'hostname;uptime;df;docker --version'` →
  conectou (dev-rdc-blk, up 7d, **/ 100% cheio**, Docker 28.5.0). Build 0 warnings;
  **.app repackaged + reaberto**. (Terminal interativo/sudo reusa o PTY provado.)
- NOTA: HostPicker perdeu o padding embutido (agora na HStack) + `.frame(maxWidth:
  .infinity)`. TerminalWindowManager é reutilizável p/ futuros terminais em janela.

## Session 21 (2026-07-01) — Fixes de log (corrupção, false-positive, overlap) ✅
User: logs do vfinance-api "tudo errado" (mojibake + texto em cima de texto).
3 bugs corrigidos + 1 formatter novo:
1. **Corrupção de linhas grandes (core/logs.go)**: `streamTagger` prefixava
   `\x00stdout\x00` a CADA Write do StdCopy → linhas gigantes (JSON de INSERT do
   GORM) quebradas em vários frames tinham o marcador INJETADO no meio → mojibake.
   FIX: streamTagger stateful (`inLine *bool`), marcador só no início de cada linha.
2. **Parser HTTP guloso (LogFormat.swift)**: achava "POST"/`/path` em qualquer
   lugar → linha SQL do GORM virava falso `[POST]`. FIX: caso genérico exige
   `^(GET|POST|…)\s` (método NO INÍCIO) + path. GIN/nginx seguem âncorados.
3. **Formatter GORM novo**: `[2.003ms] [rows:1] <sql>` → `[SQL] [rows:N] <sql>
   <timing>` (parseGorm, registrado antes do parseHTTP).
4. **Overlap de linhas (texto em cima de texto)**: o rail (`Rectangle`) dentro de
   um HStack `.firstTextBaseline` colapsava a altura (Rectangle não tem baseline).
   FIX: rail virou `.overlay(alignment:.leading)`; HStack do LogRow + LeveledLog
   Content usam `.top`; mensagens ganharam `.frame(maxWidth:.infinity, alignment:
   .leading)` (sem largura, `.fixedSize` calculava altura de 1 linha e renderizava
   quebrado → overlap). Tudo validado (parser em script), build 0 warnings, .app
   repackaged. Gotchas 1 e 2 em errors.md.
- INVESTIGAÇÃO ao vivo (via `api logs clone-and-dev/vfinance-api`): "record not
  found" (72×) = `gorm.ErrRecordNotFound` de `metadata_service.go:25` (SELECT
  vehicle_metadata WHERE hash=… rows:0) seguido de INSERT → padrão benigno
  find-by-hash-then-insert. NOTA: os SELECTs levam ~400ms (lento p/ lookup de 1
  linha) — suspeita: falta índice em `hash` E/OU disco / 100% cheio no host.
- GOTCHA persistente: ~/Desktop é iCloud → evicta o dist/SkyStack.app (e o .pkg);
  reconstruir com `make app` quando sumir. Recomendei copiar p/ /Applications.

## Next steps (todas as stages 0–10 DONE)
STATUS Session 10: **roadmap completo (0–10)**. Itens que dependem de ação do
usuário p/ ir 100% ao ar:
- Stage 5 HTTPS: `make build-image` → `vm setup` → `vm install-helper` (sudo) →
  `vm restart`.
- Stage 8 k8s: rebuild da imagem (agora com k3s) → `k8s enable` → `vm restart`.
- App: notarização Developer-ID (credenciais do usuário).
Polish/futuro: persistir terminal entre abas; ANSI 16 cores; edges desenhados no
grafo de compose; SSH nas machines; ingress real do k8s (porta vs proxy :80/:443);
builder multi-plat persistente. Possível Milestone 2: telemetria/UX, settings, etc.
- Stage 5 ainda precisa: `make build-image` → `vm setup` → `vm install-helper` →
  `vm restart` p/ ir ao ar (rebuild + sudo + restart — ação do usuário).
- Stage 6 restante: empacotar como **.app assinado/notarizado** (Info.plist, ícone,
  sandbox-off) → sem toolchain Swift p/ usuário; persistir sessão do terminal entre
  trocas de aba; tema ANSI 16 cores; demais inovações de logs (campos/ruído).
- Depois: 7 Debug Shell, 8 Kubernetes, 9 Linux machines, 10 build/compose UX.

**Recommended next: Stage 6 — native macOS app** (SwiftUI menu bar + container
explorer + log viewer over the Go core). Then 7 Debug Shell, 8 Kubernetes,
9 Linux machines, 10 build/compose UX.

Polish backlog (not blocking):
- Make SkyVM a launchd-managed background daemon (survives logout / auto-start).
- Trim verbose initramfs diagnostics; re-add `quiet` once fully stable.
- Persistent data disk separate from rootfs; dynamic memory; pause-when-idle.
- Watch the one-off guest KERNEL crash (NULL deref/RCU stall, Alpine 6.12 on vz)
  — did not reproduce, but if it recurs consider a different/newer guest kernel.
- Could not live-test the remote SSH host path (no remote host available).
