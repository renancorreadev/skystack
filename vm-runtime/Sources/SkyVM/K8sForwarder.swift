import Foundation

/// Forwards the in-VM Kubernetes (k3s) API server to a stable localhost port:
/// `127.0.0.1:6443 → guestIP:6443`. k3s' default serving cert includes
/// 127.0.0.1, so the exported kubeconfig works against this fixed address even
/// though the guest IP is DHCP-dynamic. Plain TCP (TLS passes through untouched).
final class K8sForwarder {
    private let guest: GuestInfo
    private let port: UInt16
    private let accept = DispatchQueue(label: "dev.skystack.k8s.accept")
    private let io = DispatchQueue(label: "dev.skystack.k8s.io", attributes: .concurrent)
    private var listenFd: Int32 = -1

    init(guest: GuestInfo, port: UInt16 = 6443) {
        self.guest = guest
        self.port = port
    }

    func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 || listen(fd, 32) != 0 {
            close(fd)
            FileHandle.standardError.write(Data("[SkyVM] k8s API forward bind 127.0.0.1:\(port) failed\n".utf8))
            return
        }
        listenFd = fd
        FileHandle.standardError.write(Data("[SkyVM] k8s API forward 127.0.0.1:\(port) → guest:\(port)\n".utf8))
        accept.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let client = Foundation.accept(listenFd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let ip = guest.ip
            if ip.isEmpty { close(client); continue }
            io.async { [weak self] in
                guard let self = self else { close(client); return }
                let upstream = self.dial(ip: ip, port: self.port)
                if upstream < 0 { close(client); return }
                K8sPump(a: client, b: upstream, queue: self.io).run()
            }
        }
    }

    private func dial(ip: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return -1 }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }
}

/// Bidirectional byte pump with independent half-close (SIGPIPE-safe).
private final class K8sPump {
    private let a: Int32
    private let b: Int32
    private let queue: DispatchQueue
    private var remaining = 2
    private let lock = NSLock()

    init(a: Int32, b: Int32, queue: DispatchQueue) {
        self.a = a
        self.b = b
        self.queue = queue
    }

    func run() {
        queue.async { self.copy(from: self.a, to: self.b) }
        queue.async { self.copy(from: self.b, to: self.a) }
    }

    private func copy(from src: Int32, to dst: Int32) {
        let size = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = read(src, buf, size)
            if n <= 0 { break }
            var off = 0
            while off < n {
                let w = write(dst, buf + off, n - off)
                if w <= 0 { break }
                off += w
            }
        }
        shutdown(dst, SHUT_WR)
        finish()
    }

    private func finish() {
        lock.lock()
        remaining -= 1
        let done = remaining == 0
        lock.unlock()
        if done { close(a); close(b) }
    }
}
