import Foundation

// Host mirrors `skystack api hosts`.
struct Host: Codable, Identifiable, Hashable {
    let name: String
    let kind: String // local | skyvm | ssh
    var description: String?
    let up: Bool
    var engine: String?
    var error: String?

    var id: String { name }
}

// ContainerUsage is one container's resource slice (for top-consumer lists).
struct ContainerUsage: Codable, Identifiable, Hashable {
    let name: String
    let cpu: Double
    let mem: Int64
    var id: String { name }
}

// HardwareSample mirrors one `skystack api hwstats` frame — a host's capacity,
// system info, and live aggregate resource usage across its containers.
struct HardwareSample: Codable {
    var cpu: Double = 0          // aggregate CPU % across running containers
    var cpus: Int = 0           // host logical CPUs (capacity)
    var memUsed: Int64 = 0      // sum of container memory
    var memTotal: Int64 = 0     // host total memory
    var memPercent: Double = 0
    var netRx: Int64 = 0
    var netTx: Int64 = 0
    var containers: Int = 0
    var running: Int = 0

    var os: String?
    var kernel: String?
    var arch: String?
    var serverVersion: String?
    var images: Int = 0
    var diskUsed: Int64 = 0

    var topCpu: [ContainerUsage] = []
    var topMem: [ContainerUsage] = []
}

// VMStatus mirrors `skystack api vm` — the local SkyVM's lifecycle state.
struct VMStatus: Codable {
    var configured: Bool = false
    var running: Bool = false
    var ready: Bool = false
    var version: String?
    var pid: Int?
    var ip: String?
    var routed: Bool?
    var ports: [String]?
    var caTrusted: Bool?

    // "booting" = process alive but Docker not answering yet.
    var booting: Bool { running && !ready }
}

// SSHHostEntry mirrors `skystack api ssh-hosts` — an alias from ~/.ssh/config the
// user can one-click connect to as a remote Docker host.
struct SSHHostEntry: Codable, Identifiable, Hashable {
    let alias: String
    var hostName: String?
    var user: String?
    var port: String?
    var registered: Bool = false

    var id: String { alias }
    var subtitle: String {
        var s = hostName ?? "alias"
        if let u = user, !u.isEmpty { s = "\(u)@\(s)" }
        if let p = port, !p.isEmpty { s += ":\(p)" }
        return s
    }
}

// SSHTarget mirrors `skystack api host-ssh` — the ssh argv to reach a host's
// underlying machine (for a real VM shell + admin actions).
struct SSHTarget: Decodable {
    var ok: Bool
    var target: String?
    var args: [String]?
    var reason: String?
}

// ActiveForward is one live on-demand port-forward (container port → localhost).
struct ActiveForward: Identifiable, Hashable {
    let id: String        // "\(ref)#\(containerPort)"
    let ref: String
    let containerName: String
    let localPort: Int
    let containerPort: Int
    var url: String { "http://localhost:\(localPort)" }
}

// Container mirrors `skystack api ps`.
struct Container: Codable, Identifiable, Hashable {
    let host: String
    let dockerID: String
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: [String]
    var compose: String?
    var service: String?

    enum CodingKeys: String, CodingKey {
        case host, name, image, state, status, ports, compose, service
        case dockerID = "id"
    }

    // Stable, host-qualified identity for selection.
    var id: String { "\(host)/\(dockerID)" }
    // Reference accepted by `skystack api logs|action`.
    var ref: String { "\(host)/\(name)" }

    var isRunning: Bool { state == "running" }

    var composeLabel: String? {
        guard let p = compose, !p.isEmpty else { return nil }
        if let s = service, !s.isEmpty { return "\(p)/\(s)" }
        return p
    }
}

// DockerImage mirrors `skystack api images`.
struct DockerImage: Codable, Identifiable, Hashable {
    let id: String
    var tags: [String]?
    let size: Int64
    let created: Int64
    var dangling: Bool = false

    var primaryTag: String { tags?.first ?? "<none>" }
    var humanSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

// Volume mirrors `skystack api volumes`.
struct Volume: Codable, Identifiable, Hashable {
    let name: String
    let driver: String
    var mountpoint: String?
    var createdAt: String?
    var id: String { name }
}

// DockerNetwork mirrors `skystack api networks`.
struct DockerNetwork: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let driver: String
    var scope: String?
    var subnet: String?
    var builtin: Bool = false
}

// Machine mirrors `skystack api machines`.
struct Machine: Codable, Identifiable, Hashable {
    let name: String
    let distro: String
    var image: String?
    let state: String
    let status: String
    var id: String { name }
}

// StatsSample mirrors one `skystack api stats` NDJSON record.
struct StatsSample: Codable, Hashable {
    let cpu: Double
    let memUsed: Int64
    let memLimit: Int64
    let memPercent: Double
    var netRx: Int64 = 0
    var netTx: Int64 = 0
}

// FileEntry / FilesListing mirror `skystack api files`.
struct FileEntry: Codable, Identifiable, Hashable {
    let name: String
    let isDir: Bool
    let path: String
    var id: String { path }
}

struct FilesListing: Codable {
    let path: String
    var entries: [FileEntry]?
}

struct FileContent: Codable, Identifiable {
    let path: String
    let content: String
    var truncated: Bool = false
    var id: String { path }
}

// Compose service graph (from `skystack api compose`).
struct ComposeService: Codable, Identifiable, Hashable {
    let name: String
    var image: String?
    var build: String?
    var ports: [String]?
    var dependsOn: [String]?
    var id: String { name }

    var source: String { image ?? build.map { "build \($0)" } ?? "" }
}

struct ComposeGraph: Codable {
    let name: String
    let services: [ComposeService]
    let layers: [[String]]

    func service(_ name: String) -> ComposeService? { services.first { $0.name == name } }
}

// Severity is the detected log level, shared by the timeline and the stream.
enum Severity: String, CaseIterable {
    case error, warn, info, debug, none

    init(_ raw: String?) {
        switch (raw ?? "").uppercased() {
        case "ERROR", "ERR", "FATAL", "PANIC": self = .error
        case "WARN", "WARNING": self = .warn
        case "DEBUG", "TRACE": self = .debug
        case "INFO": self = .info
        default: self = .none
        }
    }

    var tag: String {
        switch self {
        case .error: return "ERROR"
        case .warn: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        case .none: return ""
        }
    }
}

// RawLog is the wire shape of one `skystack api logs` NDJSON record.
struct RawLog: Decodable {
    let time: String?
    let host: String
    let container: String
    let stream: String
    let severity: String?
    let message: String
}

// LogLine is an enriched, identifiable log entry held in the UI buffer. `seq` is
// assigned on receipt so identity/order are stable even without a timestamp.
struct LogLine: Identifiable, Hashable {
    let seq: Int
    let time: String?
    let stream: String
    let severityRaw: String?
    let message: String
    let receivedAt: Date

    init(seq: Int, raw: RawLog, receivedAt: Date) {
        self.seq = seq
        self.time = raw.time
        self.stream = raw.stream
        self.severityRaw = raw.severity
        self.message = raw.message
        self.receivedAt = receivedAt
    }

    var id: Int { seq }
    // Explicit level when the stream tagged one; otherwise inferred from the log's
    // structure (a 5xx GIN/nginx line is an error, a 4xx a warning, etc.) so the
    // rail, chips, and severity timeline reflect HTTP outcomes too.
    var level: Severity {
        let base = Severity(severityRaw)
        return base == .none ? LogFormat.inferredSeverity(message) : base
    }

    // Real log time if present, else the time we received the line.
    var timestamp: Date { LogTime.parse(time) ?? receivedAt }

    var clock: String {
        let f = DateFormatter.skyClock
        return f.string(from: timestamp)
    }
}

// LogTime parses Go's RFC3339Nano, tolerating nanosecond precision.
enum LogTime {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        // Trim fractional seconds to milliseconds (ISO8601DateFormatter caps at 3).
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return frac.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}

extension DateFormatter {
    static let skyClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
