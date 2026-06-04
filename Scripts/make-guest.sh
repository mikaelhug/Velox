#!/usr/bin/env bash
# Build the Velox guest USERSPACE (initrd) with LinuxKit, and install it next to
# the from-source kernel that Scripts/build-kernel.sh produced.
#
# The kernel is no longer a LinuxKit artifact: Velox builds its own bare arm64
# kernel from kernel.org source (Scripts/build-kernel.sh → Assets/velox-vmlinux).
# LinuxKit is used ONLY to assemble the initrd (init + containerd + dockerd +
# vsock-relay). The Swift host boots Assets' kernel + this initrd, both installed
# to ~/.velox. Produces: guest/build/velox-initrd.img.
set -euo pipefail
cd "$(dirname "$0")/.."

LINUXKIT="${LINUXKIT:-$(command -v linuxkit || echo "$(go env GOPATH)/bin/linuxkit")}"
if [ ! -x "$LINUXKIT" ]; then
    echo "error: linuxkit not found. Install with:" >&2
    echo "  go install github.com/linuxkit/linuxkit/src/cmd/linuxkit@latest" >&2
    exit 1
fi

KERNEL_ARTIFACT="Assets/velox-vmlinux"
OUT="guest/build"
DEST="$HOME/.velox"
mkdir -p "$OUT" "$DEST"

# The kernel must already be built from source (it is NOT produced here).
if [ ! -f "$KERNEL_ARTIFACT" ]; then
    echo "error: $KERNEL_ARTIFACT not found — build the kernel first:" >&2
    echo "  ./Scripts/build-kernel.sh" >&2
    exit 1
fi

# Render guest/velox.yml from the template using versions.env (single source).
# No $KERNEL_IMAGE anymore — the YAML has no kernel section (initrd-only build).
set -a; . ./versions.env; set +a
echo "==> render guest/velox.yml from guest/velox.yml.tmpl"
envsubst '$INIT_IMAGE $RUNC_IMAGE $CONTAINERD_IMAGE $RNGD_IMAGE $GETTY_IMAGE $FORMAT_IMAGE $MOUNT_IMAGE $DHCPCD_IMAGE $ACPID_IMAGE $ALPINE_IMAGE $DIND_IMAGE' \
    < guest/velox.yml.tmpl > guest/velox.yml

# Build the guest vsock-relay image into the local Docker daemon first so
# `linuxkit build --docker` can resolve it without a registry.
if command -v docker >/dev/null 2>&1; then
    ./Scripts/build-relay.sh
else
    echo "warning: docker not found — skipping vsock-relay image build" >&2
fi

# The kernel comes from Assets/velox-vmlinux, not LinuxKit. LinuxKit has no plain
# "initrd" output, and its `kernel+initrd` format would require a kernel image we
# no longer ship — so build the root filesystem as a `tar` (needs no kernel) and
# repack it into a cpio.gz initramfs ourselves, exactly what `kernel+initrd` does
# internally. The repack runs in a Linux container so device nodes, permissions
# and setuid bits survive (the host is macOS/APFS, which would mangle them).
echo "==> linuxkit build (rootfs tar, arm64) → $OUT/velox.tar"
"$LINUXKIT" build \
    --docker \
    --format tar \
    --arch arm64 \
    --dir "$OUT" \
    --name velox \
    guest/velox.yml

# Reuse the kernel builder image (it has GNU tar + cpio); build it if absent.
CONVERTER="velox-kernel-builder"
if ! docker image inspect "$CONVERTER" >/dev/null 2>&1; then
    echo "==> building $CONVERTER image (tar→cpio.gz helper)"
    docker build --platform linux/arm64 -t "$CONVERTER" -f guest/kernel/Dockerfile.builder guest/kernel
fi
echo "==> repacking rootfs tar → cpio.gz initramfs"
docker run --rm -i --platform linux/arm64 "$CONVERTER" \
    bash -c 'set -o pipefail; mkdir /r && cd /r && tar --overwrite -xf - 2>/dev/null && find . | cpio -o -H newc 2>/dev/null | gzip -9' \
    < "$OUT/velox.tar" > "$OUT/velox-initrd.img"
rm -f "$OUT/velox.tar"

# Sanity: a real initramfs is tens-to-hundreds of MB; a near-empty file means the
# repack silently failed.
isize=$(wc -c < "$OUT/velox-initrd.img" | tr -d ' ')
if [ "$isize" -lt 10485760 ]; then
    echo "error: initramfs $OUT/velox-initrd.img is only ${isize}B — repack failed" >&2
    exit 1
fi

# Install kernel (from source build) + initrd so `velox start` finds them.
cp "$KERNEL_ARTIFACT" "$DEST/kernel"
cp "$OUT/velox-initrd.img" "$DEST/initrd.img"
echo "==> Installed kernel + initrd.img → $DEST"

echo "==> Output:"
ls -la "$DEST/kernel" "$DEST/initrd.img"
