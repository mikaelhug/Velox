#!/usr/bin/env bash
# Velox one-line installer.
#   curl -fsSL https://raw.githubusercontent.com/mikaelhug/Velox/main/install.sh | bash
#
# Downloads the latest release, verifies it (SHA-256 from the release, plus the bundle's
# own code signature), installs Velox.app, and only bypasses Gatekeeper if the build is
# not notarized. Nothing else needed — the app bundles the guest VM, the engine, and the
# `docker` client.
set -euo pipefail

REPO="mikaelhug/Velox"
APP="Velox.app"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "Velox requires macOS on Apple Silicon (arm64)." >&2
    exit 1
fi

echo "==> finding the latest Velox release"
release_json="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"
# Anchor on the closing quote so sibling assets (…zip.sig) can never match, AND on the
# /releases/download/<repo>/ path: the JSON also carries a `body` built from commit and PR
# titles (generate_release_notes), so matching any https URL let release *text* influence
# what gets downloaded.
dl_prefix="https://github.com/${REPO}/releases/download/"
asset_url="$(printf '%s' "$release_json" | grep -oE "${dl_prefix}[^\"]+macos-arm64\.zip\"" | tr -d '"' | head -1)"
sums_url="$(printf '%s' "$release_json" | grep -oE "${dl_prefix}[^\"]+/SHA256SUMS\"" | tr -d '"' | head -1)"
if [ -z "${asset_url:-}" ]; then
    echo "error: no macOS arm64 .zip found in the latest release of ${REPO}." >&2
    echo "       See https://github.com/${REPO}/releases" >&2
    exit 1
fi
echo "    ${asset_url}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "==> downloading"
curl -fSL "$asset_url" -o "$tmp/velox.zip"

# Integrity, part 1: SHA256SUMS. FAIL CLOSED — a missing sums file used to print a friendly
# note and install anyway, so deleting or renaming one asset silently disabled the only
# check this script performed. Note this catches corruption and a swapped asset, NOT a
# compromised release: the sums come from the same release as the zip. Part 2 below is the
# check that does not share that trust root.
if [ -z "${sums_url:-}" ]; then
    echo "error: the latest release of ${REPO} publishes no SHA256SUMS." >&2
    echo "       Refusing to install an unverifiable download. Install manually from" >&2
    echo "       https://github.com/${REPO}/releases if you trust it." >&2
    exit 1
fi
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

echo "==> unpacking"
/usr/bin/ditto -x -k "$tmp/velox.zip" "$tmp/out"
src="$(/usr/bin/find "$tmp/out" -maxdepth 2 -type d -name "$APP" | head -1)"
[ -n "$src" ] || { echo "error: $APP not found in the downloaded archive." >&2; exit 1; }

# Prefer /Applications (writable by admins); fall back to ~/Applications otherwise.
dest_dir="/Applications"
[ -w "$dest_dir" ] || { dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; }
dest="$dest_dir/$APP"

# Integrity, part 2: the bundle's own code signature. Unlike SHA256SUMS this does not come
# from the release JSON, so it survives a compromised release page — a Developer ID
# signature cannot be forged, and any modification of the bundle invalidates it.
# (The Ed25519 .sig that the in-app updater checks cannot be verified here: macOS ships
# LibreSSL, which has no Ed25519 support, and there is no portable verifier in base macOS.)
echo "==> verifying the app signature"
if ! /usr/bin/codesign --verify --strict --deep "$src" 2>/dev/null; then
    echo "error: $APP failed code-signature verification — the bundle has been modified." >&2
    exit 1
fi
authority="$(/usr/bin/codesign -dv --verbose=2 "$src" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
echo "    signed by: ${authority:-(ad-hoc, no certificate)}"

echo "==> installing to $dest"
rm -rf "$dest"
/bin/cp -R "$src" "$dest"

# Gatekeeper is the one check that does not depend on anything this script downloaded, so
# only bypass it when it would refuse solely for lack of notarization — and say so out loud.
# This used to strip quarantine unconditionally, which disabled the OS backstop on every
# install regardless of what had been verified.
if /usr/sbin/spctl -a -t exec "$dest" 2>/dev/null; then
    echo "==> notarized — leaving Gatekeeper quarantine in place"
else
    echo "==> this build is not notarized; clearing the download-quarantine flag so it can open."
    echo "    (Gatekeeper's own check is being bypassed. The checksum and signature above are"
    echo "     what stands behind this install.)"
    /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
fi

echo "==> launching Velox"
/usr/bin/open "$dest" || true

echo
echo "Installed: $dest"
echo "Open a terminal and try:  docker run --rm hello-world"
