import SwiftUI

// LogSyntax renders a log message into a colorized AttributedString. If the line
// carries ANSI color codes (e.g. GIN, zap, pino), they're INTERPRETED to show the
// app's intended colors; otherwise the text is smart-highlighted by token type
// (strings, numbers, IPs, URLs, key=value, JSON keys, HTTP methods + status,
// booleans, levels). A search term is highlighted on top in both modes.
enum LogSyntax {
    // Token palette (dark-mode friendly).
    private static let cNumber = Color(red: 0.92, green: 0.66, blue: 0.40)
    private static let cString = Color(red: 0.56, green: 0.80, blue: 0.55)
    private static let cIP     = Color(red: 0.40, green: 0.80, blue: 0.78)
    private static let cHash   = Color.secondary
    private static let cURL    = Color(red: 0.46, green: 0.68, blue: 0.99)
    private static let cBool   = Color(red: 0.80, green: 0.56, blue: 0.96)
    private static let cKey    = Color(red: 0.42, green: 0.74, blue: 0.92)
    private static let cMethod = Color(red: 0.80, green: 0.56, blue: 0.96)
    private static let c2xx    = Color(red: 0.36, green: 0.80, blue: 0.50)
    private static let c3xx    = Color(red: 0.46, green: 0.68, blue: 0.99)
    private static let c4xx    = Color(red: 0.96, green: 0.72, blue: 0.30)
    private static let c5xx    = Color(red: 0.96, green: 0.40, blue: 0.42)

    // Standard 16-colour terminal palette (0-7 normal, 8-15 bright).
    private static let ansi16: [Color] = [
        Color(white: 0.45), c5xx, c2xx, c4xx, c3xx, cMethod, cIP, Color(white: 0.85),
        Color(white: 0.6), c5xx, c2xx, c4xx, c3xx, cMethod, cIP, Color.white,
    ]

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    // Cache the per-line base coloring (the costly regex/ANSI work) so re-renders
    // while scrolling don't recompute it. The search overlay is applied on a copy.
    nonisolated(unsafe) private static var cache: [String: AttributedString] = [:]

    static func attributed(_ raw: String, query: String? = nil) -> AttributedString {
        var base = cachedBase(raw)
        if let q = query, !q.isEmpty { highlightMatches(&base, q) }
        return base
    }

    private static func cachedBase(_ raw: String) -> AttributedString {
        if let c = cache[raw] { return c }
        let base: AttributedString = (raw.contains("\u{1B}[") ? ansiColored(raw) : nil) ?? syntaxColored(stripANSI(raw))
        if cache.count > 4000 { cache.removeAll() }   // simple bound; logs cap at 5000
        cache[raw] = base
        return base
    }

    // MARK: token highlighting

    private static func syntaxColored(_ message: String) -> AttributedString {
        var attr = AttributedString(message)
        attr.foregroundColor = .primary.opacity(0.9)

        func paint(_ pattern: String, _ color: Color, ci: Bool = false, bold: Bool = false, group: Int = 0) {
            let opts: NSRegularExpression.Options = ci ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            for m in re.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
                let nr = m.range(at: group)
                guard nr.location != NSNotFound, let sr = Range(nr, in: message) else { continue }
                let lo = message.distance(from: message.startIndex, to: sr.lowerBound)
                let len = message.distance(from: sr.lowerBound, to: sr.upperBound)
                let a = attr.index(attr.startIndex, offsetByCharacters: lo)
                let b = attr.index(a, offsetByCharacters: len)
                attr[a..<b].foregroundColor = color
                if bold { attr[a..<b].inlinePresentationIntent = .stronglyEmphasized }
            }
        }

        paint(#"\b\d+(?:\.\d+)?\b"#, cNumber)
        paint(#"\b[0-9a-fA-F]{8}-[0-9a-fA-F-]{8,}\b|\b[0-9a-f]{12,}\b"#, cHash)
        paint(#"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"#, cIP)
        paint(#"https?://[^\s"']+"#, cURL)
        paint(#"(?<=[\s"'(=:])/[\w./%@:-]+"#, cURL)
        paint(#"\b(?:true|false|null|nil|none|undefined)\b"#, cBool, ci: true)
        paint(#"\b[\w.$-]+(?==)"#, .secondary)
        paint(#"\b(?:GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|TRACE)\b"#, cMethod, bold: true)
        paint(#"(?<=[\s|\[(>])2\d{2}(?=[\s|\])<,])"#, c2xx)
        paint(#"(?<=[\s|\[(>])3\d{2}(?=[\s|\])<,])"#, c3xx)
        paint(#"(?<=[\s|\[(>])4\d{2}(?=[\s|\])<,])"#, c4xx)
        paint(#"(?<=[\s|\[(>])5\d{2}(?=[\s|\])<,])"#, c5xx)
        paint(#""(?:[^"\\]|\\.)*""#, cString)
        paint(#"'(?:[^'\\]|\\.)*'"#, cString)
        paint(#"("[\w.$-]+")\s*:"#, cKey, group: 1)
        paint(#"\b(?:ERROR|ERR|FATAL|PANIC|FAIL(?:ED)?)\b"#, c5xx, ci: true)
        paint(#"\b(?:WARN(?:ING)?)\b"#, c4xx, ci: true)
        return attr
    }

    // MARK: ANSI interpretation

    private static func ansiColored(_ raw: String) -> AttributedString? {
        guard raw.contains("\u{1B}[") else { return nil }
        var result = AttributedString()
        var fg: Color?
        var bg: Color?
        var bold = false
        var buf = ""
        let chars = Array(raw)
        var i = 0

        func flush() {
            guard !buf.isEmpty else { return }
            var piece = AttributedString(buf)
            piece.foregroundColor = fg ?? .primary.opacity(0.9)
            if let bg { piece.backgroundColor = bg }
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
            buf = ""
        }

        while i < chars.count {
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                flush()
                var j = i + 2
                var code = ""
                while j < chars.count, !chars[j].isLetter { code.append(chars[j]); j += 1 }
                if j < chars.count, chars[j] == "m" { applySGR(code, &fg, &bg, &bold) }
                i = j + 1
            } else {
                buf.append(chars[i]); i += 1
            }
        }
        flush()
        return result
    }

    private static func applySGR(_ code: String, _ fg: inout Color?, _ bg: inout Color?, _ bold: inout Bool) {
        let parts = code.isEmpty ? ["0"] : code.split(separator: ";").map(String.init)
        var k = 0
        while k < parts.count {
            let n = Int(parts[k]) ?? 0
            switch n {
            case 0:        fg = nil; bg = nil; bold = false
            case 1:        bold = true
            case 22:       bold = false
            case 30...37:  fg = ansi16[n - 30]
            case 90...97:  fg = ansi16[n - 90 + 8]
            case 39:       fg = nil
            case 40...47:  bg = ansi16[n - 40].opacity(0.30)
            case 100...107: bg = ansi16[n - 100 + 8].opacity(0.30)
            case 49:       bg = nil
            case 38, 48:   // extended colour — skip its params
                if k + 1 < parts.count, parts[k + 1] == "5" { k += 2 }
                else if k + 1 < parts.count, parts[k + 1] == "2" { k += 4 }
            default:       break
            }
            k += 1
        }
    }

    // MARK: search

    private static func highlightMatches(_ attr: inout AttributedString, _ q: String) {
        let plain = String(attr.characters)
        let pat = NSRegularExpression.escapedPattern(for: q)
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return }
        for m in re.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let sr = Range(m.range, in: plain) else { continue }
            let lo = plain.distance(from: plain.startIndex, to: sr.lowerBound)
            let len = plain.distance(from: sr.lowerBound, to: sr.upperBound)
            let a = attr.index(attr.startIndex, offsetByCharacters: lo)
            let b = attr.index(a, offsetByCharacters: len)
            attr[a..<b].backgroundColor = .yellow.opacity(0.35)
        }
    }
}
