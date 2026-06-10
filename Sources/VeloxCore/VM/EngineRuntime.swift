import Foundation

/// The engine plumbing both front ends (the `velox` CLI and the GUI's
/// `EngineController`) wire identically around a started VM: the Docker-API unix-socket
/// proxy, published-port forwarders (TCP + UDP, privileged ports via the porthelper),
/// the events watcher feeding them, direct named access (DNS responder + host routes),
/// clock sync, and the async VZNAT conduit-pool fast path.
///
/// Exists so a fix to this critical path lands ONCE — the CLI and GUI previously
/// duplicated ~150 lines of this wiring and drifted (the CLI never stopped the conduit
/// pool). Front-end-specific pieces stay outside: ResourceSaver (the GUI re-arms it on
/// settings changes), the GUI's resource/stats stores, the console pipe, and the CLI's
/// context binding.
///
/// Lifecycle: create after the VM is running, `start()` once, `stop()` on engine
/// shutdown (idempotent — both the explicit-stop and crash paths may call it).
public final class EngineRuntime: @unchecked Sendable {
    /// The in-process Docker API client (persistent VSOCK connections, straight to
    /// dockerd). Front ends use it for dashboards, resource savers, readiness.
    public let docker: DockerClient

    private let manager: VMManager
    private let proxy: DockerSocketProxy
    private let portHelper: PortHelperManager
    private let forwarder: PortForwarder
    private let udpForwarder: UDPForwarder
    private let endpoints: PublishedEndpoints
    private let namedRouter: NamedAccessRouter
    private let nameDNS: NameDNSResponder
    private let watcher: DockerEventsWatcher
    private let clockSync: ClockSync
    /// Set by the async gateway-probe task once the fast path is up; guarded by `lock`
    /// because `stop()` can race the probe.
    private var conduitPool: ConduitPool?
    private var stopped = false
    private let lock = NSLock()

    public init(manager: VMManager) {
        self.manager = manager
        let bridge = VsockBridge(manager: manager)
        proxy = DockerSocketProxy(
            socketPath: Paths.dockerSocket.path,
            guestPort: VsockPort.docker,
            bridge: bridge)
        docker = DockerClient(manager: manager)
        // Published ports: 127.0.0.1 listeners per `-p` port, reverse-forwarded to the
        // guest. Privileged ports (<1024) come pre-bound from the root helper.
        let helper = PortHelperManager()
        portHelper = helper
        let fwd = PortForwarder(bridge: bridge, privilegedBinder: helper)
        forwarder = fwd
        let udp = UDPForwarder(manager: manager, privilegedBinder: helper)
        udpForwarder = udp
        // Direct-dial endpoint map: the watcher fills it, the conduit pool reads it.
        endpoints = PublishedEndpoints()
        // Direct (named) container access: the watcher fills name→IP for the loopback
        // DNS responder and surfaces bridge subnets, which the router routes to the
        // guest via the porthelper. Gated on the one-time grant; inert if declined.
        let registry = NameRegistry()
        let router = NamedAccessRouter(helper: helper)
        namedRouter = router
        nameDNS = NameDNSResponder(registry: registry)
        watcher = DockerEventsWatcher(
            docker: docker,
            onPorts: helper.reconciler(
                tcp: { fwd.reconcile($0) },
                udp: { udp.reconcile($0) }),
            endpoints: endpoints,
            names: registry,
            onSubnets: { router.update(subnets: $0) })
        clockSync = ClockSync(manager: manager)
    }

    /// Wire everything up. Throws only if the Docker unix-socket proxy can't bind
    /// (everything else is best-effort and degrades gracefully).
    public func start() throws {
        try proxy.start()
        try? nameDNS.start()  // loopback-only; named access is off without it
        watcher.start()       // event-driven -p port forwarding + name registry
        clockSync.start()     // keep the guest clock aligned across host sleep
        // Fast published-port datapath: learn the (Swift-opaque) VZNAT gateway from the
        // guest, then bind a warm conduit pool so published ports ride VZNAT instead of
        // the vsock relay. Best-effort and async (the probe waits on guest DHCP): on
        // failure the forwarder keeps the vsock fallback; nothing blocks readiness.
        Task { [weak self] in
            guard let self, let info = await GatewayProbe.probe(manager: self.manager) else { return }
            let pool = ConduitPool(gateway: info, endpoints: self.endpoints)
            do {
                try pool.start()
                self.forwarder.attachConduitPool(pool)
                if !self.registerPool(pool) { pool.stop() } // raced an engine stop — don't leak the listener
            } catch {
                Log.warn("conduit pool failed to start: \(error); using vsock fallback")
            }
            // Named access: route container subnets to the guest (next hop = guest IP),
            // and request the one-time grant (porthelper install + /etc/resolver) so the
            // routes apply. Silent if already installed; declined ⇒ named access stays off.
            self.namedRouter.setGateway(info.guestIP)
            if await self.portHelper.ensureInstalled() { self.namedRouter.refresh() }
        }
    }

    /// Adopt the conduit pool unless `stop()` already ran (sync — the lock can't be
    /// taken directly in the async probe task). False ⇒ the caller must stop the pool.
    private func registerPool(_ pool: ConduitPool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        conduitPool = pool
        return true
    }

    /// Tear everything down (idempotent). Safe to call before VM stop (graceful
    /// shutdown) and again from the stopped/crashed handler.
    public func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let pool = conduitPool
        conduitPool = nil
        lock.unlock()
        watcher.stop()
        nameDNS.stop()
        namedRouter.stop()  // remove host routes so none dangle once the VM is gone
        forwarder.stopAll()
        pool?.stop()
        udpForwarder.stopAll()
        clockSync.stop()
        proxy.stop()
        // The installed helper daemon stays resident (it's idle); just drop our handle.
    }

    /// Wait for dockerd to answer before declaring the engine ready. The events
    /// watcher's first successful reconcile is the signal — no `/_ping` polling
    /// (CLAUDE.md §8). Bounded so a broken guest can't hang the caller.
    public func waitUntilDockerReady(timeout: Duration) async -> Bool {
        await watcher.waitUntilReady(timeout: timeout)
    }

    /// Surface published-port bind failures (port, blocked?) — the GUI badges the
    /// affected port links. Call before `start()`.
    public func setPortIssueHandler(_ handler: @escaping @Sendable (UInt16, Bool) -> Void) {
        forwarder.onBindIssue = handler
    }
}
