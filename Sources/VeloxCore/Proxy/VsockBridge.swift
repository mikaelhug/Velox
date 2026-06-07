import Foundation

/// Bridges an accepted host fd to a guest VSOCK port: asks the VM to open a
/// vsock connection, then pumps bytes between the two until either side closes.
public final class VsockBridge: @unchecked Sendable {
    private let manager: VMManager
    private let lock = NSLock()
    private var pumps: [UUID: SocketPump] = [:]

    public init(manager: VMManager) {
        self.manager = manager
    }

    /// Takes ownership of `localFd` and connects it to `port` in the guest. If
    /// `header` is set, it is written to the guest connection before piping
    /// (used by reverse port-forwarding to name the target port).
    public func bridge(localFd: Int32, toGuestPort port: UInt32, header: String? = nil) {
        manager.connectToGuestPort(port) { [weak self] result in
            guard let self else { close(localFd); return }
            switch result {
            case .failure(let error):
                Log.error("vsock connect to port \(port) failed: \(error.localizedDescription)")
                close(localFd)
            case .success(let vsockFd):
                if let header {
                    // Write the header (names the target) off the VM queue, then pump.
                    // If it can't be fully written, the guest never learns the target
                    // port, so tear the connection down instead of pumping a stream the
                    // peer can't frame.
                    DispatchQueue.global().async {
                        guard Self.writeAll(vsockFd, Array(header.utf8)) else {
                            Log.error("vsock header write to port \(port) failed; dropping connection")
                            close(vsockFd)
                            close(localFd)
                            return
                        }
                        self.startPump(localFd, vsockFd)
                    }
                } else {
                    self.startPump(localFd, vsockFd)
                }
            }
        }
    }

    private func startPump(_ localFd: Int32, _ vsockFd: Int32) {
        let id = UUID()
        let pump = SocketPump(fdA: localFd, fdB: vsockFd) { [weak self] in
            self?.remove(id)
        }
        store(id, pump)
        pump.start()
    }

    /// Write all of `buf` to `fd`, retrying short writes and `EINTR`. Returns false
    /// if the descriptor errors before the whole buffer is written.
    private static func writeAll(_ fd: Int32, _ buf: [UInt8]) -> Bool {
        var off = 0
        return buf.withUnsafeBytes { raw in
            while off < buf.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    private func store(_ id: UUID, _ pump: SocketPump) {
        lock.lock(); pumps[id] = pump; lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock(); pumps[id] = nil; lock.unlock()
    }
}
