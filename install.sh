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
release_json="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"
# Anchor on the closing quote so sibling assets (…zip.sig) can never match.
asset_url="$(printf '%s' "$release_json" | grep -oE 'https://[^"]+macos-arm64\.zip"' | tr -d '"' | head -1)"
sums_url="$(printf '%s' "$release_json" | grep -oE 'https://[^"]+/SHA256SUMS"' | tr -d '"' | head -1)"
if [ -z "${asset_url:-}" ]; then
    echo "error: no macOS arm64 .zip found in the latest release of ${REPO}." >&2
    echo "       See https://github.com/${REPO}/releases" >&2
    exit 1
fi
echo "    ${asset_url}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "==> downloading"
curl -fSL "$asset_url" -o "$tmp/velox.zip"

# Integrity: verify against the release's SHA256SUMS when present (all releases going
# forward publish one). bash can't verify the Ed25519 .sig portably — the in-app
# updater does that full check; this catches corrupt/tampered downloads.
if [ -n "${sums_url:-}" ]; then
    echo "==> verifying checksum"
    curl -fsSL "$sums_url" -o "$tmp/SHA256SUMS"
    zip_name="$(basename "$asset_url")"
    expected="$(awk -v f="$zip_name" '$2 == f { print $1 }' "$tmp/SHA256SUMS" | head -1)"
    actual="$(/usr/bin/shasum -a 256 "$tmp/velox.zip" | awk '{ print $1 }')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "error: SHA-256 mismatch for ${zip_name} (expected ${expected:-<missing>}, got ${actual})." >&2
        echo "       Refusing to install a corrupt or tampered download." >&2
        exit 1
    fi
else
    echo "    (release has no SHA256SUMS — skipping checksum verification)"
fi

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
