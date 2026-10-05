import SwiftUI

struct ConsoleEntry: Identifiable {
    let id = UUID()
    let command: String
    var output: String
    var running: Bool
}

// CommandConsole runs `skystack …` subcommands with a live syntax-highlighted
// input, autocomplete chips, command history, and a highlighted transcript.
struct CommandConsole: View {
    var container: Container?
    @EnvironmentObject var app: AppState

    @State private var input = ""
    @State private var entries: [ConsoleEntry] = []
    @State private var history: [String] = []
    @State private var histIndex: Int?
    @FocusState private var focused: Bool

    private var name: String { container?.name ?? "" }

    private var suggestions: [String] {
        let base: [String]
        if let n = container?.name {
            base = ["logs \(n)", "logs \(n) --tail 100", "inspect \(n)", "restart \(n)", "stop \(n)", "ps -A", "hosts"]
        } else {
            base = ["ps -A", "hosts", "vm status", "machine list", "k8s status", "images skyvm"]
        }
        let q = input.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(base.prefix(5)) }
        return base.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2).foregroundStyle(.tint)
                Text("Console").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !entries.isEmpty {
                    Button { entries.removeAll() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Clear")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)

            Divider()
            transcript
            Divider()
            if !suggestions.isEmpty { suggestionBar }
            inputBar
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        Text("Run skystack commands here — try  ps -A  ·  machine list  ·  hosts")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }
                    ForEach(entries) { entry in
                        ConsoleEntryView(entry: entry, container: name).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .onChange(of: entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: entries.last?.running) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { s in
                    Button { input = s; focused = true } label: {
                        Text(s).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.background.secondary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            Text("skystack").font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tint)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if input.isEmpty {
                    Text(container == nil ? "ps -A · machine list · k8s status" : "ps -A · logs \(name) · inspect \(name)")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(CommandHighlighter.attributed(input, container: name))
                }
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.clear) // hide glyphs; the highlighted overlay shows instead
                    .focused($focused)
                    .onSubmit(run)
                    .onKeyPress(.upArrow) { historyPrev(); return .handled }
                    .onKeyPress(.downArrow) { historyNext(); return .handled }
            }
            .font(.system(size: 13, design: .monospaced))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func run() {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        history.append(line)
        histIndex = nil

        var args = CommandHighlighter.splitArgs(line)
        if args.first == "skystack" { args.removeFirst() }
        guard !args.isEmpty else { input = ""; return }

        entries.append(ConsoleEntry(command: line, output: "", running: true))
        let idx = entries.count - 1
        input = ""
        Task {
            let out = await app.cli.runText(args)
            if idx < entries.count {
                entries[idx].output = out.trimmingCharacters(in: .newlines)
                entries[idx].running = false
            }
        }
    }

    private func historyPrev() {
        guard !history.isEmpty else { return }
        let next = (histIndex ?? history.count) - 1
        histIndex = max(0, next)
        input = history[histIndex!]
    }

    private func historyNext() {
        guard let idx = histIndex else { return }
        let next = idx + 1
        if next >= history.count { histIndex = nil; input = "" } else { histIndex = next; input = history[next] }
    }
}

struct ConsoleEntryView: View {
    let entry: ConsoleEntry
    let container: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("skystack").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.tint)
                Text("❯").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Text(CommandHighlighter.attributed(entry.command, container: container))
                    .font(.system(size: 12, design: .monospaced))
                if entry.running {
                    ProgressView().controlSize(.mini).padding(.leading, 2)
                }
            }
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
