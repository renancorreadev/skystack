import SwiftUI
import AppKit

@MainActor
final class FilesModel: ObservableObject {
    @Published var path = "/"
    @Published var entries: [FileEntry] = []
    @Published var loading = false
    @Published var error: String?

    let cli = SkyCLI()
    let ref: String
    init(ref: String) { self.ref = ref }

    func load(_ dir: String) {
        loading = true
        error = nil
        Task {
            do {
                let listing = try await cli.files(ref: ref, path: dir)
                path = listing.path
                entries = listing.entries ?? []
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            loading = false
        }
    }

    func up() {
        let parent = (path as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }
}

struct FilesView: View {
    let container: Container
    @StateObject private var model: FilesModel
    @State private var viewing: FileContent?
    @State private var loadingFile = false

    init(container: Container) {
        self.container = container
        _model = StateObject(wrappedValue: FilesModel(ref: container.ref))
    }

    private func open(_ entry: FileEntry) {
        if entry.isDir { model.load(entry.path); return }
        loadingFile = true
        Task {
            viewing = try? await model.cli.fileContent(ref: container.ref, path: entry.path)
            loadingFile = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.up() } label: { Image(systemName: "chevron.up") }
                    .disabled(model.path == "/")
                Text(model.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.load(model.path) } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.bar)
            Divider()

            if let e = model.error {
                Placeholder(icon: "exclamationmark.triangle", text: e)
            } else {
                List {
                    ForEach(model.entries) { entry in
                        Button { open(entry) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                                    .foregroundStyle(entry.isDir ? Color.blue : .secondary)
                                    .font(.system(size: 12))
                                Text(entry.name).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Image(systemName: entry.isDir ? "chevron.right" : "eye")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if loadingFile { ProgressView().controlSize(.small).padding(6).background(.regularMaterial, in: Capsule()) }
        }
        .sheet(item: $viewing) { FileContentSheet(file: $0) }
        .onAppear { if model.entries.isEmpty { model.load("/") } }
    }
}

struct FileContentSheet: View {
    let file: FileContent
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text((file.path as NSString).lastPathComponent).font(.headline)
                if file.truncated { Tag(text: "truncated", color: .orange) }
                Spacer()
                Button { copy() } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                Button("Done") { dismiss() }
            }
            .padding(12).background(.bar)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(file.content.isEmpty ? "(empty or binary)" : file.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 620, height: 500)
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.content, forType: .string)
    }
}
