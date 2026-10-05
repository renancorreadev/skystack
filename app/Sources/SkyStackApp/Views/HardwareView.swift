import SwiftUI
import Charts

// HardwareModel streams aggregate hardware usage for a host and keeps short
// history for the charts.
@MainActor
final class HardwareModel: ObservableObject {
    @Published var sample: HardwareSample?
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var netRxRate: Double = 0
    @Published var netTxRate: Double = 0

    private let cli = SkyCLI()
    private var task: Task<Void, Never>?
    private var cancel: (() -> Void)?
    private var host: String?
    private var prevRx: Int64?
    private var prevTx: Int64?
    let interval = 2.0
    private let maxPoints = 60

    func start(host: String) {
        if host == self.host, task != nil { return }
        stop()
        self.host = host
        sample = nil; cpuHistory = []; memHistory = []; prevRx = nil; prevTx = nil
        let (stream, c) = cli.streamHardware(host: host)
        cancel = c
        task = Task { [weak self] in
            for await s in stream {
                guard let self else { break }
                self.ingest(s)
            }
        }
    }

    private func ingest(_ s: HardwareSample) {
        sample = s
        cpuHistory.append(min(max(s.cpu, 0), 100))
        memHistory.append(min(max(s.memPercent, 0), 100))
        if cpuHistory.count > maxPoints { cpuHistory.removeFirst() }
        if memHistory.count > maxPoints { memHistory.removeFirst() }
        if let pr = prevRx, s.netRx >= pr { netRxRate = Double(s.netRx - pr) / interval }
        if let pt = prevTx, s.netTx >= pt { netTxRate = Double(s.netTx - pt) / interval }
        prevRx = s.netRx; prevTx = s.netTx
    }

    func stop() { cancel?(); task?.cancel(); task = nil; host = nil }
}

struct HardwareView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = HardwareModel()

    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                systemHeader
                if let s = model.sample {
                    LazyVGrid(columns: cols, spacing: 14) {
                        MetricHero(title: "CPU", icon: "cpu", tint: .blue,
                                   percent: s.cpu, valueLabel: String(format: "%.1f%%", s.cpu),
                                   subtitle: "across \(s.cpus) core\(s.cpus == 1 ? "" : "s")",
                                   history: model.cpuHistory)
                        MetricHero(title: "Memory", icon: "memorychip", tint: .green,
                                   percent: s.memPercent, valueLabel: "\(bytes(s.memUsed)) / \(bytes(s.memTotal))",
                                   subtitle: String(format: "%.1f%% of total", s.memPercent),
                                   history: model.memHistory)
                    }
                    UsageHistoryChart(cpu: model.cpuHistory, mem: model.memHistory, interval: model.interval)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        MiniStat(title: "Running", value: "\(s.running)", sub: "of \(s.containers)", icon: "shippingbox.fill", tint: .blue)
                        MiniStat(title: "Images", value: "\(s.images)", sub: "on host", icon: "square.stack.3d.up.fill", tint: .indigo)
                        MiniStat(title: "Disk", value: s.diskUsed > 0 ? bytes(s.diskUsed) : "…", sub: "docker", icon: "internaldrive.fill", tint: .teal)
                        MiniStat(title: "Network", value: rate(model.netRxRate), sub: "↑ \(rate(model.netTxRate))", icon: "arrow.up.arrow.down.circle.fill", tint: .orange)
                    }
                    LazyVGrid(columns: cols, spacing: 14) {
                        TopChart(title: "Top CPU", icon: "cpu", tint: .blue, items: s.topCpu,
                                 metric: { $0.cpu }, label: { String(format: "%.1f%%", $0.cpu) })
                        TopChart(title: "Top memory", icon: "memorychip", tint: .green, items: s.topMem,
                                 metric: { Double($0.mem) }, label: { bytes($0.mem) })
                    }
                } else if app.hostOffline {
                    OfflineState(host: app.selectedHost, error: app.selectedHostError,
                                 retry: { Task { await app.refreshResources() } },
                                 vmStart: app.vmStartAction)
                        .frame(minHeight: 240)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading hardware on \(app.selectedHost)…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(18)
        }
        .background(.background)
        .navigationTitle("Hardware")
        .navigationSubtitle(app.selectedHost)
        .onAppear { model.start(host: app.selectedHost) }
        .onChange(of: app.selectedHost) { _, h in model.start(host: h) }
        .onDisappear { model.stop() }
    }

    private var systemHeader: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: hostIcon(app.selectedHostInfo?.kind ?? "local"))
                    .font(.system(size: 26)).foregroundStyle(.tint).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.selectedHost).font(.system(size: 17, weight: .semibold))
                    if let s = model.sample {
                        Text([s.os, s.arch].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if let k = s.kernel { Label(k, systemImage: "cpu") }
                            if let v = s.serverVersion { Label("Docker \(v)", systemImage: "shippingbox") }
                        }
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    } else {
                        Text("Connecting…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }
    private func rate(_ bps: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(max(0, bps)), countStyle: .memory) + "/s" }
}

// MetricHero: a native Gauge ring + the live value + a Swift Charts area history.
struct MetricHero: View {
    let title: String
    let icon: String
    let tint: Color
    let percent: Double          // 0–100, host-wide
    let valueLabel: String
    let subtitle: String
    let history: [Double]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(tint)
                    Text(title).font(.headline)
                    Spacer()
                }
                HStack(spacing: 16) {
                    Gauge(value: min(max(percent, 0), 100), in: 0...100) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(Int(percent.rounded()))").font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(tint)
                    .scaleEffect(1.25)
                    .frame(width: 70, height: 70)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(valueLabel).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        AreaHistory(values: history, tint: tint).frame(height: 38)
                    }
                }
            }
        }
    }
}

// AreaHistory is a smooth gradient area chart of the last N readings (0–100%).
struct AreaHistory: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { idx, v in
            AreaMark(x: .value("t", idx), y: .value("%", v))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.linearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", idx), y: .value("%", v))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

// HistorySample is one point of the combined CPU/Mem history, with a relative
// time `t` (seconds ago, ≤ 0; the newest reading is 0 = "now").
struct HistorySample: Identifiable {
    let id: Int
    let t: Double
    let cpu: Double
    let mem: Double
}

// UsageHistoryChart is the larger, interactive CPU + Memory history: a real time
// axis (seconds-ago) and a hover tooltip (chartOverlay → vertical rule + the CPU/
// Mem values at the hovered instant). Both series share the 0–100% y-scale.
struct UsageHistoryChart: View {
    let cpu: [Double]
    let mem: [Double]
    let interval: Double
    @State private var selected: HistorySample?

    private var data: [HistorySample] {
        let n = max(cpu.count, mem.count)
        guard n > 1 else { return [] }
        let last = n - 1
        return (0..<n).map { i in
            HistorySample(id: i, t: Double(i - last) * interval,
                          cpu: i < cpu.count ? cpu[i] : 0,
                          mem: i < mem.count ? mem[i] : 0)
        }
    }
    private var span: Int { data.first.map { Int(-$0.t) } ?? 0 }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    legend("CPU", "cpu", .blue)
                    legend("Memory", "memorychip", .green)
                    Spacer()
                    readout
                }
                if data.isEmpty {
                    Text("Collecting history…").font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    chart.frame(height: 150)
                }
            }
        }
    }

    private func legend(_ label: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var readout: some View {
        if let s = selected {
            Text("\(Int(-s.t))s ago · CPU \(Int(s.cpu.rounded()))% · Mem \(Int(s.mem.rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.primary)
        } else if span > 0 {
            Text("last \(span)s").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(data) { p in
                AreaMark(x: .value("t", p.t), y: .value("%", p.cpu), series: .value("s", "CPU"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(colors: [.blue.opacity(0.25), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", p.t), y: .value("%", p.cpu), series: .value("s", "CPU"))
                    .interpolationMethod(.catmullRom).foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 1.8))
                LineMark(x: .value("t", p.t), y: .value("%", p.mem), series: .value("s", "Memory"))
                    .interpolationMethod(.catmullRom).foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            if let s = selected {
                RuleMark(x: .value("t", s.t))
                    .foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("t", s.t), y: .value("%", s.cpu)).foregroundStyle(.blue).symbolSize(60)
                PointMark(x: .value("t", s.t), y: .value("%", s.mem)).foregroundStyle(.green).symbolSize(60)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                AxisGridLine().foregroundStyle(.separator.opacity(0.4))
                AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").font(.system(size: 9)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 30)) { v in
                AxisGridLine().foregroundStyle(.separator.opacity(0.3))
                AxisValueLabel {
                    if let t = v.as(Double.self) { Text(t == 0 ? "now" : "\(Int(t))s").font(.system(size: 9)) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let plot = proxy.plotFrame else { return }
                            let x = loc.x - geo[plot].origin.x
                            if let t: Double = proxy.value(atX: x) {
                                selected = data.min(by: { abs($0.t - t) < abs($1.t - t) })
                            }
                        case .ended:
                            selected = nil
                        }
                    }
            }
        }
    }
}

struct MiniStat: View {
    let title: String
    let value: String
    let sub: String
    let icon: String
    let tint: Color
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(tint).font(.system(size: 12))
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// TopChart shows the heaviest containers as a native horizontal bar chart.
struct TopChart: View {
    let title: String
    let icon: String
    let tint: Color
    let items: [ContainerUsage]
    let metric: (ContainerUsage) -> Double
    let label: (ContainerUsage) -> String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(tint).font(.system(size: 12))
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    Text("No running containers").font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Chart(items) { it in
                        BarMark(
                            x: .value("usage", metric(it)),
                            y: .value("name", it.name)
                        )
                        .foregroundStyle(tint.gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                            Text(label(it)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel(horizontalSpacing: 6).font(.system(size: 11))
                        }
                    }
                    .chartXScale(domain: 0...(items.map(metric).max().map { $0 * 1.25 } ?? 1))
                    .frame(height: CGFloat(items.count) * 30 + 6)
                }
            }
        }
    }
}
