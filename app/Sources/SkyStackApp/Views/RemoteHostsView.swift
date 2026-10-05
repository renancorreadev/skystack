import SwiftUI

// RemoteHostsSheet lists the aliases from ~/.ssh/config and connects to any of
// them as a remote Docker host with one click — reusing the user's SSH keys,
// hostnames, ports and ProxyJump. A manual ssh:// entry covers hosts not in the
// config. On success it jumps straight to that host's containers.
struct RemoteHostsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var hosts: [SSHHostEntry] = []
    @State private var loading = true
    @State private var busy: String?
    @State private var errors: [String: String] = [:]

    @State private var manualName = ""
    @State private var manualURL = "ssh://"
    @State private var manualBusy = false
    @State private var manualError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "network").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connect to a remote host").font(.headline)
                    Text("Reuses your ~/.ssh/config — keys, hostnames, ports, ProxyJump.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(14)
            .background(.bar)
            Divider()

            if loading {
                VStack(spacing: 10) { ProgressView(); Text("Reading ~/.ssh/config…").font(.callout).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hosts.isEmpty {
                EmptyState(text: "No aliases found in ~/.ssh/config", icon: "network")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hosts) { h in
                            row(h)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            manualEntry
        }
        .frame(width: 460, height: 540)
        .onAppear(perform: reload)
    }

    private func row(_ h: SSHHostEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.alias).font(.system(size: 13, weight: .medium))
                    Text(h.subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                trailing(h)
            }
            if let e = errors[h.alias] {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private func trailing(_ h: SSHHostEntry) -> some View {
        if busy == h.alias {
            ProgressView().controlSize(.small)
        } else if h.registered {
            HStack(spacing: 6) {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
                Button("Open") { open(h.alias) }.controlSize(.small)
                Button("Disconnect", role: .destructive) { disconnect(h.alias) }.controlSize(.small)
            }
        } else {
            Button { connect(alias: h.alias, url: "ssh://\(h.alias)") } label: {
                Label("Connect", systemImage: "bolt.horizontal").font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or add manually").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("name", text: $manualName).textFieldStyle(.roundedBorder).frame(width: 110)
                TextField("ssh://user@host[:port]", text: $manualURL).textFieldStyle(.roundedBorder)
                Button(manualBusy ? "…" : "Add") { connectManual() }
                    .disabled(manualBusy || manualName.isEmpty || !manualURL.hasPrefix("ssh://") || manualURL == "ssh://")
            }
            if let manualError { Text(manualError).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
        .padding(14)
    }

    private func reload() {
        Task {
            hosts = (try? await app.cli.sshHosts()) ?? []
            loading = false
        }
    }

    private func connect(alias: String, url: String) {
        busy = alias; errors[alias] = nil
        Task {
            do {
                try await app.cli.connect(name: alias, url: url)
                await app.refresh()
                busy = nil
                open(alias)
            } catch {
                errors[alias] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                busy = nil
            }
        }
    }

    private func connectManual() {
        manualBusy = true; manualError = nil
        let name = manualName, url = manualURL
        Task {
            do {
                try await app.cli.connect(name: name, url: url)
                await app.refresh()
                manualBusy = false
                open(name)
            } catch {
                manualError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                manualBusy = false
            }
        }
    }

    private func disconnect(_ alias: String) {
        busy = alias
        Task {
            try? await app.cli.disconnect(name: alias)
            await app.refresh()
            await reloadAsync()
            busy = nil
        }
    }

    private func reloadAsync() async {
        hosts = (try? await app.cli.sshHosts()) ?? []
    }

    // Connect succeeded → jump straight to that host's containers.
    private func open(_ name: String) {
        app.selectHost(name)
        dismiss()
    }
}
