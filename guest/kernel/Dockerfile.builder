# Minimal arm64 Linux-to-Linux kernel build environment for Velox.
# Built and run by Scripts/build-kernel.sh as --platform linux/arm64 so the
# compile is NATIVE (no cross-arch). The kernel source tree never touches the
# host APFS: extraction + build happen on a Docker named volume mounted here.
FROM debian:bookworm-slim

# Exactly the toolchain a modern arm64 kernel needs to build `Image`, plus
# curl/xz/gpg for fetching+verifying the kernel.org tarball inside the volume.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        bc \
        bison \
        flex \
        libelf-dev \
        libssl-dev \
        cpio \
        kmod \
        xz-utils \
        gzip \
        zstd \
        ca-certificates \
        curl \
        gnupg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
