import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                Text("SkyStack").font(.headline)
                Spacer()
            }

            HStack(spacing: 16) {
                Stat(value: "\(app.runningCount)", label: "running")
                Stat(value: "\(app.containers.count)", label: "containers")
                Stat(value: "\(app.hosts.filter(\.up).count)", label: "hosts up")
            }

            Divider()

            ForEach(app.hosts) { host in
                HStack(spacing: 6) {
                    StateDot(color: host.up ? stateColor("running") : stateColor("exited"), size: 6)
                    Text(host.name).font(.callout)
                    Spacer()
                    if let v = host.engine, host.up {
                        Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Button("Compose Graph…") { openWindow(id: "compose") }
            Button("Quit SkyStack") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
