#!/bin/busybox sh
# SkyStack guest initramfs init: load virtio drivers, mount the ext4 root from
# /dev/vda, and switch_root into the real system. Verbose on purpose — this is
# the trickiest part of bring-up.
BB=/bin/busybox
$BB mount -t proc none /proc
$BB mount -t sysfs none /sys
$BB mount -t devtmpfs none /dev 2>/dev/null && echo "[skyinit] devtmpfs mounted" || echo "[skyinit] devtmpfs FAILED"

echo "[skyinit] kernel: $($BB uname -r)"
echo "[skyinit] loading virtio drivers"
for m in virtio virtio_ring virtio_pci virtio_mmio virtio_blk virtio_console virtio_net crc32c_generic crc32c crc16 ext4 overlay; do
  out=$($BB modprobe "$m" 2>&1)
  if [ -z "$out" ]; then echo "  + $m"; else echo "  ! $m: $out"; fi
done

# Wait for the root block device to enumerate (devtmpfs creates the node).
n=0
while [ ! -b /dev/vda ] && [ $n -lt 30 ]; do
  $BB sleep 1
  n=$((n + 1))
done

echo "[skyinit] /sys/block: $($BB ls /sys/block 2>/dev/null)"
echo "[skyinit] /dev block nodes: $($BB ls -d /dev/vd* 2>/dev/null) (waited ${n}s)"
echo "[skyinit] ext4 in /proc/filesystems: $($BB grep -c ext4 /proc/filesystems)"

if [ ! -b /dev/vda ]; then
  echo "[skyinit] FATAL: /dev/vda never appeared. /dev contents:"
  $BB ls /dev
  echo "[skyinit] dropping to a debug shell"
  exec $BB sh
fi

echo "[skyinit] vda size(sectors)=$($BB cat /sys/block/vda/size 2>/dev/null) ro=$($BB cat /sys/block/vda/ro 2>/dev/null)"
echo "[skyinit] ext4 magic@1080 (want 53 ef): $($BB dd if=/dev/vda bs=1024 skip=1 count=1 2>/dev/null | $BB od -An -tx1 -j56 -N2)"

$BB mkdir -p /sysroot
# Use our own mount(2) wrapper — busybox mount returns a misleading ENOENT for
# block filesystems in this minimal initramfs.
if /bin/skymount /dev/vda /sysroot ext4; then
  echo "[skyinit] root mounted (skymount)"
elif $BB mount -i -t ext4 /dev/vda /sysroot; then
  echo "[skyinit] root mounted (busybox fallback)"
else
  echo "[skyinit] FATAL: could not mount root; debug shell"
  exec $BB sh
fi

echo "[skyinit] switch_root → /sbin/init"
exec $BB switch_root /sysroot /sbin/init
