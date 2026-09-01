import Foundation
import VeloxCore

/// The single, persistent source of truth for the four Docker resource lists the
/// dashboards render (containers, images, volumes, networks).
///
/// **Why it exists:** the sidebar's detail pane rebuilds each dashboard view from
/// scratch on every selection change, so view-local fetching meant every pane switch
/// threw away its data and re-fetched from empty — a visible "No images" flash plus
/// the round-trip latency, every time, multiplied under many containers. This store is
/// owned by `EngineController` (above the navigation), so it **survives pane switches**:
/// the dashboards just read already-loaded data and switching is instant.
///
/// It follows the CLAUDE.md §8 informer pattern: one persistent `events()` stream is
/// the trigger, a full per-resource reconcile is the source of truth (re-run on every
/// (re)connect so a missed event or daemon restart self-heals). Per-event refreshes are
/// coalesced, so a burst (e.g. `compose up` of 18 containers) collapses to one reconcile
/// instead of a storm through the serialized `DockerClient`.
@MainActor
@Observable
final class DockerResourceStore {
    private(set) var containers: [ContainerSummary] = []
    private(set) var images: [ImageSummary] = []
    private(set) var volumes: [Volume] = []
    private(set) var networks: [NetworkSummary] = []

    private(set) var containersError: String?
    private(set) var imagesError: String?
    private(set) var volumesError: String?
    private(set) var networksError: String?

    // Whether each resource has completed at least one load — so a view shows a spinner
    // on first load and "No X" only after a real empty result (never a startup flash).
    private(set) var containersLoaded = false
    private(set) var imagesLoaded = false
    private(set) var volumesLoaded = false
    private(set) var networksLoaded = false

    enum Resource: CaseIterable { case containers, images, volumes, networks }

    private let docker: any DockerClientProtocol
    private var eventsTask: Task<Void, Never>?
    private var debounce: [Resource: Task<Void, Never>] = [:]

    init(docker: any DockerClientProtocol) { self.docker = docker }

    /// Begin the informer: full reconcile on (re)connect, then refresh the affected
    /// resource per event. Idempotent — safe to call once when the engine starts.
    func start() {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                await self.refreshSystemInfo()
                for await event in self.docker.events() {
                    if Task.isCancelled { return }
                    self.handle(event)
                }
                // Stream ended (daemon not up yet, or restarted). Back off, reconnect —
                // the next loop's refreshAll() re-syncs the full state.
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        eventsTask?.cancel(); eventsTask = nil
        for task in debounce.values { task.cancel() }
        debounce.removeAll()
    }

    /// Container lifecycle actions that change a network's attached-container list.
    /// (Membership also arrives as `network` connect/disconnect events; this is the
    /// robust trigger.) Deliberately excludes frequent `health_status` / `exec_*`
    /// events so a healthcheck loop doesn't re-run the costly `networks()` in the
    /// background when you aren't even viewing Networks.
    private static let lifecycleActions: Set<String> =
        ["create", "start", "stop", "die", "kill", "restart", "destroy", "rename"]

    /// Fired on container `die` events with the name and exit code — the crash
    /// notifier hangs off this so it shares the one events stream (CLAUDE.md §8).
    var onContainerDied: ((String, Int) -> Void)?

    /// Fired whenever a container list actually comes back from the daemon. For a remote
    /// host this is the readiness signal its `SSHTunnel` reports as "connected": the
    /// daemon answering *is* the event, so nothing has to poll `/_ping` or watch for the
    /// forwarded socket file to appear (CLAUDE.md §8).
    var onReachable: (() -> Void)?

    /// Route an event to the resource(s) it can change.
    private func handle(_ event: DockerEvent) {
        switch event.type {
        case "image":   schedule(.images)
        case "volume":  schedule(.volumes)
        case "network": schedule(.networks)
        case "container", nil:
            schedule(.containers)
            if event.action == "die", let onContainerDied {
                onContainerDied(event.containerName ?? "container", event.exitCode ?? 0)
            }
            if let action = event.action, Self.lifecycleActions.contains(action) {
                schedule(.networks)
                // A transition invalidates the lifecycle anchor even when the listed
                // state ends up unchanged (restart: running → running) — drop it so
                // the next refresh re-anchors from fresh StartedAt/FinishedAt.
                if let name = event.containerName,
                   let id = containers.first(where: { $0.displayName == name })?.id {
                    anchors[id] = nil
                }
            }
        default: break
        }
    }

    /// Coalesce a burst into a single refresh ~120 ms after the *first* event of the
    /// burst — a leading-edge schedule with a trailing fire. Crucially it does **not**
    /// reset the timer on each event (that classic debounce would starve under a
    /// sustained event stream and never fire); events arriving while one is pending are
    /// simply absorbed. The slot is cleared just before the fetch, so an event that
    /// lands during the fetch schedules the next one — eventual consistency, no misses.
    private func schedule(_ resource: Resource) {
        guard debounce[resource] == nil else { return }
        debounce[resource] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.debounce[resource] = nil
            await self.refresh(resource)
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for resource in Resource.allCases {
                group.addTask { await self.refresh(resource) }
            }
        }
    }

    /// Re-read one resource list. Errors are surfaced per-resource (not thrown) so one
    /// failing list never blanks the others. `…Loaded` flips only on the first *success*
    /// (not a failed attempt), so the startup race — store starting before dockerd
    /// answers — shows nothing rather than a false "No X". For the same reason an error
    /// is recorded only *after* that first successful load: a pre-ready failure while
    /// dockerd is still coming up (e.g. ECONNRESET / "Connection reset by peer") is
    /// expected and stays silent, so the Overview never flashes it on launch. A genuine
    /// mid-session failure — after the list has loaded once — still surfaces.
    func refresh(_ resource: Resource) async {
        switch resource {
        case .containers:
            do {
                containers = try await docker.containers()
                containersError = nil; containersLoaded = true
                onReachable?()
                await refreshAnchors()
            }
            catch { if containersLoaded { containersError = "\(error)" } }
        case .images:
            do { images = try await docker.images(); imagesError = nil; imagesLoaded = true }
            catch { if imagesLoaded { imagesError = "\(error)" } }
        case .volumes:
            do { volumes = try await docker.volumes(); volumesError = nil; volumesLoaded = true }
            catch { if volumesLoaded { volumesError = "\(error)" } }
        case .networks:
            do { networks = try await docker.networks(); networksError = nil; networksLoaded = true }
            catch { if networksLoaded { networksError = "\(error)" } }
        }
    }

    // Immediate refresh after a user action, so the UI doesn't wait for the event echo.
    func refreshContainers() async { await refresh(.containers) }
    func refreshImages() async { await refresh(.images) }
    func refreshVolumes() async { await refresh(.volumes) }
    func refreshNetworks() async { await refresh(.networks) }

    // MARK: - Host info (/info)

    /// What machine is running this daemon — CPU count, RAM, OS, engine version. Refreshed
    /// on every (re)connect rather than on a timer: it cannot change under a live daemon,
    /// and a daemon restart re-runs this path anyway.
    private(set) var systemInfo: SystemInfo?

    func refreshSystemInfo() async {
        systemInfo = try? await docker.systemInfo()
    }

    // MARK: - Disk usage (/system/df)

    /// Last `/system/df` snapshot — sizes by category for the Overview breakdown and
    /// the Reclaim sheet. Fetched on demand (df walks every image/container/volume in
    /// the engine — too heavy to refresh per event), but cached HERE so those views
    /// render the last snapshot instantly on every appearance and update in place;
    /// view-local state made the breakdown card pop in on each pane switch. A failed
    /// refresh keeps the snapshot and surfaces the error.
    private(set) var diskUsage: DiskUsage?
    private(set) var diskUsageError: String?

    func refreshDiskUsage() async {
        do {
            diskUsage = try await docker.systemDiskUsage()
            diskUsageError = nil
        } catch {
            diskUsageError = DockerClient.diskUsageMessage(for: "\(error)")
        }
    }

    // MARK: - Lifecycle anchors (native uptime, no polling)

    /// A running container's lifecycle anchor: when it started, per dockerd's own
    /// RFC3339 StartedAt. The UI renders Docker-style uptime from it on a minute-tick
    /// TimelineView — replacing the old re-list of Docker's pre-rendered "Up 3 minutes"
    /// strings (the last GUI timer). Stopped containers don't get one — the UI shows
    /// a plain "Stopped", so inspecting them would be a wasted round-trip.
    struct LifeAnchor: Equatable {
        let state: String
        let date: Date?
    }

    private(set) var anchors: [String: LifeAnchor] = [:]

    /// Fetch anchors for running containers whose (id, state) we haven't inspected
    /// yet, and drop anchors for containers that are gone. One inspect per lifecycle
    /// transition — never per render, never on a timer. Bounded parallel.
    private func refreshAnchors() async {
        let current = containers
        let ids = Set(current.map(\.id))
        anchors = anchors.filter { ids.contains($0.key) }
        let missing = current.filter { $0.isRunning && anchors[$0.id]?.state != $0.state }
        guard !missing.isEmpty else { return }
        let docker = self.docker
        let fetched: [(String, LifeAnchor)] = await withTaskGroup(
            of: (String, LifeAnchor)?.self
        ) { group in
            for c in missing.prefix(32) {
                group.addTask {
                    guard let info = try? await docker.inspectContainer(c.id) else { return nil }
                    return (c.id, LifeAnchor(state: c.state,
                                             date: DockerDates.parse(info.state?.startedAt)))
                }
            }
            var out: [(String, LifeAnchor)] = []
            for await item in group { if let item { out.append(item) } }
            return out
        }
        for (id, anchor) in fetched { anchors[id] = anchor }
        // Continue only if this pass made PROGRESS. `missing` shrinks solely because
        // `anchors` grew, and `anchors` grows solely from a SUCCESSFUL inspect — so when
        // every inspect in the batch fails (engine stopping: the socket is gone and the
        // tasks are cancelled) an unconditional recursion never terminates. That is a tight
        // loop spawning 32 child tasks per turn, pegging a core and growing the heap until
        // the app is force-quit. Bail on cancellation too, so a stop ends this immediately.
        guard !fetched.isEmpty, !Task.isCancelled, missing.count > 32 else { return }
        await refreshAnchors()
    }
}
