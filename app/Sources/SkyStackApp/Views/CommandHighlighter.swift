import SwiftUI

// Role of a token on a command line, mapped to a color.
enum CmdRole {
    case subcommand, flag, string, path, container, normal

    var color: Color {
        switch self {
        case .subcommand: return Color(red: 0.36, green: 0.66, blue: 0.98)
        case .flag: return Color(red: 0.98, green: 0.65, blue: 0.16)
        case .string: return Color(red: 0.40, green: 0.80, blue: 0.45)
        case .path: return Color(red: 0.30, green: 0.78, blue: 0.76)
        case .container: return Color(red: 0.78, green: 0.52, blue: 0.96)
        case .normal: return .primary
        }
    }
}

struct CmdToken {
    let text: String
    let role: CmdRole
}

// CommandHighlighter tokenizes a `skystack` command line (the leading `skystack`
// is implied by the prompt) and colors it. Shared by the live input overlay and
// the transcript echo.
enum CommandHighlighter {
    // Tokenize preserving spaces and quotes so the rendered string matches the
    // typed text 1:1 (essential for the transparent-TextField overlay to align).
    static func tokenize(_ line: String, container: String? = nil) -> [CmdToken] {
        var tokens: [CmdToken] = []
        var nonFlagWord = 0
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == " " {
                tokens.append(CmdToken(text: " ", role: .normal))
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" {
                let quote = ch
                var j = i + 1
                while j < chars.count && chars[j] != quote { j += 1 }
                if j < chars.count { j += 1 } // include closing quote
                tokens.append(CmdToken(text: String(chars[i..<j]), role: .string))
                i = j
                continue
            }
            var j = i
            while j < chars.count && chars[j] != " " { j += 1 }
            let word = String(chars[i..<j])
            tokens.append(CmdToken(text: word, role: classify(word, nonFlagWord: &nonFlagWord, container: container)))
            i = j
        }
        return tokens
    }

    private static func classify(_ word: String, nonFlagWord: inout Int, container: String?) -> CmdRole {
        if word.hasPrefix("-") { return .flag }
        if word.hasPrefix("/") || word.hasPrefix("http://") || word.hasPrefix("https://") { return .path }
        if let c = container, word == c { return .container }
        defer { nonFlagWord += 1 }
        return nonFlagWord == 0 ? .subcommand : .normal // first bare word = subcommand
    }

    // Highlighted rendering for SwiftUI Text. Font is inherited from the caller's
    // `.font` modifier so glyph advances match the overlaid TextField.
    static func attributed(_ line: String, container: String? = nil) -> AttributedString {
        var out = AttributedString()
        for tok in tokenize(line, container: container) {
            var piece = AttributedString(tok.text)
            piece.foregroundColor = tok.role.color
            out += piece
        }
        return out
    }

    // Split a command line into argv, honoring quotes (quotes removed).
    static func splitArgs(_ line: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var inQuote: Character?
        var started = false
        for ch in line {
            if let q = inQuote {
                if ch == q { inQuote = nil } else { cur.append(ch); started = true }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
                started = true
            } else if ch == " " {
                if started { args.append(cur); cur = ""; started = false }
            } else {
                cur.append(ch)
                started = true
            }
        }
        if started { args.append(cur) }
        return args
    }
}
