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
                        guard FDIO.writeAll(vsockFd, Array(header.utf8)) else {
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
        EventRelay.shared.relay(localFd, vsockFd) {}
        lock.unlock()
    }

    /// Stop admitting new streams. The in-flight ones are torn down by
    /// `EventRelay.shared.stopAll()`, which `EngineRuntime.stop()` calls for every relayed
    /// pair in the process — conduit and Docker-API alike — so this no longer keeps its own
    /// registry of live pumps.
    public func stopAll() {
        lock.lock(); stopped = true; lock.unlock()
    }
}
