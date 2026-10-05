import SwiftUI
import AppKit

// One turn in the AI conversation.
struct AIMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant }
    let role: Role
    var text: String
}

// A runnable corrective action the model proposed (a single skystack command).
struct FixSuggestion: Equatable {
    let command: String                 // e.g. "skystack restart skyvm/web"
    var args: [String] {                // ["restart","skyvm/web"] for the CLI
        var a = CommandHighlighter.splitArgs(command)
        if a.first == "skystack" { a.removeFirst() }
        return a
    }
}

// AIChat drives a Claude Code conversation about one container: the first turn
// analyzes full context (or seeded logs), follow-ups resume the same session,
// and any proposed fix is parsed into a one-click runnable command.
@MainActor
final class AIChat: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var loading = false
    @Published var error: String?
    @Published var fix: FixSuggestion?
    @Published var applying = false
    @Published var applyOutput: String?

    @Published private(set) var started = false

    private let container: Container
    private let seedLogs: String?
    private let cli = SkyCLI()
    private var sessionID: String?

    init(container: Container, seedLogs: String? = nil) {
        self.container = container
        self.seedLogs = seedLogs
    }

    var claudeAvailable: Bool { cli.claudeAvailable }
    var scopeLabel: String { seedLogs == nil ? "full container" : "selected logs" }
    var lastAssistant: String? { messages.last(where: { $0.role == .assistant })?.text }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task { await analyze() }
    }

    func rerun() {
        messages = []; fix = nil; applyOutput = nil; sessionID = nil; error = nil
        Task { await analyze() }
    }

    private func analyze() async {
        loading = true; error = nil
        do {
            let input: String
            let scope: String
            if let seedLogs {
                input = seedLogs
                scope = "the following recent log lines"
            } else {
                input = try await cli.containerContextRaw(ref: container.ref)
                scope = "the following JSON snapshot of the container — its `inspect`, a live `stats` sample, and a recent log tail"
            }
            let reply = try await cli.analyzeJSON(prompt: firstPrompt(scope: scope), input: input)
            sessionID = reply.sessionID
            appendAssistant(reply.text)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !loading else { return }
        messages.append(AIMessage(role: .user, text: q))
        loading = true; error = nil
        Task {
            do {
                let reply = try await cli.analyzeJSON(prompt: followUpPrompt(q), resume: sessionID)
                if reply.sessionID != nil { sessionID = reply.sessionID }
                appendAssistant(reply.text)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            loading = false
        }
    }

    func applyFix() {
        guard let fix, !fix.args.isEmpty, !applying else { return }
        applying = true; applyOutput = nil
        Task {
            let out = await cli.runText(fix.args)
            applyOutput = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "✓ Applied." : out
            applying = false
        }
    }

    private func appendAssistant(_ raw: String) {
        let text = raw.isEmpty ? "Claude returned no output." : raw
        messages.append(AIMessage(role: .assistant, text: stripFixBlock(text)))
        if let f = parseFix(text) { fix = f; applyOutput = nil }
    }

    // Pull a ```skyfix\n<skystack …>\n``` block into a runnable command.
    private func parseFix(_ text: String) -> FixSuggestion? {
        guard let open = text.range(of: "```skyfix") else { return nil }
        let after = text[open.upperBound...]
        guard let close = after.range(of: "```") else { return nil }
        let body = after[..<close.lowerBound]
        let cmd = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return cmd.hasPrefix("skystack ") ? FixSuggestion(command: cmd) : nil
    }

    // Hide the raw fence from the rendered transcript — it's shown as a button.
    private func stripFixBlock(_ text: String) -> String {
        guard let open = text.range(of: "```skyfix") else { return text }
        let after = text[open.upperBound...]
        guard let close = after.range(of: "```") else { return text }
        var out = text
        out.removeSubrange(open.lowerBound..<text.index(after.startIndex, offsetBy: text.distance(from: after.startIndex, to: close.upperBound)))
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstPrompt(scope: String) -> String {
        """
        You are a senior SRE diagnosing a Docker container named "\(container.name)" \
        (image \(container.image), host \(container.host), state \(container.state)). \
        You are given \(scope) on stdin. Reply in concise GitHub-flavored markdown:
        ## Summary — what this service is and what it's doing.
        ## Diagnosis — concrete problems, errors, or risks, most likely root cause first. If it's healthy, say so plainly.
        ## Fix — specific steps or commands to try.
        Then, ONLY IF a single safe corrective action can be run through the SkyStack CLI, \
        append it last as a fenced block exactly like:
        ```skyfix
        skystack restart \(container.host)/\(container.name)
        ```
        Allowed corrective commands: `restart`, `stop`, `start`, or `exec \(container.host)/\(container.name) -- <cmd>`. \
        Always use the reference "\(container.host)/\(container.name)". Do not invent flags. \
        If no safe one-command fix applies, omit the skyfix block. Keep it under ~280 words. Do not ask questions.
        """
    }

    private func followUpPrompt(_ q: String) -> String {
        """
        \(q)

        (Keep using concise markdown. If your answer implies one safe corrective action runnable via the \
        SkyStack CLI — restart/stop/start/exec on "\(container.host)/\(container.name)" — end with a ```skyfix fenced \
        block containing exactly one `skystack …` command.)
        """
    }
}

// ContainerAIView is the AI tab: full-container analysis, a suggested one-click
// fix, and a follow-up chat — all backed by Claude Code.
struct ContainerAIView: View {
    let container: Container
    var seedLogs: String?
    var autoStart: Bool = false
    @StateObject private var chat: AIChat
    @State private var draft = ""

    init(container: Container, seedLogs: String? = nil, autoStart: Bool = false) {
        self.container = container
        self.seedLogs = seedLogs
        self.autoStart = autoStart
        _chat = StateObject(wrappedValue: AIChat(container: container, seedLogs: seedLogs))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !chat.claudeAvailable {
                Placeholder(icon: "sparkles", text: "Claude Code not found.\nInstall Claude Code (or set CLAUDE_BIN) to enable AI analysis.")
            } else if !chat.started {
                intro
            } else {
                transcript
                if let fix = chat.fix { fixCard(fix) }
                composer
            }
        }
        .background(.background)
        .onAppear { if autoStart { chat.startIfNeeded() } }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(.purple)
            Text(seedLogs == nil ? "Analyze this container with AI" : "Analyze these logs with AI")
                .font(.headline)
            Text(seedLogs == nil
                 ? "Sends the container's inspect, a live stats sample, and recent logs to Claude Code for a root-cause read — then suggests a one-click fix you can apply."
                 : "Sends the selected log lines to Claude Code for a root-cause read, with a one-click fix and follow-up chat.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button { chat.startIfNeeded() } label: {
                Label(seedLogs == nil ? "Analyze container" : "Analyze logs", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("AI analysis").font(.headline)
            Text("· \(chat.scopeLabel)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if chat.loading { ProgressView().controlSize(.small) }
            Button { chat.rerun() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(chat.loading).help("Re-analyze")
            Button { copyLast() } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).disabled(chat.lastAssistant == nil).help("Copy last reply")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty && chat.loading {
                        thinkingRow
                    }
                    ForEach(chat.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if chat.loading && !chat.messages.isEmpty { thinkingRow }
                    if let e = chat.error { errorRow(e) }
                    Color.clear.frame(height: 1).id("ai.bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("ai.bottom", anchor: .bottom) }
            }
            .onChange(of: chat.loading) { _, _ in
                withAnimation { proxy.scrollTo("ai.bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: AIMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple).font(.system(size: 13)).padding(.top, 2)
                MarkdownText(msg.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Claude is analyzing…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ e: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(e).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func fixCard(_ fix: FixSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.tint).font(.caption)
                Text("Suggested fix").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    chat.applyFix()
                } label: {
                    Label(chat.applying ? "Applying…" : "Apply fix", systemImage: "play.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(.green)
                .disabled(chat.applying)
            }
            Text(fix.command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            if let out = chat.applyOutput {
                Text(out)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .top)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask a follow-up…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.loading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .top)
    }

    private func send() {
        let q = draft
        draft = ""
        chat.ask(q)
    }

    private func copyLast() {
        guard let t = chat.lastAssistant else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
}

// LogAnalysisView keeps the logs-tab "Analyze" entry point: a sheet scoped to the
// currently filtered log window, with the same chat + fix affordances.
struct LogAnalysisView: View {
    let container: Container
    let logsText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ContainerAIView(container: container, seedLogs: logsText, autoStart: true)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(10)
        }
        .frame(width: 580, height: 600)
    }
}

// MarkdownText renders Claude's markdown: headers, bullets, and inline bold/code.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                lineView(raw)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("### ") {
            Text(inline(String(t.dropFirst(4)))).font(.subheadline.weight(.semibold)).padding(.top, 4)
        } else if t.hasPrefix("## ") {
            Text(inline(String(t.dropFirst(3)))).font(.headline).foregroundStyle(.tint).padding(.top, 6)
        } else if t.hasPrefix("# ") {
            Text(inline(String(t.dropFirst(2)))).font(.title3.weight(.bold)).padding(.top, 6)
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(t.dropFirst(2))))
            }
        } else if t.isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(inline(t))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
