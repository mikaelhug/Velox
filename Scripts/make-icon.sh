#!/usr/bin/env bash
# Generate the Velox app icon (Resources/AppIcon.icns) — a rounded squircle with an
# indigo->cyan gradient and a clean white V. Pure CoreGraphics (Swift), then sips +
# iconutil to assemble the .icns. Re-run after editing the design below; commit the
# resulting Resources/AppIcon.icns (build-app.sh just copies it into the bundle).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Resources/AppIcon.icns"
WORK="$(mktemp -d)"
SWIFT="$WORK/gen.swift"
MASTER="$WORK/master.png"
SET="$WORK/AppIcon.iconset"

cat > "$SWIFT" <<'SWIFT'
import CoreGraphics
import ImageIO
import Foundation
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let S = CGFloat(size)
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius = rect.width * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
let colors = [CGColor(red: 0.32, green: 0.27, blue: 0.93, alpha: 1),
              CGColor(red: 0.06, green: 0.74, blue: 0.86, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
ctx.restoreGState()
let cx = S/2
let armY = S * 0.655, tipY = S * 0.355, halfW = S * 0.205
ctx.setLineWidth(S * 0.118); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.move(to: CGPoint(x: cx - halfW, y: armY))
ctx.addLine(to: CGPoint(x: cx, y: tipY))
ctx.addLine(to: CGPoint(x: cx + halfW, y: armY))
ctx.strokePath()
let img = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
SWIFT

echo "==> render master 1024px"
swift "$SWIFT" "$MASTER"

echo "==> build .iconset"
mkdir -p "$SET"
sips -z 16   16   "$MASTER" --out "$SET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$MASTER" --out "$SET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$MASTER" --out "$SET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$MASTER" --out "$SET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$MASTER" --out "$SET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$MASTER" --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$MASTER" --out "$SET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$MASTER" --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$MASTER" --out "$SET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$SET/icon_512x512@2x.png"

echo "==> iconutil -> $OUT"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$WORK"
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))"
