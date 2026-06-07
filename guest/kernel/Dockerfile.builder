# Minimal arm64 Linux-to-Linux kernel build environment for Velox.
# Built and run by Scripts/build-kernel.sh as --platform linux/arm64 so the
# compile is NATIVE (no cross-arch). The kernel source tree never touches the
# host APFS: extraction + build happen on a Docker named volume mounted here.
# Base image is pinned in versions.env (KERNEL_BUILDER_IMAGE) and passed by
# Scripts/build-kernel.sh; the default keeps a bare `docker build` working.
ARG KERNEL_BUILDER_IMAGE=debian:trixie-slim
FROM ${KERNEL_BUILDER_IMAGE}

# Exactly the toolchain a modern arm64 kernel needs to build `Image`, plus
# curl/xz/gpg for fetching+verifying the kernel.org tarball inside the volume.
# (No cpio/kmod/gzip: the guest has no initramfs, the kernel is monolithic — no
# modules — and the tarball is .tar.xz with an uncompressed arm64 `Image`.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        bc \
        bison \
        flex \
        libelf-dev \
        libssl-dev \
        xz-utils \
        zstd \
        ca-certificates \
        curl \
        gnupg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
