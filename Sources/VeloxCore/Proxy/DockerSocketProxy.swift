import Foundation

/// Listens on a host AF_UNIX socket and bridges every connection to a guest
/// VSOCK port. This is the host half of the Docker API bridge: clients (the
/// `docker` CLI via `DOCKER_HOST`) talk to `~/.velox/docker.sock`, and the
/// bytes are forwarded to the guest where the relay hands them to dockerd.
public final class DockerSocketProxy: @unchecked Sendable {
    private let socketPath: String
    private let guestPort: UInt32
    private let bridge: VsockBridge
    private let acceptQueue = DispatchQueue(label: "dev.velox.proxy.accept")
    private var listenFd: Int32 = -1
    private var throttled = false   // accepts paused for fd exhaustion (on `acceptQueue`)
    private var source: DispatchSourceRead?

    public init(socketPath: String, guestPort: UInt32, bridge: VsockBridge) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.bridge = bridge
    }

    public func start() throws {
        unlink(socketPath) // clear any stale socket file

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VeloxError.socketSetupFailed("socket()", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw VeloxError.socketSetupFailed("socket path too long", 0)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw VeloxError.socketSetupFailed("bind(\(socketPath))", errno)
        }
        guard listen(fd, 128) == 0 else {
            close(fd)
            throw VeloxError.socketSetupFailed("listen()", errno)
        }

        // Non-blocking so the accept loop can drain without blocking the queue.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        // Strong `src` capture: dispatch releases the handlers on cancel, breaking the cycle.
        src.setEventHandler { [weak self] in self?.acceptConnections(source: src) }
        // Clear the field in the cancel handler — it runs on `acceptQueue`, the same queue
        // as `acceptConnections`, so a queued accept event that lands after `stop()` sees
        // -1 and bails instead of calling `accept()` on a closed (possibly reused) fd.
        src.setCancelHandler { [weak self] in self?.listenFd = -1; close(fd) }
        src.resume()
        source = src

        Log.info("docker socket proxy: \(socketPath) → guest vsock port \(guestPort)")
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(socketPath)
    }

    private func acceptConnections(source: DispatchSourceRead) {
        while true {
            let fd = listenFd
            guard fd >= 0 else { return } // stopped
            let client = accept(fd, nil, nil)
            if client < 0 {
                // Level-triggered: under fd exhaustion the connection stays queued and this
                // source re-fires immediately, spinning the accept queue at 100% CPU.
                if errno == EMFILE || errno == ENFILE, !throttled {
                    throttled = true
                    Log.warn("docker socket proxy: out of file descriptors — pausing accepts briefly")
                    source.suspend()
                    acceptQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                        guard let self, self.throttled else { return }
                        self.throttled = false
                        source.resume()
                    }
                }
                break // EWOULDBLOCK (drained) or error
            }
            bridge.bridge(localFd: client, toGuestPort: guestPort)
        }
    }
}
