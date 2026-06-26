import SwiftUI
import VeloxCore

/// Aggregates the four resource lists into headline counts/sizes and streams a
/// live CPU/memory total across every running container. Like the other models
/// it reconciles on the Docker `events` stream rather than polling.
@MainActor
@Observable
final class OverviewModel {
    let store: DockerResourceStore
    /// Resolved location of `data.img` (honors a relocated data disk). The model is recreated
    /// on every pane switch, so capturing it at init stays correct after a move.
    private let dataDiskURL: URL
    private(set) var diskUsedBytes: Int64?

    init(store: DockerResourceStore, dataDiskURL: URL) {
        self.store = store
        self.dataDiskURL = dataDiskURL
        // Synchronous metadata read — fill the disk gauge BEFORE the first frame so
        // it never renders "—" and flips a beat later (the model is recreated on
        // every pane switch, so this covers each appearance).
        refreshDiskUsage()
    }

    // List data is read from the shared store (persistent across pane switches); the
    // live CPU/memory aggregate below stays Overview-scoped (it streams 18 stats only
    // while this pane is on screen).
    var containers: [ContainerSummary] { store.containers }
    var images: [ImageSummary] { store.images }
    var volumes: [Volume] { store.volumes }
    var loadError: String? { store.containersError ?? store.imagesError ?? store.volumesError }

    var runningCount: Int { containers.lazy.filter(\.isRunning).count }
    var totalImageBytes: Int64 { images.reduce(0) { $0 + $1.size } }
    var totalVolumeBytes: Int64 { volumes.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Host-side read of the data disk's actual (sparse) footprint. Cheap; refreshed
    /// on appear and when the container set changes.
    func refreshDiskUsage() {
        let vals = try? dataDiskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        diskUsedBytes = vals?.totalFileAllocatedSize.map(Int64.init)
    }
}

/// The home page: an engine hero strip, a grid of resource metrics, and a live
/// usage section. Shown by the shell only while the engine is running.
struct OverviewView: View {
    let stats: StatsStore
    @Environment(EngineController.self) private var engine
    @State private var model: OverviewModel
    @State private var showReclaim = false
    // The /system/df snapshot lives in the STORE (not view state): it survives pane
    // switches, so the breakdown card renders instantly on return instead of popping
    // in. Refreshed with the disk gauge (on appear + when the container set changes;
    // no timer); a failure keeps the snapshot and surfaces the error in the banner.

    init(store: DockerResourceStore, stats: StatsStore, dataDiskURL: URL) {
        self.stats = stats
        _model = State(initialValue: OverviewModel(store: store, dataDiskURL: dataDiskURL))
    }

    private let columns = Array(repeating: GridItem(.flexible(minimum: 136), spacing: Theme.gridSpacing),
                                count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let error = model.loadError ?? dfError { errorBanner(error) }
                statGrid
                if let df = model.store.diskUsage { DiskBreakdownCard(usage: df) }
                // A separate view so its per-sample stats reads don't re-evaluate the
                // whole Overview body (and its O(N) stat-card reductions) every tick.
                LiveUsageSection(stats: stats)
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .retainingStats(stats)
        .task(id: model.containers.count) {
            model.refreshDiskUsage()
            await model.store.refreshDiskUsage()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showReclaim = true } label: {
                    Label("Reclaim Space", systemImage: "sparkles")
                }
                .help("Free disk space — prune unused Docker data")
            }
        }
        .sheet(isPresented: $showReclaim) {
            if let docker = engine.docker {
                ReclaimSpaceSheet(docker: docker, seed: model.store.diskUsage,
                                  isPresented: $showReclaim) {
                    model.refreshDiskUsage()
                    Task { await model.store.refreshDiskUsage() }
                }
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        DashboardCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(engine.state.tint.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: engine.state.menuBarSymbol)
                        .font(.title2)
                        .foregroundStyle(engine.state.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Engine \(engine.state.label)").font(.headline)
                        if engine.state.isRunning, let started = engine.startedAt {
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text("· up \(Format.uptime(since: started))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(allocationSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Velox \(Versions.velox)").font(.callout).foregroundStyle(.secondary)
                    Text("Docker \(Versions.dockerVersion)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var dfError: String? {
        model.store.diskUsageError.map { "Disk breakdown unavailable: \($0)" }
    }

    private var allocationSummary: String {
        let c = engine.config
        return "\(c.cpuCount) vCPU · \(c.memoryGiB) GB RAM · \(c.diskGiB) GB disk"
    }

    // MARK: Stat grid

    private var statGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.gridSpacing) {
            StatCard(title: "Containers", systemImage: "shippingbox", value: "\(model.runningCount)",
                     caption: "of \(model.containers.count) total", tint: .green)
            StatCard(title: "Images", systemImage: "square.stack.3d.up", value: "\(model.images.count)",
                     caption: "\(Format.bytes(model.totalImageBytes)) total", tint: .blue)
            StatCard(title: "Volumes", systemImage: "externaldrive", value: "\(model.volumes.count)",
                     caption: "\(Format.bytes(model.totalVolumeBytes)) stored", tint: .orange)
            StatCard(title: "Disk", systemImage: "internaldrive",
                     value: model.diskUsedBytes.map(Format.bytes) ?? "—",
                     caption: "of \(engine.config.diskGiB) GB allocated", tint: .purple)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The aggregate CPU/memory section. Its own view so the per-sample `stats` reads
/// re-render only this — not the parent Overview body (and its stat-card reductions).
private struct LiveUsageSection: View {
    let stats: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Live Usage").font(.headline)
                Text("Aggregate across running containers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: Theme.gridSpacing) {
                HStack(spacing: Theme.gridSpacing) {
                    LiveMetricCard(title: "CPU", tint: .green,
                                   value: String(format: "%.0f%%", stats.totalCPU),
                                   history: stats.cpuHistory)
                    LiveMetricCard(title: "Memory", tint: .blue,
                                   value: Format.bytes(stats.totalMemBytes),
                                   history: stats.memHistory)
                }
                // Disk and Network are bidirectional, so they get the mirrored macOS-style
                // graph — Read/In above the baseline, Write/Out below — not a single line.
                HStack(spacing: Theme.gridSpacing) {
                    LiveIOCard(title: "Disk I/O", upLabel: "Read", downLabel: "Write",
                               upValue: stats.totalDiskRead, downValue: stats.totalDiskWrite,
                               upHistory: stats.diskReadHistory, downHistory: stats.diskWriteHistory)
                    LiveIOCard(title: "Network", upLabel: "In", downLabel: "Out",
                               upValue: stats.totalNetRx, downValue: stats.totalNetTx,
                               upHistory: stats.netRxHistory, downHistory: stats.netTxHistory)
                }
            }
        }
    }
}

/// A live metric tile: a headline value over a wide sparkline. The chart
/// auto-scales to its own recent peak (with headroom) so real usage fills the
/// plot instead of flat-lining against the full VM allocation.
private struct LiveMetricCard: View {
    let title: String
    let tint: Color
    let value: String
    let history: [Double]

    /// 30% headroom above the window's peak, so the line never pegs the top and
    /// a rising trend still has room to climb. Falls back to 1 when idle (all-zero).
    private var ceiling: Double {
        let peak = history.max() ?? 0
        return peak > 0 ? peak * 1.3 : 1
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                SparklineView(values: history, maxValue: ceiling, tint: tint)
                    .frame(height: 46)
            }
        }
    }
}

/// A live bidirectional-I/O tile (macOS Activity Monitor style): two mirrored throughput
/// series over a center baseline, with the up/down rates shown as colored readouts that
/// double as the legend. Used for Disk (Read up / Write down) and Network (In up / Out down).
private struct LiveIOCard: View {
    let title: String
    let upLabel: String
    let downLabel: String
    let upValue: Double      // bytes/sec
    let downValue: Double
    let upHistory: [Double]
    let downHistory: [Double]
    var upTint: Color = .blue
    var downTint: Color = .red

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    readout(upLabel, upValue, upTint)
                    readout(downLabel, downValue, downTint)
                }
                .lineLimit(1)
                MirroredSparklineView(up: upHistory, down: downHistory,
                                      upTint: upTint, downTint: downTint)
                    .frame(height: 54)
            }
        }
    }

    private func readout(_ label: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.weight(.semibold))
            Text(Format.bytes(UInt64(max(0, value))) + "/s")
                .font(.callout.monospacedDigit())
                .contentTransition(.numericText())
        }
        .foregroundStyle(tint)
    }
}

/// What's on the data disk, by category — a stacked proportion bar + legend. Data
/// from the same `/system/df` snapshot that prices the Reclaim Space toggles.
private struct DiskBreakdownCard: View {
    let usage: DiskUsage

    private var segments: [(String, UInt64, Color)] {
        [("Images", usage.imagesTotal, .blue),
         ("Containers", usage.containersTotal, .green),
         ("Volumes", usage.volumesTotal, .purple),
         ("Build cache", usage.buildCacheTotal, .orange)].filter { $0.1 > 0 }
    }

    var body: some View {
        let total = segments.reduce(UInt64(0)) { $0 + $1.1 }
        if total > 0 {
            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Disk Breakdown").font(.headline)
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(segments, id: \.0) { seg in
                                seg.2.opacity(0.75)
                                    .frame(width: max(2, geo.size.width
                                        * CGFloat(seg.1) / CGFloat(total)))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(height: 8)
                    HStack(spacing: 14) {
                        ForEach(segments, id: \.0) { seg in
                            HStack(spacing: 4) {
                                Circle().fill(seg.2.opacity(0.75)).frame(width: 7, height: 7)
                                Text(verbatim: "\(seg.0) \(Format.bytes(seg.1))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// "Reclaim Space" — the four prune levers in one dialog, with the freed total shown
/// after. Velox can make a promise Docker Desktop can't: the guest's periodic TRIM
/// hole-punches the raw data disk, so reclaimed bytes return to macOS by themselves.
private struct ReclaimSpaceSheet: View {
    let docker: any DockerClientProtocol
    @Binding var isPresented: Bool
    /// Called after a successful run so the disk gauge refreshes.
    var onReclaimed: () -> Void = {}

    @State private var stoppedContainers = true
    @State private var unusedImages = true
    @State private var buildCache = true
    @State private var unusedVolumes = false
    @State private var running = false
    @State private var reclaimed: UInt64?
    @State private var failure: String?
    /// Each toggle shows what it frees. Seeded with the store's last snapshot so the
    /// sheet opens with sizes already in place (no pop-in); a fresh fetch on open —
    /// and after a run — updates them.
    @State private var usage: DiskUsage?

    init(docker: any DockerClientProtocol, seed: DiskUsage?, isPresented: Binding<Bool>,
         onReclaimed: @escaping () -> Void = {}) {
        self.docker = docker
        self.onReclaimed = onReclaimed
        _isPresented = isPresented
        _usage = State(initialValue: seed)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $stoppedContainers) {
                        sized("Stopped containers", usage?.containersReclaimable)
                    }
                    Toggle(isOn: $unusedImages) {
                        sized("Unused images", usage?.imagesReclaimable)
                    }
                    Toggle(isOn: $buildCache) {
                        sized("Build cache", usage?.buildCacheReclaimable)
                    }
                    Toggle(isOn: $unusedVolumes) {
                        sized("Unused volumes", usage?.volumesReclaimable)
                    }
                    .tint(.red)
                } header: {
                    Text("Reclaim Space")
                } footer: {
                    Text("Removes Docker data nothing references. Volumes hold real data — leave them off unless you're sure. Freed space returns to macOS automatically (the data disk is TRIMmed).")
                }
                if let reclaimed {
                    Section {
                        Label("Reclaimed \(Format.bytes(reclaimed))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(reclaimed == nil ? "Cancel" : "Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Reclaim", role: .destructive) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running ||
                              !(stoppedContainers || unusedImages || buildCache || unusedVolumes))
            }
            .padding(12)
        }
        .frame(width: 400, height: 380)
        .task { usage = try? await docker.systemDiskUsage() }
    }

    /// Toggle label with the category's reclaimable size beside it ("— 1.2 GB").
    private func sized(_ title: String, _ bytes: UInt64?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let bytes {
                Text(verbatim: bytes == 0 ? "—" : "≈ " + Format.bytes(bytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func run() {
        running = true
        failure = nil
        let (c, i, b, v) = (stoppedContainers, unusedImages, buildCache, unusedVolumes)
        let docker = docker
        Task {
            var total: UInt64 = 0
            do {
                if c { total += try await docker.pruneContainers() }
                if i { total += try await docker.pruneImages(all: true) }
                if b { total += try await docker.pruneBuildCache() }
                if v { total += try await docker.pruneVolumes() }
                reclaimed = total
                onReclaimed()
                // Re-fetch so the per-toggle sizes reflect what's left after the run.
                usage = try? await docker.systemDiskUsage()
            } catch {
                failure = "\(error)"
            }
            running = false
        }
    }
}

#if DEBUG
struct OverviewView_Previews: PreviewProvider {
    static var previews: some View {
        OverviewView(store: DockerResourceStore(docker: MockDockerClient()),
                     stats: StatsStore(docker: MockDockerClient(),
                                       resources: DockerResourceStore(docker: MockDockerClient())),
                     dataDiskURL: Paths.dataDisk)
            .environment(EngineController())
            .frame(width: 820, height: 560)
    }
}
#endif
