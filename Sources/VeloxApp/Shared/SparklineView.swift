import SwiftUI
import VeloxCore

/// A compact line chart drawn with `Canvas` — cheap enough to live in every
/// table row and update several times a second.
struct SparklineView: View {
    let values: [Double]
    /// Upper bound for the y-axis. When nil, scales to the data's own max.
    var maxValue: Double? = nil
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let ceiling = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)

            var line = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(min(v, ceiling) / ceiling))
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Soft fill under the line.
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.25), tint.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))

            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        .drawingGroup()
    }
}

/// One cell showing a container's live CPU and memory, read from the shared
/// `StatsStore` (which owns a single stats stream per running container). No per-row
/// stream — that fan-out lived here before and didn't scale.
struct ContainerUsageCell: View {
    let stats: StatsStore
    let containerID: String

    var body: some View {
        let sample = stats.latest[containerID]
        return HStack(spacing: 14) {
            metric(title: "CPU", value: sample.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—")
            metric(title: "MEM", value: sample.map { Format.bytes($0.memoryBytes) } ?? "—")
        }
    }

    private func metric(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

extension View {
    /// Keep `stats` retained — its streams running — while this view is on screen. The
    /// keep-alive task holds until the view disappears (the `.task` is cancelled), then
    /// releases; the store stops streaming after the last release (with a short grace).
    func retainingStats(_ stats: StatsStore) -> some View {
        task {
            stats.retain()
            defer { stats.release() }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
    }
}
