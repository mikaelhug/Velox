#!/usr/bin/env bash
# Build the Velox guest as a flat, fully-static appliance and install it.
#
# There is NO LinuxKit and no docker:*-dind image. The guest is a single erofs
# root image (read-only, compressed, demand-paged) containing only the static
# Docker server binaries, a static mkfs.ext4, the CA bundle, and the static Rust
# /sbin/init (vinit). The kernel comes from Scripts/build-kernel.sh.
#
# Produces: guest/build/root.img (erofs) and installs kernel + root.img to ~/.velox.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; . ./versions.env; set +a

KERNEL_ARTIFACT="Assets/velox-vmlinux"
OUT="guest/build"
DEST="$HOME/.velox"
ROOTFS_TAG="velox/rootfs:latest"
mkdir -p "$OUT" "$DEST"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required to build the guest rootfs" >&2; exit 1
fi
if [ ! -f "$KERNEL_ARTIFACT" ]; then
    echo "error: $KERNEL_ARTIFACT not found — build the kernel first: ./Scripts/build-kernel.sh" >&2
    exit 1
fi

echo "==> build guest rootfs image (static vinit + docker $DOCKER_VERSION + static mkfs.ext4)"
docker build --platform linux/arm64 -t "$ROOTFS_TAG" \
    --build-arg "RUST_BUILD_IMAGE=${RUST_BUILD_IMAGE}" \
    --build-arg "ALPINE_IMAGE=${ALPINE_IMAGE}" \
    --build-arg "DOCKER_VERSION=${DOCKER_VERSION}" \
    --build-arg "DOCKER_SHA256=${DOCKER_STATIC_SHA256}" \
    -f guest/rootfs/Dockerfile guest

echo "==> export the flat tree"
# (the command is ignored — we only export the filesystem; scratch images need one)
cid="$(docker create --platform linux/arm64 "$ROOTFS_TAG" /sbin/init)"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker export "$cid" -o "$OUT/rootfs.tar"

echo "==> mkfs.erofs (lz4hc) → $OUT/root.img"
OUT_ABS="$(cd "$OUT" && pwd)"
# Read the tar from the bind-mounted /out, NOT piped over the container's stdin: a
# large (>100 MB) `-i` stdin stream silently chokes over the VSOCK docker transport
# when this build runs on the Velox engine itself — mkfs never runs and root.img is
# left stale. The tar is already at $OUT (mounted at /out), so read it from there.
docker run --rm --platform linux/arm64 -v "$OUT_ABS":/out "${ALPINE_IMAGE}" sh -c '
    set -e
    apk add --no-cache erofs-utils >/dev/null 2>&1
    rm -rf /r && mkdir -p /r
    tar -C /r -xf /out/rootfs.tar
    rm -f /out/root.img
    # lz4hc level 12 (max): lz4 decompression speed is independent of the level —
    # a higher level only costs build time and yields a smaller image that reads
    # FEWER bytes per demand-page. Strictly better at runtime than the default (9).
    mkfs.erofs -zlz4hc,12 -T0 --all-root /out/root.img /r >/dev/null
'
rm -f "$OUT/rootfs.tar"

# Sanity: erofs image should be tens of MB, not near-empty.
isize=$(wc -c < "$OUT/root.img" | tr -d ' ')
if [ "$isize" -lt 5242880 ]; then
    echo "error: $OUT/root.img is only ${isize}B — build failed" >&2; exit 1
fi

cp "$KERNEL_ARTIFACT" "$DEST/kernel"
cp "$OUT/root.img" "$DEST/root.img"
# Stamp the installed guest with this version so a same-version Velox.app launch leaves this
# dev build in place (GuestInstall only refreshes from the bundle when the stamp differs).
echo "$VELOX_VERSION" > "$DEST/guest.version"
# The old initramfs is gone — remove a stale one so the boot path is unambiguous.
rm -f "$DEST/initrd.img"
echo "==> Installed kernel + root.img → $DEST"
ls -lh "$DEST/kernel" "$DEST/root.img"
echo "    root.img: $(echo "scale=1; $isize/1048576" | bc 2>/dev/null || echo $((isize/1048576)))MB erofs"
