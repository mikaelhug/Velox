#!/usr/bin/env bash
# Build a custom LinuxKit kernel for Velox with CONFIG_VIRTIO_FS=y enabled.
#
# The stock linuxkit/kernel is built WITHOUT VirtioFS, and Apple's
# Virtualization.framework only offers VirtioFS for file sharing (no virtio-9p).
# VirtioFS (`vlcmd run -v`) and Rosetta both require it — so, like Docker
# Desktop, Velox builds its own kernel. The result is retagged and pinned in
# versions.env (KERNEL_IMAGE).
#
# Requires: linuxkit CLI (~/go/bin), Docker, git. Takes tens of minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./versions.env; set +a

WORK="${VELOX_LINUXKIT_SRC:-/tmp/velox-linuxkit}"
LINUXKIT_REF="${LINUXKIT_REF:-master}"
SERIES="6.12.x"
OUT_TAG="${KERNEL_IMAGE:-velox/kernel:6.12.59-virtiofs}"
export PATH="$(go env GOPATH)/bin:$PATH"

if [ ! -d "$WORK/.git" ]; then
    echo "==> cloning linuxkit ($LINUXKIT_REF) → $WORK"
    git clone --depth 1 -b "$LINUXKIT_REF" https://github.com/linuxkit/linuxkit.git "$WORK"
fi

CFG="$WORK/kernel/$SERIES/config-aarch64"
echo "==> enabling CONFIG_VIRTIO_FS in $CFG"
if grep -q '^# CONFIG_VIRTIO_FS is not set' "$CFG"; then
    sed -i '' 's/^# CONFIG_VIRTIO_FS is not set/CONFIG_VIRTIO_FS=y/' "$CFG"
fi
grep -q '^CONFIG_VIRTIO_FS=y' "$CFG" || echo 'CONFIG_VIRTIO_FS=y' >> "$CFG"

echo "==> building kernel (this takes a while)…"
( cd "$WORK/kernel" && make "buildplainkernel-$SERIES" )

# `linuxkit pkg build` stores the image in the LinuxKit cache (~/.linuxkit/cache),
# not Docker. Find the built tag, export it to Docker, and retag stably so
# `make-guest.sh` (linuxkit build --docker) and versions.env can use it.
CACHE_TAG=$(linuxkit cache ls 2>/dev/null \
    | awk '{print $1}' | sed 's#^docker.io/##' \
    | grep "^linuxkit/kernel:${SERIES}-" | grep -v -- '-arm64$' | head -1)
if [ -z "$CACHE_TAG" ]; then
    echo "error: could not find built kernel in linuxkit cache" >&2
    exit 1
fi
echo "==> built $CACHE_TAG — exporting to Docker and tagging as $OUT_TAG"
TAR=$(mktemp /tmp/velox-kernel.XXXXXX.tar)
linuxkit cache export --format docker --platform linux/arm64 --outfile "$TAR" "$CACHE_TAG"
docker load -i "$TAR"
docker tag "$CACHE_TAG" "$OUT_TAG"
rm -f "$TAR"
echo "==> done: $OUT_TAG (matches KERNEL_IMAGE in versions.env). Run ./Scripts/make-guest.sh"
