import AppKit
import SwiftUI

/// Shared visual tokens so the dashboards read as one app rather than a pile of
/// default tables. Spacing, radii, and the card surfaces all come from here.
enum Theme {
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let gridSpacing: CGFloat = 12
    static let pagePadding: CGFloat = 20

    /// Content background that sits one step above the window — the card fill.
    static var cardFill: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }

    /// Terminal-style console surface for the log views: a FIXED dark background
    /// (like Terminal/iTerm, regardless of system appearance) with fixed light
    /// default text — logs read the way developers expect, and ANSI colors sit on
    /// the background they were designed for. Never use adaptive label colors on
    /// this surface: in light mode they'd render black-on-dark.
    static let consoleBackground = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.089, alpha: 1)
    static let consoleText = NSColor(calibratedWhite: 0.88, alpha: 1)
}

extension View {
    /// Hide the horizontal scroll bar of the nearest AppKit table behind this view.
    /// Inspector show/hide resizes the table mid-animation, and AppKit flashes the
    /// horizontal overlay scroller while the content is briefly wider than the
    /// clip — reads as a glitch. Sideways trackpad scrolling still works when
    /// columns genuinely overflow; only the indicator and the sideways rubber-band
    /// are suppressed. (SwiftUI's `.scrollIndicators` doesn't reach Table's
    /// underlying scroll view, hence the introspection.)
    func suppressHorizontalScroller() -> some View {
        background(HorizontalScrollerSuppressor())
    }
}

private struct HorizontalScrollerSuppressor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // The AppKit table materializes a beat after this background lands — retry
        // on a short ladder. Pane switches recreate the view, re-running this.
        for delay: TimeInterval in [0, 0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak probe, coordinator = context.coordinator] in
                if let probe { coordinator.attach(around: probe) }
            }
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Holds the found scroll view and KEEPS the horizontal scroller off. A
    /// one-shot set isn't enough: SwiftUI re-asserts its scroller configuration
    /// when it updates the table — exactly when an inspector toggle resizes it —
    /// so re-apply on every frame change of the scroll view.
    @MainActor
    final class Coordinator {
        private weak var scrollView: NSScrollView?
        // nonisolated(unsafe): deinit is nonisolated and removeObserver is
        // thread-safe; the token is written once from the main actor.
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        func attach(around probe: NSView) {
            guard scrollView == nil else { return }
            guard let sv = Self.find(around: probe) else { return }
            scrollView = sv
            apply()
            sv.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: sv, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        private func apply() {
            guard let sv = scrollView else { return }
            // Measured: SwiftUI does re-enable the scroller (the attach-time log
            // caught it re-asserting) — both checks must stay cheap and idempotent.
            if sv.hasHorizontalScroller { sv.hasHorizontalScroller = false }
            if sv.horizontalScrollElasticity != .none { sv.horizontalScrollElasticity = .none }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        /// Climb from the probe until an ancestor's subtree contains a table scroll
        /// view, then stop — never wander up to the window (the sidebar List is
        /// also an NSTableView and isn't ours to touch).
        private static func find(around probe: NSView) -> NSScrollView? {
            var node = probe.superview
            for _ in 0..<6 {
                guard let host = node else { return nil }
                if let found = tableScrollView(in: host) { return found }
                node = host.superview
            }
            return nil
        }

        private static func tableScrollView(in root: NSView, depth: Int = 0) -> NSScrollView? {
            if depth > 12 { return nil }
            if let scroll = root as? NSScrollView, scroll.documentView is NSTableView {
                return scroll
            }
            for sub in root.subviews {
                if let found = tableScrollView(in: sub, depth: depth + 1) { return found }
            }
            return nil
        }
    }
}

@MainActor
enum TableLayout {
    private static func key(_ name: String) -> String { "velox.tableLayout.v2.\(name)" }

    static func load<R: Identifiable>(_ name: String) -> TableColumnCustomization<R> {
        guard let data = UserDefaults.standard.data(forKey: key(name)),
              let value = try? JSONDecoder().decode(TableColumnCustomization<R>.self, from: data)
        else { return TableColumnCustomization<R>() }
        return value
    }

    static func save<R: Identifiable>(_ name: String, _ value: TableColumnCustomization<R>) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key(name))
    }
}

extension View {
    func persistTableLayout<R: Identifiable>(_ layout: TableColumnCustomization<R>,
                                             _ name: String) -> some View {
        onChange(of: layout) { _, newValue in TableLayout.save(name, newValue) }
    }
}

/// A rounded content surface used for every dashboard tile. A hairline border
/// plus a whisper of shadow lifts it off the window background in both appearances.
struct DashboardCard<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(Theme.cardPadding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }
}

/// A single headline metric: an icon-tinted title, a large rounded value, and a
/// secondary caption. Used across the Overview grid.
struct StatCard: View {
    let title: String
    let systemImage: String
    let value: String
    var caption: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
