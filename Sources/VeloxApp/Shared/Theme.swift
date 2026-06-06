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
}

/// Measures the width a table column needs to show its widest value without
/// truncation. SwiftUI's `Table` can't size columns to content on its own, so we
/// measure the strings ourselves and pin each bounded column to a fixed width —
/// that way short columns (a "Tag" of "3.0.1") stay tight instead of stretching
/// to fill the table, and a single flexible column absorbs the leftover space.
@MainActor
enum ColumnWidth {
    static var caption: NSFont { .preferredFont(forTextStyle: .caption1) }
    static var callout: NSFont { .preferredFont(forTextStyle: .callout) }
    static var captionMono: NSFont { .monospacedSystemFont(ofSize: caption.pointSize, weight: .regular) }
    static var calloutMono: NSFont { .monospacedSystemFont(ofSize: callout.pointSize, weight: .regular) }

    private static var headerFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) }

    /// Width that fits the column `header` and the widest of `values` in `font`,
    /// plus cell `padding`, clamped to `[lo, hi]`.
    static func fit(header: String, _ values: [String], font: NSFont,
                    min lo: CGFloat, max hi: CGFloat, padding: CGFloat = 22) -> CGFloat {
        var widest = (header as NSString).size(withAttributes: [.font: headerFont]).width
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        for value in values {
            let w = (value as NSString).size(withAttributes: attrs).width
            if w > widest { widest = w }
        }
        return Swift.min(Swift.max(widest + padding, lo), hi)
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
