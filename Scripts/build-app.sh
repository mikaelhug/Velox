#!/usr/bin/env bash
# Build the VeloxApp executable and wrap it into a signed Velox.app bundle.
# SwiftPM emits a bare Mach-O; a menu-bar SwiftUI app needs a real .app bundle
# with an Info.plist, so we assemble one here and ad-hoc sign it with the same
# virtualization entitlement the CLI uses.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ENTITLEMENTS="Resources/Entitlements/velox.entitlements"
APP="Velox.app"

set -a; . ./versions.env; set +a

echo "==> regenerate Versions.swift from versions.env"
./Scripts/gen-versions.sh

echo "==> swift build -c $CONFIG (VeloxApp)"
swift build -c "$CONFIG" --product VeloxApp

BIN="$(swift build -c "$CONFIG" --show-bin-path)/VeloxApp"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VeloxApp"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Velox</string>
    <key>CFBundleDisplayName</key><string>Velox</string>
    <key>CFBundleIdentifier</key><string>dev.velox.VeloxApp</string>
    <key>CFBundleExecutable</key><string>VeloxApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VELOX_VERSION}</string>
    <key>CFBundleVersion</key><string>${VELOX_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

echo "==> codesign (ad-hoc) $APP"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"

echo "==> Built: $APP"
echo "    Run with: open $APP   (or $APP/Contents/MacOS/VeloxApp for logs)"
