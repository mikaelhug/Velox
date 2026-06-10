import SwiftUI

/// The menu-bar icon: the engine-state SF Symbol, plus a crescent-moon badge in
/// the lower-right corner while Resource Saver is idling the VM.
///
/// Running (and every non-saving state) is the original `Image(systemName:)` — the
/// size that matches the other menu-bar icons. Sleeping uses a pre-baked template
/// image ([MenuBarIcon]) of the same symbol with the moon knocked out of its alpha
/// channel: the live status bar ignores SwiftUI runtime blend modes, so the
/// knockout has to be baked in rather than composited as a `.destinationOut` overlay.
struct MenuBarLabel: View {
    let symbol: String
    let saving: Bool
    /// Running-container count, shown beside the icon when non-zero — the
    /// zero-click glance ("anything running?") before even opening the panel.
    var count: Int = 0
    /// A newer Velox exists — a small up-arrow next to the icon (install in the panel).
    var updateAvailable: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            icon
            if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .medium))
            }
            if updateAvailable {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 9))
                    .accessibilityLabel("Update available")
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if saving {
            Image(nsImage: MenuBarIcon.image(symbol: symbol, saving: true))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityLabel("Velox — idle, saving memory")
        } else {
            Image(systemName: symbol)
                .accessibilityLabel("Velox")
        }
    }
}
