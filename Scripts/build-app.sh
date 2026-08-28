#!/usr/bin/env bash
# Build a SELF-CONTAINED, distributable Velox.app (packaged as a .zip).
#
# A downloaded Velox.app must run on a brand-new Mac with nothing else installed:
# so the bundle carries everything the engine and the user need —
#   Contents/MacOS/VeloxApp           the SwiftUI menu-bar app (runs the engine in-process)
#   Contents/Resources/kernel         the custom guest kernel  (Assets/velox-vmlinux)
#   Contents/Resources/root.img       the erofs guest rootfs   (guest/build/root.img)
#   Contents/Resources/bin/velox          the CLI (start/update/status) — installed onto PATH
#   Contents/Resources/bin/docker         the stock Docker client for macOS — installed onto PATH
#   Contents/Resources/bin/docker-compose the compose CLI plugin — linked into ~/.docker/cli-plugins
#   Contents/Resources/bin/docker-buildx  the buildx  CLI plugin — linked into ~/.docker/cli-plugins
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
if [ ! -f "$ROOT_SRC" ]; then
    # Fall back to the installed copy, but SAY SO: on a self-hosted runner this silently
    # shipped whatever guest happened to be installed there, with no signal in the log.
    ROOT_SRC="$HOME/.velox/root.img"
    echo "==> note: guest/build/root.img missing — falling back to $ROOT_SRC (run Scripts/make-guest.sh for a fresh guest)" >&2
fi
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
DOCKER_CLI_STAMP="$DIST/docker-cli/.docker-version"
# Reuse the cached client only when it is the PINNED version. Keying on existence alone
# let a stale client from a previous DOCKER_VERSION ship unchanged after a bump — a host
# `docker` / guest `dockerd` skew the single-source-of-truth (§2) is meant to prevent.
# Also re-verify the cached BINARY, not just the version stamp — the stamp is trivially
# stale-or-wrong on a local/self-hosted tree, and `fetch_plugin` below already does the
# stronger check. The pin in versions.env covers the TARBALL, so the stamp records the
# extracted binary's own hash at download time (after the tarball was verified) and this
# compares against that.
cached_cli_ok(){
    [ -x "$DOCKER_CLI" ] || return 1
    read -r stamp_version stamp_hash < "$DOCKER_CLI_STAMP" 2>/dev/null || return 1
    [ "$stamp_version" = "$DOCKER_VERSION" ] || return 1
    [ -n "$stamp_hash" ] || return 1
    [ "$(shasum -a 256 "$DOCKER_CLI" | awk '{print $1}')" = "$stamp_hash" ]
}
if ! cached_cli_ok; then
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
    # version + the extracted binary's own hash (the pin covers the tarball, which was
    # verified just above) so a later run can re-verify the cached binary, not just its label.
    printf '%s %s\n' "$DOCKER_VERSION" "$(shasum -a 256 "$DOCKER_CLI" | awk '{print $1}')" > "$DOCKER_CLI_STAMP"
fi

# --- fetch the host-side docker CLI plugins (compose + buildx) -----------------
# compose/buildx are CLIENT plugins the `docker` CLI discovers under its cli-plugins
# dirs (FirstRun links them into ~/.docker/cli-plugins). The mac static tarball above
# ships only `docker`, so these are bundled separately — pinned + SHA-verified from
# versions.env, arm64-only like the client. Each release uses a DIFFERENT filename:
# compose = docker-compose-darwin-aarch64, buildx = buildx-v<ver>.darwin-arm64.
fetch_plugin() {  # <dest-name> <url> <sha256>
    local name="$1" url="$2" sha="$3" out="$DIST/plugins/$1"
    # The plugin binary IS the SHA-pinned artifact, so verify the cache against the pin:
    # a stale binary from a previous plugin version won't match and is re-fetched. Keying
    # on existence alone shipped the old plugin after a version/SHA bump (§2 skew).
    [ -x "$out" ] && echo "${sha}  $out" | shasum -a 256 -c - >/dev/null 2>&1 && return
    [ "$DARCH" = "aarch64" ] || { echo "error: no pinned CLI-plugin SHA-256 for $DARCH (Velox is arm64-only)" >&2; exit 1; }
    mkdir -p "$DIST/plugins"
    echo "==> download $name plugin for macOS ($DARCH)"
    curl -fSL "$url" -o "$out"
    echo "${sha}  $out" | shasum -a 256 -c - >/dev/null \
        || { echo "error: $name SHA-256 mismatch — expected ${sha} (versions.env)" >&2; exit 1; }
    chmod +x "$out"
}
fetch_plugin docker-compose \
    "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-darwin-aarch64" \
    "$DOCKER_COMPOSE_MAC_ARM64_SHA256"
fetch_plugin docker-buildx \
    "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.darwin-arm64" \
    "$DOCKER_BUILDX_MAC_ARM64_SHA256"

# --- assemble the bundle ------------------------------------------------------
echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/VeloxApp"          "$APP/Contents/MacOS/VeloxApp"
cp "$BIN_DIR/velox"             "$APP/Contents/Resources/bin/velox"
cp "$BIN_DIR/velox-porthelper"  "$APP/Contents/Resources/bin/velox-porthelper"
cp "$DOCKER_CLI"                "$APP/Contents/Resources/bin/docker"
cp "$DIST/plugins/docker-compose" "$APP/Contents/Resources/bin/docker-compose"
cp "$DIST/plugins/docker-buildx"  "$APP/Contents/Resources/bin/docker-buildx"
cp "$KERNEL_SRC"                "$APP/Contents/Resources/kernel"
cp "$ROOT_SRC"                  "$APP/Contents/Resources/root.img"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/Resources/bin/velox" "$APP/Contents/Resources/bin/docker" \
         "$APP/Contents/Resources/bin/docker-compose" "$APP/Contents/Resources/bin/docker-buildx" \
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
codesign_once() {  # <path> [entitlements-file]
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

# Retry a transient "Operation not permitted".
#
# Measured on macOS 26: signing a bundle whose ~250 MB of binaries were written seconds
# earlier fails roughly half the time, while re-signing the same settled bundle succeeded
# 8/8. The file is fine — nothing holds it, no flags, no quarantine, and the retry produces
# a signature that verifies. It is a race against whatever scans a freshly written Mach-O
# (XProtect is the obvious candidate), and it only became visible because this script
# started being run many times a day instead of once a release.
#
# The retry is bounded and the result is VERIFIED below, so a genuine denial still fails the
# build loudly rather than shipping an unsigned app.
sign() {  # <path> [entitlements-file]
    local path="$1" ent="${2:-}" attempt out
    for attempt in 1 2 3 4 5; do
        if out=$(codesign_once "$path" "$ent" 2>&1); then
            [ -n "$out" ] && echo "$out"
            return 0
        fi
        echo "$out"
        case "$out" in
            *"Operation not permitted"*|*"resource temporarily unavailable"*|*"resource busy"*)
                echo "    (transient — retrying in ${attempt}s, attempt $attempt/5)"
                sleep "$attempt" ;;
            *)  echo "error: codesign failed on $path" >&2; return 1 ;;
        esac
    done
    echo "error: codesign kept failing on $path after 5 attempts" >&2
    return 1
}
echo "==> codesign ($SIGN_IDENTITY)"
sign "$APP/Contents/Resources/bin/docker"
# The compose/buildx CLI plugins are pure clients like `docker` — no entitlements.
sign "$APP/Contents/Resources/bin/docker-compose"
sign "$APP/Contents/Resources/bin/docker-buildx"
# The port helper runs as root via launchd; its power comes from that, not an
# entitlement — so it's signed plain, like the docker client.
sign "$APP/Contents/Resources/bin/velox-porthelper"
sign "$APP/Contents/Resources/bin/velox" "$ENTITLEMENTS"
sign "$APP" "$ENTITLEMENTS"

# Prove the seal is real. `sign` retries a transient failure, so this is what makes that
# retry safe: if the signature is somehow still bad, the build stops here instead of
# producing a bundle that fails to launch on someone else's Mac.
codesign --verify --deep --strict "$APP" || {
    echo "error: $APP failed signature verification after signing" >&2; exit 1; }

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
