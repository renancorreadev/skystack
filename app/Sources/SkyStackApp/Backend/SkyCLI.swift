import Foundation

// SkyError surfaces a human message when the CLI is missing or a call fails.
enum SkyError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "skystack CLI not found. Build it (cd skystack && make build) or set SKYSTACK_BIN."
        case .failed(let msg):
            return msg
        }
    }
}

// SkyCLI runs the `skystack` binary and decodes its JSON API. It is the app's
// only backend — no Docker SDK, no network protocol. Stateless beyond the
// resolved binary path, so it's cheap to create per use.
final class SkyCLI {
    let binaryPath: String?
    let claudePath: String?

    /// When true, read/stream calls route through the warm multi-host daemon
    /// (`skystack daemon`) instead of spawning a fresh `api` call that reconnects
    /// each time. Default: ON whenever the daemon's socket is present (the
    /// installer auto-starts it). SKYSTACK_DAEMON=0 forces it off; =1 forces on.
    /// Unary reads fall back to `api` if the daemon call fails, so it's safe.
    let useDaemon: Bool

    init() {
        self.binaryPath = SkyCLI.resolveBinary()
        self.claudePath = SkyCLI.resolveClaude()
        let env = ProcessInfo.processInfo.environment["SKYSTACK_DAEMON"]
        let sockPresent = FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.skystack/daemon.sock")
        self.useDaemon = (env == "1") || (env != "0" && sockPresent)
    }

    /// Builds a `daemon call <method> …` argv (the daemon's request transport).
    private func da(_ method: String, _ args: [String] = []) -> [String] {
        ["daemon", "call", method] + args
    }

    /// Runs a unary read either through the daemon (warm) or `api`, falling back
    /// to `api` if the daemon path errors — so an opted-in app stays resilient if
    /// the daemon stops mid-session.
    private func runRead(daemon: [String], api: [String]) async throws -> Data {
        if useDaemon {
            if let data = try? await run(daemon) { return data }
        }
        return try await run(api)
    }

    /// Locates the Claude Code CLI (`claude`) for AI features. GUI apps don't
    /// inherit the shell PATH, so we search the usual install locations.
    static func resolveClaude() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["CLAUDE_BIN"], fm.isExecutableFile(atPath: env) {
            return env
        }
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "/usr/bin/claude",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: queries

    func hosts() async throws -> [Host] {
        let data = try await runRead(daemon: da("hosts"), api: ["api", "hosts"])
        return try JSONDecoder().decode([Host].self, from: data)
    }

    func containers(host: String) async throws -> [Container] {
        let data = try await runRead(daemon: da("ps", [host]), api: ["api", "ps", host, "-a"])
        return try JSONDecoder().decode([Container].self, from: data)
    }

    func images(host: String) async throws -> [DockerImage] {
        try await decodeRead(daemon: da("images", [host]), api: ["api", "images", host])
    }

    func volumes(host: String) async throws -> [Volume] {
        try await decodeRead(daemon: da("volumes", [host]), api: ["api", "volumes", host])
    }

    func networks(host: String) async throws -> [DockerNetwork] {
        try await decodeRead(daemon: da("networks", [host]), api: ["api", "networks", host])
    }

    func machines(host: String) async throws -> [Machine] {
        try await decodeRead(daemon: da("machines", [host]), api: ["api", "machines", host])
    }

    func files(ref: String, path: String) async throws -> FilesListing {
        try await decode(["api", "files", ref, path])
    }

    func fileContent(ref: String, path: String) async throws -> FileContent {
        try await decode(["api", "filecontent", ref, path])
    }

    func machineCreate(name: String, distro: String, host: String) async throws {
        _ = try await run(["machine", "create", name, "-d", distro, "--host", host])
    }

    func machineDelete(name: String, host: String) async throws {
        _ = try await run(["machine", "delete", name, "--host", host])
    }

    func runContainer(host: String, image: String, name: String, ports: [String]) async throws {
        var args = ["api", "run", host, image]
        if !name.isEmpty { args += ["--name", name] }
        for p in ports where !p.isEmpty { args += ["-p", p] }
        _ = try await run(args)
    }

    func remove(kind: String, host: String, id: String) async throws {
        _ = try await run(["api", "rm", kind, host, id])
    }

    func prune(host: String, kind: String) async throws {
        _ = try await run(["api", "prune", host, kind])
    }

    func create(kind: String, host: String, name: String) async throws {
        _ = try await run(["api", "create", kind, host, name])
    }

    func machineLifecycle(_ action: String, name: String, host: String) async throws {
        _ = try await run(["machine", action, name, "--host", host])
    }

    /// Raw inspect JSON (already pretty-printed by the CLI) for any resource kind.
    func inspect(kind: String, host: String, id: String) async throws -> String {
        let data = try await run(["api", "inspect", kind, host, id])
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Containers using a volume or network.
    func consumers(kind: String, host: String, name: String) async throws -> [String] {
        try await decode(["api", "consumers", kind, host, name])
    }

    /// Local SkyVM status (configured/running/ready/ip/ports).
    func vmStatus() async throws -> VMStatus {
        try await decode(["api", "vm"])
    }

    /// Aliases discovered in ~/.ssh/config, for one-click remote connect.
    func sshHosts() async throws -> [SSHHostEntry] {
        try await decode(["api", "ssh-hosts"])
    }

    /// The ssh argv to reach a host's underlying machine (VM shell + admin).
    func hostSSH(host: String) async throws -> SSHTarget {
        try await decode(["api", "host-ssh", host])
    }

    /// Runs an `ssh` command directly (read-only host admin), returning combined
    /// output and never throwing — for non-interactive actions like system info.
    func sshRun(_ args: [String]) async -> String {
        do {
            let data = try await runProcess("/usr/bin/ssh", args)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Detected language/framework brand key for a container ("" if unknown).
    func framework(ref: String) async throws -> String {
        struct R: Decodable { let framework: String }
        let data = try await run(["api", "framework", ref])
        return (try? JSONDecoder().decode(R.self, from: data).framework) ?? ""
    }

    /// Registers a remote Docker host over SSH (verifies reachability first).
    func connect(name: String, url: String) async throws {
        _ = try await run(["connect", name, url])
    }

    /// Removes a registered remote host.
    func disconnect(name: String) async throws {
        _ = try await run(["disconnect", name])
    }

    /// Drives the SkyVM lifecycle (`vm start|stop|restart`). These can take ~10-20s
    /// while the VM boots; never throws — returns combined output for inline display.
    func vmLifecycle(_ action: String) async -> String {
        await runText(["vm", action])
    }

    private func decode<T: Decodable>(_ args: [String]) async throws -> T {
        let data = try await run(args)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func decodeRead<T: Decodable>(daemon: [String], api: [String]) async throws -> T {
        let data = try await runRead(daemon: daemon, api: api)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func action(_ action: String, ref: String) async throws {
        _ = try await run(["api", "action", action, ref])
    }

    func compose(file: String) async throws -> ComposeGraph {
        let data = try await run(["api", "compose", "-f", file])
        return try JSONDecoder().decode(ComposeGraph.self, from: data)
    }

    /// Deploys / tears down a local compose file on a host. Streams `docker
    /// compose` output as combined text; never throws (errors shown inline).
    func composeUp(host: String, file: String) async -> String {
        await runText(["api", "compose-up", host, file])
    }
    func composeDown(host: String, file: String) async -> String {
        await runText(["api", "compose-down", host, file])
    }

    /// One status line from `api tunnel` — the forward is live once `ready` is
    /// true; `error` set means it failed to establish.
    struct TunnelStatus: Decodable {
        var ready: Bool?
        var localPort: Int?
        var url: String?
        var error: String?
    }

    /// Starts a port-forward (container port → localhost). The process stays
    /// alive until the returned cancel closure runs (or it exits on error).
    func startTunnel(ref: String, localPort: Int, containerPort: Int) -> (AsyncStream<TunnelStatus>, () -> Void) {
        ndjsonStream(args: ["api", "tunnel", ref, "\(localPort):\(containerPort)"])
    }

    /// Runs an arbitrary `skystack` command for the console, returning combined
    /// output and never throwing — errors are shown inline like a shell.
    func runText(_ args: [String]) async -> String {
        do {
            let data = try await run(args)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: log streaming

    /// Streams `skystack api logs <ref> -f` as decoded records. The returned
    /// cancel closure terminates the underlying process.
    /// Streams container resource stats (CPU%, memory) as decoded samples.
    func streamStats(ref: String) -> (AsyncStream<StatsSample>, () -> Void) {
        ndjsonStream(args: useDaemon ? da("stats", [ref]) : ["api", "stats", ref])
    }

    func streamLogs(ref: String, tail: String = "400") -> (AsyncStream<RawLog>, () -> Void) {
        ndjsonStream(args: useDaemon ? da("logs", [ref, tail]) : ["api", "logs", ref, "-f", "--tail", tail])
    }

    /// Streams a host's container list, pushed on Docker events — one persistent,
    /// warm connection that replaces `ps` polling. Each emission is the full list.
    func watchContainers(host: String) -> (AsyncStream<[Container]>, () -> Void) {
        struct Envelope: Decodable { let containers: [Container] }
        let (raw, cancel): (AsyncStream<Envelope>, () -> Void) = ndjsonStream(args: useDaemon ? da("watch", [host]) : ["api", "watch", host])
        let mapped = AsyncStream<[Container]> { cont in
            let task = Task {
                for await env in raw { cont.yield(env.containers) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel(); cancel() }
        }
        return (mapped, cancel)
    }

    /// Streams the host list (reachability + version), pushed only on change,
    /// from one persistent process that holds warm connections per host.
    func watchHosts() -> (AsyncStream<[Host]>, () -> Void) {
        struct Envelope: Decodable { let hosts: [Host] }
        let (raw, cancel): (AsyncStream<Envelope>, () -> Void) = ndjsonStream(args: useDaemon ? da("watch-hosts") : ["api", "watch-hosts"])
        let mapped = AsyncStream<[Host]> { cont in
            let task = Task {
                for await env in raw { cont.yield(env.hosts) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel(); cancel() }
        }
        return (mapped, cancel)
    }

    /// Streams aggregate hardware usage for a host (capacity + live totals).
    func streamHardware(host: String) -> (AsyncStream<HardwareSample>, () -> Void) {
        ndjsonStream(args: useDaemon ? da("hwstats", [host]) : ["api", "hwstats", host])
    }

    /// Generic NDJSON streamer: runs a skystack command and yields decoded rows.
    private func ndjsonStream<T: Decodable>(args: [String]) -> (AsyncStream<T>, () -> Void) {
        guard let bin = binaryPath else {
            return (AsyncStream { $0.finish() }, {})
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        let stream = AsyncStream<T> { continuation in
            let handle = outPipe.fileHandleForReading
            let buffer = LineBuffer()
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { continuation.finish(); return }
                buffer.append(chunk) { lineData in
                    if let row = try? JSONDecoder().decode(T.self, from: lineData) {
                        continuation.yield(row)
                    }
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
                if proc.isRunning { proc.terminate() }
            }
            do { try proc.run() } catch { continuation.finish() }
        }
        let cancel = { if proc.isRunning { proc.terminate() } }
        return (stream, cancel)
    }

    // MARK: AI (Claude Code)

    var claudeAvailable: Bool { claudePath != nil }

    /// Analyzes `input` with Claude Code in headless print mode: the instruction
    /// goes as the prompt, the data (e.g. logs) is piped on stdin.
    /// NOTE: this sends the data to Claude — a user-initiated, explicit transfer.
    func analyze(prompt: String, input: String) async throws -> String {
        guard let bin = claudePath else {
            throw SkyError.failed("Claude Code CLI not found — install Claude Code, or set CLAUDE_BIN.")
        }
        let data = try await runProcess(bin, ["-p", prompt], stdin: input)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// One Claude reply plus the session id, so follow-up turns can resume the
    /// same conversation (`--resume <id>`).
    struct ClaudeReply {
        let text: String
        let sessionID: String?
    }

    /// Runs Claude in headless JSON mode. `input`, when present, is piped on
    /// stdin (the data to analyze); `resume` continues a prior session so the
    /// model keeps full context across follow-up questions.
    func analyzeJSON(prompt: String, input: String? = nil, resume: String? = nil) async throws -> ClaudeReply {
        guard let bin = claudePath else {
            throw SkyError.failed("Claude Code CLI not found — install Claude Code, or set CLAUDE_BIN.")
        }
        var args = ["-p", prompt, "--output-format", "json"]
        if let resume { args += ["--resume", resume] }
        let data = try await runProcess(bin, args, stdin: input)
        struct Envelope: Decodable {
            let result: String?
            let session_id: String?
            let is_error: Bool?
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            // Fall back to raw text if Claude didn't emit JSON (older CLI).
            let raw = String(data: data, encoding: .utf8) ?? ""
            return ClaudeReply(text: raw, sessionID: nil)
        }
        let text = (env.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if env.is_error == true {
            throw SkyError.failed(text.isEmpty ? "Claude returned an error." : text)
        }
        return ClaudeReply(text: text, sessionID: env.session_id)
    }

    /// Full container context (inspect + stats + recent logs) as one JSON blob,
    /// gathered in a single CLI call. Returned verbatim to feed the model.
    func containerContextRaw(ref: String) async throws -> String {
        let data = try await runRead(daemon: da("context", [ref]), api: ["api", "context", ref])
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Host-wide triage context (all containers + problem logs) for the AI
    /// operator — one call, returned verbatim to feed the model.
    func hostContextRaw(host: String) async throws -> String {
        let data = try await runRead(daemon: da("host-context", [host]), api: ["api", "host-context", host])
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: process plumbing

    private func run(_ args: [String]) async throws -> Data {
        guard let bin = binaryPath else { throw SkyError.notFound }
        return try await runProcess(bin, args)
    }

    private func runProcess(_ executable: String, _ args: [String], stdin: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = args
                let out = Pipe()
                let err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                var inPipe: Pipe?
                if stdin != nil {
                    let p = Pipe()
                    proc.standardInput = p
                    inPipe = p
                }
                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: SkyError.failed(error.localizedDescription))
                    return
                }
                if let inPipe, let s = stdin {
                    // Write stdin on a separate thread to avoid a pipe-buffer deadlock.
                    DispatchQueue.global().async {
                        inPipe.fileHandleForWriting.write(Data(s.utf8))
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: SkyError.failed(msg.isEmpty ? "exit \(proc.terminationStatus)" : msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }

    // MARK: binary discovery

    /// Resolves the skystack binary. GUI apps don't inherit the shell PATH, so we
    /// search explicit locations and walk up from the running executable to find
    /// a dev build (skystack/bin/skystack).
    static func resolveBinary() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SKYSTACK_BIN"], fm.isExecutableFile(atPath: env) {
            return env
        }
        // Prefer a CLI bundled inside the packaged .app (self-contained).
        if let res = Bundle.main.resourceURL?.appendingPathComponent("skystack").path,
           fm.isExecutableFile(atPath: res) {
            return res
        }
        let exeDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ""))
            .deletingLastPathComponent()
        let sibling = exeDir.appendingPathComponent("skystack").path
        if fm.isExecutableFile(atPath: sibling) { return sibling }

        var candidates = [
            "/opt/homebrew/bin/skystack",
            "/usr/local/bin/skystack",
            "\(NSHomeDirectory())/.local/bin/skystack",
        ]
        // Walk up from the executable looking for a sibling dev build.
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(dir.appendingPathComponent("skystack/bin/skystack").path)
            candidates.append(dir.appendingPathComponent("bin/skystack").path)
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}

// LineBuffer reassembles NDJSON lines from streamed chunks. readabilityHandler
// fires serially, so the un-synchronized buffer is safe.
final class LineBuffer {
    private var data = Data()

    func append(_ chunk: Data, onLine: (Data) -> Void) {
        data.append(chunk)
        while let nl = data.firstIndex(of: 0x0A) {
            let line = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            if !line.isEmpty { onLine(line) }
        }
    }
}
