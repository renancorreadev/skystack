#!/usr/bin/env bash
# Fast path: rebuild ONLY assets/initramfs.gz (and re-extract the kernel) without
# rebuilding the multi-GB rootfs. Used while iterating on the guest init script.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ASSETS="$ROOT/assets"
ALPINE_VER="${ALPINE_VER:-3.21}"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo ">> cross-building skymount (linux/arm64)"
( cd "$ROOT/skymount" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$STAGING/skymount" . )

docker run --rm --platform linux/arm64 \
  -v "$ASSETS":/out -v "$HERE":/builder:ro -v "$STAGING":/staging:ro \
  alpine:"$ALPINE_VER" sh -c '
set -eu
apk add --no-cache linux-virt busybox-static cpio gzip python3 >/dev/null
KVER=$(ls /lib/modules | head -1)
echo ">> kernel modules: $KVER"

# Re-extract the kernel (raw arm64 Image) in case it is missing.
python3 - /boot/vmlinuz-virt /out/vmlinux <<PY
import struct, gzip, lzma, sys
raw=open(sys.argv[1],"rb").read()
if raw[4:8]==b"zimg":
    po=struct.unpack_from("<I",raw,8)[0]; ps=struct.unpack_from("<I",raw,12)[0]
    ct=raw[0x18:0x18+32].split(b"\0")[0].decode()
    img=gzip.decompress(raw[po:po+ps]) if ct=="gzip" else lzma.decompress(raw[po:po+ps])
elif raw[:2]==b"\x1f\x8b": img=gzip.decompress(raw)
else: img=raw
assert img[0x38:0x3c]==b"ARMd","no arm64 magic"
open(sys.argv[2],"wb").write(img)
print("   kernel ok")
PY

IRD=/work/ird
mkdir -p "$IRD"/bin "$IRD"/proc "$IRD"/sys "$IRD"/dev "$IRD"/sysroot "$IRD"/lib/modules
cp /bin/busybox.static "$IRD"/bin/busybox
for a in sh mount umount modprobe switch_root mkdir cat ls sleep echo uname mdev grep dd od; do ln -sf busybox "$IRD/bin/$a"; done
cp /staging/skymount "$IRD"/bin/skymount
cp -a /lib/modules/"$KVER" "$IRD"/lib/modules/
depmod -b "$IRD" "$KVER" 2>/dev/null || true
cp /builder/initramfs-init.sh "$IRD"/init
chmod +x "$IRD"/init
( cd "$IRD" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /out/initramfs.gz )
echo ">> initramfs rebuilt: $(ls -la /out/initramfs.gz | awk "{print \$5}") bytes"
'
echo "==> assets/initramfs.gz updated"
