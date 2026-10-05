import Foundation
@preconcurrency import Virtualization

/// Owns the lifecycle of a single `VZVirtualMachine`: start, run, and graceful
/// stop. Virtualization requires all VM interaction on one serial queue, so we
/// pin everything to a dedicated dispatch queue and bridge to async/await.
final class VMRunner: NSObject, VZVirtualMachineDelegate {
    private let queue = DispatchQueue(label: "dev.skystack.vm")
    private var machine: VZVirtualMachine?

    func run(_ config: VZVirtualMachineConfiguration) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let vm = VZVirtualMachine(configuration: config, queue: self.queue)
                vm.delegate = self
                self.machine = vm
                vm.start { result in
                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Requests a graceful guest shutdown (ACPI power button equivalent).
    func requestStop() {
        queue.async {
            guard let vm = self.machine, vm.canRequestStop else { return }
            try? vm.requestStop()
        }
    }

    /// Opens a new vsock connection to a port the guest agent is listening on.
    /// All VZVirtualMachine access must happen on the VM queue, so the connect
    /// is dispatched there and the result delivered via completion.
    func connectVsock(port: UInt32, completion: @escaping (Result<VZVirtioSocketConnection, Error>) -> Void) {
        queue.async {
            guard let device = self.machine?.socketDevices.first as? VZVirtioSocketDevice else {
                completion(.failure(VMConfigError.validation("no vsock device on the VM")))
                return
            }
            device.connect(toPort: port) { result in
                switch result {
                case .success(let conn): completion(.success(conn))
                case .failure(let err): completion(.failure(err))
                }
            }
        }
    }

    // MARK: VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        FileHandle.standardError.write(Data("\n[SkyVM] guest stopped cleanly\n".utf8))
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("\n[SkyVM] guest stopped with error: \(error)\n".utf8))
        exit(1)
    }
}
