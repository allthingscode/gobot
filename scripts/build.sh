#!/usr/bin/env bash
# scripts/build.sh — Build gobot with version injection
set -euo pipefail

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "v0.1.0-dev")
COMMIT=$(git rev-parse --short HEAD)
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LDFLAGS="-X main.version=${VERSION} -X main.commitHash=${COMMIT} -X main.buildTime=${BUILD_TIME}"

echo "Building gobot ${VERSION} (${COMMIT})..."
go build -mod=vendor -ldflags "${LDFLAGS}" -o gobot ./cmd/gobot
echo "Build successful: gobot"
