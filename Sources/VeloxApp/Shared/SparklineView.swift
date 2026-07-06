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
            var minY = size.height
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(min(v, ceiling) / ceiling))
                minY = min(minY, y)
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Soft fill under the line, anchored at the line's highest point (minY) rather
            // than the canvas top — so a low line (idle CPU, a small I/O rate) still shows a
            // visible fill instead of fading to almost nothing.
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.30), tint.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: minY),
                endPoint: CGPoint(x: 0, y: size.height)))

            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
    }
}

/// A macOS Activity Monitor–style I/O graph: two series mirrored about a horizontal
/// center baseline — `up` (In / Read) fills upward, `down` (Out / Write) fills downward —
/// each a line over a soft gradient. Both halves share one ceiling so their magnitudes are
/// directly comparable. Cheap `Canvas`, same as `SparklineView`.
struct MirroredSparklineView: View {
    let up: [Double]
    let down: [Double]
    var upTint: Color = .blue
    var downTint: Color = .red

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let peak = max(up.max() ?? 0, down.max() ?? 0)
            let ceiling = max(peak * 1.3, 0.0001)
            // Split the two baselines by a hair so an idle (all-zero) up and down don't
            // stack onto the exact same row and hide each other — the up line rests just
            // above center, the down line just below, always both visible (as macOS
            // Activity Monitor's mirrored graph does).
            let gap: CGFloat = 1.5

            // One series' line + fill, mapped from its baseline (upward or downward).
            func draw(_ values: [Double], goingUp: Bool, tint: Color) {
                guard values.count > 1 else { return }
                let stepX = size.width / CGFloat(values.count - 1)
                let baseY = goingUp ? midY - gap : midY + gap  // this series' baseline
                let span = midY - gap                          // drawable height per half
                var line = Path()
                var extremeY = baseY    // the point furthest from the baseline (the peak)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let frac = CGFloat(min(v, ceiling) / ceiling)
                    let y = goingUp ? baseY - span * frac : baseY + span * frac
                    extremeY = goingUp ? min(extremeY, y) : max(extremeY, y)
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: baseY))
                fill.addLine(to: CGPoint(x: 0, y: baseY))
                fill.closeSubpath()
                // Anchor the gradient at the series' peak (not the card edge) so even small
                // throughput still shows a visible fill under the line.
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.30), tint.opacity(0.03)]),
                    startPoint: CGPoint(x: 0, y: extremeY),
                    endPoint: CGPoint(x: 0, y: baseY)))
                context.stroke(line, with: .color(tint), lineWidth: 1.5)
            }

            draw(up, goingUp: true, tint: upTint)
            draw(down, goingUp: false, tint: downTint)
        }
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
