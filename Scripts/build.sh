#!/usr/bin/env bash
# Build + ad-hoc sign the Velox executable with the virtualization entitlement.
# This is the canonical dev loop — run it after every code change.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ENTITLEMENTS="Resources/Entitlements/velox.entitlements"

echo "==> regenerate Versions.swift from versions.env"
./Scripts/gen-versions.sh

echo "==> swift build -c $CONFIG (velox CLI)"
swift build -c "$CONFIG" --product velox

BIN="$(swift build -c "$CONFIG" --show-bin-path)/velox"

echo "==> codesign (ad-hoc) $BIN"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BIN"

echo "==> Signed: $BIN"
echo "==> Embedded entitlements:"
codesign -d --entitlements - "$BIN" 2>&1 | grep -i virtualization || \
    echo "   (run: codesign -d --entitlements - \"$BIN\")"
