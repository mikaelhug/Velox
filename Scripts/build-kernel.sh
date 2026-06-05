#!/usr/bin/env bash
# Build a BARE, FAST arm64 Linux kernel for Velox straight from kernel.org source
# (no LinuxKit), under full config control — the OrbStack-style "macvirt" path.
#
# Apple's Virtualization.framework boots a raw, uncompressed arch/arm64/boot/Image
# via VZLinuxBootLoader (it cannot run an EFI-zboot self-decompression stub). So we
# compile our own minimal kernel: everything the VM actually uses built-in (=y),
# nothing else. The result lands at Assets/velox-vmlinux and ~/.velox/kernel; the
# Swift host loads it with `console=hvc0` and boots the erofs root directly off
# /dev/vda — no initramfs.
#
# The kernel source tree is NEVER written to the Mac filesystem: APFS is
# case-insensitive (netfilter headers collide by case) and bind-mounting millions
# of tiny kernel files is catastrophically slow. Extraction AND compilation happen
# inside a Docker named volume (ext4/overlay); only the final Image is copied back.
#
# Requires: Docker (with linux/arm64 support — native on Apple Silicon). No Swift,
# no linuxkit, no Go. Version + checksum are pinned in versions.env.
#
# Usage:
#   ./Scripts/build-kernel.sh          # build (incremental; reuses the volume)
#   CLEAN=1 ./Scripts/build-kernel.sh  # wipe the source/object volume first
#   VERIFY_GPG=1 ./Scripts/build-kernel.sh   # also PGP-verify the tarball
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./versions.env; set +a

# --- Modular knobs ---------------------------------------------------------
KERNEL_SERIES="${KERNEL_ORG_SERIES:?set KERNEL_ORG_SERIES in versions.env}"
KERNEL_VERSION="${KERNEL_ORG_VERSION:?set KERNEL_ORG_VERSION in versions.env}"
KERNEL_SHA256="${KERNEL_ORG_SHA256:?set KERNEL_ORG_SHA256 in versions.env}"
OUTPUT="${OUTPUT:-Assets/velox-vmlinux}"
INSTALL_DEST="${INSTALL_DEST:-$HOME/.velox/kernel}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
VOLUME="${VOLUME:-velox-kernel-build}"
BUILDER_TAG="${BUILDER_TAG:-velox-kernel-builder}"
FRAGMENT="guest/kernel/velox.fragment"
DOCKERFILE="guest/kernel/Dockerfile.builder"
PLATFORM="linux/arm64"
# kernel.org major dir is v<MAJOR>.x (e.g. 6.12.92 -> v6.x).
KERNEL_MAJOR="${KERNEL_VERSION%%.*}"
TARBALL="linux-${KERNEL_VERSION}.tar.xz"
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${TARBALL}"
# moby's container-host config validator, pinned.
CHECKCONFIG_REF="${CHECKCONFIG_REF:-v28.5.0}"
CHECKCONFIG_URL="https://raw.githubusercontent.com/moby/moby/${CHECKCONFIG_REF}/contrib/check-config.sh"
VERIFY_GPG="${VERIFY_GPG:-0}"

# Critical symbols whose silent loss (unmet dep after olddefconfig) would mean a
# kernel that won't boot under VZ or won't host dockerd. Asserted post-merge.
REQUIRED_SYMBOLS=(
    PCI PCI_HOST_GENERIC VIRTIO VIRTIO_PCI
    VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE VIRTIO_BALLOON HW_RANDOM_VIRTIO
    VSOCKETS VIRTIO_VSOCKETS
    FUSE_FS VIRTIO_FS BINFMT_MISC
    FILE_LOCKING FHANDLE INOTIFY_USER
    EROFS_FS EROFS_FS_ZIP EXT4_FS EXT4_FS_SECURITY OVERLAY_FS TMPFS TMPFS_XATTR DEVTMPFS DEVTMPFS_MOUNT BINFMT_ELF SWAP
    NET INET BRIDGE VETH BRIDGE_NETFILTER
    NETFILTER NF_CONNTRACK NF_NAT NF_TABLES NFT_NAT NFT_MASQ NFT_COMPAT
    NFT_FIB_IPV4 NFT_FIB_IPV6 NFT_FIB_INET NFT_REDIR
    NAMESPACES NET_NS PID_NS IPC_NS UTS_NS USER_NS
    CGROUPS MEMCG BLK_CGROUP CGROUP_PIDS CGROUP_DEVICE CFS_BANDWIDTH
    SECCOMP SECCOMP_FILTER BPF_SYSCALL
    RANDOMIZE_BASE STACKPROTECTOR_STRONG FORTIFY_SOURCE SLAB_FREELIST_HARDENED SLAB_FREELIST_RANDOM
)

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found — required to build the kernel in an arm64 container" >&2
    exit 1
fi
[ -f "$FRAGMENT" ]   || { echo "error: missing $FRAGMENT" >&2; exit 1; }
[ -f "$DOCKERFILE" ] || { echo "error: missing $DOCKERFILE" >&2; exit 1; }

# === Phase 1/2: build container + named volume (idempotent) ================
if [ "${CLEAN:-0}" = "1" ]; then
    echo "==> CLEAN=1: removing build volume $VOLUME"
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
fi
docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
    echo "==> creating build volume $VOLUME"
    docker volume create "$VOLUME" >/dev/null
}

echo "==> building builder image $BUILDER_TAG ($PLATFORM)"
docker build --platform "$PLATFORM" -t "$BUILDER_TAG" -f "$DOCKERFILE" guest/kernel

# Output dir on the Mac receives ONLY the final Image (one file — APFS-safe).
mkdir -p "$(dirname "$OUTPUT")"
OUT_ABS="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUT_NAME="$(basename "$OUTPUT")"

# === Phases 1,3,4: everything that touches the kernel tree runs in-container,
# writing only to the named volume (/build). The fragment is bind-mounted
# read-only (a single small file on APFS is fine); the Image is written to /out.
IN_CONTAINER='
set -euo pipefail
cd /build

SRC="linux-${KERNEL_VERSION}"
# --- Phase 1: fetch + verify + extract (idempotent) ---
if [ ! -d "$SRC" ]; then
    echo "==> [container] fetching ${TARBALL_URL}"
    curl -fSL -o "${TARBALL}" "${TARBALL_URL}"
    echo "==> [container] verifying SHA-256"
    echo "${KERNEL_SHA256}  ${TARBALL}" | sha256sum -c -
    if [ "${VERIFY_GPG}" = "1" ]; then
        echo "==> [container] PGP-verifying tarball signature"
        curl -fSL -o "${TARBALL%.xz}.sign" "${TARBALL_URL%.xz}.sign"
        export GNUPGHOME="$(mktemp -d)"
        # Greg Kroah-Hartman (stable) + Linus Torvalds release keys.
        gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys \
            647F28654894E3BD457199BE38DBBDC86092693E \
            ABAF11C65A2970B130ABE3C479BE3E4300411886
        xz -dc "${TARBALL}" > "${TARBALL%.xz}"
        gpg --batch --verify "${TARBALL%.xz}.sign" "${TARBALL%.xz}"
        rm -f "${TARBALL%.xz}"
    fi
    echo "==> [container] extracting (onto the ext4 volume, never APFS)"
    tar -xJf "${TARBALL}"
    rm -f "${TARBALL}"
fi
cd "$SRC"

# --- Phase 3: tinyconfig + curated fragment + olddefconfig ---
echo "==> [container] make tinyconfig"
make ARCH=arm64 tinyconfig >/dev/null
echo "==> [container] merge fragment + olddefconfig"
./scripts/kconfig/merge_config.sh -m .config /tmp/velox.fragment >/dev/null
make ARCH=arm64 olddefconfig >/dev/null

# --- Phase 3: assert every required symbol actually resolved to =y ---
echo "==> [container] asserting required CONFIG symbols"
missing=""
for sym in ${REQUIRED_SYMBOLS}; do
    grep -q "^CONFIG_${sym}=y" .config || missing="${missing} ${sym}"
done
if [ -n "$missing" ]; then
    echo "error: required CONFIG symbols dropped after olddefconfig:" >&2
    for s in $missing; do echo "  CONFIG_$s" >&2; done
    echo "(check the fragment + its Kconfig deps; nothing was built)" >&2
    exit 1
fi
echo "    all required symbols present."

# --- Phase 3: moby check-config.sh; hard-fail on Generally Necessary misses ---
echo "==> [container] running moby check-config.sh"
curl -fSL -o /tmp/check-config.sh "${CHECKCONFIG_URL}"
chmod +x /tmp/check-config.sh
report="$(CONFIG=.config bash /tmp/check-config.sh .config 2>&1 || true)"
echo "$report"
# Symbols moby check-config still lists as "generally necessary" but that Velox
# deliberately omits: the legacy iptables/ip6tables xtables TABLES (we run the
# nftables firewall backend instead), and IPVS (single-node Docker never uses it,
# only Swarm/kube load-balancing). Their absence must NOT fail the build.
expected_missing="CONFIG_(IP_NF_(IPTABLES|FILTER|MANGLE|RAW|NAT|TARGET_MASQUERADE)|IP6_NF_(IPTABLES|FILTER|MANGLE|RAW|NAT|TARGET_MASQUERADE)|NETFILTER_XT_MATCH_IPVS|IP_VS)"
# Strip ANSI, isolate the "Generally Necessary" block, flag any "missing" that
# is not on the intentionally-omitted list above.
necessary_missing="$(printf "%s\n" "$report" \
    | sed -E "s/\x1b\[[0-9;]*m//g" \
    | awk "/Generally Necessary/{f=1;next} /Optional Features/{f=0} f" \
    | grep -i "missing" \
    | grep -vE "$expected_missing" || true)"
if [ -n "$necessary_missing" ]; then
    echo "error: check-config.sh reports Generally-Necessary items missing:" >&2
    echo "$necessary_missing" >&2
    exit 1
fi

# CONFIG_ONLY: validate the fragment/symbols/check-config without the long compile.
if [ "${CONFIG_ONLY}" = "1" ]; then
    echo "==> [container] CONFIG_ONLY=1 — config validated, skipping make Image"
    exit 0
fi

# --- Phase 4: build the uncompressed Image ---
echo "==> [container] make -j${JOBS} Image"
make -j"${JOBS}" ARCH=arm64 Image
cp arch/arm64/boot/Image "/out/${OUT_NAME}"
echo "==> [container] wrote /out/${OUT_NAME} ($(du -h arch/arm64/boot/Image | cut -f1))"
'

echo "==> compiling kernel ${KERNEL_VERSION} in $VOLUME (jobs=$JOBS) — first run is slow"
docker run --rm --platform "$PLATFORM" \
    -e KERNEL_VERSION="$KERNEL_VERSION" \
    -e TARBALL="$TARBALL" \
    -e TARBALL_URL="$TARBALL_URL" \
    -e KERNEL_SHA256="$KERNEL_SHA256" \
    -e CHECKCONFIG_URL="$CHECKCONFIG_URL" \
    -e VERIFY_GPG="$VERIFY_GPG" \
    -e JOBS="$JOBS" \
    -e OUT_NAME="$OUT_NAME" \
    -e CONFIG_ONLY="${CONFIG_ONLY:-0}" \
    -e REQUIRED_SYMBOLS="${REQUIRED_SYMBOLS[*]}" \
    -v "$VOLUME":/build \
    -v "$PWD/$FRAGMENT":/tmp/velox.fragment:ro \
    -v "$OUT_ABS":/out \
    "$BUILDER_TAG" bash -c "$IN_CONTAINER"

if [ "${CONFIG_ONLY:-0}" = "1" ]; then
    echo "==> CONFIG_ONLY=1: config validated; no Image produced. Re-run without CONFIG_ONLY to build."
    exit 0
fi

# === Phase 4: install + Phase 5: verify the artifact on the host ===========
mkdir -p "$(dirname "$INSTALL_DEST")"
cp "$OUTPUT" "$INSTALL_DEST"
echo "==> installed kernel → $INSTALL_DEST"

echo "==> verifying artifact"
# arm64 raw boot Image carries the ASCII magic "ARM\x64" at offset 0x38; an
# EFI-zboot wrapper would instead show "zimg" at 0x04. We want the raw Image.
magic="$(dd if="$OUTPUT" bs=1 skip=56 count=4 2>/dev/null | tr -d '\0')"
if [ "$magic" != "ARM" ] && [ "${magic:0:3}" != "ARM" ]; then
    echo "error: $OUTPUT does not look like a raw arm64 Image (magic='$magic')" >&2
    exit 1
fi
size_bytes=$(wc -c < "$OUTPUT" | tr -d ' ')
size_mb=$(( size_bytes / 1024 / 1024 ))
if [ "$size_mb" -lt 4 ] || [ "$size_mb" -gt 64 ]; then
    echo "error: $OUTPUT size ${size_mb}MB is outside the sane 4–64MB band" >&2
    exit 1
fi
echo "==> done: $OUTPUT (${size_mb}MB), installed to $INSTALL_DEST"
echo "    smoke-boot: ./Scripts/make-guest.sh && velox start  (expect console=hvc0 output)"
