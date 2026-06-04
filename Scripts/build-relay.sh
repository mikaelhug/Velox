#!/usr/bin/env bash
# Build the guest vsock-relay image (arm64) into the local Docker daemon so
# `linuxkit build --docker` can pick it up.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; . ./versions.env; set +a

TAG="${1:-velox/vsock-relay:latest}"
echo "==> docker build $TAG (linux/arm64, go=${GO_BUILD_IMAGE})"
docker build --platform=linux/arm64 \
    --build-arg "GO_BUILD_IMAGE=${GO_BUILD_IMAGE}" \
    -t "$TAG" guest/pkg/vsock-relay
echo "==> built $TAG"
