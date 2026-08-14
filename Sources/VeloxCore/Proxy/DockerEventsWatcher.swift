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
    private let onPorts: @Sendable (Set<PublishedPort>, Set<PublishedPort>) -> Void
    /// Updated each reconcile with `hostPort → "containerIP:containerPort"` for direct-dial
    /// (the conduit pool reads it). Optional — nil when the conduit fast path isn't used.
    private let endpoints: PublishedEndpoints?
    /// Updated each reconcile with `name → container IPv4` for direct (named) access. Optional.
    private let names: NameRegistry?
    /// Fired with the set of bridge-network subnets (CIDRs) whenever it changes — the host routes
    /// each to the guest so container IPs are reachable. Nil → named-access routing disabled.
    private let onSubnets: (@Sendable (Set<String>) -> Void)?
    private var task: Task<Void, Never>?
    private var lastTCP: Set<PublishedPort> = []
    private var lastUDP: Set<PublishedPort> = []
    private var lastSubnets: Set<String> = []
    /// Coalesces event-driven reconciles so a healthcheck / `compose up` storm collapses
    /// to one `containers()` fetch instead of one per event (CLAUDE.md §8).
    private var coalescer: Coalescer?
    /// Guards `lastTCP`/`lastUDP`/`lastSubnets`.
    private let stateLock = NSLock()
    /// Single-flight guard for `reconcile()`. The immediate on-(re)connect reconcile and
    /// the coalescer's reconcile run from two independent Tasks; without this they could
    /// interleave (each has `await`s on `containers()`/`networks()`) and the one that read
    /// dockerd *first* could commit its now-stale port/name maps *last*. `runReconcile`
    /// serializes the bodies so commits always land in read order.
    private let reconcileLock = NSLock()
    private var reconcileRunning = false
    private var reconcilePending = false

    // Readiness: fired once, the first time a reconcile actually reaches dockerd.
    // The GUI awaits this to leave `.starting`, so it never has to poll `/_ping`.
    private let readyLock = NSLock()
    private var isReady = false
    private var readyWaiters: [ReadyWaiter] = []

    /// `onPorts` is called with the published (tcp, udp) port sets whenever either changes.
    public init(docker: any DockerClientProtocol,
                onPorts: @escaping @Sendable (Set<PublishedPort>, Set<PublishedPort>) -> Void,
                endpoints: PublishedEndpoints? = nil,
                names: NameRegistry? = nil,
                onSubnets: (@Sendable (Set<String>) -> Void)? = nil) {
        self.docker = docker
        self.onPorts = onPorts
        self.endpoints = endpoints
        self.names = names
        self.onSubnets = onSubnets
    }

    public func start() {
        let coalescer = Coalescer { [weak self] in await self?.runReconcile() }
        self.coalescer = coalescer
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Catch the current state on (re)connect (also picks up restart-policy
                // containers that were already running) — immediate, not coalesced, so
                // published ports come up fast and readiness fires promptly.
                await self.runReconcile()
                for await event in self.docker.events() {
                    if Task.isCancelled { return }
                    // Coalesce: a burst of container events fans into a single
                    // reconcile rather than one full `containers()` fetch each.
                    if event.type == nil || event.type == "container" || event.type == "network" {
                        coalescer.trigger()
                    }
                }
                // Stream ended (daemon not up yet, or restarted). Back off, reconnect.
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        coalescer?.cancel()
        coalescer = nil
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

    /// Single-flight entry point — every caller uses this, never `reconcile()` directly.
    /// Ensures at most one reconcile body runs at a time; a request that arrives mid-run
    /// triggers exactly one more run afterward, so nothing is missed (informer pattern).
    /// The lock is only touched in the sync helpers (NSLock can't be used across `await`).
    private func runReconcile() async {
        guard beginReconcileRun() else { return }
        repeat { await reconcile() } while finishReconcileRun()
    }

    /// Become the sole runner, or mark a pending re-run and bail. Returns whether we run.
    private func beginReconcileRun() -> Bool {
        reconcileLock.lock(); defer { reconcileLock.unlock() }
        if reconcileRunning { reconcilePending = true; return false }
        reconcileRunning = true
        return true
    }

    /// After a run: if a trigger arrived meanwhile, consume it and loop again; else release.
    private func finishReconcileRun() -> Bool {
        reconcileLock.lock(); defer { reconcileLock.unlock() }
        if reconcilePending { reconcilePending = false; return true }
        reconcileRunning = false
        return false
    }

    /// Re-read the authoritative published-port set; report only on change. Serialized
    /// by `runReconcile()`, so its writes never interleave with another reconcile's.
    private func reconcile() async {
        guard let containers = try? await docker.containers() else { return }
        // A successful list means dockerd is up and answering — release any
        // startup waiter (the source of truth for readiness, not a `/_ping` poll).
        signalReady()
        // port → "every binding dockerd reported for it was loopback". Accumulated with AND
        // across containers and across a port's v4/v6 entries, so a port is narrowed to
        // host-only only when nothing published it on a wider address.
        var tcpBinds: [UInt16: Bool] = [:]
        var udpBinds: [UInt16: Bool] = [:]
        var endpointMap: [UInt16: String] = [:]
        var nameMap: [String: in_addr_t] = [:]
        for c in containers where c.state == "running" {
            // Named access: `name → container IP` (+ compose `<service>` and `<service>.<project>`
            // aliases). `directIP` is non-nil only when the container's network is unambiguous.
            if let ip = c.directIP {
                let addr = inet_addr(ip)
                if addr != INADDR_NONE {
                    if let n = c.names.first { nameMap[n.lowercased()] = addr }
                    if let svc = c.labels["com.docker.compose.service"] {
                        nameMap[svc.lowercased()] = addr
                        if let proj = c.labels["com.docker.compose.project"] {
                            nameMap["\(svc).\(proj)".lowercased()] = addr
                        }
                    }
                }
            }
            for p in c.ports {
                guard let pub = p.publicPort, pub > 0, pub <= 65_535 else { continue }
                let port = UInt16(pub)
                let loopback = PublishBind.isLoopbackLiteral(p.ip)
                switch p.type {
                case "tcp":
                    tcpBinds[port] = (tcpBinds[port] ?? true) && loopback
                    // Direct-dial endpoint — only when the container's IP is unambiguous;
                    // otherwise omit and the conduit falls back to docker-proxy.
                    if let ip = c.directIP { endpointMap[port] = "\(ip):\(p.privatePort)" }
                case "udp":
                    udpBinds[port] = (udpBinds[port] ?? true) && loopback
                default: break
                }
            }
        }
        // Refresh the direct-dial map every reconcile (a restart can change a container's IP
        // without changing the published-port *set*), independent of the onPorts diff below.
        endpoints?.update(endpointMap)
        // Bridge-network subnets → the host routes each to the guest so container IPs are
        // reachable. Install these BEFORE publishing names, so a freshly-resolvable
        // <name>.velox.local is routable the moment DNS answers it (rather than briefly
        // resolving a container IP whose subnet route isn't in place yet). A second cheap
        // list (coalesced); only fires the callback on a real change.
        if let onSubnets, let nets = try? await docker.networks() {
            let subnets = Set(nets.filter { $0.driver == "bridge" }.flatMap { $0.subnets }
                                  .filter { $0.contains(".") })   // IPv4 CIDRs only
            if commitSubnets(subnets) { onSubnets(subnets) }
        }
        names?.update(nameMap)
        let tcp = Set(tcpBinds.map { PublishedPort(port: $0.key, loopbackOnly: $0.value) })
        let udp = Set(udpBinds.map { PublishedPort(port: $0.key, loopbackOnly: $0.value) })
        if commit(tcp, udp) { onPorts(tcp, udp) } // idempotent reconcile; safe outside the lock
    }

    /// Atomically diff + store the bridge-subnet set; returns whether it changed.
    private func commitSubnets(_ s: Set<String>) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard s != lastSubnets else { return false }
        lastSubnets = s
        return true
    }

    /// Atomically diff + store the published-port sets; returns whether they changed.
    /// Synchronous so the lock is never held across an `await`.
    private func commit(_ tcp: Set<PublishedPort>, _ udp: Set<PublishedPort>) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard tcp != lastTCP || udp != lastUDP else { return false }
        lastTCP = tcp; lastUDP = udp
        return true
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
