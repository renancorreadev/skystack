import SwiftUI
import AppKit

// ComposeView renders a Compose project's service dependency graph as ordered
// layers (left → right), each card showing image/build, ports, and deps.
struct ComposeView: View {
    @State private var graph: ComposeGraph?
    @State private var error: String?
    @State private var path: String?
    @State private var hosts: [Host] = []
    @State private var host = "skyvm"
    @State private var deploying = false
    @State private var deployOutput: String?
    private let cli = SkyCLI()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.tint)
                Text(graph?.name ?? "Compose graph")
                    .font(.headline)
                if let p = path {
                    Text(p).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if path != nil {
                    Menu {
                        ForEach(hosts) { h in
                            Button(h.up ? h.name : "\(h.name) (offline)") { host = h.name }.disabled(!h.up)
                        }
                    } label: { Label(host, systemImage: "server.rack") }
                        .controlSize(.small).fixedSize()
                    Button { deploy(up: true) } label: { Label("Deploy", systemImage: "arrow.up.circle.fill") }
                        .controlSize(.small).buttonStyle(.borderedProminent).tint(.green).disabled(deploying)
                    Button { deploy(up: false) } label: { Label("Down", systemImage: "arrow.down.circle") }
                        .controlSize(.small).disabled(deploying)
                }
                Button { open() } label: { Label("Open…", systemImage: "folder") }
                    .controlSize(.small)
            }
            .padding(12)
            .background(.bar)
            Divider()

            if let g = graph {
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 64) {
                        ForEach(Array(g.layers.enumerated()), id: \.offset) { idx, layer in
                            VStack(alignment: .leading, spacing: 16) {
                                Text("layer \(idx + 1)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(layer, id: \.self) { name in
                                    if let s = g.service(name) {
                                        ServiceCard(service: s)
                                            .anchorPreference(key: CardAnchorKey.self, value: .bounds) { [name: $0] }
                                    }
                                }
                            }
                        }
                    }
                    .padding(28)
                    .backgroundPreferenceValue(CardAnchorKey.self) { anchors in
                        GeometryReader { proxy in
                            edges(for: g, anchors: anchors, proxy: proxy)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(error ?? "Open a docker-compose.yml to see its service graph")
                        .foregroundStyle(.secondary)
                    Button("Open compose file…") { open() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if deploying || deployOutput != nil {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        if deploying { ProgressView().controlSize(.small) }
                        Text(deploying ? "Running…" : "docker compose").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { deployOutput = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(deploying)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    ScrollView {
                        Text(deployOutput ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    .frame(height: 150)
                }
                .background(.bar)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .task {
            hosts = (try? await cli.hosts()) ?? []
            if !hosts.contains(where: { $0.name == host && $0.up }), let up = hosts.first(where: { $0.up }) {
                host = up.name
            }
        }
    }

    private func deploy(up: Bool) {
        guard let p = path else { return }
        deploying = true
        deployOutput = (up ? "› Deploying to \(host)…\n" : "› Tearing down on \(host)…\n")
        Task {
            let out = up ? await cli.composeUp(host: host, file: p) : await cli.composeDown(host: host, file: p)
            deployOutput = (deployOutput ?? "") + out + "\n✓ Done."
            deploying = false
        }
    }

    // edges draws a curve from each dependency (source, on the left) to the
    // service that depends on it (target, on the right).
    @ViewBuilder
    private func edges(for g: ComposeGraph, anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        Path { path in
            for s in g.services {
                guard let target = anchors[s.name] else { continue }
                let tRect = proxy[target]
                for dep in (s.dependsOn ?? []) {
                    guard let source = anchors[dep] else { continue }
                    let sRect = proxy[source]
                    let start = CGPoint(x: sRect.maxX, y: sRect.midY)
                    let end = CGPoint(x: tRect.minX, y: tRect.midY)
                    let c1 = CGPoint(x: (start.x + end.x) / 2, y: start.y)
                    let c2 = CGPoint(x: (start.x + end.x) / 2, y: end.y)
                    path.move(to: start)
                    path.addCurve(to: end, control1: c1, control2: c2)
                }
            }
        }
        .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        Task {
            do {
                graph = try await cli.compose(file: url.path)
                error = nil
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                graph = nil
            }
        }
    }
}

// CardAnchorKey collects each service card's frame anchor for edge drawing.
struct CardAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ServiceCard: View {
    let service: ComposeService
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: service.build != nil ? "hammer.fill" : "shippingbox.fill")
                    .font(.caption2)
                    .foregroundStyle(service.build != nil ? .orange : .blue)
                Text(service.name).font(.system(size: 13, weight: .semibold))
            }
            if !service.source.isEmpty {
                Text(service.source)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let ports = service.ports, !ports.isEmpty {
                ForEach(ports, id: \.self) { p in
                    Tag(text: p, color: .blue)
                }
            }
            if let deps = service.dependsOn, !deps.isEmpty {
                Text("→ " + deps.joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 190, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}
