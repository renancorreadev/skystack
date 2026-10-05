import SwiftUI

// RunContainerSheet creates a container from an image (optionally prefilled).
struct RunContainerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State var image: String = ""
    @State private var name = ""
    @State private var ports = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run a container").font(.headline)
            field("Image", "nginx:alpine", $image)
            field("Name (optional)", "my-app", $name)
            field("Ports (optional)", "8080:80, 5432:5432", $ports)
            if let e = error {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(busy ? "Running…" : "Run") { runIt() }
                    .buttonStyle(.borderedProminent)
                    .disabled(image.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: binding).textFieldStyle(.roundedBorder)
        }
    }

    private func runIt() {
        busy = true; error = nil
        let portList = ports.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        Task {
            do {
                try await app.runContainer(image: image, name: name, ports: portList)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                busy = false
            }
        }
    }
}
