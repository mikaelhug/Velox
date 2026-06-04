import Foundation

/// A terminal color from an SGR sequence. Kept abstract (no AppKit/SwiftUI types)
/// so the parser stays UI-agnostic and testable; the app layer maps these to
/// concrete colors.
public enum ANSIColor: Sendable, Equatable {
    case standard(Int)         // 0–7 (black…white)
    case bright(Int)           // 0–7 bright variants
    case indexed(Int)          // 256-color cube index
    case rgb(UInt8, UInt8, UInt8)
}

/// A run of text sharing one visual style, produced by `ANSIParser`.
public struct ANSISpan: Sendable, Equatable {
    public var text: String
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold: Bool
    public var underline: Bool

    public init(text: String, foreground: ANSIColor? = nil, background: ANSIColor? = nil,
                bold: Bool = false, underline: Bool = false) {
        self.text = text; self.foreground = foreground; self.background = background
        self.bold = bold; self.underline = underline
    }
}

/// Parses ANSI SGR escape sequences (`ESC[…m`) into styled spans, faithfully
/// enough for terminal-colored container logs. Cursor-movement and other CSI/OSC
/// sequences are recognized and skipped (not rendered as text). Stateless across
/// calls — each input starts from a clean style, which matches line-oriented logs.
public enum ANSIParser {
    private struct Style: Equatable {
        var fg: ANSIColor?
        var bg: ANSIColor?
        var bold = false
        var underline = false
    }

    public static func parse(_ input: String) -> [ANSISpan] {
        let scalars = Array(input.unicodeScalars)
        var spans: [ANSISpan] = []
        var current = ""
        var style = Style()
        var i = 0

        func flush() {
            guard !current.isEmpty else { return }
            spans.append(ANSISpan(text: current, foreground: style.fg, background: style.bg,
                                  bold: style.bold, underline: style.underline))
            current = ""
        }

        while i < scalars.count {
            let s = scalars[i]
            if s.value == 0x1B, i + 1 < scalars.count { // ESC
                let next = scalars[i + 1]
                if next == "[" { // CSI
                    flush()
                    i += 2
                    var params = ""
                    while i < scalars.count {
                        let c = scalars[i]
                        if c.value >= 0x40 && c.value <= 0x7E { // final byte
                            if c == "m" { applySGR(params, to: &style) }
                            i += 1
                            break
                        }
                        params.unicodeScalars.append(c)
                        i += 1
                    }
                    continue
                } else if next == "]" { // OSC — skip to BEL or ST (ESC \)
                    i += 2
                    while i < scalars.count {
                        if scalars[i].value == 0x07 { i += 1; break }
                        if scalars[i].value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "\\" {
                            i += 2; break
                        }
                        i += 1
                    }
                    continue
                }
            }
            current.unicodeScalars.append(s)
            i += 1
        }
        flush()
        return spans
    }

    private static func applySGR(_ params: String, to style: inout Style) {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var idx = 0
        // An empty parameter string means "0" (reset).
        if codes.isEmpty { style = Style(); return }
        while idx < codes.count {
            let code = codes[idx]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 22: style.bold = false
            case 4: style.underline = true
            case 24: style.underline = false
            case 30...37: style.fg = .standard(code - 30)
            case 90...97: style.fg = .bright(code - 90)
            case 39: style.fg = nil
            case 40...47: style.bg = .standard(code - 40)
            case 100...107: style.bg = .bright(code - 100)
            case 49: style.bg = nil
            case 38, 48:
                // Extended color: 38;5;n (indexed) or 38;2;r;g;b (truecolor).
                let isFG = code == 38
                if idx + 1 < codes.count, codes[idx + 1] == 5, idx + 2 < codes.count {
                    let color = ANSIColor.indexed(codes[idx + 2]); if isFG { style.fg = color } else { style.bg = color }
                    idx += 2
                } else if idx + 1 < codes.count, codes[idx + 1] == 2, idx + 4 < codes.count {
                    let color = ANSIColor.rgb(UInt8(clamping: codes[idx + 2]),
                                              UInt8(clamping: codes[idx + 3]),
                                              UInt8(clamping: codes[idx + 4]))
                    if isFG { style.fg = color } else { style.bg = color }
                    idx += 4
                }
            default: break
            }
            idx += 1
        }
    }
}
