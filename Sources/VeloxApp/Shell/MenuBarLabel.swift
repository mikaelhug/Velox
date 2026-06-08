import SwiftUI

/// The menu-bar icon: the engine-state SF Symbol, plus a crescent-moon badge in
/// the lower-right corner while Resource Saver is idling the VM (Docker-Desktop
/// style).
///
/// Built from `Image(systemName:)` — the same thing `MenuBarExtra(systemImage:)`
/// renders — so it sizes and template-tints exactly like the original menu-bar
/// icon (a fixed-size `Image(nsImage:)` does NOT scale to the bar and shows up
/// tiny). The moon is knocked out with a `destinationOut` ring so it reads as a
/// separate glyph once the bar tints the whole image one colour. When not saving
/// this is *literally* the original `Image(systemName:)`, untouched.
struct MenuBarLabel: View {
    let symbol: String
    let saving: Bool

    var body: some View {
        if saving {
            Image(systemName: symbol)
                .overlay(alignment: .bottomTrailing) { moonBadge }
                .compositingGroup()                       // scope the knockout to this icon
                .accessibilityLabel("Velox — idle, saving memory")
        } else {
            Image(systemName: symbol)
                .accessibilityLabel("Velox")
        }
    }

    /// Crescent moon sitting in the lower-right corner, with a transparent ring
    /// punched around it so it doesn't merge into the box under the bar's tint.
    /// Sized relative to the rendered icon so it tracks the menu-bar scale.
    private var moonBadge: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let moon = side * 0.52
            let ring = moon * 1.34
            ZStack {
                Circle()
                    .frame(width: ring, height: ring)
                    .blendMode(.destinationOut)
                Image(systemName: "moon.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: moon, height: moon)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
        }
    }
}
