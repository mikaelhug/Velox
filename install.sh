#!/usr/bin/env bash
# Velox one-line installer.
#   curl -fsSL https://raw.githubusercontent.com/mikaelhug/Velox/main/install.sh | bash
#
# Downloads the latest release, installs Velox.app, and clears the macOS
# download-quarantine flag so it opens without the Gatekeeper "Apple could not
# verify..." prompt (Velox is code-signed but not notarized). Nothing else needed —
# the app bundles the guest VM, the engine, and the `docker` client.
set -euo pipefail

REPO="mikaelhug/Velox"
APP="Velox.app"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "Velox requires macOS on Apple Silicon (arm64)." >&2
    exit 1
fi

echo "==> finding the latest Velox release"
asset_url="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -oE 'https://[^"]+macos-arm64\.zip' | head -1)"
if [ -z "${asset_url:-}" ]; then
    echo "error: no macOS arm64 .zip found in the latest release of ${REPO}." >&2
    echo "       See https://github.com/${REPO}/releases" >&2
    exit 1
fi
echo "    ${asset_url}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "==> downloading"
curl -fSL "$asset_url" -o "$tmp/velox.zip"

echo "==> unpacking"
/usr/bin/ditto -x -k "$tmp/velox.zip" "$tmp/out"
src="$(/usr/bin/find "$tmp/out" -maxdepth 2 -type d -name "$APP" | head -1)"
[ -n "$src" ] || { echo "error: $APP not found in the downloaded archive." >&2; exit 1; }

# Prefer /Applications (writable by admins); fall back to ~/Applications otherwise.
dest_dir="/Applications"
[ -w "$dest_dir" ] || { dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; }
dest="$dest_dir/$APP"

echo "==> installing to $dest"
rm -rf "$dest"
/bin/cp -R "$src" "$dest"

echo "==> clearing the download-quarantine flag"
/usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

echo "==> launching Velox"
/usr/bin/open "$dest" || true

echo
echo "Installed: $dest"
echo "Open a terminal and try:  docker run --rm hello-world"
