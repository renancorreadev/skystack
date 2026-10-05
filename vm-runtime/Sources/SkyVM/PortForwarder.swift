import Foundation
@preconcurrency import Virtualization

/// Forwards published container ports to the Mac's localhost. It learns the
/// guest IP and the live set of published ports from the guest agent over a
/// vsock control channel, then reconciles `127.0.0.1:P → guestIP:P` TCP proxies
/// as containers come and go. The data path is direct (the guest IP is routable
/// from the host via Apple's NAT), so only control flows over vsock.
final class PortForwarder {
    private let runner: VMRunner
    private let netinfoPort: UInt32
    private let guestInfo: GuestInfo?
    private let control = DispatchQueue(label: "dev.skystack.ports.control")
    private let io = DispatchQueue(label: "dev.skystack.ports.io", attributes: .concurrent)
    private let lock = NSLock()
    private var guestIP = ""
    private var listeners: [Int: Int32] = [:] // host port → listen fd

    init(runner: VMRunner, guestInfo: GuestInfo? = nil, netinfoPort: UInt32 = 1024) {
        self.runner = runner
        self.guestInfo = guestInfo
        self.netinfoPort = netinfoPort
    }

    func start() {
        control.async { [weak self] in self?.runControlLoop() }
    }

    // MARK: control channel

    private func runControlLoop() {
        while true {
            guard let conn = connectNetInfo() else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            readUpdates(fd: conn.fileDescriptor)
            conn.close()
            Thread.sleep(forTimeInterval: 1) // brief backoff before reconnect
        }
    }

    private func connectNetInfo() -> VZVirtioSocketConnection? {
        let sem = DispatchSemaphore(value: 0)
        var result: VZVirtioSocketConnection?
        runner.connectVsock(port: netinfoPort) { r in
            if case .success(let c) = r { result = c }
            sem.signal()
        }
        sem.wait()
        return result
    }

    private func readUpdates(fd: Int32) {
        var buffer = Data()
        let size = 8192
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, size)
            if n <= 0 { return }
            buffer.append(Data(bytes: buf, count: n))
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                handleLine(line)
            }
        }
    }

    private func handleLine(_ line: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        let ip = obj["ip"] as? String ?? ""
        let ports = (obj["ports"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        reconcile(ip: ip, ports: Set(ports))
    }

    // MARK: reconciliation

    private func reconcile(ip: String, ports: Set<Int>) {
        lock.lock()
        guestIP = ip
        let current = Set(listeners.keys)
        lock.unlock()

        guestInfo?.setIP(ip)
        persistState(ip: ip, ports: ports.sorted())
        if ip.isEmpty { return }

        for p in ports.subtracting(current) { openListener(port: p) }
        for p in current.subtracting(ports) { closeListener(port: p) }
    }

    /// Publishes {ip, ports} to ~/.skystack/skyvm-net.json so the skystack CLI
    /// can read the (DHCP-assigned, dynamic) guest IP for `vm route` and status.
    private func persistState(ip: String, ports: [Int]) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = home + "/.skystack"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["ip": ip, "ports": ports]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/skyvm-net.json"))
        }
    }

    private func openListener(port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 64) != 0 {
            close(fd) // port busy on the Mac — skip silently
            return
        }
        lock.lock(); listeners[port] = fd; lock.unlock()
        FileHandle.standardError.write(Data("[SkyVM] forward localhost:\(port) → guest:\(port)\n".utf8))
        io.async { [weak self] in self?.acceptLoop(listenFd: fd, port: port) }
    }

    private func closeListener(port: Int) {
        lock.lock(); let fd = listeners.removeValue(forKey: port); lock.unlock()
        guard let fd = fd else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        FileHandle.standardError.write(Data("[SkyVM] stop forwarding localhost:\(port)\n".utf8))
    }

    private func acceptLoop(listenFd: Int32, port: Int) {
        while true {
            let client = accept(listenFd, nil, nil)
            if client < 0 { return } // listener was closed
            lock.lock(); let active = listeners[port] == listenFd; let ip = guestIP; lock.unlock()
            if !active { close(client); return }
            io.async { [weak self] in
                guard let self = self else { close(client); return }
                let upstream = self.dial(ip: ip, port: port)
                if upstream < 0 { close(client); return }
                TCPPump(a: client, b: upstream, queue: self.io).run()
            }
        }
    }

    private func dial(ip: String, port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return -1 }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(ip)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }
}

/// Bidirectional byte pump between two raw fds with independent half-close, so a
/// finished direction never tears down the other (matches the vsock bridge).
private final class TCPPump {
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
        if done {
            close(a)
            close(b)
        }
    }
}
