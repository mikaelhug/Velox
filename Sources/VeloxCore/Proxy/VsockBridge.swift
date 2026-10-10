import Foundation

/// Bridges an accepted host fd to a guest VSOCK port: asks the VM to open a
/// vsock connection, then pumps bytes between the two until either side closes.
public final class VsockBridge: @unchecked Sendable {
    private let manager: VMManager
    private let lock = NSLock()
    /// Set by `stopAll()`. `bridge()` completes asynchronously (VM queue + a VZ vsock connect
    /// callback), so without this a connect landing after the stop would repopulate `pumps`
    /// with a live pump on a VM being powered off — and since the next start builds a fresh
    /// `VsockBridge`, that pump and its two fds would leak for the life of the process.
    private var stopped = false
    /// Counts live Docker-API connections (port 2375 only) for Resource Saver's nap: a
    /// connected client — `docker events`, a build session, a `compose` run — is activity.
    private let activity: ActivityCounter?

    public init(manager: VMManager, activity: ActivityCounter? = nil) {
        self.manager = manager
        self.activity = activity
    }

    /// Takes ownership of `localFd` and connects it to `port` in the guest. If
    /// `header` is set, it is written to the guest connection before piping
    /// (used by reverse port-forwarding to name the target port).
    public func bridge(localFd: Int32, toGuestPort port: UInt32, header: String? = nil) {
        connect(localFd: localFd, port: port, header: header,
                deadline: .now() + Self.bootGrace, delay: .milliseconds(20))
    }

    /// How long a Docker-API connect may keep being refused before the client is dropped.
    ///
    /// The VM is "running" to Virtualization.framework ~0.1 s before vinit's vsock agent is
    /// listening, and a connect in that window is refused. Nothing used to land there by
    /// accident; a wake from a nap lands there by design — the client that woke the engine is
    /// bridged the moment the VM starts. Bounded and only for the Docker port: a published-port
    /// connection exists only once the engine has been up for a while.
    static let bootGrace: DispatchTimeInterval = .seconds(10)

    private func connect(localFd: Int32, port: UInt32, header: String?,
                         deadline: DispatchTime, delay: DispatchTimeInterval) {
        manager.connectToGuestPort(port) { [weak self] result in
            guard let self else { close(localFd); return }
            switch result {
            case .failure(let error):
                if port == VsockPort.docker, DispatchTime.now() < deadline, !self.isStopped {
                    let next: DispatchTimeInterval
                    if case .milliseconds(let ms) = delay { next = .milliseconds(min(ms * 2, 500)) }
                    else { next = delay }
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.connect(localFd: localFd, port: port, header: header,
                                     deadline: deadline, delay: next)
                    }
                    return
                }
                Log.error("vsock connect to port \(port) failed: \(error.localizedDescription)")
                close(localFd)
            case .success(let vsockFd):
                // The Docker-API leg's other half (the unix-socket side is raised in
                // `DockerSocketProxy`). Best-effort: VZ hands back an fd whose socket type
                // is its own business, and a refusal just leaves its defaults in place. The
                // published-port fallback (`reverse`) is left alone — it can carry hundreds
                // of connections, and the guest sizes only the Docker port's window too.
                if port == VsockPort.docker { FDIO.setSocketBuffers(vsockFd) }
                if let header {
                    // Write the header (names the target) off the VM queue, then pump.
                    // If it can't be fully written, the guest never learns the target
                    // port, so tear the connection down instead of pumping a stream the
                    // peer can't frame.
                    DispatchQueue.global().async {
                        guard FDIO.writeAll(vsockFd, Array(header.utf8)) else {
                            Log.error("vsock header write to port \(port) failed; dropping connection")
                            close(vsockFd)
                            close(localFd)
                            return
                        }
                        self.startPump(localFd, vsockFd, port: port)
                    }
                } else {
                    self.startPump(localFd, vsockFd, port: port)
                }
            }
        }
    }

    private func startPump(_ localFd: Int32, _ vsockFd: Int32, port: UInt32) {
        // One relay for the whole process (CLAUDE.md: one mechanism per job). This path used
        // to run its own `SocketPump` — a second, independent implementation of exactly the
        // same job (bidirectional splice with backpressure and half-close). Both had to get
        // fd ownership, half-close and teardown ordering right, and in the 2026-08 audit both
        // got at least one of them wrong, separately. `EventRelay` takes ownership of both
        // fds, closes them exactly once, and preserves the half-close that Docker's hijacked
        // attach/exec/logs streams depend on.
        // Admit and splice under the SAME lock hold. Checking `admit()` and then registering
        // left a window in which `stopAll()` could run in between, so the pair was handed to
        // the relay after `EngineRuntime.stop()` had already drained it and survived the stop.
        // Holding the lock across the registration makes "not stopped" and "visible to the
        // drain" the same instant — `bridge.stopAll()` runs before `EventRelay.stopAll()`, so
        // anything that got past this guard is in the relay's set by the time it drains.
        lock.lock()
        guard !stopped else { lock.unlock(); close(localFd); close(vsockFd); return }
        let isDocker = port == VsockPort.docker
        let activity = isDocker ? self.activity : nil
        activity?.begin()
        EventRelay.shared.relay(localFd, vsockFd, spinReads: isDocker) { activity?.end() }
        lock.unlock()
    }

    /// Stop admitting new streams. The in-flight ones are torn down by
    /// `EventRelay.shared.stopAll()`, which `EngineRuntime.stop()` calls for every relayed
    /// pair in the process — conduit and Docker-API alike — so this no longer keeps its own
    /// registry of live pumps.
    public func stopAll() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
