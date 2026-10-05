// swift-tools-version:5.9
import PackageDescription

// SkyVM — the SkyStack local runtime (MVP 2).
//
// A thin, native wrapper over Apple's Virtualization.framework that boots a
// minimal Linux VM to host the container engine, mirroring OrbStack's
// "one lightweight VM, many environments" model. The Go core (MVP 1) talks to
// the Docker engine running inside this VM over a forwarded socket.
let package = Package(
    name: "SkyVM",
    platforms: [
        .macOS(.v13) // Virtualization Linux features + Rosetta directory share
    ],
    targets: [
        .executableTarget(
            name: "SkyVM",
            path: "Sources/SkyVM"
        )
    ]
)
