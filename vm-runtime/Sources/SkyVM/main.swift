import Foundation
import Virtualization

// SkyVM — boots the SkyStack local Linux VM (MVP 2).
//
// Usage:
//   SkyVM --kernel <vmlinux> --rootfs <disk.img> [--initrd <initrd>] \
//         [--share <hostDir>] [--cpus N] [--memory-gib N]
//
// Requires the `com.apple.security.virtualization` entitlement and a signed
// binary to actually start a VM (see README). Configuration build + validation
// runs without entitlements, which is what CI exercises.

struct Args {
    var kernel: String?
    var rootfs: String?
    var initrd: String?
    var share: String?
    var shareMount: String?
    var cpus: Int?
    var memoryGiB: Int?
    var validateOnly = false
    var dockerSocket: String?
    var vsockPort: UInt32 = 2375
    var verbose = false
    var k8s = false
}

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        func next() -> String? { i += 1; return i < argv.count ? argv[i] : nil }
        switch arg {
        case "--kernel": a.kernel = next()
        case "--rootfs": a.rootfs = next()
        case "--initrd": a.initrd = next()
        case "--share": a.share = next()
        case "--share-mount": a.shareMount = next()
        case "--cpus": a.cpus = next().flatMap { Int($0) }
        case "--memory-gib": a.memoryGiB = next().flatMap { Int($0) }
        case "--docker-socket": a.dockerSocket = next()
        case "--vsock-port": a.vsockPort = next().flatMap { UInt32($0) } ?? 2375
        case "--verbose": a.verbose = true
        case "--k8s": a.k8s = true
        case "--validate-only": a.validateOnly = true
        default: break
        }
        i += 1
    }
    return a
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

let args = parseArgs(Array(CommandLine.arguments.dropFirst()))

guard let kernel = args.kernel, let rootfs = args.rootfs else {
    die("--kernel and --rootfs are required (run with --validate-only to dry-run config)")
}

var spec = VMSpec.defaultSpec(
    kernel: URL(fileURLWithPath: kernel),
    initrd: args.initrd.map { URL(fileURLWithPath: $0) },
    rootDisk: URL(fileURLWithPath: rootfs),
    share: args.share.map { URL(fileURLWithPath: $0) }
)
if let c = args.cpus { spec.cpuCount = c }
if let g = args.memoryGiB { spec.memoryBytes = UInt64(g) * 1024 * 1024 * 1024 }
if args.verbose { spec.kernelCommandLine = "console=hvc0 root=/dev/vda rw ignore_loglevel" }
// Tell the guest where to mount the virtiofs share (consumed by skyvm-share).
if let mountpoint = args.shareMount, args.share != nil {
    spec.kernelCommandLine += " skyvm.share=\(mountpoint)"
}
// Opt into the in-VM Kubernetes (k3s) — the skyvm-k8s service gates on this.
if args.k8s {
    spec.kernelCommandLine += " skyvm.k8s=1"
}

do {
    let config = try VMConfigurationBuilder.build(spec)
    FileHandle.standardError.write(Data(
        "[SkyVM] configuration valid: \(spec.cpuCount) vCPU, \(spec.memoryBytes / (1024*1024)) MiB, rosetta=\(spec.enableRosetta)\n".utf8))

    if args.validateOnly {
        FileHandle.standardError.write(Data("[SkyVM] --validate-only: not booting\n".utf8))
        exit(0)
    }

    let runner = VMRunner()
    var forwarders: [VsockForwarder] = []
    var portForwarder: PortForwarder?
    var dnsForwarder: DnsForwarder?
    var caForwarder: CAForwarder?
    var k8sForwarder: K8sForwarder?

    // Never let a write to a half-closed socket kill the process — the vsock
    // forwarder routinely writes to peers that have already gone away.
    signal(SIGPIPE, SIG_IGN)

    // Forward Ctrl-C to a graceful guest stop.
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { runner.requestStop() }
    sigint.resume()
    signal(SIGINT, SIG_IGN)

    Task {
        do {
            try await runner.run(config)
            FileHandle.standardError.write(Data("[SkyVM] guest booting…\n".utf8))

            // Expose the in-VM Docker engine on the Mac over vsock.
            if let sockPath = args.dockerSocket {
                let dir = (sockPath as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let forwarder = VsockForwarder(runner: runner, guestPort: args.vsockPort, socketPath: sockPath)
                do {
                    try forwarder.start()
                    forwarders.append(forwarder)
                } catch {
                    FileHandle.standardError.write(Data("[SkyVM] docker socket forward failed: \(error)\n".utf8))
                }
            }

            // Automatically forward published container ports to localhost, and
            // forward *.sky.local DNS to the guest resolver.
            let guestInfo = GuestInfo()
            let pf = PortForwarder(runner: runner, guestInfo: guestInfo)
            pf.start()
            portForwarder = pf
            let dns = DnsForwarder(guest: guestInfo)
            dns.start()
            dnsForwarder = dns

            // Push the local HTTPS CA into the guest (if generated on the Mac),
            // enabling the in-VM reverse proxy to serve https://*.sky.local.
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            if let ca = CAForwarder(runner: runner, caDir: home + "/.skystack/ca") {
                ca.start()
                caForwarder = ca
            } else {
                FileHandle.standardError.write(Data("[SkyVM] no local CA found — HTTPS disabled (run `skystack vm trust-ca`)\n".utf8))
            }

            // Forward the in-VM Kubernetes API to a stable localhost port.
            if args.k8s {
                let k8s = K8sForwarder(guest: guestInfo)
                k8s.start()
                k8sForwarder = k8s
            }
        } catch {
            die("failed to start VM: \(error)")
        }
    }
    // Hand control to the run loop; delegate callbacks call exit().
    RunLoop.main.run()
} catch {
    die("\(error)")
}
