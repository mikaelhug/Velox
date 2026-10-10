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
    /// Owner-thread state: the engine starts and stops the proxy in sequence.
    private var loop: AcceptLoop?

    public init(socketPath: String, guestPort: UInt32, bridge: VsockBridge) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.bridge = bridge
    }

    /// - Parameter adopting: a listener handed over from a `NapGate` — already bound to
    ///   `socketPath`, listening and non-blocking. Taking it over instead of re-binding is what
    ///   makes a resume seamless: the path never disappears, so no client sees a refused connect.
    public func start(adopting adopted: Int32? = nil) throws {
        let fd: Int32
        if let adopted {
            fd = adopted
        } else {
            unlink(socketPath) // clear any stale socket file
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw VeloxError.socketSetupFailed("socket()", errno) }
            guard let bound = UnixSocketAddress.withSockaddr(path: socketPath, { addr, len in
                bind(fd, addr, len)
            }) else {
                close(fd)
                throw VeloxError.socketSetupFailed("socket path too long", 0)
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
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
        let bridge = self.bridge, guestPort = self.guestPort
        let loop = AcceptLoop(fd: fd, queue: acceptQueue, label: "docker socket proxy") { client in
            // Bulk Docker-API transfers (`docker cp`, `load`, build contexts) were bounded by
            // the 8 KiB AF_UNIX default buffers — see `FDIO.bulkSocketBuffer`.
            FDIO.setSocketBuffers(client)
            bridge.bridge(localFd: client, toGuestPort: guestPort)
        }
        loop.start()
        self.loop = loop
        Log.info("docker socket proxy: \(socketPath) → guest vsock port \(guestPort)"
                 + (adopted != nil ? " (resumed)" : ""))
    }

    /// Stop accepting — a barrier: no accept handler is running when this returns, which is what
    /// `EngineRuntime.stop()`'s "stop admitting, then drain" ordering relies on. With
    /// `keepListener`, the listening socket stays open and its path in place, and the fd is
    /// returned for a `NapGate` to hold; otherwise it is closed and the path removed.
    @discardableResult
    public func stop(keepListener: Bool = false) -> Int32? {
        let loop = self.loop
        self.loop = nil
        let kept = loop?.stop(keepOpen: keepListener)
        if !keepListener { unlink(socketPath) }
        return kept
    }
}
