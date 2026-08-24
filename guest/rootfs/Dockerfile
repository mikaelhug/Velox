# Velox guest root filesystem — a minimal, demand-paged appliance.
# NO LinuxKit, NO docker:*-dind, NO per-container rootfs duplication. The guest is:
#   - the static Rust /sbin/init (vinit): PID1 + supervisor + vsock agent
#   - Docker's official STATIC server binaries (dockerd/containerd/runc/…)
#   - a tiny musl userland (nftables, e2fsprogs, ca-certificates) — the only tools
#     dockerd shells out to (native nftables firewall via `nft` + one-time data-disk mkfs)
#   - three static QEMU user-mode emulators (arm, i386, x86_64) so linux/arm and linux/386
#     images run out of the box; vinit registers them in binfmt_misc at boot
# Scripts/make-guest.sh exports this and runs mkfs.erofs over it → root.img.
#
# (Eliminating the musl /lib entirely would require building a static nft + mke2fs
#  from source — a follow-up polish; everything else is already static.)

ARG RUST_BUILD_IMAGE=rust:1-alpine
ARG ALPINE_IMAGE=alpine:3.23
# The Docker engine version + its tgz SHA-256. The SINGLE source is versions.env
# (DOCKER_VERSION / DOCKER_STATIC_SHA256); Scripts/make-guest.sh passes them as build-args.
# NO defaults on purpose (CLAUDE.md §2): a hard-coded value silently drifted from versions.env
# and shipped the wrong engine on a bare `docker build`. Without these args the guard in the
# `docker` stage fails loudly — always build via Scripts/make-guest.sh.
ARG DOCKER_VERSION
ARG DOCKER_SHA256

# --- vinit: static musl PID1 (init + supervisor + vsock agent) ---
FROM ${RUST_BUILD_IMAGE} AS vinit
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY vinit/Cargo.toml vinit/Cargo.lock ./
COPY vinit/src ./src
# rust:alpine already targets *-musl, so a normal release build is fully static.
# `--locked`: without the lockfile in the context, cargo re-resolved `libc = "0.2"` to
# whatever was newest on crates.io at build time — floating dependencies compiled into the
# VM's PID 1, and two builds of the same commit producing different bytes (which also
# quietly invalidated the premise of the rootfs cache key, since Cargo.lock IS hashed into it).
RUN cargo build --locked --release && strip target/release/vinit && cp target/release/vinit /vinit

# --- Docker static server binaries ---
FROM ${ALPINE_IMAGE} AS docker
ARG DOCKER_VERSION
ARG DOCKER_SHA256
# Fail loudly if the build-args weren't supplied (bare `docker build` instead of make-guest.sh),
# rather than fetching a wrong/empty version — versions.env is the single source of truth (§2).
RUN test -n "${DOCKER_VERSION}" && test -n "${DOCKER_SHA256}" \
 || { echo "ERROR: DOCKER_VERSION/DOCKER_SHA256 build-args required — build via Scripts/make-guest.sh (from versions.env)" >&2; exit 1; }
RUN wget -qO docker.tgz "https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz" \
 && echo "${DOCKER_SHA256}  docker.tgz" | sha256sum -c - \
 && tar xf docker.tgz \
 && mkdir -p /out/bin \
 && cp docker/dockerd docker/containerd docker/containerd-shim-runc-v2 docker/runc \
       docker/docker-proxy docker/docker-init /out/bin/

# --- QEMU user-mode emulators: linux/arm + linux/386 (+ a linux/amd64 fallback) ---
# Rosetta covers linux/amd64; these cover the rest of the matrix Docker Desktop and OrbStack
# support out of the box. Apple silicon has no AArch32 EL0 and the kernel is built without
# CONFIG_COMPAT, so a 32-bit image can ONLY run through an emulator — vinit registers these in
# binfmt_misc at boot (setup_binfmt), which is what makes `--platform linux/arm/v7` work with no
# privileged setup container and across restarts. qemu-x86_64 is the fallback for Macs without
# Rosetta; when Rosetta IS present vinit does not register it (Rosetta is far faster).
# Debian's `qemu-user`, not Alpine's: Alpine's user-mode QEMU is dynamically linked, and a
# dynamic interpreter cannot work inside a container that has no matching /lib. Same source
# LinuxKit (and therefore Docker Desktop) uses, for the same reason.
FROM ${ALPINE_IMAGE} AS qemu
ARG QEMU_USER_VERSION
ARG QEMU_USER_SNAPSHOT
ARG QEMU_USER_DEB_SHA256
RUN test -n "${QEMU_USER_VERSION}" && test -n "${QEMU_USER_SNAPSHOT}" && test -n "${QEMU_USER_DEB_SHA256}" \
 || { echo "ERROR: QEMU_USER_* build-args required — build via Scripts/make-guest.sh (from versions.env)" >&2; exit 1; }
RUN apk add --no-cache binutils curl xz
# deb.debian.org first (CDN, but pool URLs vanish on the next point release), then the immutable
# snapshot copy. Both are checked against the same pinned SHA-256, so the mirror is not trusted.
RUN set -e; deb="qemu-user_${QEMU_USER_VERSION}_arm64.deb"; \
    curl -fsSL -o "$deb" "https://deb.debian.org/debian/pool/main/q/qemu/${deb}" \
      || curl -fsSL -o "$deb" "https://snapshot.debian.org/archive/debian/${QEMU_USER_SNAPSHOT}/pool/main/q/qemu/${deb}"; \
    echo "${QEMU_USER_DEB_SHA256}  ${deb}" | sha256sum -c -; \
    ar x "$deb" data.tar.xz; \
    mkdir -p /out /x; \
    xz -dc data.tar.xz | tar -x -C /x ./usr/bin/qemu-arm ./usr/bin/qemu-i386 ./usr/bin/qemu-x86_64; \
    cp /x/usr/bin/qemu-arm /x/usr/bin/qemu-i386 /x/usr/bin/qemu-x86_64 /out/; \
    for f in /out/qemu-*; do \
        if readelf -lW "$f" | grep -q INTERP; then \
            echo "ERROR: $f is dynamically linked — unusable as a binfmt interpreter in a container" >&2; exit 1; \
        fi; \
        readelf -hW "$f" | grep -q "Machine:.*AArch64" \
            || { echo "ERROR: $f is not an arm64 binary" >&2; exit 1; }; \
    done; \
    ls -l /out

# --- assemble a minimal musl root with only the tools dockerd needs ---
# IMPORTANT: do ALL `RUN` steps first, then the binary COPYs last. (A RUN placed
# right after `COPY … /rootfs/sbin/init` gets exec'd AS that binary by this
# buildkit/containerd-store setup — so no RUN may follow the vinit copy.)
FROM ${ALPINE_IMAGE} AS assembly
# apk resolves the (few) musl libs these pull in. dockerd runs with its NATIVE
# nftables firewall backend (--firewall-backend=nftables), which drives the `nft`
# binary directly — so we ship only `nftables`, NOT the legacy iptables/ip6tables
# (iptables-nft) compat shim. Native dockerd capability > extra packages.
# e2fsprogs-extra is pulled in ONLY for `resize2fs`: vinit resizes the ext4 to match
# diskGiB on boot — growing online, or shrinking offline (with a prior `e2fsck`, which
# is kept from base e2fsprogs below). The rest of e2fsprogs-extra's tools are trimmed to
# keep the rootfs lean. resize2fs reuses libext2fs/libe2p/libcom_err from base e2fsprogs.
RUN apk add --no-cache --initdb --root /rootfs \
      --repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
      nftables e2fsprogs e2fsprogs-extra ca-certificates \
 && rm -rf /rootfs/etc/apk /rootfs/lib/apk /rootfs/var/cache /rootfs/etc/network \
           /rootfs/etc/init.d /rootfs/etc/conf.d /rootfs/sbin/openrc* /rootfs/usr/share/man \
 && rm -f /rootfs/bin/chattr /rootfs/bin/lsattr \
          /rootfs/usr/sbin/badblocks /rootfs/usr/sbin/debugfs /rootfs/usr/sbin/dumpe2fs \
          /rootfs/usr/sbin/e2freefrag /rootfs/usr/sbin/e2image /rootfs/usr/sbin/e2label \
          /rootfs/usr/sbin/e2mmpstatus /rootfs/usr/sbin/e2scrub /rootfs/usr/sbin/e2scrub_all \
          /rootfs/usr/sbin/e2undo /rootfs/usr/sbin/e4crypt /rootfs/usr/sbin/e4defrag \
          /rootfs/usr/sbin/filefrag /rootfs/usr/sbin/logsave /rootfs/usr/sbin/mklost+found \
          /rootfs/usr/sbin/tune2fs \
 && mkdir -p /rootfs/proc /rootfs/sys /rootfs/dev/pts /rootfs/dev/shm /rootfs/run \
      /rootfs/tmp /rootfs/var /rootfs/Users /rootfs/run/rosetta /rootfs/sys/fs/cgroup \
      /rootfs/lib/modules /rootfs/root /rootfs/bin \
 && printf '127.0.0.1 localhost\n::1 localhost\n' > /rootfs/etc/hosts \
 && : > /rootfs/etc/resolv.conf
# /etc/resolv.conf is a real (empty) file on the read-only root; vinit bind-mounts
# the DHCP-populated /run/resolv.conf over it at boot.
COPY --from=docker /out/bin/ /rootfs/bin/
# vinit at its OWN path; the kernel is told init=/sbin/vinit. (Not /sbin/init —
# the apk userland owns that as a busybox symlink, which COPY won't replace.)
# The emulators sit in /usr/bin like everywhere else; the path only matters at registration
# time (the binfmt `F` flag makes the kernel hold the open file), so containers need nothing.
COPY --from=qemu   /out/ /rootfs/usr/bin/
COPY --from=vinit  /vinit /rootfs/sbin/vinit

# --- the guest image: just the assembled tree (COPY only — no RUN) ---
FROM scratch
COPY --from=assembly /rootfs/ /
