import AppKit
import Foundation
import VeloxCore

/// Which engine the dashboards are currently showing.
enum HostSelection: Hashable {
    /// The embedded Velox engine on this Mac.
    case local
    /// A remote Docker host, by `RemoteHost.id`.
    case remote(String)

    var isLocal: Bool { self == .local }
    var remoteID: String? {
        if case .remote(let id) = self { return id }
        return nil
    }
}

/// One connected remote host: its SSH tunnel plus the same store trio the local engine
/// gets. Nothing here is remote-specific except the tunnel — `DockerResourceStore` and
/// `StatsStore` are the very same types the local dashboards use, because a remote host
/// is just another `DockerClientProtocol` behind a different connector.
@MainActor
@Observable
final class RemoteHostSession {
    let host: RemoteHost
    private(set) var state: SSHTunnel.State = .stopped

    let docker: any DockerClientProtocol
    let resources: DockerResourceStore
    let stats: StatsStore
    /// Per-host pane state: search text, selections, collapsed groups. Deliberately NOT
    /// shared with the local engine or other hosts — names and IDs collide across
    /// daemons, exactly as they do across workspaces (`PaneUIState.clearSelections`).
    let paneUI = PaneUIState()
    /// Always empty for a remote host: `PortIssues` records *this Mac's* failed localhost
    /// bindings, which a remote container's published port never involves. Present so the
    /// Containers pane takes the same shape for both engines rather than growing an
    /// optional.
    let portIssues = PortIssues()

    private let tunnel: SSHTunnel

    init(host: RemoteHost) {
        self.host = host
        let tunnel = SSHTunnel(host: host)
        self.tunnel = tunnel
        let client = DockerClient(connector: tunnel.connector)
        self.docker = client
        let resources = DockerResourceStore(docker: client)
        self.resources = resources
        self.stats = StatsStore(docker: client, resources: resources)
    }

    /// Bring the tunnel up. The informer follows the tunnel's state rather than running
    /// independently. Idempotent.
    func start() {
        // The tunnel publishes from a background queue; hop to the main actor to touch
        // observable state.
        tunnel.onStateChange = { [weak self, weak tunnel] _ in
            Task { @MainActor in
                guard let self, let tunnel else { return }
                // Read the tunnel's CURRENT state rather than the value this notification
                // carried. Two `Task { @MainActor }` hops enqueued from the tunnel's queue
                // have no ordering guarantee between them, so a stale one could otherwise
                // leave the informer stopped while the tunnel is connecting — and with
                // nothing calling `containers()`, `markReachable` would never fire and the
                // session would sit wedged. Converging on the live value is order-free.
                let state = tunnel.state
                self.state = state
                // The informer's own reconnect loop retries every second, forever, and a
                // session is only torn down by an explicit Disconnect — so a host that is
                // simply switched off cost a permanent ~6-connect/second probe in the
                // background. The tunnel already owns a bounded backoff for exactly this;
                // gating the informer on its state means one retry policy, driven by the
                // child's exit rather than by a timer that checks (CLAUDE.md §8, §10).
                switch state {
                case .connecting, .connected: self.resources.start()
                case .failed, .stopped:       self.resources.stop()
                }
            }
        }
        // The daemon answering is what "connected" means — see `onReachable`.
        resources.onReachable = { [weak self] in self?.tunnel.markReachable() }
        tunnel.start()
    }

    func stop() {
        // Unwire first: both callbacks fire from other contexts (the tunnel from its own
        // queue, the store from its informer task), and leaving them attached means a
        // stopped session can still be called back into. `weak self` makes that harmless
        // rather than correct — this makes it not happen.
        tunnel.onStateChange = nil
        resources.onReachable = nil
        resources.stop()
        stats.stop()
        tunnel.stop()
        state = .stopped
    }
}

/// Owns the remote-host list, the active selection, and one `RemoteHostSession` per
/// connected host.
///
/// Sessions are created **lazily, on first selection** — launching Velox does not dial
/// every configured server. Once connected a session stays up (so its sidebar row keeps
/// showing a live container count) until the user disconnects it or the app quits.
@MainActor
@Observable
final class RemoteHostController {
    private(set) var hosts: [RemoteHost] = []
    /// Set when `hosts.json` exists but can't be read — surfaced instead of silently
    /// showing an empty list.
    private(set) var loadError: String?

    private(set) var selection: HostSelection = .local
    private(set) var sessions: [String: RemoteHostSession] = [:]

    let panel = RemoteHostPanel()

    /// Stored so it can actually be removed in `deinit` — unlike `EngineController`, which
    /// discards its token. `@ObservationIgnored` keeps the `@Observable` macro from wrapping
    /// it (a wrapped property can't be `nonisolated`), and `nonisolated(unsafe)` is sound
    /// here because `deinit` is nonisolated, `removeObserver` is thread-safe, and the token
    /// is written exactly once from the main actor.
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    init() {
        reload()
        // Re-read the manifest when the app comes to the front, so a hand edit (or a second
        // Velox process) is picked up rather than being invisible until relaunch. A push,
        // not a poll (CLAUDE.md §8) — the same activation hook the workspace list uses.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    // MARK: - List

    /// Creation order, so connecting or renaming never reshuffles the sidebar — the same
    /// reasoning as `EngineController.sortedWorkspaces`.
    var sortedHosts: [RemoteHost] {
        hosts.sorted { $0.created < $1.created }
    }

    func host(id: String) -> RemoteHost? { hosts.first { $0.id == id } }

    func reload() {
        do {
            let loaded = try RemoteHostStore.load().hosts
            // Only publish a real change: this runs on every app activation, and
            // reassigning an identical list would invalidate every sidebar view each time
            // the user cmd-tabs back.
            if hosts != loaded { hosts = loaded }
            loadError = nil
            // A host removed from the manifest elsewhere leaves a live session — and an
            // `ssh` child — with no row left to disconnect it from.
            for id in sessions.keys where !hosts.contains(where: { $0.id == id }) {
                disconnect(id: id)
            }
        } catch {
            loadError = "\(error)"
        }
    }

    /// Move an unreadable `hosts.json` aside and start clean. Offered on the sidebar's error
    /// banner, because a corrupt file otherwise fails every mutation including the delete
    /// that would fix it.
    func resetCorruptManifest() {
        do {
            let quarantined = try RemoteHostStore.quarantineCorruptManifest()
            reload()
            panel.error = "The unreadable host list was moved to \(quarantined.lastPathComponent). "
                + "Your hosts can be added again; nothing on any server was changed."
        } catch {
            panel.error = "\(error)"
        }
    }

    // MARK: - Selection

    func select(_ selection: HostSelection) {
        self.selection = selection
        if let id = selection.remoteID, let host = host(id: id) {
            connect(host)
        }
    }

    var activeSession: RemoteHostSession? {
        guard let id = selection.remoteID else { return nil }
        return sessions[id]
    }

    // MARK: - Connection

    @discardableResult
    func connect(_ host: RemoteHost) -> RemoteHostSession {
        if let existing = sessions[host.id] { return existing }
        let session = RemoteHostSession(host: host)
        sessions[host.id] = session
        session.start()
        return session
    }

    func disconnect(id: String) {
        sessions.removeValue(forKey: id)?.stop()
        if selection.remoteID == id { selection = .local }
    }

    /// Tear every session down and **wait** for the ssh children to actually be signalled.
    ///
    /// Called from `applicationShouldTerminate`, where returning early means the process
    /// exits with its `ssh -N` children orphaned — they are not killed with their parent and
    /// never exit on their own, so they would accumulate across launches while holding
    /// sessions to the user's servers.
    func disconnectAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        selection = .local
        SSHTunnel.drainPendingWork()
    }

    func session(for id: String) -> RemoteHostSession? { sessions[id] }

    func capabilities(for host: RemoteHost) -> RemoteHostCapabilities {
        RemoteHostCapabilities(isSelected: selection.remoteID == host.id,
                               hasSession: sessions[host.id] != nil)
    }

    // MARK: - Operations
    //
    // Every one is a manifest edit plus, at most, tearing down this process's own
    // session. Velox never changes anything on the server.

    func addHost(name: String, user: String, hostname: String, port: Int,
                 socketPath: String, identityFile: String?) {
        let host = RemoteHost(name: RemoteHost.normalized(name),
                              user: RemoteHost.normalized(user),
                              hostname: RemoteHost.normalized(hostname),
                              port: RemoteHost.clampPort(port),
                              socketPath: RemoteHost.normalized(socketPath),
                              identityFile: identityFile.flatMap {
                                  let trimmed = RemoteHost.normalized($0)
                                  return trimmed.isEmpty ? nil : trimmed
                              })
        do {
            hosts = try RemoteHostStore.create(host).hosts
            panel.dismiss()
            select(.remote(host.id))
        } catch {
            // Keep the sheet up with everything typed still in it.
            panel.draftError = "\(error)"
        }
    }

    func rename(_ host: RemoteHost, to name: String) {
        do {
            hosts = try RemoteHostStore.rename(id: host.id, to: name).hosts
            panel.dismiss()
        } catch {
            panel.fail("\(error)")
        }
    }

    func delete(_ host: RemoteHost) {
        // Tear the session down first: its tunnel owns a child process and a socket in
        // `~/.velox/hosts/`, and the manifest row is the only record that they exist.
        disconnect(id: host.id)
        do {
            hosts = try RemoteHostStore.delete(id: host.id).hosts
            panel.dismiss()
        } catch {
            panel.fail("\(error)")
        }
    }
}

/// What the sidebar's context menu may offer for one host. Pure policy, mirroring
/// `WorkspaceCapabilities` — kept out of the view so the rules are testable and stated
/// once.
struct RemoteHostCapabilities: Equatable {
    let isSelected: Bool
    let canConnect: Bool
    let canDisconnect: Bool

    init(isSelected: Bool, hasSession: Bool) {
        self.isSelected = isSelected
        self.canConnect = !hasSession
        self.canDisconnect = hasSession
    }
}
