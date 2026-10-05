// swift-tools-version:5.9
import PackageDescription

// SkyStack.app — the native macOS front-end (MVP 6).
//
// A SwiftUI app that consumes the Go core through the `skystack` CLI's JSON API
// (`skystack api …`). No Electron, no embedded web view — pure AppKit/SwiftUI,
// the same "native, fast, beautiful" bar OrbStack sets.
let package = Package(
    name: "SkyStackApp",
    platforms: [
        .macOS(.v14) // NavigationSplitView, MenuBarExtra(.window), Canvas, .scrollPosition
    ],
    dependencies: [
        // Mature xterm-compatible terminal emulator for the embedded PTY shell.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "SkyStackApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/SkyStackApp",
            resources: [
                // Real brand logos (devicon/iconify), bundled for offline rendering.
                .copy("Resources/brand-icons")
            ]
        )
    ]
)
