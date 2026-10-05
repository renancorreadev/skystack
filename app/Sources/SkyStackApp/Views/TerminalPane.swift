import SwiftUI
import SwiftTerm

// TerminalRepresentable hosts a real PTY (SwiftTerm) running a `skystack`
// subcommand (an interactive `exec` shell, or a `debug` toolbox). The CLI sees a
// TTY on the PTY slave, so it enters raw interactive mode with live resize.
struct TerminalRepresentable: NSViewRepresentable {
    let binary: String
    let args: [String]
    var onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 380))
        term.processDelegate = context.coordinator
        applyTheme(term)
        launch(term)
        return term
    }

    func updateNSView(_ term: LocalProcessTerminalView, context: Context) {
        applyTheme(term)
    }

    private func launch(_ term: LocalProcessTerminalView) {
        // Preserve the environment (HOME lets skystack find ~/.skystack), add TERM.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let envArray = env.map { "\($0.key)=\($0.value)" }
        term.startProcess(executable: binary, args: args, environment: envArray, execName: nil)
    }

    private func applyTheme(_ term: LocalProcessTerminalView) {
        term.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        term.nativeBackgroundColor = NSColor(srgbRed: 0.066, green: 0.075, blue: 0.098, alpha: 1)
        term.nativeForegroundColor = NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
        term.caretColor = NSColor(srgbRed: 0.36, green: 0.78, blue: 0.98, alpha: 1)
        term.selectedTextBackgroundColor = NSColor(srgbRed: 0.20, green: 0.40, blue: 0.66, alpha: 0.55)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.onExit(exitCode) }
        }
    }
}

// PTYTerminal wraps the emulator with a Shell/Debug switch, a restart control,
// and a session-ended affordance.
struct PTYTerminal: View {
    let binary: String
    let ref: String
    var fixedArgs: [String]? = nil // when set, no Shell/Debug switch (e.g. machine shell)

    @State private var mode: TermMode = .shell
    @State private var restartToken = 0
    @State private var exitCode: Int32?
    @State private var ended = false

    enum TermMode: String, CaseIterable { case shell = "Shell", debug = "Debug" }

    private var args: [String] {
        if let f = fixedArgs { return f }
        switch mode {
        case .shell:
            return ["exec", ref, "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"]
        case .debug:
            return ["debug", ref]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .debug ? "ladybug.fill" : "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(mode == .debug ? .orange : .green)
                Text(ref)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))

                if fixedArgs == nil {
                    Picker("", selection: $mode) {
                        ForEach(TermMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)

                    if mode == .debug {
                        Text("toolbox shares the target's namespaces")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { restart() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Restart")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            ZStack {
                TerminalRepresentable(binary: binary, args: args) { code in
                    exitCode = code
                    ended = true
                }
                .id("\(mode.rawValue)-\(restartToken)") // recreate on mode/restart

                if ended {
                    VStack(spacing: 10) {
                        Image(systemName: "bolt.slash")
                            .font(.title2).foregroundStyle(.secondary)
                        Text(exitCode.map { "session ended (exit \($0))" } ?? "session ended")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Restart") { restart() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onChange(of: mode) { _, _ in ended = false; exitCode = nil }
    }

    private func restart() {
        ended = false
        exitCode = nil
        restartToken += 1
    }
}
