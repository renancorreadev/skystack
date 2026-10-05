#!/usr/bin/env bash
# Packages an already-built guest image (./assets) into a distributable bundle
# in ./dist — a .tar.gz plus a .sha256 sidecar. This step needs NO Docker (the
# assets already exist); run `make build-image` first to produce them.
#
# The resulting bundle installs on any Mac with no toolchain via:
#   skystack vm install-image <bundle.tar.gz>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ASSETS="$ROOT/assets"
DIST="$ROOT/dist"
ARCH="${ARCH:-arm64}"

for f in vmlinux initramfs.gz rootfs.ext4; do
  if [ ! -f "$ASSETS/$f" ]; then
    echo "error: $ASSETS/$f not found — run 'make build-image' first" >&2
    exit 1
  fi
done

mkdir -p "$DIST"
BUNDLE="$DIST/skyvm-image-$ARCH.tar.gz"

echo "==> packaging guest image → $BUNDLE"
members="vmlinux initramfs.gz rootfs.ext4"
[ -f "$ASSETS/IMAGE_INFO.txt" ] && members="$members IMAGE_INFO.txt"
# shellcheck disable=SC2086
tar -C "$ASSETS" -czf "$BUNDLE" $members

shasum -a 256 "$BUNDLE" | awk '{print $1}' > "$BUNDLE.sha256"

echo "    size:   $(du -h "$BUNDLE" | cut -f1)"
echo "    sha256: $(cat "$BUNDLE.sha256")"
echo
echo "==> distribute these two files (host them anywhere). Install on any Mac, no Docker:"
echo "    skystack vm install-image $BUNDLE"
echo "    # or from a URL:  skystack vm install-image https://host/skyvm-image-$ARCH.tar.gz"
