import Foundation

// Engine nap: what Resource Saver does on a macOS release whose memory balloon returns nothing
// to the host (macOS 27 — see `ResourceSaver.Mode`). After the idle period with nothing running
// and nothing connected, the front end stops the VM the ordinary way (plumbing down, guest
// flushed, VM powered off), but keeps `~/.velox/docker.sock` listening. The first client that
// connects boots the engine again, and its connection is carried over into the new engine as if
// nothing had happened — a cold boot is ~0.45 s, which is the whole cost of the nap.
//
// Two pieces live here, shared by the CLI and the GUI: `NapGate`, which holds the socket while
// the VM is down, and `ActivityCounter`, which tells Resource Saver that a Docker API request is
// in flight (so it never naps under a `docker build`, a pull, or a `docker events` session).
//
// Why a cold boot and not VZ's save/restore: restore measured SLOWER than a cold boot of this
// guest (1.8–3.1 s vs ~1.5 s then, ~0.45 s now), writes the touched guest RAM to disk on every
// nap, and its cross-process restore failed intermittently with an error never root-caused.
// See the "Engine Sleep" history in docs.

/// Counts in-flight work and reports the busy ⇄ idle edges.
///
/// One counter per engine, fed by every Docker-API path: the unix-socket proxy (each external
/// client connection, for its whole life — a `docker events` stream or a BuildKit session is
/// "busy" until it closes) and the in-process `DockerClient` (each request and each image pull).
/// Resource Saver only needs the edges, so `onChange` fires on 0 → 1 and 1 → 0, never per
/// request.
public final class ActivityCounter: @unchecked Sendable {
    private let state = Locked<(count: Int, onChange: (@Sendable (Bool) -> Void)?)>((0, nil))

    public init() {}

    /// Called with `true` when work begins after an idle stretch, `false` when the last piece of
    /// work ends. Runs on whatever thread ended or began the work — hop to your own queue.
    public func setOnChange(_ handler: (@Sendable (Bool) -> Void)?) {
        state.withLock { $0.onChange = handler }
    }

    public var isBusy: Bool { state.value.count > 0 }

    public func begin() {
        let edge = state.withLock { s -> (@Sendable (Bool) -> Void)? in
            s.count += 1
            return s.count == 1 ? s.onChange : nil
        }
        edge?(true)
    }

    public func end() {
        let edge = state.withLock { s -> (@Sendable (Bool) -> Void)? in
            guard s.count > 0 else { return nil }   // an unmatched end must not go negative
            s.count -= 1
            return s.count == 0 ? s.onChange : nil
        }
        edge?(false)
    }
}

/// Holds the Docker socket while the engine naps, and wakes it on the first client.
///
/// The listening fd is the very one the `DockerSocketProxy` was serving: the proxy hands it over
/// on nap (`EngineRuntime.stop(keepingDockerSocket:)`) and takes it back on wake
/// (`EngineRuntime.start(adopting:)`). It is never closed or re-bound in between, so there is no
/// window in which a `docker` command finds no socket or a refused one — a client that connects
/// mid-transition simply waits in the kernel's listen backlog until someone accepts it.
///
/// Accepted clients are parked, unread: their request bytes wait in the socket buffer and are
/// relayed to dockerd once the new engine adopts them (vinit holds an early Docker-API connection
/// until dockerd answers, so they can be bridged as soon as the VM runs).
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
    private var source: DispatchSourceRead?
    private var clients: [Int32] = []
    private var demanded = false
    private var finished = false

    /// - Parameters:
    ///   - listener: the proxy's listening socket (bound, listening, non-blocking).
    ///   - onDemand: fired once, on the first client — wake the engine. Runs on an internal queue.
    public init(listener: Int32, socketPath: String, onDemand: @escaping @Sendable () -> Void) {
        self.listener = listener
        self.socketPath = socketPath
        self.onDemand = onDemand
    }

    /// Start accepting. A client already waiting in the backlog fires this immediately.
    public func start() {
        queue.async { [self] in
            guard !finished, source == nil else { return }
            let src = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptAll() }
            src.resume()
            source = src
        }
    }

    /// Stop accepting and give up the listener and the parked clients to the next engine.
    /// The gate is finished afterwards; nothing it handed off is closed by it.
    public func handOff() -> Handoff {
        queue.sync {
            finished = true
            source?.cancel()   // the cancel handler is unset: the fd stays open for the adopter
            source = nil
            let parked = clients
            clients.removeAll()
            return Handoff(listener: listener, clients: parked)
        }
    }

    /// The engine is stopping for real: close everything and remove the socket file, so `docker`
    /// reports "is the daemon running?" rather than hanging on a socket nobody will serve.
    public func close() {
        queue.sync {
            guard !finished else { return }
            finished = true
            source?.cancel()
            source = nil
            for c in clients { Darwin.close(c) }
            clients.removeAll()
            Darwin.close(listener)
            unlink(socketPath)
        }
    }

    /// Close what a wake was carrying when the wake can't go ahead: the clients get EOF and the
    /// socket file goes, so `docker` says the daemon isn't running instead of hanging on a
    /// socket nobody will serve.
    public static func discard(_ handoff: Handoff?, socketPath: String) {
        guard let handoff else { return }
        for c in handoff.clients { Darwin.close(c) }
        Darwin.close(handoff.listener)
        unlink(socketPath)
    }

    private func acceptAll() {
        while !finished {
            let c = accept(listener, nil, nil)
            guard c >= 0 else { return }   // EWOULDBLOCK (drained) or a transient error
            clients.append(c)
            if !demanded {
                demanded = true
                Log.info("resource saver: Docker request received — resuming the engine")
                onDemand()
            }
        }
    }
}
