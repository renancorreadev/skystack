import Foundation

/// Thread-safe holder for the guest's current IP, written by the PortForwarder
/// (which learns it over the netinfo vsock channel) and read by the DnsForwarder.
final class GuestInfo {
    private let lock = NSLock()
    private var _ip = ""

    var ip: String {
        lock.lock()
        defer { lock.unlock() }
        return _ip
    }

    func setIP(_ value: String) {
        lock.lock()
        _ip = value
        lock.unlock()
    }
}
