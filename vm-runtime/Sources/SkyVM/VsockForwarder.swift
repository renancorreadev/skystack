import Foundation
@preconcurrency import Virtualization

/// Exposes a guest vsock port as a unix-domain socket on the Mac. Each inbound
/// connection on the unix socket opens a fresh vsock connection to the guest
/// agent and pumps bytes both ways — turning the in-VM Docker socket into a
/// normal `~/.skystack/docker.sock` that the host's docker/skystack can use,
/// before any IP networking exists.
final class VsockForwarder {
    private let runner: VMRunner
    private let port: UInt32
    private let socketPath: String
    private let io = DispatchQueue(label: "dev.skystack.vsock", attributes: .concurrent)
    private var listenFd: Int32 = -1

    init(runner: VMRunner, guestPort: UInt32, socketPath: String) {
        self.runner = runner
        self.port = guestPort
        self.socketPath = socketPath
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw err("socket() failed: \(errno)") }

        unlink(socketPath)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { close(fd); throw err("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { cptr in
                for (i, b) in bytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { close(fd); throw err("bind() failed: \(errno)") }
        guard listen(fd, 16) == 0 else { close(fd); throw err("listen() failed: \(errno)") }

        listenFd = fd
        FileHandle.standardError.write(Data("[SkyVM] forwarding guest docker → \(socketPath)\n".utf8))
        io.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            runner.connectVsock(port: port) { [weak self] result in
                switch result {
                case .success(let conn):
                    self?.bridge(clientFd: client, conn: conn)
                case .failure(let error):
                    FileHandle.standardError.write(Data("[SkyVM] vsock connect(port \(self?.port ?? 0)) failed: \(error)\n".utf8))
                    close(client)
                }
            }
        }
    }

    private func bridge(clientFd: Int32, conn: VZVirtioSocketConnection) {
        let state = BridgeState(conn: conn, clientFd: clientFd)
        let vfd = conn.fileDescriptor
        io.async { state.copy(from: clientFd, to: vfd) }
        io.async { state.copy(from: vfd, to: clientFd) }
    }

    private func err(_ message: String) -> Error {
        NSError(domain: "SkyVM.VsockForwarder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Retains the vsock connection until both copy directions finish, then tears
/// everything down exactly once.
private final class BridgeState {
    private let conn: VZVirtioSocketConnection
    private let clientFd: Int32
    private var remaining = 2
    private let lock = NSLock()

    init(conn: VZVirtioSocketConnection, clientFd: Int32) {
        self.conn = conn
        self.clientFd = clientFd
    }

    func copy(from src: Int32, to dst: Int32) {
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
        // Half-close only the write side toward dst, flushing pending bytes and
        // signalling EOF, WITHOUT killing the opposite direction. Critical for
        // Docker's hijacked streams (run/attach/exec) where one side keeps
        // streaming after the other goes quiet.
        shutdown(dst, SHUT_WR)
        finish()
    }

    private func finish() {
        lock.lock()
        remaining -= 1
        let done = remaining == 0
        lock.unlock()
        if done {
            close(clientFd)
            conn.close()
        }
    }
}
