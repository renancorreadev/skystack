import SwiftUI
import AppKit

// InspectSheet shows the raw Docker inspect JSON for any resource kind, with a
// line filter and copy — a universal viewer backed by `skystack api inspect`.
struct InspectSheet: View {
    let kind: String        // container | image | volume | network
    let host: String
    let id: String
    let title: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var json = ""
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""

    private var lines: [String] {
        let all = json.components(separatedBy: "\n")
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.tint)
                Text("Inspect · \(title)").font(.headline).lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                    TextField("filter lines", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).frame(width: 150)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.background.secondary, in: Capsule())
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy JSON").disabled(json.isEmpty)
                Button("Done") { dismiss() }
            }
            .padding(12)
            .background(.bar)
            Divider()

            if loading {
                VStack(spacing: 10) { ProgressView(); Text("Inspecting…").font(.callout).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(width: 640, height: 600)
        .onAppear(perform: load)
    }

    private func load() {
        loading = true; error = nil
        Task {
            do { json = try await app.cli.inspect(kind: kind, host: host, id: id) }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            loading = false
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }
}

// ConsumersSection shows which containers use a volume or network (Batch C).
struct ConsumersSection: View {
    let kind: String        // volume | network
    let host: String
    let name: String
    @EnvironmentObject var app: AppState
    @State private var consumers: [String] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Used by").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if !loaded {
                ProgressView().controlSize(.small)
            } else if consumers.isEmpty {
                Text("No containers").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(consumers, id: \.self) { c in
                    Button {
                        app.section = .containers
                        if let match = app.containers.first(where: { $0.name == c }) {
                            app.containerSelection = match.id
                        }
                    } label: {
                        HStack(spacing: 6) {
                            StateDot(color: stateColor(app.containers.first(where: { $0.name == c })?.state ?? "exited"), size: 7)
                            Text(c).font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: name) { await load() }
    }

    private func load() async {
        loaded = false
        consumers = (try? await app.cli.consumers(kind: kind, host: host, name: name)) ?? []
        loaded = true
    }
}
