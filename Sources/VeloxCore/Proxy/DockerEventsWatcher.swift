import Foundation

/// Watches for changes to the set of published container ports and reports them.
///
/// **Push-based**, the way Docker Desktop / OrbStack do it: it consumes the Docker
/// `/events` stream and reconciles the instant a container is published — no
/// polling. Crucially it rides the *same* proven in-process client the GUI uses
/// (`DockerClient`, a single persistent VSOCK connection over `HTTPCodec`, straight
/// to the guest dockerd — bypassing the unix-socket proxy), so there is no
/// per-poll connection churn and a port is reachable in well under a second.
///
/// On every (re)connect it reconciles the full set, so a missed event or a daemon
/// restart self-heals — the event stream is the trigger, full reconciliation is the
/// source of truth (the informer pattern).
public final class DockerEventsWatcher: @unchecked Sendable {
    private let docker: any DockerClientProtocol
    private let onPorts: @Sendable (Set<UInt16>, Set<UInt16>) -> Void
    private var task: Task<Void, Never>?
    private var lastTCP: Set<UInt16> = []
    private var lastUDP: Set<UInt16> = []

    // Readiness: fired once, the first time a reconcile actually reaches dockerd.
    // The GUI awaits this to leave `.starting`, so it never has to poll `/_ping`.
    private let readyLock = NSLock()
    private var isReady = false
    private var readyWaiters: [ReadyWaiter] = []

    /// `onPorts` is called with the published (tcp, udp) port sets whenever either changes.
    public init(docker: any DockerClientProtocol, onPorts: @escaping @Sendable (Set<UInt16>, Set<UInt16>) -> Void) {
        self.docker = docker
        self.onPorts = onPorts
    }

    public func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Catch the current state on (re)connect (also picks up restart-policy
                // containers that were already running).
                await self.reconcile()
                for await event in self.docker.events() {
                    if Task.isCancelled { return }
                    if event.type == nil || event.type == "container" {
                        await self.reconcile()
                    }
                }
                // Stream ended (daemon not up yet, or restarted). Back off, reconnect.
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Suspends until dockerd first answers — signaled by the first successful
    /// reconcile — or until `timeout` elapses. Returns true if ready, false on
    /// timeout. Rides the watcher's existing connection, so readiness costs no extra
    /// polling (CLAUDE.md §8); returns immediately if dockerd already answered.
    public func waitUntilReady(timeout: Duration) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let waiter = ReadyWaiter(cont)
            // Register, or fire immediately if dockerd already answered (decided
            // atomically under the lock — see registerWaiter).
            if registerWaiter(waiter) {
                waiter.fire(true)
                return
            }
            // Bound the wait so a broken guest never hangs the caller forever.
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.removeWaiter(waiter)
                waiter.fire(false)
            }
        }
    }

    /// Register `waiter` to be released when dockerd becomes ready, or return true
    /// if it is *already* ready (the caller fires immediately and skips registering).
    /// Synchronous so the lock is never held across an `await`.
    private func registerWaiter(_ waiter: ReadyWaiter) -> Bool {
        readyLock.lock(); defer { readyLock.unlock() }
        if isReady { return true }
        readyWaiters.append(waiter)
        return false
    }

    /// Mark dockerd reachable and release every pending `waitUntilReady`. Idempotent.
    private func signalReady() {
        readyLock.lock()
        if isReady { readyLock.unlock(); return }
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        readyLock.unlock()
        for w in waiters { w.fire(true) }
    }

    private func removeWaiter(_ waiter: ReadyWaiter) {
        readyLock.lock()
        readyWaiters.removeAll { $0 === waiter }
        readyLock.unlock()
    }

    /// Re-read the authoritative published-port set; report only on change. Runs
    /// serially inside the single watcher Task, so `last` needs no extra locking.
    private func reconcile() async {
        guard let containers = try? await docker.containers() else { return }
        // A successful list means dockerd is up and answering — release any
        // startup waiter (the source of truth for readiness, not a `/_ping` poll).
        signalReady()
        var tcp: Set<UInt16> = []
        var udp: Set<UInt16> = []
        for c in containers where c.state == "running" {
            for p in c.ports {
                guard let pub = p.publicPort, pub > 0, pub <= 65_535 else { continue }
                switch p.type {
                case "tcp": tcp.insert(UInt16(pub))
                case "udp": udp.insert(UInt16(pub))
                default: break
                }
            }
        }
        if tcp != lastTCP || udp != lastUDP {
            lastTCP = tcp
            lastUDP = udp
            onPorts(tcp, udp)
        }
    }
}

/// One pending `waitUntilReady` caller. Resumes its continuation exactly once,
/// whichever of readiness or timeout fires first.
private final class ReadyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
    func fire(_ value: Bool) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}
