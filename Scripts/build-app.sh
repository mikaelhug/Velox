#!/usr/bin/env bash
# Build a SELF-CONTAINED, distributable Velox.app (packaged as a .zip).
#
# A downloaded Velox.app must run on a brand-new Mac with nothing else installed:
# so the bundle carries everything the engine and the user need —
#   Contents/MacOS/VeloxApp           the SwiftUI menu-bar app (runs the engine in-process)
#   Contents/Resources/kernel         the custom guest kernel  (Assets/velox-vmlinux)
#   Contents/Resources/root.img       the erofs guest rootfs   (guest/build/root.img)
#   Contents/Resources/bin/velox      the CLI (start/update/status) — installed onto PATH
#   Contents/Resources/bin/docker     the stock Docker client for macOS — installed onto PATH
#
# GuestImage.resolve() reads kernel/root.img from the bundle when ~/.velox is empty,
# so no `make-guest.sh` is required on the user's machine. First-run install of the
# two CLIs onto PATH + the `velox` docker context is done by the app (FirstRun).
#
# Signing: ad-hoc by default (fine locally; Gatekeeper warns on a *downloaded* app).
# Set VELOX_SIGN_IDENTITY="Developer ID Application: …" to sign for distribution; the
# release workflow notarizes when notarytool credentials are present.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./versions.env; set +a

CONFIG="${1:-release}"
ENTITLEMENTS="Resources/Entitlements/velox.entitlements"
APP="Velox.app"
KERNEL_SRC="${KERNEL_SRC:-Assets/velox-vmlinux}"
ROOT_SRC="${ROOT_SRC:-guest/build/root.img}"
[ -f "$ROOT_SRC" ] || ROOT_SRC="$HOME/.velox/root.img"     # fall back to the installed copy
SIGN_IDENTITY="${VELOX_SIGN_IDENTITY:--}"                   # "-" = ad-hoc
DIST="${DIST:-dist}"

# --- preflight: the guest artifacts must already be built ---------------------
[ -f "$KERNEL_SRC" ] || { echo "error: $KERNEL_SRC missing — run ./Scripts/build-kernel.sh" >&2; exit 1; }
[ -f "$ROOT_SRC" ]   || { echo "error: guest root.img missing — run ./Scripts/make-guest.sh" >&2; exit 1; }

echo "==> regenerate Versions.swift from versions.env"
./Scripts/gen-versions.sh

echo "==> swift build -c $CONFIG (VeloxApp + velox CLI + porthelper)"
swift build -c "$CONFIG" --product VeloxApp
swift build -c "$CONFIG" --product velox
swift build -c "$CONFIG" --product velox-porthelper
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# --- fetch the stock Docker client for macOS (pinned DOCKER_VERSION) ----------
ARCH="$(uname -m)"; case "$ARCH" in arm64) DARCH=aarch64;; x86_64) DARCH=x86_64;; *) DARCH=aarch64;; esac
DOCKER_CLI="$DIST/docker-cli/docker"
if [ ! -x "$DOCKER_CLI" ]; then
    echo "==> download stock docker client $DOCKER_VERSION ($DARCH) for macOS"
    # Docker ships no checksum sidecar for the static tarballs, so the SHA-256 is
    # pinned in versions.env (bumped together with DOCKER_VERSION). arm64-only:
    # Velox needs Virtualization.framework on Apple Silicon, so no other host arch.
    [ "$DARCH" = "aarch64" ] || { echo "error: no pinned docker-cli SHA-256 for $DARCH (add DOCKER_CLI_MAC_${DARCH}_SHA256 to versions.env)" >&2; exit 1; }
    mkdir -p "$DIST/docker-cli"
    curl -fSL "https://download.docker.com/mac/static/stable/${DARCH}/docker-${DOCKER_VERSION}.tgz" \
        -o "$DIST/docker-cli.tgz"
    echo "${DOCKER_CLI_MAC_ARM64_SHA256}  $DIST/docker-cli.tgz" | shasum -a 256 -c - >/dev/null \
        || { echo "error: docker-cli.tgz SHA-256 mismatch — expected ${DOCKER_CLI_MAC_ARM64_SHA256} (versions.env)" >&2; exit 1; }
    tar -xzf "$DIST/docker-cli.tgz" -C "$DIST/docker-cli" --strip-components=1 docker/docker
fi

# --- assemble the bundle ------------------------------------------------------
echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/VeloxApp"          "$APP/Contents/MacOS/VeloxApp"
cp "$BIN_DIR/velox"             "$APP/Contents/Resources/bin/velox"
cp "$BIN_DIR/velox-porthelper"  "$APP/Contents/Resources/bin/velox-porthelper"
cp "$DOCKER_CLI"                "$APP/Contents/Resources/bin/docker"
cp "$KERNEL_SRC"                "$APP/Contents/Resources/kernel"
cp "$ROOT_SRC"                  "$APP/Contents/Resources/root.img"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/Resources/bin/velox" "$APP/Contents/Resources/bin/docker" \
         "$APP/Contents/Resources/bin/velox-porthelper"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Velox</string>
    <key>CFBundleDisplayName</key><string>Velox</string>
    <key>CFBundleIdentifier</key><string>dev.velox.VeloxApp</string>
    <key>CFBundleExecutable</key><string>VeloxApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VELOX_VERSION}</string>
    <key>CFBundleVersion</key><string>${VELOX_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

# --- sign (nested executables first, then the app last so the seal stays valid).
# `velox` runs the VM, so it needs the virtualization entitlement; the stock
# `docker` client does not. Hardened runtime + timestamp for Developer ID; the
# fallback covers ad-hoc (`-`), which cannot use a secure timestamp.
sign() {  # <path> [entitlements-file]
    local path="$1" ent="${2:-}"
    if [ "$SIGN_IDENTITY" = "-" ]; then
        # Ad-hoc: PLAIN signature, never the hardened runtime. An ad-hoc, non-notarized
        # app signed with --options runtime is SIGTRAP-killed on launch once downloaded
        # (the CI runner's codesign accepts --options runtime where a local one may not,
        # which is why a downloaded build crashed while a local build ran). Hardened
        # runtime + secure timestamp belong only to a real Developer ID, for notarization.
        if [ -n "$ent" ]; then codesign --force --sign - --entitlements "$ent" "$path"
        else                   codesign --force --sign - "$path"; fi
    else
        if [ -n "$ent" ]; then codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ent" "$path"
        else                   codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$path"; fi
    fi
}
echo "==> codesign ($SIGN_IDENTITY)"
sign "$APP/Contents/Resources/bin/docker"
# The port helper runs as root via launchd; its power comes from that, not an
# entitlement — so it's signed plain, like the docker client.
sign "$APP/Contents/Resources/bin/velox-porthelper"
sign "$APP/Contents/Resources/bin/velox" "$ENTITLEMENTS"
sign "$APP" "$ENTITLEMENTS"

# --- package: a single .zip ---------------------------------------------------
# One artifact serves both paths: the in-app updater unpacks it (ditto -x -k) to
# self-replace, and a human just double-clicks it (Archive Utility extracts Velox.app)
# and drags it into /Applications. A .dmg would only add mount/copy logic to the
# updater for no real gain, so we don't build one.
mkdir -p "$DIST"
ZIP="$DIST/Velox-${VELOX_VERSION}-macos-${ARCH}.zip"
echo "==> package $ZIP"
rm -f "$ZIP"; /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Built: $APP"
du -sh "$APP" | sed 's/^/    bundle size: /'
ls -1 "$DIST"/Velox-"${VELOX_VERSION}"-* 2>/dev/null | sed 's/^/    artifact: /'
echo "    Run with: open $APP"
