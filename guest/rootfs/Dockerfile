# Velox guest root filesystem — a minimal, demand-paged appliance.
# NO LinuxKit, NO docker:*-dind, NO per-container rootfs duplication. The guest is:
#   - the static Rust /sbin/init (vinit): PID1 + supervisor + vsock agent
#   - Docker's official STATIC server binaries (dockerd/containerd/runc/…)
#   - a tiny musl userland (nftables, e2fsprogs, ca-certificates) — the only tools
#     dockerd shells out to (native nftables firewall via `nft` + one-time data-disk mkfs)
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
COPY vinit/Cargo.toml ./
COPY vinit/src ./src
# rust:alpine already targets *-musl, so a normal release build is fully static.
RUN cargo build --release && strip target/release/vinit && cp target/release/vinit /vinit

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
COPY --from=vinit  /vinit /rootfs/sbin/vinit

# --- the guest image: just the assembled tree (COPY only — no RUN) ---
FROM scratch
COPY --from=assembly /rootfs/ /
