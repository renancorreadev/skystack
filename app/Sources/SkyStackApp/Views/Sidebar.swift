import SwiftUI

struct Sidebar: View {
    @EnvironmentObject var app: AppState

    private var selection: Binding<Section?> {
        Binding(get: { app.section }, set: { if let s = $0 { app.section = s } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(sidebarGroups, id: \.name) { group in
                SwiftUI.Section {
                    ForEach(group.sections) { s in
                        SectionRow(section: s, count: app.count(s)).tag(s)
                    }
                } header: {
                    Text(group.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Brand()
                HStack(spacing: 6) {
                    HostPicker()
                    HostSSHControl()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                VMControl()
                Divider()
            }
        }
    }
}

struct SectionRow: View {
    let section: Section
    let count: Int
    var body: some View {
        HStack {
            Label(section.title, systemImage: section.icon)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            Text("SkyStack")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

// VMControl surfaces the local SkyVM's lifecycle right in the sidebar, so the VM
// can be started/stopped/restarted without dropping to the CLI (Batch B).
struct VMControl: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let vm = app.vmStatus, vm.configured {
            HStack(spacing: 7) {
                Image(systemName: "cube.transparent").foregroundStyle(.secondary).font(.system(size: 11))
                statusLabel(vm)
                Spacer()
                control(vm)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    @ViewBuilder private func statusLabel(_ vm: VMStatus) -> some View {
        if app.vmBusy {
            ProgressView().controlSize(.mini)
            Text("Working…").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if vm.booting {
            ProgressView().controlSize(.mini)
            Text("SkyVM booting…").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if vm.ready {
            StateDot(color: stateColor("running"), size: 6)
            Text("SkyVM · \(vm.version ?? "")").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        } else {
            StateDot(color: stateColor("exited"), size: 6)
            Text("SkyVM stopped").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func control(_ vm: VMStatus) -> some View {
        if app.vmBusy || vm.booting {
            EmptyView()
        } else if vm.ready {
            Menu {
                Button { app.vmAction("restart") } label: { Label("Restart VM", systemImage: "arrow.clockwise") }
                Button { app.vmAction("stop") } label: { Label("Stop VM", systemImage: "stop.fill") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).frame(width: 20)
            .help("SkyVM controls")
        } else {
            Button { app.vmAction("start") } label: {
                Label("Start", systemImage: "play.fill").font(.system(size: 10, weight: .semibold))
            }
            .controlSize(.mini).buttonStyle(.borderedProminent).tint(.green)
            .help("Start SkyVM")
        }
    }
}

struct HostPicker: View {
    @EnvironmentObject var app: AppState
    @State private var showRemote = false
    var body: some View {
        Menu {
            ForEach(app.hosts) { h in
                Button {
                    app.selectHost(h.name)
                } label: {
                    if h.up, let v = h.engine {
                        Label("\(h.name) · \(v)", systemImage: hostIcon(h.kind))
                    } else {
                        Label("\(h.name) (offline)", systemImage: hostIcon(h.kind))
                    }
                }
                .disabled(!h.up)
            }
            Divider()
            Button { showRemote = true } label: { Label("Connect to remote…", systemImage: "network") }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: hostIcon(app.selectedHostInfo?.kind ?? "local"))
                    .foregroundStyle(.secondary)
                Text(app.selectedHost).font(.system(size: 12, weight: .medium))
                if let v = app.selectedHostInfo?.engine, app.selectedHostInfo?.up == true {
                    Text(v).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer()
                StateDot(color: (app.selectedHostInfo?.up ?? false) ? stateColor("running") : stateColor("exited"), size: 6)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showRemote) { RemoteHostsSheet() }
    }
}
