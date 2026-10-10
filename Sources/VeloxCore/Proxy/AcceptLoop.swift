import Foundation

/// The accept loop for a listening socket — ONE implementation (CLAUDE.md §10). The Docker socket
/// is served through it both while the engine runs (`DockerSocketProxy`, which bridges each
/// client to dockerd) and while it is stopped for idleness (`NapGate`, which parks them).
///
/// What it gets right, so its users don't have to:
/// - **fd exhaustion.** The read source is level-triggered: with EMFILE the connection stays
///   queued and the source re-fires immediately, spinning its queue at 100% CPU. Accepts pause
///   for 250 ms instead.
/// - **The dispatch-source contract.** The fd is closed only in the cancel handler — closing it
///   earlier lets a queued event act on a closed, possibly reused descriptor — or not at all, when
///   `stop(keepOpen:)` hands the still-listening socket to its next user.
/// - **A stop is a barrier.** `stop` returns once no accept handler is running and none will run
///   again, so an owner can drain whatever the handler produced right after it.
final class AcceptLoop: @unchecked Sendable {
    let fd: Int32
    private let label: String
    private let queue: DispatchQueue
    private let onAccept: (Int32) -> Void
    /// Owner-thread state: set by `start`, taken by `stop`. Start and stop are called by the one
    /// owner in sequence, never concurrently.
    private var source: DispatchSourceRead?
    // On `queue`.
    private var accepting = false
    private var throttled = false
    /// Read by the cancel handler, which must not capture `self`.
    private let closeOnCancel = Locked(true)

    /// - Parameters:
    ///   - fd: a bound, listening, non-blocking socket. Owned by the loop from `start` until a
    ///     `stop(keepOpen: true)` hands it back.
    ///   - queue: serial queue the accepts — and `onAccept` — run on.
    init(fd: Int32, queue: DispatchQueue, label: String, onAccept: @escaping (Int32) -> Void) {
        self.fd = fd
        self.queue = queue
        self.label = label
        self.onAccept = onAccept
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Strong `src` capture: dispatch releases the handlers on cancel, breaking the cycle.
        src.setEventHandler { [weak self] in self?.acceptAll(src) }
        let fd = self.fd, closeOnCancel = self.closeOnCancel
        src.setCancelHandler { if closeOnCancel.value { close(fd) } }
        queue.async { self.accepting = true }
        src.resume()
        source = src
    }

    /// Stop accepting. With `keepOpen`, the socket stays open — and listening, so new clients wait
    /// in its backlog — and is returned for its next user; otherwise it is closed. Bounded
    /// (`settle`), so a wedged queue can't hang the caller.
    @discardableResult
    func stop(keepOpen: Bool) -> Int32? {
        let src = source
        source = nil
        closeOnCancel.value = !keepOpen
        // On `queue`, so an accept handler already running finishes first and a queued event that
        // lands after this sees `accepting == false` — the barrier the owners rely on. The cancel
        // is also ordered behind any pending fd-exhaustion resume on the same queue.
        queue.async {
            self.accepting = false
            src?.cancel()
        }
        queue.settle(label)
        return keepOpen ? fd : nil
    }

    private func acceptAll(_ source: DispatchSourceRead) {
        while accepting {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EMFILE || errno == ENFILE, !throttled {
                    throttled = true
                    Log.warn("\(label): out of file descriptors — pausing accepts briefly")
                    source.suspend()
                    queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                        // Resume UNCONDITIONALLY — never behind `guard let self`. A suspended
                        // source does not run its cancel handler, so bailing out here left the
                        // listening socket open for the life of the process — precisely when it is
                        // already out of fds — and releasing a still-suspended source traps in
                        // libdispatch. Exactly one resume per suspend: `stop` only cancels.
                        self?.throttled = false
                        source.resume()
                    }
                }
                return // EWOULDBLOCK (drained) or an error
            }
            onAccept(client)
        }
    }
}
