import SwiftUI
import AppKit

struct ContainerDetail: View {
    let container: Container
    @EnvironmentObject var app: AppState
    @State private var tab: Tab = .logs
    @State private var showInspect = false

    // First published host port (from "8080→80"), for "Open in browser".
    private var firstHostPort: String? {
        container.ports.compactMap { $0.split(separator: "\u{2192}").first.map(String.init) }.first
    }

    enum Tab: String, CaseIterable {
        case logs = "Logs", stats = "Stats", ai = "AI", terminal = "Terminal", files = "Files", overview = "Info"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The terminal stays mounted (process alive) across tab switches; the
            // other tabs render on top of it when active.
            ZStack {
                TerminalTab(container: container)
                    .opacity(tab == .terminal ? 1 : 0)
                    .allowsHitTesting(tab == .terminal)
                // The AI tab stays mounted too, so its conversation survives tab
                // switches; analysis is button-gated, so nothing runs until asked.
                ContainerAIView(container: container)
                    .opacity(tab == .ai ? 1 : 0)
                    .allowsHitTesting(tab == .ai)
                Group {
                    switch tab {
                    case .logs: LogsView(container: container)
                    case .stats: StatsView(container: container)
                    case .files: FilesView(container: container)
                    case .overview: Overview(container: container)
                    case .terminal, .ai: Color.clear
                    }
                }
            }
        }
        .background(.background)
        .sheet(isPresented: $showInspect) {
            InspectSheet(kind: "container", host: container.host, id: container.name, title: container.name)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            DetailIdentity(stateColor: stateColor(container.state), title: container.name) {
                HStack(spacing: 6) {
                    Text(container.host)
                    Text("·")
                    Text(shortImage(container.image)).font(.system(size: 12, design: .monospaced))
                    Text("·").foregroundStyle(.tertiary)
                    Text(container.status).foregroundStyle(.secondary)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            } actions: {
                actions
            }
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 430)
                Spacer()
                ForEach(container.ports, id: \.self) { Tag(text: $0, color: .blue) }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if app.isBusy(container) {
                ProgressView().controlSize(.small)
            }
            if container.isRunning {
                ActionButton(icon: "stop.fill", label: "Stop") { app.perform("stop", on: container) }
                ActionButton(icon: "arrow.clockwise", label: "Restart") { app.perform("restart", on: container) }
            } else {
                ActionButton(icon: "play.fill", label: "Start", tint: .green) { app.perform("start", on: container) }
            }
            Menu {
                if let port = firstHostPort {
                    Button("Open in browser") {
                        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                    }
                }
                Button("Inspect") { showInspect = true }
                Button("Copy ID") { copyToPasteboard(container.dockerID) }
                Button("Copy name") { copyToPasteboard(container.name) }
                Divider()
                Button("Delete", role: .destructive) { app.deleteContainer(container) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .disabled(app.isBusy(container))
        }
        .disabled(app.isBusy(container))
    }
}

struct ActionButton: View {
    let icon: String
    let label: String
    var tint: Color = .secondary
    let run: () -> Void
    var body: some View {
        Button(action: run) {
            Label(label, systemImage: icon).font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered).tint(tint).controlSize(.small)
    }
}

// TerminalTab shows both a real PTY shell and the command console, resizable.
struct TerminalTab: View {
    let container: Container
    @EnvironmentObject var app: AppState
    var body: some View {
        if let bin = app.cli.binaryPath {
            VSplitView {
                PTYTerminal(binary: bin, ref: container.ref)
                    .frame(minHeight: 200, idealHeight: 340)
                CommandConsole(container: container)
                    .frame(minHeight: 150, idealHeight: 200)
            }
        } else {
            Placeholder(icon: "terminal", text: "skystack CLI not found")
        }
    }
}

struct Overview: View {
    let container: Container
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(label: "State", value: container.status)
                        InfoRow(label: "Image", value: container.image, mono: true)
                        InfoRow(label: "ID", value: String(container.dockerID.prefix(12)), mono: true)
                        InfoRow(label: "Host", value: container.host)
                        if let c = container.composeLabel { InfoRow(label: "Compose", value: c) }
                    }
                }
                if !container.ports.isEmpty {
                    PortsCard(container: container)
                }
                Spacer()
            }
            .padding(18)
        }
    }
}

// PortsCard lists published ports with on-demand forwarding. Local/SkyVM ports
// are already on the Mac's localhost (Open); remote (SSH) container ports get a
// one-click forward to localhost over SSH.
struct PortsCard: View {
    let container: Container
    @EnvironmentObject var app: AppState

    private var isRemote: Bool { (app.hosts.first { $0.name == container.host }?.kind ?? "local") == "ssh" }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Published ports").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(container.ports, id: \.self) { portRow($0) }
                if isRemote {
                    Text("Forward exposes a remote container port on your Mac over SSH.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private func portRow(_ p: String) -> some View {
        let parts = p.split(separator: "\u{2192}")
        let hostPort = Int(parts.first.map(String.init) ?? "") ?? 0
        let ctrPort = Int(parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "") ?? hostPort
        HStack(spacing: 8) {
            Text(p).font(.system(.callout, design: .monospaced))
            Spacer()
            if container.isRunning {
                if isRemote {
                    if let f = app.forward(for: container.ref, containerPort: ctrPort) {
                        Button { if let u = URL(string: f.url) { NSWorkspace.shared.open(u) } } label: {
                            Label("localhost:\(f.localPort)", systemImage: "arrow.up.forward.app")
                        }.controlSize(.small)
                        Button(role: .destructive) { app.stopForward(id: f.id) } label: {
                            Image(systemName: "stop.circle")
                        }.controlSize(.small).help("Stop forward")
                    } else {
                        Button { app.startForward(container, containerPort: ctrPort, localPort: hostPort) } label: {
                            Label("Forward", systemImage: "arrow.right.to.line")
                        }.controlSize(.small)
                    }
                } else {
                    Button { if let u = URL(string: "http://localhost:\(hostPort)") { NSWorkspace.shared.open(u) } } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }.controlSize(.small)
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
            Text(value).font(mono ? .system(.callout, design: .monospaced) : .callout).textSelection(.enabled)
            Spacer()
        }
    }
}
