#!/usr/bin/env bash
# Standalone ad-hoc signing helper. Usage: ./Scripts/sign.sh [path-to-binary]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-$(swift build -c release --show-bin-path)/Velox}"
codesign --force --sign - \
    --entitlements Resources/Entitlements/velox.entitlements \
    "$BIN"
echo "Signed: $BIN"
codesign -d --entitlements - "$BIN"
