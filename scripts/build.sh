#!/usr/bin/env bash
# scripts/build.sh — Build gobot with version injection
set -euo pipefail

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "v0.1.0-dev")
COMMIT=$(git rev-parse --short HEAD)
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LDFLAGS="-X main.version=${VERSION} -X main.commitHash=${COMMIT} -X main.buildTime=${BUILD_TIME}"

MOD_FLAG=""
if [ -d "vendor" ]; then
    echo "Using vendor directory..."
    MOD_FLAG="-mod=vendor"
else
    echo "Vendor directory missing. Downloading modules..."
    go mod download
fi

echo "Building gobot ${VERSION} (${COMMIT})..."
mkdir -p bin
go build ${MOD_FLAG} -ldflags "${LDFLAGS}" -o bin/gobot ./cmd/gobot
echo "Build successful: bin/gobot"
