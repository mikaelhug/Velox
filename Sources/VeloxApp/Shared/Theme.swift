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
