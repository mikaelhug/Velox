import SwiftUI
import VeloxCore

/// Aggregates the four resource lists into headline counts/sizes and streams a
/// live CPU/memory total across every running container. Like the other models
/// it reconciles on the Docker `events` stream rather than polling.
@MainActor
@Observable
final class OverviewModel {
    let store: DockerResourceStore
    private(set) var diskUsedBytes: Int64?

    init(store: DockerResourceStore) { self.store = store }

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
        let vals = try? Paths.dataDisk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        diskUsedBytes = vals?.totalFileAllocatedSize.map(Int64.init)
    }
}

/// The home page: an engine hero strip, a grid of resource metrics, and a live
/// usage section. Shown by the shell only while the engine is running.
struct OverviewView: View {
    let stats: StatsStore
    @Environment(EngineController.self) private var engine
    @State private var model: OverviewModel

    init(store: DockerResourceStore, stats: StatsStore) {
        self.stats = stats
        _model = State(initialValue: OverviewModel(store: store))
    }

    private let columns = Array(repeating: GridItem(.flexible(minimum: 136), spacing: Theme.gridSpacing),
                                count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let error = model.loadError { errorBanner(error) }
                statGrid
                // A separate view so its per-sample stats reads don't re-evaluate the
                // whole Overview body (and its O(N) stat-card reductions) every tick.
                LiveUsageSection(stats: stats)
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .retainingStats(stats)
        .task(id: model.containers.count) { model.refreshDiskUsage() }
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
            HStack(spacing: Theme.gridSpacing) {
                LiveMetricCard(title: "CPU", tint: .green,
                               value: String(format: "%.0f%%", stats.totalCPU),
                               history: stats.cpuHistory)
                LiveMetricCard(title: "Memory", tint: .blue,
                               value: Format.bytes(stats.totalMemBytes),
                               history: stats.memHistory)
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

#if DEBUG
struct OverviewView_Previews: PreviewProvider {
    static var previews: some View {
        OverviewView(store: DockerResourceStore(docker: MockDockerClient()),
                     stats: StatsStore(docker: MockDockerClient(),
                                       resources: DockerResourceStore(docker: MockDockerClient())))
            .environment(EngineController())
            .frame(width: 820, height: 560)
    }
}
#endif
