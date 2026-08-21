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
    private let bridge: VsockBridge
    private let proxy: DockerSocketProxy
    private let portHelper: PortHelperManager
    private let forwarder: PortForwarder
    private let udpForwarder: UDPForwarder
    private let endpoints: PublishedEndpoints
    private let namedRouter: NamedAccessRouter
    private let nameDNS: NameDNSResponder
    private let watcher: DockerEventsWatcher
    private let clockSync: ClockSync
    private let forwardingGuard: ForwardingGuard
    /// Set by the async gateway-probe task once the fast path is up; guarded by `lock`
    /// because `stop()` can race the probe.
    private var conduitPool: ConduitPool?
    /// The async gateway-probe task, so `stop()` can cancel it. Unowned, it kept running
    /// past a stop and its tail re-armed named access on a dead engine. Guarded by `lock`.
    private var probeTask: Task<Void, Never>?
    private var stopped = false
    private let lock = NSLock()

    public init(manager: VMManager, publish: PublishBind = .wildcard) {
        self.manager = manager
        let bridge = VsockBridge(manager: manager)
        self.bridge = bridge
        proxy = DockerSocketProxy(
            socketPath: Paths.dockerSocket.path,
            guestPort: VsockPort.docker,
            bridge: bridge)
        docker = DockerClient(manager: manager)
        // Published ports: one listener per `-p` port on the configured host address
        // (all interfaces by default, like Docker), reverse-forwarded to the guest.
        // Privileged ports (<1024) come pre-bound from the root helper.
        let helper = PortHelperManager()
        portHelper = helper
        let fwd = PortForwarder(bridge: bridge, privilegedBinder: helper, publish: publish)
        forwarder = fwd
        let udp = UDPForwarder(manager: manager, privilegedBinder: helper, publish: publish)
        udpForwarder = udp
        // Direct-dial endpoint map: the watcher fills it, the conduit pool reads it.
        endpoints = PublishedEndpoints()
        // Direct (named) container access: the watcher fills name→IP for the loopback
        // DNS responder and surfaces bridge subnets, which the router routes to the
        // guest via the porthelper. Gated on the one-time grant; inert if declined.
        let registry = NameRegistry()
        let router = NamedAccessRouter(helper: helper)
        namedRouter = router
        // Ephemeral only when the installed helper can rewrite /etc/resolver (revision 7+).
        // With an older helper that file still names the legacy fixed port and cannot be
        // updated, so binding ephemeral would leave every `*.velox.local` query pointed at a
        // port nothing is listening on. Keep the legacy port until the user approves the
        // upgrade; the next start after that goes ephemeral.
        nameDNS = NameDNSResponder(
            port: PortHelperState.supportsRuntimeResolver ? NamedAccess.dnsPort
                                                          : NamedAccess.legacyDNSPort,
            registry: registry)
        watcher = DockerEventsWatcher(
            docker: docker,
            onPorts: helper.reconciler(
                tcp: { fwd.reconcile($0) },
                udp: { udp.reconcile($0) }),
            endpoints: endpoints,
            names: registry,
            onSubnets: { router.update(subnets: $0) })
        clockSync = ClockSync(manager: manager)
        // Some VPN clients zero net.inet.ip.forwarding on connect, which kills the
        // entire vmnet NAT datapath; the guard restores it through the helper.
        forwardingGuard = ForwardingGuard(helper: helper)
    }

    /// Wire everything up. Throws only if the Docker unix-socket proxy can't bind
    /// (everything else is best-effort and degrades gracefully).
    public func start() throws {
        try proxy.start()
        // Loopback-only; named access is off without it. Don't swallow the error: a fast
        // restart can still find the previous responder's UDP port bound (its `stop()` is
        // async), and silently losing `<name>.velox.local` for the whole session with no log
        // line is precisely the kind of failure that costs an hour to diagnose.
        do {
            try nameDNS.start()
        } catch {
            Log.warn("named-access DNS responder failed to start: \(error.localizedDescription)"
                     + " — <name>.velox.local is unavailable this session")
        }
        watcher.start()       // event-driven -p port forwarding + name registry
        clockSync.start()     // keep the guest clock aligned across host sleep
        // Re-assert the named-access routes on every network path change too: the same VPN
        // churn that clears the forwarding sysctl can flush them, and nothing else notices.
        forwardingGuard.setPathChangeHandler { [weak self] in
            self?.namedRouter.refresh()
            // A pinned `publishHostIP` listener survives an address change but stops
            // receiving; nothing else notices, because the published-port set is unchanged.
            self?.forwarder.rebindPinnedAddresses()
        }
        forwardingGuard.start() // keep vmnet NAT alive alongside VPN clients
        // Fast published-port datapath: learn the (Swift-opaque) VZNAT gateway from the
        // guest, then bind a warm conduit pool so published ports ride VZNAT instead of
        // the vsock relay. Best-effort and async (the probe waits on guest DHCP): on
        // failure the forwarder keeps the vsock fallback; nothing blocks readiness.
        let probe = Task { [weak self] in
            guard let self, let info = await GatewayProbe.probe(manager: self.manager) else { return }
            guard !self.isStopped else { return }
            let pool = ConduitPool(gateway: info, endpoints: self.endpoints)
            do {
                try pool.start()
                // Adopt BEFORE publishing it to the forwarder: raced an engine stop, don't
                // leak the listener, don't hand a live pool to a stopped forwarder, and don't
                // go on to re-arm named access below for an engine that is already gone.
                if !self.registerPool(pool) { pool.stop(); return }
                self.forwarder.attachConduitPool(pool)
            } catch {
                Log.warn("conduit pool failed to start: \(error); using vsock fallback")
            }
            // Named access: route container subnets to the guest (next hop = guest IP),
            // and request the one-time grant (porthelper install + /etc/resolver) so the
            // routes apply. Silent if already installed; declined ⇒ named access stays off.
            // Re-check `stopped` at every step: `setGateway` would repopulate the gateway
            // `stop()` just cleared, and `ensureInstalled` can pop the one-time admin
            // prompt — both for an engine that no longer exists.
            guard !self.isStopped else { return }
            self.namedRouter.setGateway(info.guestIP)
            let installed = await self.portHelper.ensureInstalled()
            guard installed, !self.isStopped else { return }
            self.namedRouter.refresh()
            // Publish the responder's ACTUAL (ephemeral) port to /etc/resolver now that the
            // grant exists. Done at runtime rather than at install time so the port need not
            // be a fixed, squattable constant — see PortHelperManager.setResolver.
            let dnsPort = self.nameDNS.boundPort
            if dnsPort != 0, !self.portHelper.setResolver(port: dnsPort) {
                Log.warn("named-access: could not publish /etc/resolver/\(NamedAccess.domain) "
                         + "→ 127.0.0.1:\(dnsPort); <name>.\(NamedAccess.domain) will not resolve")
            }
        }
        adoptProbeTask(probe)
    }

    /// Whether `stop()` has run. Synchronous, so the lock is never held across an `await`.
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Keep the probe task so `stop()` can cancel it — unless the stop already happened
    /// while it was being created, in which case cancel it right away.
    private func adoptProbeTask(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { probeTask = task }
        lock.unlock()
        if alreadyStopped { task.cancel() }
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
    ///
    /// Pass `waitForTeardown: true` from a path that exits the process immediately
    /// afterwards (app termination). Most children release process-owned resources that
    /// the kernel reclaims at exit anyway, but the named-access **host routes** are
    /// installed out-of-process by the porthelper and would survive — so that removal
    /// has to actually complete. Blocking, so call it off the main thread.
    public func stop(waitForTeardown: Bool = false) {
        lock.lock()
        if stopped {
            lock.unlock()
            // An earlier stop (typically `cleanup()` on the crash path) may have queued the
            // route removal asynchronously. A caller that is about to exit still needs it to
            // have landed, and the router's serial queue makes this wait for that removal.
            if waitForTeardown { namedRouter.stop(wait: true) }
            return
        }
        stopped = true
        let pool = conduitPool
        conduitPool = nil
        let probe = probeTask
        probeTask = nil
        lock.unlock()
        probe?.cancel()
        forwardingGuard.stop()
        watcher.stop()
        nameDNS.stop()
        namedRouter.stop(wait: waitForTeardown)  // remove host routes so none dangle once the VM is gone
        forwarder.stopAll()
        pool?.stop()
        udpForwarder.stopAll()
        clockSync.stop()
        // ORDER MATTERS. Stop *admitting* first, then drain. Both the conduit path and the
        // Docker-API path now hand their pairs to the one shared relay, so draining it before
        // the producers are shut would let a connection that lands in between (an accept the
        // proxy's async cancel hasn't stopped yet, or a vsock connect callback still in
        // flight) be spliced in AFTER the drain and survive the stop.
        proxy.stop()          // stop accepting on the docker socket…
        bridge.stopAll()      // …and stop admitting new bridged streams
        // Withdraw the system resolver entry: leaving it behind points every
        // `*.velox.local` query on the machine at a loopback port nobody is listening on —
        // and, worse, one that any local process is then free to take over.
        // Synchronous only on the exit path (which runs off the main actor); otherwise
        // dispatched, because each helper round trip is a blocking 3 s-bounded socket call.
        let helper = portHelper
        if waitForTeardown { helper.setResolver(port: 0) }
        else { DispatchQueue.global().async { helper.setResolver(port: 0) } }
        // Now drop every established pair. These live in the shared relay, not in the pool's
        // or the bridge's own fd sets — and it is drained here rather than inside
        // `ConduitPool.stop()` so a stale pool stopping late can't cut a *newer* engine's
        // live connections.
        EventRelay.shared.stopAll()
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
        udpForwarder.onBindIssue = handler   // a failed UDP bind was invisible in the UI
    }
}
