import SwiftUI
import AppKit

// LogStreamModel owns the live log buffer for one container and the zoom window.
@MainActor
final class LogStreamModel: ObservableObject {
    @Published var lines: [LogLine] = []
    @Published var window: ClosedRange<Date>?
    @Published var follow = true
    // Paused freezes the visible list so the user can read; new lines buffer and
    // are flushed (with a count) on resume — the stream keeps running underneath.
    @Published var paused = false
    @Published var pendingCount = 0

    private var pending: [LogLine] = []
    private let ref: String
    private let cli = SkyCLI()
    private var task: Task<Void, Never>?
    private var cancel: (() -> Void)?
    private var seq = 0
    private let maxLines = 5000

    init(ref: String) { self.ref = ref }

    func togglePause() {
        if paused {
            lines.append(contentsOf: pending)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            pending.removeAll()
            pendingCount = 0
            paused = false
        } else {
            paused = true
        }
    }

    func start() {
        guard task == nil else { return }
        let (stream, cancel) = cli.streamLogs(ref: ref)
        self.cancel = cancel
        task = Task { [weak self] in
            for await raw in stream {
                guard let self else { break }
                self.append(raw)
            }
        }
    }

    func stop() {
        cancel?()
        task?.cancel()
        task = nil
    }

    // reload restarts the stream from scratch — clears the buffer, zoom, and pause
    // state, then re-tails (the "refresh" action).
    func reload() {
        stop()
        lines.removeAll()
        pending.removeAll()
        pendingCount = 0
        seq = 0
        window = nil
        paused = false
        start()
    }

    private func append(_ raw: RawLog) {
        seq += 1
        let line = LogLine(seq: seq, raw: raw, receivedAt: Date())
        if paused {
            pending.append(line)
            if pending.count > maxLines { pending.removeFirst(pending.count - maxLines) }
            pendingCount = pending.count
            return
        }
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    var timeRange: ClosedRange<Date>? {
        guard let first = lines.first?.timestamp, let last = lines.last?.timestamp, first < last else { return nil }
        return first...last
    }
}

struct LogsView: View {
    let container: Container
    @EnvironmentObject var app: AppState
    @StateObject private var model: LogStreamModel
    @State private var enabled: Set<Severity> = Set(Severity.allCases)
    @State private var query = ""
    @State private var dedup = false

    init(container: Container) {
        self.container = container
        _model = StateObject(wrappedValue: LogStreamModel(ref: container.ref))
    }

    var body: some View {
        LogsContent(container: container, model: model,
                    enabled: $enabled, query: $query, dedup: $dedup,
                    expanded: false,
                    onToggleExpand: {
                        // Open in a real window and go native full-screen (a modal
                        // sheet can't fill the screen).
                        LogsWindowManager.open(container: container, app: app,
                                               enabled: enabled, query: query, dedup: dedup)
                    })
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

// LogsWindowRoot backs the standalone full-screen Logs window: its own live
// stream (a fresh tail of the same container) plus the full control bar, seeded
// from the tab's current filters.
struct LogsWindowRoot: View {
    let container: Container
    var onClose: () -> Void
    @StateObject private var model: LogStreamModel
    @State private var enabled: Set<Severity>
    @State private var query: String
    @State private var dedup: Bool

    init(container: Container, enabled: Set<Severity>, query: String, dedup: Bool, onClose: @escaping () -> Void) {
        self.container = container
        self.onClose = onClose
        _model = StateObject(wrappedValue: LogStreamModel(ref: container.ref))
        _enabled = State(initialValue: enabled)
        _query = State(initialValue: query)
        _dedup = State(initialValue: dedup)
    }

    var body: some View {
        LogsContent(container: container, model: model,
                    enabled: $enabled, query: $query, dedup: $dedup,
                    expanded: true, onToggleExpand: onClose)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

// LogsWindowManager opens the logs in a real, resizable window and enters native
// macOS full-screen — what "expand" should feel like (the in-tab sheet can't go
// full-screen). Holds a strong ref to the window controller until it closes.
@MainActor
enum LogsWindowManager {
    private static var controllers: [NSWindowController] = []

    static func open(container: Container, app: AppState, enabled: Set<Severity>, query: String, dedup: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Logs · \(container.name) · \(container.host)"
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior.insert(.fullScreenPrimary)

        let root = LogsWindowRoot(container: container, enabled: enabled, query: query, dedup: dedup,
                                  onClose: { [weak window] in window?.close() })
            .environmentObject(app)
        window.contentViewController = NSHostingController(rootView: AnyView(root))

        let wc = NSWindowController(window: window)
        controllers.append(wc)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                controllers.removeAll { $0.window === window }
            }
        }
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Enter native full-screen once the window is on screen.
        DispatchQueue.main.async { window.toggleFullScreen(nil) }
    }
}

// LogsContent renders the timeline + control bar + stream for a container's logs.
// Shared by the inline tab (LogsView) and the expanded window (ExpandedLogsView)
// so both have identical behavior and state — same buffer, filters, and zoom.
struct LogsContent: View {
    let container: Container
    @ObservedObject var model: LogStreamModel
    @Binding var enabled: Set<Severity>
    @Binding var query: String
    @Binding var dedup: Bool
    var expanded: Bool
    var onToggleExpand: () -> Void

    @EnvironmentObject var app: AppState
    @State private var showAnalysis = false

    private var levelCounts: [Severity: Int] {
        var d: [Severity: Int] = [:]
        for l in model.lines { d[l.level, default: 0] += 1 }
        return d
    }

    private var filtered: [LogLine] {
        model.lines.filter { line in
            if !enabled.contains(line.level) { return false }
            if let w = model.window, !w.contains(line.timestamp) { return false }
            if !query.isEmpty, !line.message.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    // Optionally fold consecutive identical lines into one row with a ×N count —
    // tames spammy logs (repeated health checks, request loops) so signal stands out.
    private var displayLines: [DisplayLine] {
        let base = filtered
        guard dedup else { return base.map { DisplayLine(id: $0.id, line: $0, count: 1) } }
        var out: [DisplayLine] = []
        for l in base {
            if let last = out.last, last.line.level == l.level, last.line.message == l.message {
                out[out.count - 1].count += 1
                out[out.count - 1].line = l   // keep the latest timestamp
            } else {
                out.append(DisplayLine(id: l.id, line: l, count: 1))
            }
        }
        return out
    }

    // The text handed to Claude: the visible lines (capped), newest-last.
    private var logsText: String {
        filtered.suffix(400).map { l in
            let lvl = l.level == .none ? "" : "[\(l.level.tag)] "
            return "\(l.clock) \(lvl)\(l.message)"
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            SeverityTimeline(lines: model.lines, range: model.timeRange, window: $model.window)
                .frame(height: expanded ? 110 : 78)
            controls
            Divider()
            LogStreamList(rows: displayLines, follow: model.follow && model.window == nil && !model.paused, query: query)
        }
        .sheet(isPresented: $showAnalysis) {
            LogAnalysisView(container: container, logsText: logsText)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            SeverityFilterMenu(enabled: $enabled, counts: levelCounts)

            Spacer()

            if app.cli.claudeAvailable {
                Button { showAnalysis = true } label: {
                    Label("Analyze", systemImage: "sparkles").font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.purple)
                .disabled(filtered.isEmpty)
                .help("Analyze these logs with Claude")
            }

            if model.window != nil {
                Button {
                    model.window = nil
                } label: {
                    Label("Reset zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                TextField("filter", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: expanded ? 220 : 150)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.background.secondary, in: Capsule())

            Toggle(isOn: $dedup) {
                Image(systemName: "arrow.triangle.merge")
            }
            .toggleStyle(.button).controlSize(.small)
            .help("Collapse repeated lines")

            Button { model.togglePause() } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    if model.paused && model.pendingCount > 0 {
                        Text("\(model.pendingCount)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                }
            }
            .controlSize(.small)
            .tint(model.paused ? .orange : .secondary)
            .help(model.paused ? "Resume (\(model.pendingCount) new)" : "Pause to read")

            Toggle(isOn: $model.follow) {
                Image(systemName: "arrow.down.to.line.compact")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Follow new lines")
            .disabled(model.paused)

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Reload logs")

            Text("\(filtered.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)

            Button(action: onToggleExpand) {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .controlSize(.small)
            .help(expanded ? "Collapse" : "Expand to a full window")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// SeverityFilterMenu collapses the four level filters into one compact dropdown
// (toggles + quick presets) so the control bar stays responsive. The label shows
// a colored dot per enabled level, or "All levels".
struct SeverityFilterMenu: View {
    @Binding var enabled: Set<Severity>
    let counts: [Severity: Int]
    private let levels: [Severity] = [.error, .warn, .info, .debug]

    private var isAll: Bool { levels.allSatisfy { enabled.contains($0) } && enabled.contains(.none) }

    var body: some View {
        Menu {
            ForEach(levels, id: \.self) { sev in
                Toggle(isOn: Binding(
                    get: { enabled.contains(sev) },
                    set: { on in if on { enabled.insert(sev) } else { enabled.remove(sev) } }
                )) {
                    Text("\(sev.tag)  (\(counts[sev] ?? 0))")
                }
            }
            Divider()
            Button("All levels") { enabled = Set(Severity.allCases) }
            Button("Errors & warnings") { enabled = [.error, .warn] }
            Button("Errors only") { enabled = [.error] }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12))
                label
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by severity")
    }

    @ViewBuilder private var label: some View {
        if isAll {
            Text("All levels").font(.system(size: 11, weight: .medium))
        } else if levels.allSatisfy({ !enabled.contains($0) }) {
            Text("None").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 3) {
                ForEach(levels.filter { enabled.contains($0) }, id: \.self) { sev in
                    Circle().fill(sev.color).frame(width: 7, height: 7)
                }
            }
        }
    }
}

// SeverityTimeline draws stacked-by-severity volume bars and supports drag-to-zoom.
struct SeverityTimeline: View {
    let lines: [LogLine]
    let range: ClosedRange<Date>?
    @Binding var window: ClosedRange<Date>?
    @State private var dragStart: CGFloat?
    @State private var dragCurrent: CGFloat?

    private let stackOrder: [Severity] = [.none, .debug, .info, .warn, .error]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let buckets = makeBuckets(lines, count: 90, range: range)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, sz in
                    draw(ctx, sz, buckets: buckets)
                    drawWindow(ctx, sz)
                    drawDrag(ctx, sz)
                }
                if lines.isEmpty {
                    Text("waiting for logs…")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                axis(size: size).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        if dragStart == nil { dragStart = clampX(v.startLocation.x, size.width) }
                        dragCurrent = clampX(v.location.x, size.width)
                    }
                    .onEnded { v in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard let s = dragStart, let r = range else { window = nil; return }
                        let e = clampX(v.location.x, size.width)
                        let a = min(s, e), b = max(s, e)
                        if b - a < 6 { window = nil; return } // tiny drag → reset
                        let span = r.upperBound.timeIntervalSince(r.lowerBound)
                        let t0 = r.lowerBound.addingTimeInterval(Double(a / size.width) * span)
                        let t1 = r.lowerBound.addingTimeInterval(Double(b / size.width) * span)
                        window = t0...t1
                    }
            )
        }
        .background(.background.secondary)
    }

    private func clampX(_ x: CGFloat, _ w: CGFloat) -> CGFloat { min(max(0, x), w) }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, buckets: [Bucket]) {
        guard !buckets.isEmpty else { return }
        let maxTotal = max(1, buckets.map(\.total).max() ?? 1)
        let bw = size.width / CGFloat(buckets.count)
        let pad: CGFloat = 6
        let usable = size.height - pad
        for (i, b) in buckets.enumerated() {
            var y = size.height
            let x = CGFloat(i) * bw
            for sev in stackOrder {
                let c = b.counts[sev] ?? 0
                if c == 0 { continue }
                let h = usable * CGFloat(c) / CGFloat(maxTotal)
                let rect = CGRect(x: x + 0.5, y: y - h, width: max(1, bw - 1), height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.6), with: .color(sev.color.opacity(0.92)))
                y -= h
            }
        }
    }

    private func drawWindow(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let w = window, let r = range else { return }
        let span = r.upperBound.timeIntervalSince(r.lowerBound)
        guard span > 0 else { return }
        let x0 = CGFloat(w.lowerBound.timeIntervalSince(r.lowerBound) / span) * size.width
        let x1 = CGFloat(w.upperBound.timeIntervalSince(r.lowerBound) / span) * size.width
        // Dim outside the window.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: x0, height: size.height)), with: .color(.black.opacity(0.28)))
        ctx.fill(Path(CGRect(x: x1, y: 0, width: size.width - x1, height: size.height)), with: .color(.black.opacity(0.28)))
        ctx.stroke(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                   with: .color(.accentColor.opacity(0.7)), lineWidth: 1)
    }

    private func drawDrag(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let s = dragStart, let c = dragCurrent else { return }
        let a = min(s, c), b = max(s, c)
        ctx.fill(Path(CGRect(x: a, y: 0, width: b - a, height: size.height)),
                 with: .color(.accentColor.opacity(0.2)))
    }

    private func axis(size: CGSize) -> some View {
        Group {
            if let r = range {
                HStack {
                    Text(DateFormatter.skyClock.string(from: r.lowerBound))
                    Spacer()
                    Text(DateFormatter.skyClock.string(from: r.upperBound))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 3)
            }
        }
    }
}

struct Bucket {
    var counts: [Severity: Int] = [:]
    var total: Int = 0
}

func makeBuckets(_ lines: [LogLine], count: Int, range: ClosedRange<Date>?) -> [Bucket] {
    guard count > 0 else { return [] }
    var buckets = Array(repeating: Bucket(), count: count)
    guard let r = range else {
        // No spread (≤1 distinct time): drop everything into the last bucket.
        for l in lines {
            buckets[count - 1].counts[l.level, default: 0] += 1
            buckets[count - 1].total += 1
        }
        return buckets
    }
    let span = r.upperBound.timeIntervalSince(r.lowerBound)
    for l in lines {
        let frac = span > 0 ? l.timestamp.timeIntervalSince(r.lowerBound) / span : 1
        var idx = Int(frac * Double(count))
        if idx < 0 { idx = 0 }
        if idx >= count { idx = count - 1 }
        buckets[idx].counts[l.level, default: 0] += 1
        buckets[idx].total += 1
    }
    return buckets
}

// LogJSON memoizes the "is this message a JSON object?" pretty-print, so scrolling
// doesn't re-parse the same lines. Returns the indented JSON or nil.
enum LogJSON {
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    static func pretty(_ message: String) -> String? {
        if let c = cache[message] { return c }
        var result: String? = nil
        let s = LogSyntax.stripANSI(message).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("{"), s.hasSuffix("}"), s.count > 8,
           let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            result = str
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[message] = result
        return result
    }
}

// A line to render, with a fold count when consecutive duplicates are collapsed.
struct DisplayLine: Identifiable {
    let id: Int          // stable: the first occurrence's seq
    var line: LogLine
    var count: Int
}

struct LogStreamList: View {
    let rows: [DisplayLine]
    let follow: Bool
    var query: String = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        LogRow(line: row.line, count: row.count, query: query).id(row.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: rows.last?.id) { _, _ in
                if follow { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(bottomID, anchor: .bottom) } }
            }
            .onChange(of: rows.last?.count) { _, _ in
                if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    private let bottomID = "sky.logs.bottom"
}

struct LogRow: View {
    let line: LogLine
    var count: Int = 1
    var query: String = ""
    @State private var expanded = false

    // A pretty-printed form when the message is a JSON object, else nil (memoized).
    private var prettyJSON: String? { LogJSON.pretty(line.message) }

    // Structured rendering per recognized format (GIN/NestJS/access-log); plain
    // lines keep the generic syntax highlighter.
    @ViewBuilder private var messageContent: some View {
        switch LogFormat.classify(line.message) {
        case .http(let h):
            HTTPLogContent(http: h, query: query)
        case .leveled(let l):
            LeveledLogContent(log: l, query: query)
        case .plain:
            Text(LogSyntax.attributed(line.message, query: query.isEmpty ? nil : query))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(expanded ? 1 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        let json = prettyJSON
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Text(line.clock)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                if line.level != .none {
                    Text(line.level.tag)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(line.level.color)
                        .frame(width: 44, alignment: .leading)
                } else {
                    Spacer().frame(width: 44)
                }
                if json != nil {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                messageContent
                if count > 1 {
                    Text("×\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            if expanded, let json {
                Text(LogSyntax.attributed(json))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 117)
                    .padding(.trailing, 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Rectangle().fill(line.level.color).frame(width: 3)
        }
        .contextMenu {
            Button("Copy line") { copyToPasteboard("\(line.clock) \(LogSyntax.stripANSI(line.message))") }
            Button("Copy message") { copyToPasteboard(LogSyntax.stripANSI(line.message)) }
            if let json { Button("Copy JSON (pretty)") { copyToPasteboard(json) } }
        }
    }
}
