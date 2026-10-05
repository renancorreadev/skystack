import Foundation

/// Forwards DNS over UDP from a stable localhost port to the guest's DNS server
/// (which resolves *.sky.local → container IPs). macOS points
/// /etc/resolver/sky.local at 127.0.0.1:localPort, so the resolver target stays
/// fixed even though the guest IP is DHCP-dynamic.
final class DnsForwarder {
    private let guest: GuestInfo
    private let localPort: UInt16
    private let guestPort: UInt16
    private let queue = DispatchQueue(label: "dev.skystack.dns", attributes: .concurrent)
    private var fd: Int32 = -1

    init(guest: GuestInfo, localPort: UInt16 = 5354, guestPort: UInt16 = 53) {
        self.guest = guest
        self.localPort = localPort
        self.guestPort = guestPort
    }

    func start() {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = localPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(s)
            FileHandle.standardError.write(Data("[SkyVM] DNS bind 127.0.0.1:\(localPort) failed\n".utf8))
            return
        }
        fd = s
        FileHandle.standardError.write(Data("[SkyVM] DNS forwarder 127.0.0.1:\(localPort) → guest:\(guestPort) (*.sky.local)\n".utf8))
        queue.async { [weak self] in self?.serveLoop() }
    }

    private func serveLoop() {
        let bufSize = 1500
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate() }
        while true {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, buf, bufSize, 0, sa, &fromLen)
                }
            }
            if n <= 0 { continue }
            let query = Data(bytes: buf, count: n)
            let client = from
            let clientLen = fromLen
            queue.async { [weak self] in self?.forward(query: query, client: client, clientLen: clientLen) }
        }
    }

    private func forward(query: Data, client: sockaddr_storage, clientLen: socklen_t) {
        let ip = guest.ip
        if ip.isEmpty { return }

        let up = socket(AF_INET, SOCK_DGRAM, 0)
        if up < 0 { return }
        defer { close(up) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(up, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var guestAddr = sockaddr_in()
        guestAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guestAddr.sin_family = sa_family_t(AF_INET)
        guestAddr.sin_port = guestPort.bigEndian
        guestAddr.sin_addr.s_addr = inet_addr(ip)

        let sent = query.withUnsafeBytes { raw in
            withUnsafePointer(to: &guestAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(up, raw.baseAddress, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent <= 0 { return }

        let bufSize = 1500
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate() }
        let n = recvfrom(up, buf, bufSize, 0, nil, nil)
        if n <= 0 { return }

        var dst = client
        let dstLen = clientLen
        _ = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buf, n, 0, $0, dstLen)
            }
        }
    }
}
