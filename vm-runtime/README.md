# SkyVM — SkyStack local runtime (Stage 2 ✅ boots & runs Docker)

A native Swift wrapper over Apple's **Virtualization.framework** that boots a
minimal Linux VM hosting the container engine — SkyStack's answer to OrbStack's
"one lightweight VM, many environments" model.

**Status: working.** SkyVM boots a minimal Alpine arm64 guest (kernel 6.12),
starts **Docker + containerd**, and exposes the engine on the Mac over vsock as
`~/.skystack/skyvm-docker.sock`. Verified end-to-end:

```console
$ DOCKER_HOST=unix://$HOME/.skystack/skyvm-docker.sock docker version
Client v29.4.0  →  Server v27.3.1 (linux/arm64, kernel 6.12.94-0-virt)
$ DOCKER_HOST=unix://$HOME/.skystack/skyvm-docker.sock docker run --rm hello-world
Hello from Docker!     # pulled over the guest's NAT network, ran in our VM
```

So the Go core (`../skystack`) can point `DOCKER_HOST` at SkyVM and use our own
engine instead of Docker Desktop.

## Quick start

```bash
make build-image          # build kernel + initramfs + rootfs into ./assets (needs Docker + Go)
make run-vm               # sign + boot; exposes ~/.skystack/skyvm-docker.sock
# in another shell:
export DOCKER_HOST=unix://$HOME/.skystack/skyvm-docker.sock
docker ps                 # or: skystack ps
```

## What's here

A real, compiling executable that builds and validates a full Linux VM
configuration with the pieces the architecture brief calls out:

- **Direct Linux kernel boot** (`VZLinuxBootLoader`) — no firmware overhead.
- **virtio block** root disk, **virtio-net NAT** networking, **entropy**,
  **memory balloon**, and a **vsock** control channel.
- **virtiofs** directory share (`tag: skyshare`) for fast Mac⇄Linux bind mounts.
- **Rosetta** directory share so `linux/amd64` images run on Apple Silicon
  without QEMU — gated on `VZLinuxRosettaDirectoryShare.availability`.
- Serial console bridged to host stdin/stdout; graceful `Ctrl-C` → guest stop.

```
Sources/SkyVM/
  main.swift              CLI arg parsing + run loop + signal handling
  VMConfiguration.swift   VMSpec → validated VZVirtualMachineConfiguration
  VMRunner.swift          VZVirtualMachine lifecycle + vsock connect
  VsockForwarder.swift    guest vsock port → Mac unix socket (the docker socket)
SkyVM.entitlements        com.apple.security.virtualization (+ .rosetta)
agent/                    skyvm-agent: in-guest vsock ⇄ /var/run/docker.sock bridge
skymount/                 tiny syscall.Mount helper for the initramfs
image-builder/            builds the bootable guest image (kernel/initramfs/rootfs)
```

## How the image is built (no privileges required)

`image-builder/build.sh` does everything inside an arm64 alpine container:

1. `apk --root` assembles an Alpine rootfs with **docker + containerd + runc**,
   OpenRC services, networking (DHCP), and the cross-built `skyvm-agent`.
2. The arm64 `vmlinuz` is **EFI-zboot**, which Apple's bootloader can't run, so
   the gzip payload is extracted to a raw `Image` (`ARMd` magic verified).
3. A minimal **initramfs** is assembled (busybox + virtio/crypto modules +
   `skymount`); its `/init` loads virtio, mounts `/dev/vda`, and `switch_root`s.
4. The rootfs becomes an **ext4** image via `mke2fs -d` (built *without*
   `metadata_csum` so the initramfs can mount it without the crc32c module).

`image-builder/rebuild-initramfs.sh` rebuilds just the initramfs/kernel in
seconds (no multi-GB rootfs rebuild) for fast iteration on the init script.

## Build & run

```bash
make build-image     # → assets/{vmlinux, initramfs.gz, rootfs.ext4}
make run-vm          # release build + ad-hoc sign + boot, exposes the docker socket
make validate        # build the VM config against the image without booting
make agent-test      # unit-test the agent proxy logic on the host
```

`run-vm` ad-hoc signs the binary with the `com.apple.security.virtualization`
entitlement (required — `Virtualization.framework` refuses to create a VM
otherwise; even building the config needs it). For distribution, sign with a
Developer ID and request the entitlement from Apple.

Two `Sendable` warnings remain in `VMRunner.swift` (Virtualization's ObjC types
crossing the VM dispatch queue) — present in Apple's own samples, benign.

## Status

- [x] Builds a bootable arm64 guest image with no privileges
- [x] Boots Alpine 6.12 guest → OpenRC → Docker + containerd
- [x] vsock agent + host forwarder → Docker socket on the Mac
- [x] `docker` / `skystack` on the Mac drive the in-VM engine
- [x] Container pull/run over guest NAT networking
- [x] First-class `skystack` integration (`skyvm` host) + background daemon
- [x] Hijacked-stream bridge (run/attach/exec/logs -f) via per-direction half-close
- [x] VirtioFS: Mac home mirrored into the guest at the same path (bind mounts work)
- [x] Automatic port-forward of published ports to localhost (vsock netinfo + PortForwarder)
- [x] host.docker.internal → the Mac (dockerd host-gateway-ip)
- [x] Direct container-IP routing from the Mac (guest iptables + scoped sudoers helper)
- [ ] Separate data disk; dynamic memory + pause-when-idle
