import SwiftUI

// LogFormat turns a raw log line into a uniform, renderable shape. It recognizes
// well-known service/framework formats so each line shows as clean, scannable
// columns instead of one undifferentiated string.
//
// ── Adding a new service ────────────────────────────────────────────────────
// 1. Write `static func parseX(_ s: String) -> LeveledLog?` (or -> HTTPLog? for
//    request logs) that returns nil unless the line matches that format.
// 2. Add one line to `parsers` below, in specificity order (most specific first).
// That's it — the renderer and severity inference work off the uniform model.

// HTTPLog is a web request line (GIN, nginx, generic): method/path/status/etc.
struct HTTPLog: Hashable {
    var flavor: String?      // "GIN", "nginx", "HTTP"
    var method: String?
    var path: String?
    var status: Int?
    var latency: String?
    var ip: String?
}

// LeveledLog is the uniform shape for level-based service logs (Postgres, Redis,
// RabbitMQ, Besu, Vault, NATS, Kafka, NestJS, generic). source + level +
// component + message is enough to render every one of them consistently.
struct LeveledLog: Hashable {
    var source: String?      // short service tag: "PG", "redis", "besu", "vault"…
    var level: Severity
    var component: String?   // subsystem / logger / context tag
    var message: String
    var trailing: String?    // right-aligned extra (e.g. NestJS "+2ms")
}

enum LogShape: Hashable {
    case http(HTTPLog)
    case leveled(LeveledLog)
    case plain
}

enum LogFormat {
    // Ordered most-specific → most-generic. The first parser that matches wins.
    private static let parsers: [(String) -> LogShape?] = [
        { parseNest($0).map(LogShape.leveled) },
        { parseGorm($0).map(LogShape.leveled) },
        { parseHTTP($0).map(LogShape.http) },
        { parsePostgres($0).map(LogShape.leveled) },
        { parseRedis($0).map(LogShape.leveled) },
        { parseRabbitMQ($0).map(LogShape.leveled) },
        { parseBesu($0).map(LogShape.leveled) },
        { parseVault($0).map(LogShape.leveled) },
        { parseNATS($0).map(LogShape.leveled) },
        { parseKafka($0).map(LogShape.leveled) },
        { parseGenericLeveled($0).map(LogShape.leveled) },
    ]

    // Memoized — the same lines are re-rendered on every scroll/filter.
    nonisolated(unsafe) private static var cache: [String: LogShape] = [:]

    static func classify(_ message: String) -> LogShape {
        if let c = cache[message] { return c }
        let msg = LogSyntax.stripANSI(message).trimmingCharacters(in: .whitespaces)
        var shape: LogShape = .plain
        if !msg.isEmpty, !msg.hasPrefix("{") { // JSON is handled by the row's expander
            for p in parsers {
                if let s = p(msg) { shape = s; break }
            }
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[message] = shape
        return shape
    }

    // Severity inferred from structure when the stream tagged no explicit level.
    static func inferredSeverity(_ message: String) -> Severity {
        switch classify(message) {
        case .http(let h):
            if let s = h.status { if s >= 500 { return .error }; if s >= 400 { return .warn } }
            return .none
        case .leveled(let l):
            return l.level
        case .plain:
            return .none
        }
    }

    // MARK: severity mapping (covers every service's level vocabulary)

    static func sev(_ raw: String) -> Severity {
        let u = raw.uppercased()
        switch u {
        case "ERROR", "ERR", "FATAL", "PANIC", "CRIT", "CRITICAL", "ALERT", "EMERG", "EMERGENCY", "FTL", "SEVERE":
            return .error
        case "WARN", "WARNING", "WRN":
            return .warn
        case "INFO", "INF", "NOTICE", "LOG", "INFORMATION":
            return .info
        case "DEBUG", "DBG", "TRACE", "TRC", "VERBOSE", "FINE", "FINER", "FINEST":
            return .debug
        default:
            return u.hasPrefix("DEBUG") ? .debug : .none // Postgres DEBUG1..5
        }
    }

    // MARK: per-service parsers

    // NestJS: [Nest] 19796  - 06/30/2026, 8:33 AM   LOG [Ctx] message +2ms
    static func parseNest(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\[Nest\]\s+\d+\s+-\s+.+?\s+(LOG|ERROR|WARN|WARNING|DEBUG|VERBOSE|FATAL)\s+\[([^\]]+)\]\s+(.*?)(\s+\+\d+m?s)?$"#)
        else { return nil }
        return LeveledLog(source: "Nest", level: sev(c[0]), component: c[1], message: c[2],
                          trailing: c[3].trimmingCharacters(in: .whitespaces).isEmpty ? nil : c[3].trimmingCharacters(in: .whitespaces))
    }

    // Postgres: 2026-06-30 08:33:55.123 UTC [123] LOG:  message
    static func parsePostgres(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?(?:\s+[A-Z]{2,5})?\s+\[(\d+)(?:-\d+)?\]\s+(LOG|DEBUG[1-5]?|INFO|NOTICE|WARNING|ERROR|FATAL|PANIC|STATEMENT|DETAIL|HINT|CONTEXT)(?:\s+\w+)?:\s{1,2}(.*)$"#)
        else { return nil }
        return LeveledLog(source: "PG", level: sev(c[1]), component: nil, message: c[2], trailing: nil)
    }

    // Redis: 1:M 30 Jun 2026 08:33:55.123 * message   (level char . - * #)
    static func parseRedis(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\d+:[MSCX]\s+\d{1,2}\s+\w{3}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\.\d+\s+([.\-*#])\s+(.*)$"#)
        else { return nil }
        let level: Severity = c[0] == "#" ? .warn : (c[0] == "." ? .debug : .info)
        return LeveledLog(source: "redis", level: level, component: nil, message: c[1], trailing: nil)
    }

    // RabbitMQ: 2026-06-30 08:33:55.123+00:00 [info] <0.123.0> message
    static func parseRabbitMQ(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}\S*\s+\[(debug|info|notice|warning|error|critical|alert|emergency)\]\s+(<[\d.]+>\s+)?(.*)$"#)
        else { return nil }
        return LeveledLog(source: "rabbitmq", level: sev(c[0]), component: nil, message: c[2], trailing: nil)
    }

    // Hyperledger Besu: 2026-06-30 08:33:55.123+00:00 | thread | INFO | Logger | message
    static func parseBesu(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}\S*\s+\|\s+\S+\s+\|\s+(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+\|\s+([\w.$]+)\s+\|\s+(.*)$"#)
        else { return nil }
        return LeveledLog(source: "besu", level: sev(c[0]), component: shortLogger(c[1]), message: c[2], trailing: nil)
    }

    // HashiCorp Vault (hclog): 2026-06-30T08:33:55.123Z [INFO]  core: message
    static func parseVault(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\S*\s+\[(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|ERR)\]\s*([\w.\-/]+):\s+(.*)$"#)
        else { return nil }
        return LeveledLog(source: "vault", level: sev(c[0]), component: c[1], message: c[2], trailing: nil)
    }

    // NATS: [1] 2026/06/30 08:33:55.123456 [INF] message
    static func parseNATS(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\[\d+\]\s+\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+\[(INF|WRN|ERR|DBG|TRC|FTL)\]\s+(.*)$"#)
        else { return nil }
        return LeveledLog(source: "NATS", level: sev(c[0]), component: nil, message: c[1], trailing: nil)
    }

    // Kafka / log4j: [2026-06-30 08:33:55,123] INFO message (logger)
    static func parseKafka(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d+\]\s+(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+(.*?)(?:\s+\(([\w.$]+)\))?$"#)
        else { return nil }
        return LeveledLog(source: "log4j", level: sev(c[0]), component: c.count > 2 ? shortLogger(c[2]) : nil, message: c[1], trailing: nil)
    }

    // Generic leveled (logrus, zap/zerolog console, syslog-ish): an optional
    // leading timestamp, then a level token, then the message. The timestamp guard
    // keeps it from reformatting ordinary prose that merely contains a level word.
    static func parseGenericLeveled(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^(?:(?:\d{4}[-/]\d{2}[-/]\d{2}|\d{2}:\d{2}:\d{2})\S*[ T]?\s*){0,2}(?:\[)?(TRACE|DEBUG|INFO|INFORMATION|NOTICE|WARN|WARNING|ERROR|ERR|CRIT|CRITICAL|FATAL|PANIC|ALERT)(?:\])?[\s:]+(.+)$"#)
        else { return nil }
        return LeveledLog(source: nil, level: sev(c[0]), component: nil, message: c[1], trailing: nil)
    }

    // GORM SQL logger: [2.003ms] [rows:1] INSERT INTO …
    static func parseGorm(_ s: String) -> LeveledLog? {
        guard let c = caps(s, #"^\[([\d.]+(?:µs|us|ms|ns|s))\]\s+\[rows:(-?\d+|-)\]\s+(.*)$"#) else { return nil }
        return LeveledLog(source: "SQL", level: .none, component: "rows:\(c[1])", message: c[2], trailing: c[0])
    }

    // MARK: HTTP request lines (GIN, nginx, generic)

    static func parseHTTP(_ s: String) -> HTTPLog? {
        var work = s
        var flavor: String?
        if let r = work.range(of: #"^\[GIN\]\s*\d{4}/\d{2}/\d{2}\s*-\s*\d{2}:\d{2}:\d{2}\s*"#, options: .regularExpression) {
            flavor = "GIN"; work.removeSubrange(r)
        } else if work.range(of: #"^[0-9a-fA-F.:]+\s+-\s+\S+\s+\[[^\]]+\]\s+""#, options: .regularExpression) != nil {
            flavor = "nginx"
        }
        // Generic request logs (morgan/express) must START with the method — so we
        // never misread an SQL/app line that merely mentions "POST" or a "/path".
        let startsWithMethod = work.range(of: #"^(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s"#, options: .regularExpression) != nil
        let method = match(work, #"\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\b"#)?.value.uppercased()
        let path = extractPath(work)
        var ip: String?
        if let m = matchRange(work, #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#) {
            ip = String(work[m]); work.removeSubrange(m)
        } else if let m = matchRange(work, #"\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b"#) {
            ip = String(work[m]); work.removeSubrange(m)
        }
        var latency: String?
        if let m = matchRange(work, #"\b\d+(?:\.\d+)?\s*(?:µs|us|ms|ns|s)\b"#) {
            latency = String(work[m]).replacingOccurrences(of: " ", with: ""); work.removeSubrange(m)
        }
        let status = match(work, #"\b([1-5]\d{2})\b"#, group: 1).flatMap { Int($0.value) }
        // GIN/nginx are anchored; otherwise require the line to START with a method
        // AND have a path (kills false positives on SQL/JSON/app logs).
        let confident = flavor != nil || (startsWithMethod && method != nil && path != nil)
        guard confident else { return nil }
        return HTTPLog(flavor: flavor ?? "HTTP", method: method, path: path, status: status, latency: latency, ip: ip)
    }

    private static func extractPath(_ w: String) -> String? {
        if let m = match(w, #""(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)\s+HTTP/[\d.]+""#, group: 1) { return m.value }
        if let m = match(w, #""(/[^"\s]*)""#, group: 1) { return m.value }
        if let m = match(w, #"(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+"?(/[^\s"]*)"#, group: 1) { return m.value }
        if let m = match(w, #"(?<![\w/])(/[A-Za-z0-9_\-./{}:%?=&]+)"#, group: 1) { return m.value }
        return nil
    }

    // MARK: helpers

    // Keep the last 2 dotted segments of a logger/class path (e.g.
    // org.hyperledger.besu.ethereum.eth.sync.DefaultSynchronizer → eth.DefaultSynchronizer→ DefaultSynchronizer).
    static func shortLogger(_ s: String) -> String {
        let parts = s.split(separator: ".")
        return parts.count > 1 ? String(parts.suffix(1).joined(separator: ".")) : s
    }

    private static func caps(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r) else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            if let rng = Range(m.range(at: i), in: s) { out.append(String(s[rng])) } else { out.append("") }
        }
        return out
    }

    private static func match(_ s: String, _ pattern: String, group: Int = 0) -> (value: String, range: Range<String.Index>)? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r), m.numberOfRanges > group,
              let rng = Range(m.range(at: group), in: s) else { return nil }
        return (String(s[rng]), rng)
    }

    private static func matchRange(_ s: String, _ pattern: String) -> Range<String.Index>? {
        match(s, pattern, group: 0)?.range
    }

    static func latencyMillis(_ l: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"([\d.]+)\s*(µs|us|ms|ns|s)"#) else { return nil }
        let r = NSRange(l.startIndex..., in: l)
        guard let m = re.firstMatch(in: l, range: r), m.numberOfRanges > 2,
              let vr = Range(m.range(at: 1), in: l), let ur = Range(m.range(at: 2), in: l),
              let v = Double(l[vr]) else { return nil }
        switch String(l[ur]) {
        case "ns": return v / 1_000_000
        case "µs", "us": return v / 1000
        case "ms": return v
        case "s": return v * 1000
        default: return nil
        }
    }
}

// MARK: colors

func httpMethodColor(_ m: String) -> Color {
    switch m {
    case "GET": return Color(red: 0.30, green: 0.66, blue: 0.98)
    case "POST": return Color(red: 0.27, green: 0.78, blue: 0.45)
    case "PUT", "PATCH": return Color(red: 0.98, green: 0.65, blue: 0.16)
    case "DELETE": return Color(red: 0.96, green: 0.27, blue: 0.31)
    default: return .secondary
    }
}

func httpStatusColor(_ s: Int) -> Color {
    switch s {
    case 200..<300: return Color(red: 0.27, green: 0.78, blue: 0.45)
    case 300..<400: return .teal
    case 400..<500: return Color(red: 0.98, green: 0.65, blue: 0.16)
    case 500..<600: return Color(red: 0.96, green: 0.27, blue: 0.31)
    default: return .secondary
    }
}

func latencyColor(_ l: String) -> Color {
    guard let ms = LogFormat.latencyMillis(l) else { return .secondary }
    if ms >= 1000 { return Color(red: 0.96, green: 0.27, blue: 0.31) }
    if ms >= 300 { return Color(red: 0.98, green: 0.65, blue: 0.16) }
    return .secondary
}

// MARK: structured row content

// SourceBadge is the tiny dim tag naming the service/framework (PG, redis, besu…).
struct SourceBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }
}

// HTTPLogContent renders one HTTP request line as aligned, color-coded fields.
struct HTTPLogContent: View {
    let http: HTTPLog
    var query: String

    var body: some View {
        HStack(spacing: 7) {
            if let f = http.flavor, f != "HTTP" { SourceBadge(text: f) }
            if let m = http.method {
                Text(m)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(httpMethodColor(m), in: RoundedRectangle(cornerRadius: 4))
            }
            if let s = http.status {
                Text("\(s)")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(httpStatusColor(s))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(httpStatusColor(s).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            }
            if let p = http.path {
                Text(queryHighlighted(p, query))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let l = http.latency {
                Text(l).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(latencyColor(l))
            }
            if let ip = http.ip {
                Text(ip).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }
}

// LeveledLogContent renders every level-based service log uniformly: a source
// tag, an optional component tag, the message, and an optional trailing extra.
struct LeveledLogContent: View {
    let log: LeveledLog
    var query: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if let src = log.source { SourceBadge(text: src) }
            if let comp = log.component, !comp.isEmpty {
                Text(comp)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)
            }
            Text(LogSyntax.attributed(log.message, query: query.isEmpty ? nil : query))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let t = log.trailing {
                Text(t).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(.orange)
            }
        }
    }
}

// queryHighlighted is a light highlighter for plain fields (paths): the search
// match gets a yellow background; everything else is rendered as-is.
func queryHighlighted(_ text: String, _ query: String) -> AttributedString {
    var attr = AttributedString(text)
    guard !query.isEmpty, let range = text.range(of: query, options: .caseInsensitive),
          let lo = AttributedString.Index(range.lowerBound, within: attr),
          let hi = AttributedString.Index(range.upperBound, within: attr) else { return attr }
    attr[lo..<hi].backgroundColor = .yellow.opacity(0.4)
    return attr
}
