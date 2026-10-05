import SwiftUI
import AppKit

// HostSSHControl is the button next to the host picker that opens a real SSH
// session to the selected host's MACHINE (not a container) and offers a few safe
// admin actions. Shown only for SSH hosts (local/skyvm have their own controls).
struct HostSSHControl: View {
    @EnvironmentObject var app: AppState
    @State private var target: SSHTarget?
    @State private var output: SSHOutput?
    @State private var confirmReboot = false
    @State private var confirmRestartDocker = false
    @State private var running = false

    private var isSSHHost: Bool { app.selectedHostInfo?.kind == "ssh" }
    private var args: [String]? { (target?.ok == true) ? target?.args : nil }

    var body: some View {
        Group {
            if isSSHHost {
                Menu {
                    Button { openTerminal() } label: { Label("Open SSH terminal", systemImage: "terminal") }
                        .disabled(args == nil)
                    Divider()
                    Button { runInfo() } label: { Label("System info", systemImage: "info.circle") }
                    Button { runDockerDF() } label: { Label("Docker disk usage", systemImage: "internaldrive") }
                    Button { runDockerPrune() } label: { Label("Docker prune (unused)", systemImage: "trash") }
                    Divider()
                    Button { confirmRestartDocker = true } label: { Label("Restart Docker daemon…", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { confirmReboot = true } label: { Label("Reboot machine…", systemImage: "power") }
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("SSH into \(app.selectedHost)")
                .disabled(target == nil)
                .task(id: app.selectedHost) { await loadTarget() }
                .confirmationDialog("Reboot \(app.selectedHost)?", isPresented: $confirmReboot, titleVisibility: .visible) {
                    Button("Reboot", role: .destructive) { reboot() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Reboots the remote machine over SSH. Containers stop until it comes back up.")
                }
                .confirmationDialog("Restart Docker on \(app.selectedHost)?", isPresented: $confirmRestartDocker, titleVisibility: .visible) {
                    Button("Restart Docker", role: .destructive) { restartDocker() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Restarts the Docker daemon. Running containers restart per their policy.")
                }
                .sheet(item: $output) { SSHOutputSheet(output: $0, running: running) }
            }
        }
    }

    private func loadTarget() async {
        target = try? await app.cli.hostSSH(host: app.selectedHost)
    }

    // Interactive shell on the machine.
    private func openTerminal() {
        guard let a = args else { return }
        TerminalWindowManager.open(title: "ssh · \(target?.target ?? app.selectedHost)", binary: "/usr/bin/ssh", args: a)
    }

    // Read-only admin: run over SSH and show the output.
    private func runReadOnly(_ title: String, _ remote: String) {
        guard let a = args else { return }
        output = SSHOutput(title: title, text: "")
        running = true
        Task {
            let text = await app.cli.sshRun(a + [remote])
            output = SSHOutput(title: title, text: text.isEmpty ? "(no output)" : text)
            running = false
        }
    }

    private func runInfo() {
        runReadOnly("System info · \(app.selectedHost)",
                    "echo \"host: $(hostname)\"; echo; uptime; echo; echo '— disk —'; df -h /; echo; echo '— memory —'; (free -h 2>/dev/null || true); echo; echo '— docker —'; docker --version 2>/dev/null; docker info --format 'containers: {{.Containers}} running, images: {{.Images}}' 2>/dev/null")
    }
    private func runDockerDF() {
        runReadOnly("Docker disk usage · \(app.selectedHost)", "docker system df")
    }
    private func runDockerPrune() {
        runReadOnly("Docker prune · \(app.selectedHost)", "docker system prune -f")
    }

    // Privileged actions need a TTY for the sudo prompt → an interactive window.
    private func restartDocker() {
        guard let a = args else { return }
        TerminalWindowManager.open(title: "restart docker · \(app.selectedHost)", binary: "/usr/bin/ssh",
                                   args: ["-t"] + a + ["sudo systemctl restart docker || sudo service docker restart; echo; echo 'done — press any key'; read -n1"])
    }
    private func reboot() {
        guard let a = args else { return }
        TerminalWindowManager.open(title: "reboot · \(app.selectedHost)", binary: "/usr/bin/ssh",
                                   args: ["-t"] + a + ["sudo reboot"])
    }
}

// SSHOutput is a one-shot admin command's result (shown in a sheet).
struct SSHOutput: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct SSHOutputSheet: View {
    let output: SSHOutput
    var running: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.tint)
                Text(output.title).font(.headline)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(output.text.isEmpty && running ? "Running…" : output.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 660, height: 460)
    }
}

// TerminalWindowManager opens any binary+args in a real PTY inside a resizable,
// full-screen-capable window (reuses the container terminal's PTY view). Used for
// the host SSH shell and privileged SSH actions.
@MainActor
enum TerminalWindowManager {
    private static var controllers: [NSWindowController] = []

    static func open(title: String, binary: String, args: [String]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior.insert(.fullScreenPrimary)

        let root = TerminalWindowRoot(title: title, binary: binary, args: args,
                                      onClose: { [weak window] in window?.close() })
        window.contentViewController = NSHostingController(rootView: AnyView(root))

        let wc = NSWindowController(window: window)
        controllers.append(wc)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { controllers.removeAll { $0.window === window } }
        }
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TerminalWindowRoot: View {
    let title: String
    let binary: String
    let args: [String]
    var onClose: () -> Void

    @State private var restartToken = 0
    @State private var ended = false
    @State private var exitCode: Int32?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").foregroundStyle(.green)
                Text(title).font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Button { reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reconnect")
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
            Divider()
            ZStack {
                TerminalRepresentable(binary: binary, args: args) { code in
                    exitCode = code; ended = true
                }
                .id(restartToken)
                if ended {
                    VStack(spacing: 10) {
                        Image(systemName: "bolt.slash").font(.title2).foregroundStyle(.secondary)
                        Text(exitCode.map { "session ended (exit \($0))" } ?? "session ended")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Reconnect") { reconnect() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(minWidth: 600, minHeight: 360)
    }

    private func reconnect() { ended = false; exitCode = nil; restartToken += 1 }
}
