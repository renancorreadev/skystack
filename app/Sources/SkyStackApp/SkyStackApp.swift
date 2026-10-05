import SwiftUI
import AppKit

// When run as a bare SwiftPM executable (`swift run`), macOS may launch the app
// as a background accessory and never bring its window forward. This delegate
// forces a regular, activated app so the window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SkyStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 940, minHeight: 580)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { app.paletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        Window("Compose Graph", id: "compose") {
            ComposeView()
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("SkyStack", systemImage: "shippingbox.fill") {
            MenuBarView()
                .environmentObject(app)
        }
        .menuBarExtraStyle(.window)
    }
}
