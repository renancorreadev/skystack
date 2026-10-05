import Foundation
import Virtualization

/// Describes everything needed to boot the SkyStack Linux VM. Paths point at a
/// custom kernel + initramfs and a root disk image produced by the (separate)
/// image-builder; see README for how to obtain them.
struct VMSpec {
    var kernelURL: URL
    var initialRamdiskURL: URL?
    var rootDiskURL: URL
    var cpuCount: Int
    var memoryBytes: UInt64
    /// Host directory exposed to the guest over virtiofs (fast bind mounts).
    var sharedDirectoryURL: URL?
    /// Kernel command line. Console on hvc0 keeps boot output on our serial pipe.
    /// Quiet by default; `--verbose` swaps in `ignore_loglevel` for bring-up.
    var kernelCommandLine: String = "console=hvc0 root=/dev/vda rw quiet"
    /// Enable a Rosetta share so the guest can run linux/amd64 images on Apple
    /// Silicon without QEMU (the OrbStack approach).
    var enableRosetta: Bool = true

    static func defaultSpec(kernel: URL, initrd: URL?, rootDisk: URL, share: URL?) -> VMSpec {
        let hostCPUs = ProcessInfo.processInfo.processorCount
        let hostMem = ProcessInfo.processInfo.physicalMemory
        return VMSpec(
            kernelURL: kernel,
            initialRamdiskURL: initrd,
            rootDiskURL: rootDisk,
            cpuCount: max(1, min(hostCPUs - 2, 8)),
            // Start modest; a production runtime grows this dynamically.
            memoryBytes: min(hostMem / 2, 2 * 1024 * 1024 * 1024),
            sharedDirectoryURL: share
        )
    }
}

enum VMConfigError: Error, CustomStringConvertible {
    case missingFile(String)
    case validation(String)

    var description: String {
        switch self {
        case .missingFile(let p): return "required file not found: \(p)"
        case .validation(let m): return "invalid VM configuration: \(m)"
        }
    }
}

/// Builds and validates a `VZVirtualMachineConfiguration` from a `VMSpec`.
enum VMConfigurationBuilder {
    static func build(_ spec: VMSpec) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        guard fm.fileExists(atPath: spec.kernelURL.path) else {
            throw VMConfigError.missingFile(spec.kernelURL.path)
        }
        guard fm.fileExists(atPath: spec.rootDiskURL.path) else {
            throw VMConfigError.missingFile(spec.rootDiskURL.path)
        }

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = spec.cpuCount
        config.memorySize = spec.memoryBytes

        // --- Boot loader: direct Linux kernel boot (no firmware overhead) ---
        let bootLoader = VZLinuxBootLoader(kernelURL: spec.kernelURL)
        bootLoader.commandLine = spec.kernelCommandLine
        if let initrd = spec.initialRamdiskURL {
            bootLoader.initialRamdiskURL = initrd
        }
        config.bootLoader = bootLoader

        // --- Console: bridge guest serial to host stdin/stdout ---
        config.serialPorts = [makeConsole()]

        // --- Root block device ---
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: spec.rootDiskURL,
            readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // --- Networking: user-mode NAT (host ⇄ guest, no extra privileges) ---
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        // --- Entropy + memory balloon + vsock (control channel to the guest) ---
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // --- virtiofs share for fast Mac⇄Linux bind mounts ---
        var fsDevices: [VZDirectorySharingDeviceConfiguration] = []
        if let share = spec.sharedDirectoryURL {
            let dir = VZSharedDirectory(url: share, readOnly: false)
            let singleShare = VZSingleDirectoryShare(directory: dir)
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "skyshare")
            fsDevice.share = singleShare
            fsDevices.append(fsDevice)
        }

        // --- Rosetta: run linux/amd64 binaries on Apple Silicon ---
        if spec.enableRosetta {
            if let rosetta = try makeRosettaDevice() {
                fsDevices.append(rosetta)
            }
        }
        config.directorySharingDevices = fsDevices

        try config.validate()
        return config
    }

    private static func makeConsole() -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        let attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        console.attachment = attachment
        return console
    }

    /// Returns a Rosetta directory-sharing device when Rosetta is installed and
    /// supported on this host; nil otherwise (caller treats x86 as QEMU/binfmt).
    private static func makeRosettaDevice() throws -> VZDirectorySharingDeviceConfiguration? {
        let availability = VZLinuxRosettaDirectoryShare.availability
        switch availability {
        case .installed:
            let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            rosetta.share = try VZLinuxRosettaDirectoryShare()
            return rosetta
        case .notInstalled, .notSupported:
            return nil
        @unknown default:
            return nil
        }
    }
}
