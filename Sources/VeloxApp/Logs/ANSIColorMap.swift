import AppKit
import VeloxCore

/// Maps the parser's abstract `ANSIColor` onto concrete terminal colors for the
/// log view. Kept in the app layer so `ANSIParser` stays UI-free.
enum ANSIPalette {
    // A standard, readable 16-color terminal palette.
    private static let standard: [NSColor] = [
        NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1), // black
        NSColor(srgbRed: 0.80, green: 0.25, blue: 0.25, alpha: 1), // red
        NSColor(srgbRed: 0.25, green: 0.66, blue: 0.36, alpha: 1), // green
        NSColor(srgbRed: 0.78, green: 0.60, blue: 0.20, alpha: 1), // yellow
        NSColor(srgbRed: 0.30, green: 0.52, blue: 0.84, alpha: 1), // blue
        NSColor(srgbRed: 0.66, green: 0.40, blue: 0.74, alpha: 1), // magenta
        NSColor(srgbRed: 0.27, green: 0.66, blue: 0.69, alpha: 1), // cyan
        NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1), // white
    ]
    private static let bright: [NSColor] = [
        NSColor(srgbRed: 0.40, green: 0.40, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.40, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.85, blue: 0.50, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.68, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.55, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.40, green: 0.85, blue: 0.88, alpha: 1),
        NSColor.white,
    ]

    static func color(_ ansi: ANSIColor) -> NSColor {
        switch ansi {
        case .standard(let i): return standard[safe: i] ?? .labelColor
        case .bright(let i):   return bright[safe: i] ?? .labelColor
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .indexed(let n):  return indexed(n)
        }
    }

    /// Resolve an xterm 256-color index to an NSColor.
    private static func indexed(_ n: Int) -> NSColor {
        switch n {
        case 0...7:  return standard[n]
        case 8...15: return bright[n - 8]
        case 16...231:
            let c = n - 16
            let r = c / 36, g = (c / 6) % 6, b = c % 6
            func comp(_ v: Int) -> CGFloat { v == 0 ? 0 : CGFloat(55 + v * 40) / 255 }
            return NSColor(srgbRed: comp(r), green: comp(g), blue: comp(b), alpha: 1)
        case 232...255:
            let v = CGFloat(8 + (n - 232) * 10) / 255
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        default:
            return .labelColor
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
