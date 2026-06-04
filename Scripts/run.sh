#!/usr/bin/env bash
# Build, sign, then run Velox, forwarding any arguments.
# Usage: ./Scripts/run.sh [velox args...]    (CONFIG=debug ./Scripts/run.sh ...)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
./Scripts/build.sh "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Velox"
exec "$BIN" "$@"
