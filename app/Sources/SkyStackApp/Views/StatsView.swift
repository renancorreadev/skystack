import SwiftUI

@MainActor
final class StatsModel: ObservableObject {
    @Published var current: StatsSample?
    @Published var cpuHistory: [Double] = []

    private let cli = SkyCLI()
    private let ref: String
    private var task: Task<Void, Never>?
    private var cancel: (() -> Void)?
    private let maxPoints = 60

    init(ref: String) { self.ref = ref }

    func start() {
        guard task == nil else { return }
        let (stream, cancel) = cli.streamStats(ref: ref)
        self.cancel = cancel
        task = Task { [weak self] in
            for await s in stream {
                guard let self else { break }
                self.current = s
                self.cpuHistory.append(s.cpu)
                if self.cpuHistory.count > self.maxPoints { self.cpuHistory.removeFirst() }
            }
        }
    }

    func stop() { cancel?(); task?.cancel(); task = nil }
}

struct StatsView: View {
    let container: Container
    @StateObject private var model: StatsModel

    init(container: Container) {
        self.container = container
        _model = StateObject(wrappedValue: StatsModel(ref: container.ref))
    }

    private func mem(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !container.isRunning {
                    Placeholder(icon: "pause.circle", text: "Container is not running")
                        .frame(height: 200)
                } else if let s = model.current {
                    HStack(spacing: 16) {
                        StatGauge(title: "CPU", value: String(format: "%.1f%%", s.cpu), percent: s.cpu / 100, color: .blue)
                        StatGauge(title: "Memory", value: mem(s.memUsed),
                                  subtitle: s.memLimit > 0 ? "of \(mem(s.memLimit))" : nil,
                                  percent: s.memPercent / 100, color: .green)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CPU history").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Sparkline(values: model.cpuHistory, color: .blue).frame(height: 70)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            InfoRow(label: "Net RX", value: mem(s.netRx))
                            InfoRow(label: "Net TX", value: mem(s.netTx))
                            if s.memLimit > 0 { InfoRow(label: "Mem limit", value: mem(s.memLimit)) }
                        }
                    }
                } else {
                    ProgressView("collecting…").frame(height: 200)
                }
                Spacer()
            }
            .padding(18)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

struct StatGauge: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    let percent: Double
    let color: Color
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                if let sub = subtitle { Text(sub).font(.caption).foregroundStyle(.tertiary) }
                ProgressView(value: min(max(percent, 0), 1)).tint(color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard values.count > 1 else { return }
                let maxV = max(values.max() ?? 1, 1)
                let stepX = size.width / CGFloat(values.count - 1)
                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = size.height - CGFloat(v / maxV) * size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.5)
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(color.opacity(0.12)))
            }
        }
    }
}
