import SwiftUI
import AppKit

// OperatorChat drives a Claude Code conversation about a whole HOST, not one
// container: it feeds the host-wide triage context (every container's state +
// problem logs) and parses the model's reply into one-or-more runnable fixes.
@MainActor
final class OperatorChat: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var loading = false
    @Published var error: String?
    @Published var fixes: [FixSuggestion] = []
    @Published var applyingIndex: Int?
    @Published var applyOutputs: [Int: String] = [:]
    @Published private(set) var started = false

    let host: String
    private let cli = SkyCLI()
    private var sessionID: String?

    init(host: String) { self.host = host }

    var claudeAvailable: Bool { cli.claudeAvailable }
    var lastAssistant: String? { messages.last(where: { $0.role == .assistant })?.text }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task { await triage() }
    }
    func rerun() {
        messages = []; fixes = []; applyOutputs = [:]; sessionID = nil; error = nil
        Task { await triage() }
    }

    private func triage() async {
        loading = true; error = nil
        do {
            let input = try await cli.hostContextRaw(host: host)
            let reply = try await cli.analyzeJSON(prompt: firstPrompt(), input: input)
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

    func applyFix(_ i: Int) {
        guard fixes.indices.contains(i), applyingIndex == nil, !fixes[i].args.isEmpty else { return }
        applyingIndex = i; applyOutputs[i] = nil
        Task {
            let out = await cli.runText(fixes[i].args)
            applyOutputs[i] = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "✓ Applied." : out
            applyingIndex = nil
        }
    }

    private func appendAssistant(_ raw: String) {
        let text = raw.isEmpty ? "Claude returned no output." : raw
        let (clean, parsed) = extractFixes(text)
        messages.append(AIMessage(role: .assistant, text: clean))
        if !parsed.isEmpty { fixes = parsed; applyOutputs = [:] }
    }

    // Pull EVERY ```skyfix block (one `skystack …` command each) into a list of
    // runnable fixes, and strip the fences from the rendered transcript.
    private func extractFixes(_ text: String) -> (String, [FixSuggestion]) {
        var out = text
        var found: [FixSuggestion] = []
        while let open = out.range(of: "```skyfix") {
            let after = out[open.upperBound...]
            guard let close = after.range(of: "```") else { break }
            let body = after[..<close.lowerBound]
            for line in body.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where line.hasPrefix("skystack ") {
                found.append(FixSuggestion(command: line))
            }
            let blockEnd = out.index(after.startIndex, offsetBy: out.distance(from: after.startIndex, to: close.upperBound))
            out.removeSubrange(open.lowerBound..<blockEnd)
        }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), found)
    }

    private func firstPrompt() -> String {
        """
        You are a senior SRE triaging a Docker host named "\(host)". You are given a JSON \
        snapshot on stdin: the engine version, container counts, and a list of containers \
        (name, image, state, status, ports, and a recent log tail for any that are not healthy). \
        Reply in concise GitHub-flavored markdown:
        ## Overview — running vs total, and the host's overall health in a sentence.
        ## Problems — for each unhealthy/exited/restarting service, name it and give the likely \
        root cause from its status/logs, most severe first. If everything is healthy, say so plainly.
        ## Recommended actions — concrete next steps.
        Then, for EACH container with a single safe corrective action runnable via the SkyStack CLI, \
        append a SEPARATE fenced block exactly like:
        ```skyfix
        skystack restart \(host)/<name>
        ```
        Allowed commands: `restart`, `stop`, `start`. Always use the reference "\(host)/<name>". \
        One command per block; include several blocks if several services need attention. \
        Omit blocks entirely if no safe one-command fix applies. Keep it under ~350 words. Do not ask questions.
        """
    }

    private func followUpPrompt(_ q: String) -> String {
        """
        \(q)

        (Keep using concise markdown. For any safe corrective action runnable via the SkyStack CLI — \
        restart/stop/start on "\(host)/<name>" — end with one ```skyfix fenced block per command.)
        """
    }
}

// OperatorView is the host-level AI operator: one-click whole-host triage,
// per-service suggested fixes you can apply individually, and a follow-up chat.
struct OperatorView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var chat: OperatorChat
    @State private var draft = ""

    init(host: String) {
        _chat = StateObject(wrappedValue: OperatorChat(host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !chat.claudeAvailable {
                Placeholder(icon: "sparkles", text: "Claude Code not found.\nInstall Claude Code (or set CLAUDE_BIN) to enable the AI operator.")
            } else if !chat.started {
                intro
            } else {
                transcript
                if !chat.fixes.isEmpty { fixList }
                composer
            }
        }
        .background(.background)
        .navigationTitle("Operator")
        .navigationSubtitle(chat.host)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(.purple)
            Text("AI operator").font(.headline)
            Text("· \(chat.host)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if chat.loading { ProgressView().controlSize(.small) }
            Button { chat.rerun() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(chat.loading || !chat.started).help("Re-triage")
            Button { copyLast() } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).disabled(chat.lastAssistant == nil).help("Copy last reply")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars").font(.system(size: 34)).foregroundStyle(.purple)
            Text("Triage the whole host with AI").font(.headline)
            Text("Sends every container's state plus recent logs from any that are unhealthy on \(chat.host) to Claude Code — for a host-wide root-cause read and per-service one-click fixes.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { chat.startIfNeeded() } label: {
                Label("Triage \(chat.host)", systemImage: "sparkles").font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty && chat.loading { thinkingRow }
                    ForEach(chat.messages) { msg in messageRow(msg).id(msg.id) }
                    if chat.loading && !chat.messages.isEmpty { thinkingRow }
                    if let e = chat.error { errorRow(e) }
                    Color.clear.frame(height: 1).id("op.bottom")
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("op.bottom", anchor: .bottom) }
            }
            .onChange(of: chat.loading) { _, _ in
                withAnimation { proxy.scrollTo("op.bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func messageRow(_ msg: AIMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text).font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple).font(.system(size: 13)).padding(.top, 2)
                MarkdownText(msg.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Claude is triaging \(chat.host)…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ e: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(e).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var fixList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.tint).font(.caption)
                Text("Suggested actions (\(chat.fixes.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(Array(chat.fixes.enumerated()), id: \.offset) { i, fix in
                HStack(spacing: 8) {
                    Text(fix.command)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    Button { chat.applyFix(i) } label: {
                        Label(chat.applyingIndex == i ? "Applying…" : "Apply", systemImage: "play.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.green)
                    .disabled(chat.applyingIndex != nil)
                }
                if let out = chat.applyOutputs[i] {
                    Text(out).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .top)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask a follow-up about \(chat.host)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.loading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .top)
    }

    private func send() {
        let q = draft; draft = ""; chat.ask(q)
    }
    private func copyLast() {
        guard let t = chat.lastAssistant else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
}
