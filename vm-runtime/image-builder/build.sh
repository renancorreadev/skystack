#!/usr/bin/env bash
# Builds the SkyStack guest VM image (kernel + initramfs + ext4 rootfs) into
# ../assets. Runs the heavy lifting inside an arm64 alpine container, so the only
# host requirements are Docker and a Go toolchain (for the guest agent).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ASSETS="$ROOT/assets"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ALPINE_VER="${ALPINE_VER:-3.21}"
ROOTFS_SIZE="${ROOTFS_SIZE:-3G}"

echo "==> cross-building skyvm-agent + skymount (linux/arm64)"
( cd "$ROOT/agent" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$STAGING/skyvm-agent" . )
( cd "$ROOT/skymount" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$STAGING/skymount" . )

mkdir -p "$ASSETS"
echo "==> building guest image (Alpine $ALPINE_VER, rootfs $ROOTFS_SIZE)"
docker run --rm \
  -e ALPINE_VER="$ALPINE_VER" \
  -e ROOTFS_SIZE="$ROOTFS_SIZE" \
  -v "$ASSETS":/out \
  -v "$STAGING":/staging:ro \
  -v "$HERE":/builder:ro \
  --platform linux/arm64 \
  alpine:"$ALPINE_VER" sh /builder/guest-build.sh

echo
echo "==> image ready in $ASSETS"
echo "    boot it with:  (cd $ROOT && make run-vm)"
