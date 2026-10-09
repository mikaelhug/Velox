import AppKit
import SwiftUI

extension View {
    /// Keep the menu-bar panel's window exactly as tall as this content.
    ///
    /// `MenuBarExtra`'s `.window` panel grows with its content but never shrinks: while the
    /// panel is closed its hosting view isn't updated, and on reopen SwiftUI only raises the
    /// window to the content's minimum size. Measured on the live app: switching from a
    /// workspace with a scrolling container list (391pt) to an empty one (107pt) left the
    /// window at 391pt, with the compact content floating in the middle of it.
    ///
    /// So the content's own height is measured, and the window is set to it whenever that
    /// height changes and whenever the panel is shown (it becomes key) — both events (§8),
    /// no polling. The top edge stays put so the panel stays docked under the menu bar.
    func fitsMenuBarPanelHeight() -> some View {
        modifier(MenuBarPanelFit())
    }
}

private struct MenuBarPanelFit: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .background(PanelHeightFitter(height: height))
    }
}

private struct PanelHeightFitter: NSViewRepresentable {
    let height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.height = height
        // Next turn: the probe has no window until SwiftUI has installed it, and the
        // window's own layout pass for this update should land first.
        DispatchQueue.main.async { [weak view] in
            coordinator.attach(to: view?.window)
            coordinator.fit()
        }
    }

    @MainActor
    final class Coordinator {
        var height: CGFloat = 0
        private weak var window: NSWindow?
        // nonisolated(unsafe): deinit is nonisolated and removeObserver is thread-safe;
        // the token is written only from the main actor.
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        func attach(to window: NSWindow?) {
            guard let window, window !== self.window else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            self.window = window
            // The panel becomes key each time it opens — the moment a size left over from
            // while it was closed would otherwise show.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            }
        }

        /// Idempotent: a no-op when the window already matches, so SwiftUI's own sizing and
        /// this never chase each other.
        func fit() {
            guard let window, height > 0 else { return }
            let content = NSRect(x: 0, y: 0, width: window.contentLayoutRect.width, height: height)
            let target = window.frameRect(forContentRect: content).height
            guard abs(window.frame.height - target) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - target
            frame.size.height = target
            window.setFrame(frame, display: true)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
