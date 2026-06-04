#!/usr/bin/env bash
# Install the `vlcmd` wrapper onto PATH. Prefers /usr/local/bin; falls back to
# ~/.velox/bin (printing a PATH hint) when /usr/local/bin isn't writable.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="$PWD/Scripts/vlcmd"
chmod +x "$SRC"

if [ -w /usr/local/bin ] || [ "$(id -u)" = "0" ]; then
    DEST="/usr/local/bin/vlcmd"
    ln -sf "$SRC" "$DEST"
    echo "installed: $DEST -> $SRC"
else
    mkdir -p "$HOME/.velox/bin"
    DEST="$HOME/.velox/bin/vlcmd"
    ln -sf "$SRC" "$DEST"
    echo "installed: $DEST -> $SRC"
    echo "add to PATH:  export PATH=\"\$HOME/.velox/bin:\$PATH\""
fi
