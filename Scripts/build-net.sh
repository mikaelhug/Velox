#!/usr/bin/env bash
# Build the velox-net host staticlib (libveloxnet.a) that the Swift host links
# in-process. This is the host-side Rust netstack (smoltcp) that replaces VZNAT.
# Must run BEFORE `swift build`, since VeloxCore links the archive.
#
# The host is Apple Silicon (aarch64-apple-darwin), so a plain `cargo build` is a
# native build — no cross-target needed. Requires the Rust toolchain (rustup).
set -euo pipefail
cd "$(dirname "$0")/.."

# Pick up a rustup install that isn't on PATH yet (fresh shells).
if ! command -v cargo >/dev/null 2>&1 && [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found — install Rust: https://rustup.rs" >&2
    exit 1
fi

# Always release: Package.swift links host/velox-net/target/release, and the
# netstack is the throughput-critical path — we want it optimized even when the
# Swift side is a debug build.
echo "==> build velox-net staticlib (release, host $(rustc -vV | awk '/^host/{print $2}'))"
( cd host/velox-net && cargo build --release )

LIB="host/velox-net/target/release/libveloxnet.a"
[ -f "$LIB" ] || { echo "error: $LIB not produced" >&2; exit 1; }
echo "==> $LIB ($(du -h "$LIB" | cut -f1))"
