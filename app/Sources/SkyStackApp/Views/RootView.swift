import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 208, ideal: 230, max: 300)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            DetailColumn()
        }
        .overlay(alignment: .bottom) {
            if let err = app.cliError, !app.binaryMissing {
                ErrorBar(text: err, dismiss: { app.cliError = nil }).padding(10)
            }
        }
        .overlay {
            if app.binaryMissing { BinaryMissing() }
        }
        .overlay {
            if app.paletteOpen { CommandPalette().transition(.opacity) }
        }
        .sheet(isPresented: $app.remoteSheetOpen) { RemoteHostsSheet() }
    }
}

// ContentColumn shows the list for the selected section, with search.
struct ContentColumn: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if showsOffline {
                OfflineState(host: app.selectedHost, error: app.selectedHostError,
                             retry: { Task { await app.refreshResources() } },
                             vmStart: app.vmStartAction)
            } else {
                switch app.section {
                case .containers: ContainersList()
                case .images: ImagesList()
                case .volumes: VolumesList()
                case .networks: NetworksList()
                case .machines: MachinesList()
                case .commands: CommandConsole(container: nil)
                case .hardware: Placeholder(icon: "cpu", text: "Live metrics for \(app.selectedHost) →")
                case .operatorAI: Placeholder(icon: "wand.and.stars", text: "AI operator for \(app.selectedHost) →")
                }
            }
        }
        .navigationTitle(app.section.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $app.search, placement: .toolbar, prompt: "Filter")
    }

    // Resource sections (Docker/Linux) reflect host reachability; Commands runs
    // local skystack, Hardware and Operator show their own connection state.
    private var showsOffline: Bool {
        app.hostOffline && app.section != .commands && app.section != .hardware && app.section != .operatorAI
    }

    private var subtitle: String {
        switch app.section {
        case .containers:
            return app.containers.isEmpty ? "" : "\(app.runningCount) running · \(app.containers.count) total"
        case .commands:
            return ""
        default:
            let n = app.count(app.section)
            return n == 0 ? "" : "\(n)"
        }
    }
}

// DetailColumn shows the detail for the selected item of the active section.
struct DetailColumn: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.hostOffline, app.section != .commands, app.section != .hardware, app.section != .operatorAI {
            OfflineState(host: app.selectedHost, error: app.selectedHostError,
                         retry: { Task { await app.refreshResources() } },
                         vmStart: app.vmStartAction)
        } else {
            sectionDetail
        }
    }

    @ViewBuilder private var sectionDetail: some View {
        switch app.section {
        case .containers:
            if let c = app.selectedContainer {
                ContainerDetail(container: c).id(c.id)
            } else { Placeholder(icon: "shippingbox", text: app.containers.isEmpty ? "No containers — run one with `docker run`" : "Select a container") }
        case .images:
            if let i = app.images.first(where: { $0.id == app.imageSelection }) {
                ImageDetail(image: i)
            } else { Placeholder(icon: "square.stack.3d.up", text: "Select an image") }
        case .volumes:
            if let v = app.volumes.first(where: { $0.id == app.volumeSelection }) {
                VolumeDetail(volume: v)
            } else { Placeholder(icon: "externaldrive", text: "Select a volume") }
        case .networks:
            if let n = app.networks.first(where: { $0.id == app.networkSelection }) {
                NetworkDetail(network: n)
            } else { Placeholder(icon: "point.3.connected.trianglepath.dotted", text: "Select a network") }
        case .machines:
            if let m = app.machines.first(where: { $0.id == app.machineSelection }) {
                MachineDetail(machine: m)
            } else { Placeholder(icon: "desktopcomputer", text: app.machines.isEmpty ? "No machines yet" : "Select a machine") }
        case .commands:
            Placeholder(icon: "chevron.left.forwardslash.chevron.right", text: "Run skystack commands on the left")
        case .hardware:
            HardwareView()
        case .operatorAI:
            OperatorView(host: app.selectedHost).id(app.selectedHost)
        }
    }
}

struct Placeholder: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct ErrorBar: View {
    let text: String
    var dismiss: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).lineLimit(2).textSelection(.enabled)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(radius: 8, y: 2)
    }
}

// OfflineState replaces the empty/placeholder panels when the selected host is
// unreachable, so "couldn't reach Docker" never masquerades as "nothing here".
struct OfflineState: View {
    let host: String
    var error: String?
    var retry: (() -> Void)? = nil
    var vmStart: (() -> Void)? = nil

    private var detail: String {
        if let e = error, !e.isEmpty { return e }
        return "Couldn't reach Docker on this host. Make sure it's running and reachable, then retry."
    }

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.orange)
            Text("\(host) is offline").font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 10) {
                if let vmStart {
                    Button(action: vmStart) { Label("Start SkyVM", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.green).controlSize(.regular)
                }
                if let retry {
                    Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                        .controlSize(.regular)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct BinaryMissing: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "terminal").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text("skystack CLI not found").font(.title3.weight(.semibold))
                Text("Build it with  `cd skystack && make build`,\nor set SKYSTACK_BIN to its path.")
                    .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
}
