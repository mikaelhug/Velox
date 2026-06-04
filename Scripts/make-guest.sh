#!/usr/bin/env bash
# Build the LinuxKit guest image into guest/build/ as kernel + initrd.
# Produces: guest/build/velox-kernel, velox-initrd.img, velox-cmdline
set -euo pipefail
cd "$(dirname "$0")/.."

LINUXKIT="${LINUXKIT:-$(command -v linuxkit || echo "$(go env GOPATH)/bin/linuxkit")}"
if [ ! -x "$LINUXKIT" ]; then
    echo "error: linuxkit not found. Install with:" >&2
    echo "  go install github.com/linuxkit/linuxkit/src/cmd/linuxkit@latest" >&2
    exit 1
fi

OUT="guest/build"
mkdir -p "$OUT"

# Render guest/velox.yml from the template using versions.env (single source).
set -a; . ./versions.env; set +a
echo "==> render guest/velox.yml from guest/velox.yml.tmpl"
envsubst '$KERNEL_IMAGE $INIT_IMAGE $RUNC_IMAGE $CONTAINERD_IMAGE $RNGD_IMAGE $GETTY_IMAGE $FORMAT_IMAGE $MOUNT_IMAGE $DHCPCD_IMAGE $ACPID_IMAGE $ALPINE_IMAGE $DIND_IMAGE' \
    < guest/velox.yml.tmpl > guest/velox.yml

# Build the guest vsock-relay image into the local Docker daemon first so
# `linuxkit build --docker` can resolve it without a registry.
if command -v docker >/dev/null 2>&1; then
    ./Scripts/build-relay.sh
else
    echo "warning: docker not found — skipping vsock-relay image build" >&2
fi

echo "==> linuxkit build (kernel+initrd, arm64) → $OUT"
"$LINUXKIT" build \
    --docker \
    --format kernel+initrd \
    --arch arm64 \
    --dir "$OUT" \
    --name velox \
    guest/velox.yml

# Recent arm64 kernels ship as EFI zboot ("MZ....zimg"): a compressed kernel in
# a PE wrapper. VZLinuxBootLoader loads the kernel directly and cannot run the
# EFI self-decompression stub, so extract the raw Image it expects.
KIMG="$OUT/velox-kernel"
MAGIC=$(dd if="$KIMG" bs=1 skip=4 count=4 2>/dev/null | tr -d '\0')
if [ "$MAGIC" = "zimg" ]; then
    OFF=$(od -An -tu4 -j8 -N4 "$KIMG" | tr -d ' ')
    COMP=$(dd if="$KIMG" bs=1 skip=24 count=8 2>/dev/null | tr -d '\0')
    echo "==> EFI zboot kernel detected (compression=$COMP) — decompressing for Virtualization.framework"
    case "$COMP" in
        gzip)  tail -c +"$((OFF + 1))" "$KIMG" | gunzip       > "$KIMG.raw" 2>/dev/null || true ;;
        lz4)   tail -c +"$((OFF + 1))" "$KIMG" | lz4 -d       > "$KIMG.raw" 2>/dev/null || true ;;
        zstd)  tail -c +"$((OFF + 1))" "$KIMG" | zstd -d      > "$KIMG.raw" 2>/dev/null || true ;;
        *) echo "error: unsupported zboot compression '$COMP'" >&2; exit 1 ;;
    esac
    # Sanity check: decompressed arm64 Image carries the "ARMd" magic at 0x38.
    if [ "$(dd if="$KIMG.raw" bs=1 skip=56 count=4 2>/dev/null)" != "ARMd" ]; then
        echo "error: decompressed kernel is not a valid arm64 Image" >&2; exit 1
    fi
    mv "$KIMG.raw" "$KIMG"
    echo "==> kernel: $(file -b "$KIMG")"
fi

# Install to ~/.velox so `velox start` finds artifacts with no env vars.
DEST="$HOME/.velox"
mkdir -p "$DEST"
cp "$KIMG" "$DEST/kernel"
cp "$OUT/velox-initrd.img" "$DEST/initrd.img"
echo "==> Installed kernel + initrd.img → $DEST"

echo "==> Output:"
ls -la "$OUT" "$DEST/kernel" "$DEST/initrd.img"
