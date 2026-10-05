import Foundation
@preconcurrency import Virtualization

/// Pushes the SkyStack local CA (cert + key) into the guest over a vsock control
/// channel, so the in-VM agent can mint per-host leaf certificates for the HTTPS
/// reverse proxy. The CA key is delivered in memory and never written to the
/// guest's disk. Delivery is one-shot: it retries until the agent acknowledges
/// by closing the connection, then stops.
final class CAForwarder {
    private let runner: VMRunner
    private let port: UInt32
    private let bundle: Data
    private let queue = DispatchQueue(label: "dev.skystack.ca")

    /// Fails to initialize if the CA files are not present (HTTPS then disabled).
    init?(runner: VMRunner, caDir: String, port: UInt32 = 1026) {
        let cert = URL(fileURLWithPath: caDir + "/ca.crt")
        let key = URL(fileURLWithPath: caDir + "/ca.key")
        guard let certData = try? Data(contentsOf: cert),
              let keyData = try? Data(contentsOf: key) else { return nil }
        var b = Data()
        b.append(certData)
        b.append(keyData)
        self.runner = runner
        self.port = port
        self.bundle = b
    }

    func start() {
        queue.async { [weak self] in self?.pushLoop() }
    }

    private func pushLoop() {
        for _ in 0..<150 { // ~5 min of retries while the guest boots
            if let conn = connect() {
                let acked = push(fd: conn.fileDescriptor)
                conn.close()
                if acked {
                    FileHandle.standardError.write(Data("[SkyVM] delivered local CA to guest (HTTPS *.sky.local)\n".utf8))
                    return
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        FileHandle.standardError.write(Data("[SkyVM] could not deliver CA to guest — HTTPS unavailable\n".utf8))
    }

    private func connect() -> VZVirtioSocketConnection? {
        let sem = DispatchSemaphore(value: 0)
        var result: VZVirtioSocketConnection?
        runner.connectVsock(port: port) { r in
            if case .success(let c) = r { result = c }
            sem.signal()
        }
        sem.wait()
        return result
    }

    /// Writes the whole bundle, half-closes the write side to signal EOF, then
    /// waits for the agent to close (its ack). Returns true once acked.
    private func push(fd: Int32) -> Bool {
        let total = bundle.count
        var off = 0
        let wrote = bundle.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            while off < total {
                let n = write(fd, base + off, total - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if !wrote { return false }
        shutdown(fd, SHUT_WR) // EOF → the agent's read completes and it parses the CA

        // The agent closes the connection after consuming the bundle; treat that
        // EOF as the ack. Bound the wait so a missing/old agent doesn't hang us.
        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var tmp = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &tmp, tmp.count)
        return n == 0 // 0 = clean EOF (agent acked); <0 = timeout/error → retry
    }
}
