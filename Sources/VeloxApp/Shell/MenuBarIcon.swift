import AppKit

/// Bakes the Resource Saver menu-bar icon into a **template NSImage**: the base
/// SF Symbol with a crescent-moon badge knocked out of the lower-right corner.
///
/// Why baked instead of a SwiftUI overlay: the live status bar rasterizes a
/// MenuBarExtra label to a template by reading its alpha mask, and it does NOT
/// honor runtime blend modes (`.destinationOut`) — so a SwiftUI knockout silently
/// merges and the moon vanishes. Baking the knockout into the image's alpha makes
/// the transparent ring part of the mask, which template tinting always respects.
enum MenuBarIcon {
    /// Template image for `symbol` with the moon badge. Drawn into a 3× bitmap so
    /// it stays crisp when SwiftUI scales it to the menu-bar size.
    static func image(symbol: String, saving: Bool, pointSize: CGFloat = 15) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        let canvas = NSSize(width: ceil(base.size.width), height: ceil(base.size.height))

        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            base.isTemplate = true
            return base
        }
        // MUST set rep.size BEFORE building the context, otherwise the context uses
        // the raw pixel dimensions (1 unit = 1 px) and our point-based drawing fills
        // only the bottom-left 1/3 of the bitmap — making the icon render tiny.
        rep.size = canvas
        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            base.isTemplate = true
            return base
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let cg = gctx.cgContext

        base.draw(in: NSRect(origin: .zero, size: canvas), from: .zero, operation: .sourceOver, fraction: 1)

        if saving {
            let d = canvas.height * 0.56
            let moonRect = NSRect(x: canvas.width - d, y: 0, width: d, height: d)
            let halo = moonRect.insetBy(dx: -d * 0.15, dy: -d * 0.15)
            cg.saveGState()
            cg.setBlendMode(.clear)               // baked transparent ring (alpha knockout)
            cg.fillEllipse(in: halo)
            cg.restoreGState()

            let moonCfg = NSImage.SymbolConfiguration(pointSize: d, weight: .heavy)
            let moon = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(moonCfg) ?? NSImage()
            let mScale = min(moonRect.width / moon.size.width, moonRect.height / moon.size.height) * 0.92
            let md = NSSize(width: moon.size.width * mScale, height: moon.size.height * mScale)
            moon.draw(in: NSRect(x: moonRect.midX - md.width / 2, y: moonRect.midY - md.height / 2,
                                 width: md.width, height: md.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: canvas)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
