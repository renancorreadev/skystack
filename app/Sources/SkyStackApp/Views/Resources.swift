import SwiftUI
import AppKit

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// revealInFinder opens a path in Finder (the Mac home is shared into machines).
func revealInFinder(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

// openInTerminal launches the command in the system Terminal.app via a throwaway
// .command script — gives a real, detachable shell outside the app window.
func openInTerminal(_ binary: String, _ args: [String]) {
    let quoted = ([binary] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    let script = "#!/bin/bash\nexec \(quoted)\n"
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("skystack-\(UUID().uuidString).command")
    do {
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
    } catch { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Terminal", tmp.path]
    try? p.run()
}

// MARK: - Containers

struct ContainersList: View {
    @EnvironmentObject var app: AppState
    @State private var running = false
    @State private var collapsed: Set<String> = []

    private var items: [Container] {
        app.containers.filter { app.search.isEmpty || $0.name.localizedCaseInsensitiveContains(app.search) || $0.image.localizedCaseInsensitiveContains(app.search) }
    }
    // Compose-project stacks, sorted; standalone containers handled separately.
    private var groups: [(project: String, items: [Container])] {
        var dict: [String: [Container]] = [:]
        for c in items where !(c.compose ?? "").isEmpty { dict[c.compose!, default: []].append(c) }
        return dict.map { (project: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.project < $1.project }
    }
    private var standalone: [Container] {
        items.filter { ($0.compose ?? "").isEmpty }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if app.containers.isEmpty {
                if app.loadingResources {
                    VStack(spacing: 10) { ProgressView().controlSize(.small); Text("Loading…").font(.callout).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(text: "No containers on \(app.selectedHost)", ctaLabel: "Run a container", cta: { running = true })
                }
            } else {
                List(selection: $app.containerSelection) {
                    ForEach(groups, id: \.project) { g in
                        SwiftUI.Section {
                            if !collapsed.contains(g.project) {
                                ForEach(g.items) { row($0) }
                            }
                        } header: {
                            StackHeader(project: g.project, items: g.items,
                                        collapsed: collapsed.contains(g.project),
                                        toggle: { toggle(g.project) })
                        }
                    }
                    if !standalone.isEmpty {
                        SwiftUI.Section {
                            ForEach(standalone) { row($0) }
                        } header: {
                            if !groups.isEmpty {
                                Text("Standalone").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { running = true } label: { Image(systemName: "plus") }
                    .help("Run a container").accessibilityLabel("Run a container")
            }
        }
        .sheet(isPresented: $running) { RunContainerSheet() }
    }

    private func row(_ c: Container) -> some View {
        ContainerRow(container: c)
            .tag(c.id)
            .contextMenu {
                if c.isRunning {
                    Button("Stop") { app.perform("stop", on: c) }
                    Button("Restart") { app.perform("restart", on: c) }
                } else {
                    Button("Start") { app.perform("start", on: c) }
                }
                Button("Copy ID") { copyToPasteboard(c.dockerID) }
                Divider()
                Button("Delete", role: .destructive) { app.deleteContainer(c) }
            }
    }

    private func toggle(_ p: String) {
        if collapsed.contains(p) { collapsed.remove(p) } else { collapsed.insert(p) }
    }
}

// StackHeader is a collapsible compose-project header; bulk actions reveal on hover.
struct StackHeader: View {
    let project: String
    let items: [Container]
    let collapsed: Bool
    let toggle: () -> Void
    @EnvironmentObject var app: AppState
    @State private var hover = false

    private var running: Int { items.filter(\.isRunning).count }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 9)
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint).font(.system(size: 12))
                    Text(project).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    StateDot(color: running > 0 ? stateColor("running") : stateColor("exited"), size: 5)
                    Text("\(running)/\(items.count)").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if hover {
                if running > 0 {
                    bulk("stop.fill", "Stop all in \(project)", .secondary) { app.performAll("stop", items) }
                    bulk("arrow.clockwise", "Restart all in \(project)", .secondary) { app.performAll("restart", items.filter(\.isRunning)) }
                } else {
                    bulk("play.fill", "Start all in \(project)", .green) { app.performAll("start", items) }
                }
            }
        }
        .padding(.vertical, 3)
        .onHover { hover = $0 }
    }

    private func bulk(_ icon: String, _ help: String, _ tint: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: icon).font(.system(size: 10)).frame(width: 18, height: 18).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(tint).help(help)
    }
}

struct ContainerRow: View {
    let container: Container
    @EnvironmentObject var app: AppState
    @State private var hover = false

    private var firstHostPort: String? {
        container.ports.compactMap { $0.split(separator: "\u{2192}").first.map(String.init) }.first
    }

    var body: some View {
        HStack(spacing: 11) {
            ServiceIcon(image: container.image, name: container.name,
                        running: container.isRunning, framework: app.frameworks[container.id], size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(shortImage(container.image)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hover = $0 }
        .onAppear {
            // Only inspect when the image/name don't already resolve a brand logo.
            if brandKey(image: container.image, name: container.name) == nil {
                app.detectFramework(container)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if app.isBusy(container) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 18)
        } else if hover {
            HStack(spacing: 2) {
                if let port = firstHostPort {
                    RowActionButton(icon: "arrow.up.forward.app", help: "Open localhost:\(port)") {
                        if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) }
                    }
                }
                if container.isRunning {
                    RowActionButton(icon: "stop.fill", help: "Stop") { app.perform("stop", on: container) }
                    RowActionButton(icon: "arrow.clockwise", help: "Restart") { app.perform("restart", on: container) }
                } else {
                    RowActionButton(icon: "play.fill", help: "Start") { app.perform("start", on: container) }
                }
                RowActionButton(icon: "trash", help: "Delete") { app.deleteContainer(container) }
            }
            .transition(.opacity)
        } else if !container.ports.isEmpty {
            Tag(text: "\(container.ports.count)P", color: .blue.opacity(0.85))
        }
    }
}

// MARK: - Images

struct ImagesList: View {
    @EnvironmentObject var app: AppState
    private var items: [DockerImage] {
        app.images.filter { app.search.isEmpty || $0.primaryTag.localizedCaseInsensitiveContains(app.search) || $0.id.contains(app.search) }
    }
    var body: some View {
        ResourceList(empty: app.images.isEmpty, emptyText: "No images on \(app.selectedHost)",
                     loading: app.loadingResources, selection: $app.imageSelection, rows: items) { im in
            HoverRow { hover in
                HStack(spacing: 11) {
                    ServiceIcon(image: im.primaryTag, name: im.primaryTag, running: !im.dangling, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(im.primaryTag).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(im.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if hover {
                        RowActionButton(icon: "trash", help: "Delete image") { app.remove("image", id: im.id) }
                    } else {
                        Text(im.humanSize).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            .tag(im.id)
            .contextMenu {
                Button("Copy ID") { copyToPasteboard(im.id) }
                Button("Delete", role: .destructive) { app.remove("image", id: im.id) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { app.prune("images") } label: { Image(systemName: "trash") }
                    .help("Prune unused images").accessibilityLabel("Prune unused images")
            }
        }
    }
}

struct ImageDetail: View {
    let image: DockerImage
    @EnvironmentObject var app: AppState
    @State private var running = false
    @State private var showInspect = false
    var body: some View {
        ResourceDetail(icon: "square.stack.3d.up.fill", title: image.primaryTag, tint: .blue) {
            InfoRow(label: "Tags", value: (image.tags ?? ["<none>"]).joined(separator: "\n"))
            InfoRow(label: "ID", value: image.id, mono: true)
            InfoRow(label: "Size", value: image.humanSize)
            if image.dangling { InfoRow(label: "Note", value: "dangling (untagged)") }
            HStack(spacing: 8) {
                Button { running = true } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.green)
                Button { showInspect = true } label: { Label("Inspect", systemImage: "doc.text.magnifyingglass") }
                    .controlSize(.small)
                Button(role: .destructive) { app.remove("image", id: image.id) } label: { Label("Delete", systemImage: "trash") }
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $running) { RunContainerSheet(image: image.primaryTag) }
        .sheet(isPresented: $showInspect) { InspectSheet(kind: "image", host: app.selectedHost, id: image.id, title: image.primaryTag) }
    }
}

// MARK: - Volumes

struct VolumesList: View {
    @EnvironmentObject var app: AppState
    @State private var creating = false
    private var items: [Volume] {
        app.volumes.filter { app.search.isEmpty || $0.name.localizedCaseInsensitiveContains(app.search) }
    }
    var body: some View {
        ResourceList(empty: app.volumes.isEmpty, emptyText: "No volumes on \(app.selectedHost)",
                     loading: app.loadingResources, ctaLabel: "New volume", cta: { creating = true },
                     selection: $app.volumeSelection, rows: items) { v in
            HoverRow { hover in
                HStack(spacing: 9) {
                    Image(systemName: "externaldrive.fill").foregroundStyle(.teal).font(.system(size: 12))
                    Text(v.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if hover {
                        RowActionButton(icon: "trash", help: "Delete volume") { app.remove("volume", id: v.name) }
                    } else {
                        Text(v.driver).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .tag(v.id)
            .contextMenu {
                Button("Copy name") { copyToPasteboard(v.name) }
                Button("Delete", role: .destructive) { app.remove("volume", id: v.name) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .help("Create volume").accessibilityLabel("Create volume")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { app.prune("volumes") } label: { Image(systemName: "trash") }
                    .help("Prune unused volumes").accessibilityLabel("Prune unused volumes")
            }
        }
        .sheet(isPresented: $creating) { CreateNameSheet(kind: "volume", title: "New volume") }
    }
}

// CreateNameSheet creates a volume or network by name.
struct CreateNameSheet: View {
    let kind: String
    let title: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("name", text: $name).textFieldStyle(.roundedBorder)
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(busy ? "Creating…" : "Create") {
                    busy = true; error = nil
                    Task {
                        do { try await app.create(kind, name: name); dismiss() }
                        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"; busy = false }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(name.isEmpty || busy)
            }
        }
        .padding(20).frame(width: 320)
    }
}

struct VolumeDetail: View {
    let volume: Volume
    @EnvironmentObject var app: AppState
    @State private var showInspect = false
    var body: some View {
        ResourceDetail(icon: "externaldrive.fill", title: volume.name, tint: .teal) {
            InfoRow(label: "Driver", value: volume.driver)
            if let m = volume.mountpoint { InfoRow(label: "Mountpoint", value: m, mono: true) }
            if let c = volume.createdAt { InfoRow(label: "Created", value: c) }
            Divider()
            ConsumersSection(kind: "volume", host: app.selectedHost, name: volume.name)
            HStack(spacing: 8) {
                Button { showInspect = true } label: { Label("Inspect", systemImage: "doc.text.magnifyingglass") }.controlSize(.small)
                Button(role: .destructive) { app.remove("volume", id: volume.name) } label: { Label("Delete", systemImage: "trash") }.controlSize(.small)
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showInspect) { InspectSheet(kind: "volume", host: app.selectedHost, id: volume.name, title: volume.name) }
    }
}

// MARK: - Networks

struct NetworksList: View {
    @EnvironmentObject var app: AppState
    @State private var creating = false
    private var items: [DockerNetwork] {
        app.networks.filter { app.search.isEmpty || $0.name.localizedCaseInsensitiveContains(app.search) }
    }
    var body: some View {
        ResourceList(empty: app.networks.isEmpty, emptyText: "No networks on \(app.selectedHost)",
                     loading: app.loadingResources, ctaLabel: "New network", cta: { creating = true },
                     selection: $app.networkSelection, rows: items) { n in
            HoverRow { hover in
                HStack(spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.purple).font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let s = n.subnet, !s.isEmpty { Text(s).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    if hover && !n.builtin {
                        RowActionButton(icon: "trash", help: "Delete network") { app.remove("network", id: n.id) }
                    } else {
                        Text(n.driver).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .tag(n.id)
            .contextMenu {
                Button("Copy ID") { copyToPasteboard(n.id) }
                if !n.builtin { Button("Delete", role: .destructive) { app.remove("network", id: n.id) } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .help("Create network").accessibilityLabel("Create network")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { app.prune("networks") } label: { Image(systemName: "trash") }
                    .help("Prune unused networks").accessibilityLabel("Prune unused networks")
            }
        }
        .sheet(isPresented: $creating) { CreateNameSheet(kind: "network", title: "New network") }
    }
}

struct NetworkDetail: View {
    let network: DockerNetwork
    @EnvironmentObject var app: AppState
    @State private var showInspect = false
    var body: some View {
        ResourceDetail(icon: "point.3.connected.trianglepath.dotted", title: network.name, tint: .purple) {
            InfoRow(label: "Driver", value: network.driver)
            if let s = network.scope { InfoRow(label: "Scope", value: s) }
            if let s = network.subnet, !s.isEmpty { InfoRow(label: "Subnet", value: s, mono: true) }
            InfoRow(label: "ID", value: network.id, mono: true)
            Divider()
            ConsumersSection(kind: "network", host: app.selectedHost, name: network.name)
            HStack(spacing: 8) {
                Button { showInspect = true } label: { Label("Inspect", systemImage: "doc.text.magnifyingglass") }.controlSize(.small)
                if !network.builtin {
                    Button(role: .destructive) { app.remove("network", id: network.id) } label: { Label("Delete", systemImage: "trash") }.controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: $showInspect) { InspectSheet(kind: "network", host: app.selectedHost, id: network.id, title: network.name) }
    }
}

// MARK: - Machines

struct MachinesList: View {
    @EnvironmentObject var app: AppState
    @State private var creating = false
    private var items: [Machine] {
        app.machines.filter { app.search.isEmpty || $0.name.localizedCaseInsensitiveContains(app.search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            ResourceList(empty: app.machines.isEmpty, emptyText: "No Linux machines on \(app.selectedHost)",
                         loading: app.loadingResources, ctaLabel: "New machine", cta: { creating = true },
                         selection: $app.machineSelection, rows: items) { m in
                HoverRow { hover in
                    HStack(spacing: 9) {
                        StateDot(color: stateColor(m.state))
                        Image(systemName: distroIcon(m.distro)).foregroundStyle(distroColor(m.distro)).font(.system(size: 12))
                        Text(m.name).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 4)
                        if hover {
                            if m.state == "running" {
                                RowActionButton(icon: "stop.fill", help: "Stop") { app.machineLifecycle("stop", name: m.name) }
                            } else {
                                RowActionButton(icon: "play.fill", help: "Start", tint: .green) { app.machineLifecycle("start", name: m.name) }
                            }
                            RowActionButton(icon: "trash", help: "Delete machine") { app.machineDelete(m.name) }
                        } else {
                            Tag(text: m.distro, color: distroColor(m.distro))
                        }
                    }
                }
                .tag(m.id)
                .contextMenu {
                    if m.state == "running" {
                        Button("Stop") { app.machineLifecycle("stop", name: m.name) }
                    } else {
                        Button("Start") { app.machineLifecycle("start", name: m.name) }
                    }
                    Button("Copy name") { copyToPasteboard(m.name) }
                    Divider()
                    Button("Delete", role: .destructive) { app.machineDelete(m.name) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .help("New machine").accessibilityLabel("New machine")
            }
        }
        .sheet(isPresented: $creating) { NewMachineSheet() }
    }
}

struct NewMachineSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var distro = "ubuntu"
    @State private var busy = false
    @State private var error: String?
    private let distros = ["ubuntu", "debian", "alpine", "fedora", "arch", "rocky"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Linux machine").font(.headline)
            TextField("name", text: $name).textFieldStyle(.roundedBorder)
            Picker("distro", selection: $distro) { ForEach(distros, id: \.self) { Text($0) } }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(busy ? "Creating…" : "Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func create() {
        busy = true; error = nil
        Task {
            do {
                try await app.cli.machineCreate(name: name, distro: distro, host: app.selectedHost)
                await app.refreshResources()
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                busy = false
            }
        }
    }
}

struct MachineDetail: View {
    let machine: Machine
    @EnvironmentObject var app: AppState

    private var shellArgs: [String] { ["machine", "shell", machine.name, "--host", app.selectedHost] }

    var body: some View {
        VStack(spacing: 0) {
            DetailIdentity(stateColor: stateColor(machine.state),
                           title: machine.name,
                           subtitle: {
                HStack(spacing: 6) {
                    Image(systemName: distroIcon(machine.distro)).foregroundStyle(distroColor(machine.distro))
                    Text(machine.distro)
                    Text("·").foregroundStyle(.tertiary)
                    Text(machine.status).foregroundStyle(.secondary)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }, actions: { actions })
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            if let bin = app.cli.binaryPath {
                PTYTerminal(binary: bin, ref: machine.name, fixedArgs: shellArgs)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if machine.state == "running" {
                Button { app.machineLifecycle("stop", name: machine.name) } label: { Label("Stop", systemImage: "stop.fill") }.controlSize(.small)
                if let bin = app.cli.binaryPath {
                    Button { openInTerminal(bin, shellArgs) } label: { Label("Terminal", systemImage: "terminal") }
                        .controlSize(.small).help("Open a shell in Terminal.app")
                }
            } else {
                Button { app.machineLifecycle("start", name: machine.name) } label: { Label("Start", systemImage: "play.fill") }.controlSize(.small).tint(.green)
            }
            Menu {
                Button("Open home in Finder") { revealInFinder(NSHomeDirectory()) }
                Button("Copy name") { copyToPasteboard(machine.name) }
                Divider()
                Button("Delete", role: .destructive) { app.machineDelete(machine.name) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 28)
        }
    }
}

// MARK: - reusable list / detail scaffolding

struct ResourceList<Item: Identifiable, Row: View>: View {
    let empty: Bool
    let emptyText: String
    var loading: Bool = false
    var ctaLabel: String? = nil
    var ctaIcon: String = "plus"
    var cta: (() -> Void)? = nil
    @Binding var selection: String?
    let rows: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if empty {
            if loading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(text: emptyText, ctaLabel: ctaLabel, ctaIcon: ctaIcon, cta: cta)
            }
        } else {
            List(selection: $selection) {
                ForEach(rows) { row($0) }
            }
        }
    }
}

// EmptyState is the shared "nothing here yet" panel, with an optional call to action.
struct EmptyState: View {
    let text: String
    var icon: String = "tray"
    var ctaLabel: String? = nil
    var ctaIcon: String = "plus"
    var cta: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let ctaLabel, let cta {
                Button(action: cta) {
                    Label(ctaLabel, systemImage: ctaIcon).font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// HoverRow gives a resource row the same treatment as ContainerRow: a soft
// rounded background on hover, and inline trailing actions revealed on hover
// (the closure receives the live hover state so the row can swap static info for
// actions). Keeps volumes/networks/images/machines visually consistent.
struct HoverRow<Content: View>: View {
    @State private var hover = false
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        content(hover)
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hover = $0 }
    }
}

// RowActionButton is the shared inline action icon used by hover rows.
struct RowActionButton: View {
    let icon: String
    let help: String
    var tint: Color = .secondary
    let run: () -> Void
    var body: some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(tint).help(help)
    }
}

// DetailIdentity is the shared header identity row (state dot + title + subtitle +
// trailing actions) used by container and machine detail panels.
struct DetailIdentity<Subtitle: View, Actions: View>: View {
    var stateColor: Color
    var dotSize: CGFloat = 11
    let title: String
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 10) {
            StateDot(color: stateColor, size: dotSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                subtitle
            }
            Spacer()
            actions
        }
    }
}

struct ResourceDetail<Content: View>: View {
    let icon: String
    let title: String
    var tint: Color = .blue
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.title2).foregroundStyle(tint)
                    Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                Card { VStack(alignment: .leading, spacing: 10) { content } }
                Spacer()
            }
            .padding(18)
        }
        .background(.background)
    }
}

// A distinct accent color per Linux distro (best-effort, falls back to orange).
func distroColor(_ distro: String) -> Color {
    switch distro.lowercased() {
    case "ubuntu": return Color(red: 0.90, green: 0.36, blue: 0.16)   // ubuntu orange
    case "debian": return Color(red: 0.84, green: 0.10, blue: 0.36)   // debian red
    case "alpine": return Color(red: 0.05, green: 0.40, blue: 0.65)   // alpine blue
    case "fedora": return Color(red: 0.20, green: 0.40, blue: 0.78)   // fedora blue
    case "arch":   return Color(red: 0.10, green: 0.59, blue: 0.91)   // arch cyan
    case "rocky":  return Color(red: 0.06, green: 0.66, blue: 0.42)   // rocky green
    default:        return .orange
    }
}

// SF Symbol per distro — no brand logos available, so a tasteful generic mark.
func distroIcon(_ distro: String) -> String {
    switch distro.lowercased() {
    case "alpine": return "mountain.2.fill"
    case "arch":   return "triangle.fill"
    default:        return "shippingbox.fill"
    }
}

// Trim a long image ref for list display.
func shortImage(_ image: String) -> String {
    var img = image
    if let at = img.range(of: "@") { img = String(img[..<at.lowerBound]) }
    if let slash = img.range(of: "/", options: .backwards) { img = String(img[slash.upperBound...]) }
    return img
}
