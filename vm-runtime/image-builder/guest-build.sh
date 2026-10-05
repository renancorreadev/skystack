#!/bin/sh
# Runs INSIDE an alpine:3.21 aarch64 container. Produces, in /out:
#   vmlinux         uncompressed arm64 kernel for VZLinuxBootLoader
#   initramfs.gz    minimal initramfs: loads virtio modules, switch_root → /dev/vda
#   rootfs.ext4     ext4 disk: Alpine + Docker + containerd + skyvm-agent
#   IMAGE_INFO.txt  build metadata
#
# No privileges required: the rootfs is assembled with `apk --root` and turned
# into an ext4 image with `mke2fs -d` (populate-from-directory, no loop mount).
set -eu

ALPINE_VER="${ALPINE_VER:-3.21}"
ROOTFS_SIZE="${ROOTFS_SIZE:-3G}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ROOT=/work/rootfs
IRD=/work/initramfs
OUT=/out

echo ">> installing build tools"
apk add --no-cache e2fsprogs cpio gzip xz busybox-static python3 curl >/dev/null

K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"

echo ">> building guest rootfs at $ROOT"
mkdir -p "$ROOT"/etc/apk/keys
# The target root needs the Alpine signing keys to trust the package index.
cp /etc/apk/keys/* "$ROOT"/etc/apk/keys/ 2>/dev/null || true
apk add --root "$ROOT" --initdb --no-cache \
  --repository "$MIRROR/v$ALPINE_VER/main" \
  --repository "$MIRROR/v$ALPINE_VER/community" \
  alpine-base linux-virt openrc util-linux e2fsprogs iptables ca-certificates \
  docker docker-cli containerd runc >/dev/null

KVER="$(ls "$ROOT"/lib/modules | head -1)"
echo ">> guest kernel modules: $KVER"

echo ">> downloading k3s $K3S_VERSION (single-node Kubernetes, started only when enabled)"
K3S_URL="https://github.com/k3s-io/k3s/releases/download/$(echo "$K3S_VERSION" | sed 's/+/%2B/')/k3s-arm64"
curl -sfL "$K3S_URL" -o "$ROOT/usr/local/bin/k3s" && chmod +x "$ROOT/usr/local/bin/k3s" \
  && echo "   k3s ok ($(du -h "$ROOT/usr/local/bin/k3s" | cut -f1))" \
  || echo "   WARN: k3s download failed — Kubernetes will be unavailable"

echo ">> configuring guest"
# Passwordless root for a dev VM.
sed -i 's/^root:[^:]*:/root::/' "$ROOT"/etc/shadow

# init: openrc + a login getty on the virtio console (hvc0) and arm serial.
cat > "$ROOT"/etc/inittab <<EOF
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
hvc0::respawn:/sbin/getty -L hvc0 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

cat > "$ROOT"/etc/fstab <<EOF
/dev/vda  /  ext4  rw,relatime  0 1
EOF

echo skystack > "$ROOT"/etc/hostname

# Networking: DHCP on eth0 (Apple's NAT provides DHCP + DNS).
cat > "$ROOT"/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF

# Enable services across the right runlevels.
rl() { mkdir -p "$ROOT/etc/runlevels/$2"; ln -sf "/etc/init.d/$1" "$ROOT/etc/runlevels/$2/$1"; }
rl devfs      sysinit
rl sysfs      sysinit
rl cgroups    sysinit
rl procfs     boot
rl hostname   boot
rl networking boot
rl containerd default
rl docker     default

# skyvm-agent: vsock ⇄ docker.sock bridge, *.sky.local DNS, the localhost
# port-forward control channel, the CA-delivery channel (vsock 1026), and the
# HTTPS reverse proxy (:80/:443 → containers). Started after docker.
install -m0755 /staging/skyvm-agent "$ROOT"/usr/local/bin/skyvm-agent
cat > "$ROOT"/etc/init.d/skyvm-agent <<'EOF'
#!/sbin/openrc-run
name="skyvm-agent"
description="Bridge the Docker socket to the host over vsock"
command="/usr/local/bin/skyvm-agent"
command_args="--port 2375 --docker /var/run/docker.sock"
command_background=true
pidfile="/run/skyvm-agent.pid"
output_log="/var/log/skyvm-agent.log"
error_log="/var/log/skyvm-agent.log"
depend() { need docker; }
start_pre() {
    # The virtio-vsock transport is required for the agent to listen on vsock.
    modprobe vmw_vsock_virtio_transport 2>/dev/null || modprobe virtio_transport 2>/dev/null || true
}
EOF
chmod +x "$ROOT"/etc/init.d/skyvm-agent
rl skyvm-agent default

# skyvm-share: mount the Mac directory share over virtiofs at the host path
# (skyvm.share=<path> on the kernel cmdline), BEFORE docker so bind mounts of
# Mac paths resolve transparently — `docker run -v /Users/me/x:/y` just works.
cat > "$ROOT"/etc/init.d/skyvm-share <<'EOF'
#!/sbin/openrc-run
name="skyvm-share"
description="Mount the Mac directory share over virtiofs"
depend() {
    after localmount
    before containerd docker
}
mountpoint_arg() { sed -n 's/.*skyvm\.share=\([^ ]*\).*/\1/p' /proc/cmdline; }
start() {
    mp="$(mountpoint_arg)"
    if [ -z "$mp" ]; then einfo "skyvm-share: no share configured"; return 0; fi
    modprobe virtiofs 2>/dev/null || true
    mkdir -p "$mp"
    if mountpoint -q "$mp"; then return 0; fi
    ebegin "Mounting Mac share (virtiofs) at $mp"
    mount -t virtiofs skyshare "$mp"
    eend $?
}
stop() {
    mp="$(mountpoint_arg)"
    [ -n "$mp" ] && umount "$mp" 2>/dev/null
    return 0
}
EOF
chmod +x "$ROOT"/etc/init.d/skyvm-share
rl skyvm-share default

# skyvm-netcfg: point dockerd's host-gateway-ip at the default gateway (the Mac),
# so `--add-host host.docker.internal:host-gateway` reaches the host. Runs after
# networking and before docker.
cat > "$ROOT"/etc/init.d/skyvm-netcfg <<'EOF'
#!/sbin/openrc-run
name="skyvm-netcfg"
description="Configure host.docker.internal (host-gateway-ip)"
depend() {
    need net
    before containerd docker
}
start() {
    gw="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    [ -z "$gw" ] && { einfo "skyvm-netcfg: no default gateway yet"; return 0; }
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<JSON
{ "host-gateway-ip": "$gw" }
JSON
    einfo "host.docker.internal → $gw"
}
EOF
chmod +x "$ROOT"/etc/init.d/skyvm-netcfg
rl skyvm-netcfg default

# skyvm-route: make container IPs directly reachable from the Mac. Runs AFTER
# docker (DOCKER-USER exists). Allows eth0→container-bridge forwarding, and
# exempts container→Mac-subnet traffic from Docker's MASQUERADE so the real
# container source IP is preserved (the Mac routes 172.16/12 via the guest).
cat > "$ROOT"/etc/init.d/skyvm-route <<'EOF'
#!/sbin/openrc-run
name="skyvm-route"
description="Enable direct container-IP access from the host"
depend() {
    after docker
}
start() {
    eth_net="$(ip -o -f inet route show dev eth0 scope link 2>/dev/null | awk '{print $1; exit}')"
    # Re-ensure the rules for a window: Docker rebuilds its iptables chains
    # (flushing DOCKER-USER) during startup, so a one-shot insert can be lost.
    # The checks are idempotent, so re-applying is safe.
    (
        i=0
        while [ $i -lt 20 ]; do
            if iptables -t filter -L DOCKER-USER >/dev/null 2>&1; then
                iptables -C DOCKER-USER -i eth0 -d 172.16.0.0/12 -j ACCEPT 2>/dev/null \
                    || iptables -I DOCKER-USER -i eth0 -d 172.16.0.0/12 -j ACCEPT
            fi
            if [ -n "$eth_net" ]; then
                iptables -t nat -C POSTROUTING -s 172.16.0.0/12 -d "$eth_net" -j RETURN 2>/dev/null \
                    || iptables -t nat -I POSTROUTING -s 172.16.0.0/12 -d "$eth_net" -j RETURN
            fi
            sleep 1
            i=$((i + 1))
        done
    ) >/dev/null 2>&1 &
    einfo "direct container-IP access enabled (172.16.0.0/12 → host route)"
}
EOF
chmod +x "$ROOT"/etc/init.d/skyvm-route
rl skyvm-route default

# skyvm-k8s: single-node Kubernetes (k3s). OFF by default — only starts when the
# kernel cmdline carries skyvm.k8s=1 (set by SkyVM's --k8s, enabled via
# `skystack k8s enable`). Exports the kubeconfig (server already 127.0.0.1:6443)
# to the Mac over the virtiofs share so `kubectl` works from the host.
cat > "$ROOT"/etc/init.d/skyvm-k8s <<'EOF'
#!/sbin/openrc-run
name="skyvm-k8s"
description="Single-node Kubernetes (k3s)"
pidfile="/run/skyvm-k8s.pid"
depend() {
    need net
    after docker
}
share_path() { sed -n 's/.*skyvm\.share=\([^ ]*\).*/\1/p' /proc/cmdline; }
start() {
    if ! grep -q 'skyvm.k8s=1' /proc/cmdline; then
        einfo "skyvm-k8s: disabled (enable with 'skystack k8s enable')"
        return 0
    fi
    ebegin "Starting k3s (single-node Kubernetes)"
    /sbin/modprobe br_netfilter 2>/dev/null || true
    /sbin/modprobe overlay 2>/dev/null || true
    start-stop-daemon --start --background --make-pidfile --pidfile "$pidfile" \
        --stdout /var/log/skyvm-k8s.log --stderr /var/log/skyvm-k8s.log \
        --exec /usr/local/bin/k3s -- server \
            --disable traefik --disable-network-policy \
            --tls-san 127.0.0.1 --write-kubeconfig-mode 644
    eend $?
    # Export kubeconfig to the Mac via the share, once k3s has written it.
    share="$(share_path)"
    [ -n "$share" ] || return 0
    (
        i=0
        while [ $i -lt 90 ]; do
            if [ -f /etc/rancher/k3s/k3s.yaml ]; then
                mkdir -p "$share/.skystack"
                cp /etc/rancher/k3s/k3s.yaml "$share/.skystack/k3s.yaml" 2>/dev/null && break
            fi
            sleep 2
            i=$((i + 1))
        done
    ) >/dev/null 2>&1 &
}
stop() {
    grep -q 'skyvm.k8s=1' /proc/cmdline || return 0
    ebegin "Stopping k3s"
    start-stop-daemon --stop --pidfile "$pidfile" 2>/dev/null
    /usr/local/bin/k3s-killall.sh 2>/dev/null || true
    eend 0
}
EOF
chmod +x "$ROOT"/etc/init.d/skyvm-k8s
rl skyvm-k8s default

echo ">> extracting kernel to a raw arm64 Image (Apple's VZLinuxBootLoader needs"
echo "   an uncompressed Image; modern arm64 vmlinuz uses EFI zboot self-decompression)"
KIMG="$ROOT/boot/vmlinuz-virt"
python3 - "$KIMG" "$OUT/vmlinux" <<'PY'
import struct, gzip, lzma, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, 'rb').read()
if raw[4:8] == b'zimg':  # EFI zboot wrapper
    poff  = struct.unpack_from('<I', raw, 8)[0]
    psize = struct.unpack_from('<I', raw, 12)[0]
    ctype = raw[0x18:0x18+32].split(b'\0')[0].decode()
    payload = raw[poff:poff+psize]
    if ctype == 'gzip':
        img = gzip.decompress(payload)
    elif ctype in ('lzma', 'xz'):
        img = lzma.decompress(payload)
    else:
        sys.exit(f"unsupported zboot compression: {ctype}")
    print(f"   EFI zboot ({ctype}): {len(payload)} -> {len(img)} bytes")
elif raw[:2] == b'\x1f\x8b':  # plain gzip kernel
    img = gzip.decompress(raw); print("   gzip kernel decompressed")
else:
    img = raw; print("   kernel used as-is")
if img[0x38:0x3c] != b'ARMd':
    sys.exit("ERROR: extracted kernel lacks arm64 'ARMd' magic at 0x38")
open(dst, 'wb').write(img)
print("   raw arm64 Image OK (ARMd magic verified)")
PY
grep -E 'CONFIG_VIRTIO_BLK|CONFIG_VIRTIO_CONSOLE|CONFIG_EXT4_FS' "$ROOT"/boot/config-virt 2>/dev/null || true

echo ">> building initramfs"
mkdir -p "$IRD"/bin "$IRD"/proc "$IRD"/sys "$IRD"/dev "$IRD"/sysroot "$IRD"/lib/modules
cp /bin/busybox.static "$IRD"/bin/busybox
for a in sh mount umount modprobe switch_root mkdir cat ls sleep echo uname mdev grep dd od; do
  ln -sf busybox "$IRD/bin/$a"
done
cp /staging/skymount "$IRD"/bin/skymount
cp -a "$ROOT"/lib/modules/"$KVER" "$IRD"/lib/modules/
depmod -b "$IRD" "$KVER" 2>/dev/null || true
cp /builder/initramfs-init.sh "$IRD"/init
chmod +x "$IRD"/init
( cd "$IRD" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT/initramfs.gz" )

echo ">> building ext4 rootfs image ($ROOTFS_SIZE)"
truncate -s "$ROOTFS_SIZE" "$OUT/rootfs.ext4"
# Disable metadata_csum so the initramfs can mount root without the crc32c
# crypto module (which the kernel cannot auto-load in our minimal initramfs).
mke2fs -q -F -t ext4 -b 4096 -O ^metadata_csum -d "$ROOT" "$OUT/rootfs.ext4"

cat > "$OUT/IMAGE_INFO.txt" <<EOF
distro:  Alpine $ALPINE_VER (aarch64)
kernel:  $KVER
docker:  $(cat "$ROOT"/lib/apk/db/installed 2>/dev/null | awk '/^P:docker-engine$/{f=1} f&&/^V:/{print $0; exit}' | sed 's/V://')
agent:   /usr/local/bin/skyvm-agent (docker vsock 2375, netinfo 1024, CA 1026; DNS :53; proxy :80/:443)
EOF

echo ">> done; artifacts:"
ls -la "$OUT"
