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
    /// Set on `acceptQueue` by `stop(keepListener: true)`: the cancel handler then leaves the
    /// listening fd open, because an engine nap is handing it to a `NapGate`.
    private var keepListenerOnCancel = false
    public init(socketPath: String, guestPort: UInt32, bridge: VsockBridge) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.bridge = bridge
    }

    /// - Parameter adopting: a listener handed over from a `NapGate` — already bound to
    ///   `socketPath`, listening and non-blocking. Taking it over instead of re-binding is what
    ///   makes a wake seamless: the path never disappears, so no client sees a refused connect.
    public func start(adopting adopted: Int32? = nil) throws {
        if let adopted {
            listenFd = adopted
            startAccepting(adopted)
            Log.info("docker socket proxy: \(socketPath) → guest vsock port \(guestPort) (resumed)")
            return
        }
        unlink(socketPath) // clear any stale socket file

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFd = fd
        startAccepting(fd)
        Log.info("docker socket proxy: \(socketPath) → guest vsock port \(guestPort)")
    }

    private func startAccepting(_ fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        // Strong `src` capture: dispatch releases the handlers on cancel, breaking the cycle.
        src.setEventHandler { [weak self] in self?.acceptConnections(source: src) }
        // Clear the field in the cancel handler — it runs on `acceptQueue`, the same queue
        // as `acceptConnections`, so a queued accept event that lands after `stop()` sees
        // -1 and bails instead of calling `accept()` on a closed (possibly reused) fd.
        src.setCancelHandler { [weak self] in
            let keep = self?.keepListenerOnCancel ?? false
            self?.listenFd = -1
            if !keep { close(fd) }
        }
        src.resume()
        source = src
    }

    /// Stop accepting. With `keepListener`, the listening socket stays open and its path stays
    /// in place, and the fd is returned for a `NapGate` to hold; otherwise it is closed and the
    /// path removed.
    @discardableResult
    public func stop(keepListener: Bool = false) -> Int32? {
        let src = source
        source = nil
        let kept = Locked<Int32>(-1)
        // Cancel ON `acceptQueue`, synchronously. Two things depend on it: an accept handler
        // already running finishes before this returns (so `EngineRuntime.stop()`'s documented
        // "stop admitting, then drain" ordering is actually enforced, not merely intended), and
        // the cancel is ordered behind any pending fd-exhaustion resume on the same queue.
        acceptQueue.async { [self] in
            keepListenerOnCancel = keepListener
            kept.value = listenFd
            src?.cancel()
        }
        acceptQueue.settle("docker-proxy")
        // nil only if the accept queue never quiesced — the caller then has no socket to hold.
        guard !keepListener else { let fd = kept.value; return fd >= 0 ? fd : nil }
        unlink(socketPath)
        return nil
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
                        // Resume UNCONDITIONALLY — never behind `guard let self`. A suspended
                        // dispatch source does not run its cancel handler, so bailing out here
                        // (the proxy deallocated inside this 250 ms window, e.g. an engine
                        // restart) left the listening socket open for the life of the process —
                        // precisely when the process is already out of fds. Releasing a still-
                        // suspended source also traps in libdispatch. The strong `source`
                        // capture keeps it alive to be resumed. Exactly one resume per suspend:
                        // `stop()` must not resume as well, it just cancels behind this.
                        self?.throttled = false
                        source.resume()
                    }
                }
                break // EWOULDBLOCK (drained) or error
            }
            // Bulk Docker-API transfers (`docker cp`, `load`, build contexts) were bounded by
            // the 8 KiB AF_UNIX default buffers — see `FDIO.bulkSocketBuffer`.
            FDIO.setSocketBuffers(client)
            bridge.bridge(localFd: client, toGuestPort: guestPort)
        }
    }
}
