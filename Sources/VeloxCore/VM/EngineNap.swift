import Foundation

// Engine nap: what Resource Saver does on a macOS release whose memory balloon returns nothing
// to the host (macOS 27 — see `ResourceSaver.Mode`). After the idle period with nothing running
// and nothing connected, the front end stops the VM the ordinary way (plumbing down, guest
// flushed, VM powered off), but keeps `~/.velox/docker.sock` listening. The first client that
// connects boots the engine again, and its connection is carried over into the new engine as if
// nothing had happened — a cold boot is ~0.45 s, which is the whole cost of the nap.
//
// Shared by the CLI and the GUI: `EngineNap.stop`, the stop sequence itself; `NapGate`, which
// holds the socket while the VM is down; and `ActivityCounter`, which tells Resource Saver that a
// Docker API request is in flight (so it never naps under a `docker build`, a pull, or a
// `docker events` session).
//
// Why a cold boot and not VZ's save/restore: that was built ("Engine Sleep") and removed on
// 2026-08-16. Restore measured SLOWER than a cold boot of this guest (1.8–3.1 s vs ~1.5 s then,
// ~0.45 s now), every sleep wrote the touched guest RAM to disk (448 MiB idle, 1.3 GiB after a
// pull), ballooning before the save made it bigger, not smaller, and a cross-process restore
// failed intermittently with VZErrorDomain 12 ("permission denied"), never root-caused. A
// restore also needs the machine identifier, MAC and exact cmdline pinned; a cold boot needs none.

/// Counts in-flight work and signals the busy ⇄ idle edges.
///
/// One counter per engine, fed by every Docker-API path: the unix-socket proxy (each external
/// client connection, for its whole life — a `docker events` stream or a BuildKit session is
/// "busy" until it closes) and the in-process `DockerClient` (each request and each image pull).
/// Resource Saver only needs the edges, so `onChange` fires on 0 → 1 and 1 → 0, never per
/// request.
///
/// The edge carries no value on purpose. Handlers run outside the lock, so two threads crossing
/// zero at once can deliver their notifications in either order; a handler that trusted a
/// "busy: false" argument could record idle while a `docker build` is connected. A handler reads
/// `isBusy` when it runs instead — the last one to run always sees the current state.
public final class ActivityCounter: @unchecked Sendable {
    // Plain stored properties behind a plain lock — deliberately NOT a `Locked<(count, onChange)>`.
    // Mutating a tuple that holds a closure through the generic `Locked.withLock(inout T)`
    // re-abstracts the closure on every pass (into the generic representation and back), and the
    // stored value grows by a pair of thunks each time: after ~4,000 requests, firing the handler
    // recursed through 16,000 thunk frames and overflowed the stack (crashed v1.7.1-dev after
    // 50 minutes of dashboard use, 2026-10-10).
    private let lock = NSLock()
    private var count = 0
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Called when work begins after an idle stretch and when the last piece of work ends. Runs on
    /// whatever thread ended or began the work — hop to your own queue, then read `isBusy`.
    public func setOnChange(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); onChange = handler; lock.unlock()
    }

    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }

    public func begin() {
        lock.lock()
        count += 1
        let edge = count == 1 ? onChange : nil
        lock.unlock()
        edge?()
    }

    public func end() {
        lock.lock()
        guard count > 0 else { lock.unlock(); return }   // an unmatched end must not go negative
        count -= 1
        let edge = count == 0 ? onChange : nil
        lock.unlock()
        edge?()
    }
}

/// Holds the Docker socket while the engine is stopped for idleness, and wakes it on the first
/// client.
///
/// The listening fd is the very one the `DockerSocketProxy` was serving: the runtime releases it
/// (`EngineRuntime.releaseDockerSocketIfIdle()`), the gate holds it, and the next runtime adopts it
/// (`EngineRuntime.start(adopting:)`). It is never closed or re-bound in between, so there is no
/// window in which a `docker` command finds no socket or a refused one — a client that connects
/// mid-transition simply waits in the kernel's listen backlog until someone accepts it.
///
/// Accepted clients are parked, unread: their request bytes wait in the socket buffer and are
/// relayed to dockerd once the new engine adopts them (vinit holds an early Docker-API connection
/// until dockerd answers, and `VsockBridge` retries while vinit's agent comes up). Accepting is
/// the shared `AcceptLoop` — the proxy's own, not a second implementation.
public final class NapGate: @unchecked Sendable {
    /// What the next engine adopts: the listener and every client parked meanwhile.
    public struct Handoff: Sendable {
        public let listener: Int32
        public let clients: [Int32]
    }

    private let listener: Int32
    private let socketPath: String
    private let onDemand: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.velox.napgate")
    /// Guarded by `lock`: the owner may hand off or close from any thread.
    private let lock = NSLock()
    private var loop: AcceptLoop?
    private var finished = false
    // On `queue` (the accept loop's queue).
    private var clients: [Int32] = []
    private var demanded = false

    /// - Parameters:
    ///   - listener: the proxy's listening socket (bound, listening, non-blocking).
    ///   - onDemand: fired once, on the first client — resume the engine. Runs on an internal queue.
    public init(listener: Int32, socketPath: String, onDemand: @escaping @Sendable () -> Void) {
        self.listener = listener
        self.socketPath = socketPath
        self.onDemand = onDemand
    }

    /// Start accepting. A client already waiting in the backlog fires this immediately.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, loop == nil else { return }
        let loop = AcceptLoop(fd: listener, queue: queue, label: "docker socket (idle)") {
            [weak self] client in self?.park(client)
        }
        loop.start()
        self.loop = loop
    }

    /// Stop accepting and give up the listener and the parked clients to the next engine. The
    /// gate is finished afterwards; nothing it handed off is closed by it.
    public func handOff() -> Handoff {
        lock.lock()
        finished = true
        let loop = self.loop
        self.loop = nil
        lock.unlock()
        loop?.stop(keepOpen: true)   // a barrier: no park() runs after this
        let parked = queue.sync { () -> [Int32] in
            defer { clients.removeAll() }
            return clients
        }
        return Handoff(listener: listener, clients: parked)
    }

    /// The engine is stopping for real: close everything and remove the socket file, so `docker`
    /// reports "is the daemon running?" rather than hanging on a socket nobody will serve.
    public func close() {
        lock.lock()
        let wasFinished = finished
        finished = true
        let loop = self.loop
        self.loop = nil
        lock.unlock()
        guard !wasFinished else { return }
        if let loop { loop.stop(keepOpen: false) } else { Darwin.close(listener) }
        queue.sync {
            for c in clients { Darwin.close(c) }
            clients.removeAll()
        }
        unlink(socketPath)
    }

    /// Close what a resume was carrying when it can't go ahead: the clients get EOF and the socket
    /// file goes, so `docker` says the daemon isn't running instead of hanging on a socket nobody
    /// will serve.
    public static func discard(_ handoff: Handoff?, socketPath: String) {
        guard let handoff else { return }
        for c in handoff.clients { Darwin.close(c) }
        Darwin.close(handoff.listener)
        unlink(socketPath)
    }

    /// On `queue`.
    private func park(_ client: Int32) {
        clients.append(client)
        guard !demanded else { return }
        demanded = true
        Log.info("resource saver: Docker request received — resuming the engine")
        onDemand()
    }
}

/// The idle stop itself — ONE sequence for the CLI and the app, so a fix lands once (the reason
/// `EngineRuntime` exists). The front ends keep only what differs: their own state machine and
/// how they boot.
public enum EngineNap {
    public enum Outcome: Sendable {
        /// Down and flushed. The gate holds the Docker socket but is not accepting yet: store it,
        /// then `start()` it.
        case stopped(NapGate)
        /// A stop took over before the socket was claimed; `EngineRuntime.stop()` closed it.
        case cancelled
        /// The VM did not confirm it stopped within the deadline and may still be running. The
        /// socket has been closed and removed.
        case stuck
    }

    /// Stop the engine for idleness, once `runtime.releaseDockerSocketIfIdle()` returned true:
    /// plumbing down, guest flushed, VM off — the ordinary stop — keeping the Docker socket for a
    /// gate. `completion` runs on a background queue, never on the VM queue.
    public static func stop(runtime: EngineRuntime, manager: VMManager, deadline: TimeInterval,
                            onDemand: @escaping @Sendable () -> Void,
                            completion: @escaping @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let listener = runtime.takeReleasedDockerSocket() else {
                completion(.cancelled)
                return
            }
            // Blocking: the named-access routes go through the porthelper (up to 3 s each).
            runtime.stop(waitForTeardown: true)
            let settled = Locked(false)
            @Sendable func settle() -> Bool { settled.withLock { done in defer { done = true }; return !done } }
            let socketPath = Paths.dockerSocket.path
            manager.stopGracefully {
                guard settle() else { return }
                let gate = NapGate(listener: listener, socketPath: socketPath, onDemand: onDemand)
                DispatchQueue.global(qos: .userInitiated).async { completion(.stopped(gate)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                guard settle() else { return }
                Log.warn("resource saver: the VM did not stop within \(Int(deadline)) s")
                NapGate.discard(NapGate.Handoff(listener: listener, clients: []), socketPath: socketPath)
                completion(.stuck)
            }
        }
    }
}
