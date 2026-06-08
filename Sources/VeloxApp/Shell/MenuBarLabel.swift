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

    var body: some View {
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
