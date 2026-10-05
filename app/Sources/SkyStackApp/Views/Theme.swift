import SwiftUI

// Severity → color, the single source of truth for the timeline lanes and the
// log stream's left rail.
extension Severity {
    var color: Color {
        switch self {
        case .error: return Color(red: 0.96, green: 0.27, blue: 0.31)
        case .warn: return Color(red: 0.98, green: 0.65, blue: 0.16)
        case .info: return Color(red: 0.30, green: 0.66, blue: 0.98)
        case .debug: return Color(red: 0.55, green: 0.56, blue: 0.62)
        case .none: return Color.secondary.opacity(0.5)
        }
    }
}

// Color for a container/engine state dot.
func stateColor(_ state: String) -> Color {
    switch state {
    case "running": return Color(red: 0.27, green: 0.78, blue: 0.45)
    case "paused": return Color(red: 0.98, green: 0.74, blue: 0.18)
    case "restarting", "created": return Color(red: 0.30, green: 0.66, blue: 0.98)
    case "exited", "dead": return Color.secondary.opacity(0.55)
    default: return Color.secondary.opacity(0.55)
    }
}

func hostIcon(_ kind: String) -> String {
    switch kind {
    case "local": return "desktopcomputer"
    case "skyvm": return "cube.transparent"
    case "ssh": return "network"
    default: return "server.rack"
    }
}

// A small filled status dot with a soft glow.
struct StateDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: size * 0.4)
    }
}

// A compact rounded tag/pill.
struct Tag: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// Card surface used by detail panels.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}
