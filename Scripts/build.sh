#!/usr/bin/env bash
# Build + ad-hoc sign the Velox executable with the virtualization entitlement.
# This is the canonical dev loop — run it after every code change.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ENTITLEMENTS="Resources/Entitlements/velox.entitlements"

echo "==> regenerate Versions.swift from versions.env"
./Scripts/gen-versions.sh

# Build every product (velox CLI + VeloxApp GUI + velox-porthelper) so a break in any
# target is caught in the dev loop — not only the CLI (a GUI-only break once shipped silently).
echo "==> swift build -c $CONFIG (all products)"
swift build -c "$CONFIG"

BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BINDIR/velox"

# Sign BOTH VM-hosting executables: the CLI and the bare dev GUI binary. Without the
# virtualization entitlement, a dev-run VeloxApp fails VM-config validation with an
# opaque configurationInvalid — only the packaged .app (build-app.sh) was signed before.
echo "==> codesign (ad-hoc) $BIN + VeloxApp"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BIN"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINDIR/VeloxApp"

echo "==> Signed: $BIN"
echo "==> Embedded entitlements:"
codesign -d --entitlements - "$BIN" 2>&1 | grep -i virtualization || \
    echo "   (run: codesign -d --entitlements - \"$BIN\")"
