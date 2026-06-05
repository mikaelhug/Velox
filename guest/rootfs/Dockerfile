# Velox guest root filesystem — a minimal, demand-paged appliance.
# NO LinuxKit, NO docker:*-dind, NO per-container rootfs duplication. The guest is:
#   - the static Rust /sbin/init (vinit): PID1 + supervisor + vsock agent
#   - Docker's official STATIC server binaries (dockerd/containerd/runc/…)
#   - a tiny musl userland (iptables-nft, e2fsprogs, ca-certificates) — the only
#     tools dockerd shells out to (firewall rules + one-time data-disk mkfs)
# Scripts/make-guest.sh exports this and runs mkfs.erofs over it → root.img.
#
# (Eliminating the musl /lib entirely would require building a static nft/iptables
#  + mke2fs from source — a follow-up polish; everything else is already static.)

ARG RUST_BUILD_IMAGE=rust:1-alpine
ARG ALPINE_IMAGE=alpine:3.23
ARG DOCKER_VERSION=29.5.3

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
RUN wget -qO docker.tgz "https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz" \
 && tar xf docker.tgz \
 && mkdir -p /out/bin \
 && cp docker/dockerd docker/containerd docker/containerd-shim-runc-v2 docker/runc \
       docker/docker-proxy docker/docker-init /out/bin/

# --- assemble a minimal musl root with only the tools dockerd needs ---
# IMPORTANT: do ALL `RUN` steps first, then the binary COPYs last. (A RUN placed
# right after `COPY … /rootfs/sbin/init` gets exec'd AS that binary by this
# buildkit/containerd-store setup — so no RUN may follow the vinit copy.)
FROM ${ALPINE_IMAGE} AS assembly
# apk resolves the (few) musl libs these pull in. iptables = iptables-nft → nf_tables;
# nftables provides the `nft` binary dockerd 29 uses by default for its firewall.
RUN apk add --no-cache --initdb --root /rootfs \
      --repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
      iptables ip6tables nftables e2fsprogs ca-certificates \
 && rm -rf /rootfs/etc/apk /rootfs/lib/apk /rootfs/var/cache /rootfs/etc/network \
           /rootfs/etc/init.d /rootfs/etc/conf.d /rootfs/sbin/openrc* /rootfs/usr/share/man \
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
