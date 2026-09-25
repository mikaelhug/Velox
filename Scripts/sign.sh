#!/usr/bin/env bash
# Standalone ad-hoc signing helper. Usage: ./Scripts/sign.sh [path-to-binary]
set -euo pipefail
cd "$(dirname "$0")/.."
[ -n "${1:-}" ] || . ./Scripts/toolchain.sh   # only needed to locate the default binary

BIN="${1:-$(swift build -c release --show-bin-path)/velox}"
codesign --force --sign - \
    --entitlements Resources/Entitlements/velox.entitlements \
    "$BIN"
echo "Signed: $BIN"
codesign -d --entitlements - "$BIN"
