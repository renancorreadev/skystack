#!/usr/bin/env bash
# Builds SkyStack-Installer.pkg — a native macOS installer that sets SkyStack up
# to run PERSISTENTLY on this Mac: the app in /Applications, the `skystack` CLI on
# PATH, the SkyVM engine + guest image installed, and LaunchAgents that start the
# VM and the multi-host daemon at login (surviving reboots). The privileged setup
# (*.sky.local DNS, container routing, CA trust) runs in the installer's own admin
# authorization — no second password prompt.
#
# Payload (root-owned, system locations):
#   /Applications/SkyStack.app
#   /usr/local/bin/skystack                         (the CLI)
#   /usr/local/libexec/skystack/SkyVM(+.entitlements)   (engine, copied per-user)
#   /usr/local/share/skystack/skyvm-image-<arch>.tar.gz (guest image, ~340 MB)
#
# postinstall (root) → per-user part as the console user (launchctl asuser) +
# privileged part as root. See the heredoc below.
#
# Usage:  bash packaging/build-pkg.sh [--no-image]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
VMRT="$ROOT/vm-runtime"
DIST="$APP_DIR/dist"
APP="$DIST/SkyStack.app"
ARCH="$(uname -m)"
VERSION="$(date +%Y.%m.%d)"
PKG="$DIST/SkyStack-Installer.pkg"
INCLUDE_IMAGE=1
[ "${1:-}" = "--no-image" ] && INCLUDE_IMAGE=0

echo "==> SkyStack installer  (arch=$ARCH, version=$VERSION)"

# 1) the app bundle (with the embedded CLI)
if [ ! -d "$APP" ]; then
  echo "==> SkyStack.app not found — building it (make app)"
  make -C "$APP_DIR" app
fi
CLI="$APP/Contents/Resources/skystack"
[ -x "$CLI" ] || { echo "error: embedded CLI missing at $CLI" >&2; exit 1; }

# 2) the SkyVM engine + entitlements
SKYVM="$VMRT/.build/release/SkyVM"
SKYVM_ENT="$VMRT/SkyVM.entitlements"
[ -x "$SKYVM" ] || { echo "error: SkyVM binary missing at $SKYVM (build vm-runtime first)" >&2; exit 1; }
[ -f "$SKYVM_ENT" ] || { echo "error: SkyVM.entitlements missing at $SKYVM_ENT" >&2; exit 1; }

# 3) the guest image bundle
IMG_BUNDLE="$VMRT/dist/skyvm-image-$ARCH.tar.gz"
if [ "$INCLUDE_IMAGE" = 1 ] && [ ! -f "$IMG_BUNDLE" ]; then
  echo "==> guest image bundle not found — packaging it (no Docker needed)"
  ( cd "$VMRT/image-builder" && bash package.sh )
fi

# 4) assemble the payload
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
PAYLOAD="$STAGING/payload"
SCRIPTS="$STAGING/scripts"
mkdir -p "$PAYLOAD/Applications" \
         "$PAYLOAD/usr/local/bin" \
         "$PAYLOAD/usr/local/libexec/skystack" \
         "$PAYLOAD/usr/local/share/skystack" \
         "$SCRIPTS"

echo "==> staging payload"
cp -R "$APP" "$PAYLOAD/Applications/SkyStack.app"
cp "$CLI" "$PAYLOAD/usr/local/bin/skystack"
chmod 755 "$PAYLOAD/usr/local/bin/skystack"
cp "$SKYVM" "$PAYLOAD/usr/local/libexec/skystack/SkyVM"
cp "$SKYVM_ENT" "$PAYLOAD/usr/local/libexec/skystack/SkyVM.entitlements"
chmod 755 "$PAYLOAD/usr/local/libexec/skystack/SkyVM"
IMG_ARG=""
if [ "$INCLUDE_IMAGE" = 1 ]; then
  cp "$IMG_BUNDLE" "$PAYLOAD/usr/local/share/skystack/skyvm-image-$ARCH.tar.gz"
  IMG_ARG="--image /usr/local/share/skystack/skyvm-image-$ARCH.tar.gz"
fi

# 5) postinstall: per-user part as the console user, privileged part as root
cat > "$SCRIPTS/postinstall" <<POSTINSTALL
#!/bin/bash
# Runs as root after the payload is laid down.
set -u
CLI=/usr/local/bin/skystack
SKYVM=/usr/local/libexec/skystack/SkyVM
IMG_ARG="$IMG_ARG"

user="\$(stat -f %Su /dev/console)"
[ -z "\$user" ] || [ "\$user" = "root" ] && user="\$(ls -l /dev/console | awk '{print \$3}')"
uid="\$(id -u "\$user")"
home="\$(dscl . -read /Users/"\$user" NFSHomeDirectory 2>/dev/null | awk '{print \$2}')"
[ -z "\$home" ] && home="/Users/\$user"

echo "SkyStack: per-user setup for \$user (uid \$uid)"
# Per-user part (binary copy/sign, runtime.json, LaunchAgents) in the user's GUI
# session. --user-only skips the privileged steps (done as root below).
launchctl asuser "\$uid" sudo -u "\$user" "\$CLI" install --user-only \
    --skyvm-binary "\$SKYVM" \$IMG_ARG || echo "SkyStack: per-user step reported a problem (continuing)"

echo "SkyStack: privileged setup (DNS + routing + CA trust)"
# Privileged part directly as root (we already are) — no extra password prompt.
"\$CLI" install --system-only --user "\$user" --home "\$home" || echo "SkyStack: privileged step reported a problem (continuing)"

echo "SkyStack: install complete"
exit 0
POSTINSTALL
chmod 755 "$SCRIPTS/postinstall"

# Remove any literal AppleDouble sidecar FILES (iCloud cruft). We intentionally do
# NOT `xattr -rc` the payload — pkgbuild encodes real xattrs (incl. the .app's
# code signature) as AppleDouble streams in the cpio, and the installer merges
# them back into each file's xattrs on extraction (they are not written as ._
# files on disk). Stripping them would break the embedded app's signature.
find "$PAYLOAD" -name '._*' -type f -delete 2>/dev/null || true

# 6) build the component pkg (double-clickable, installs to /)
echo "==> pkgbuild"
mkdir -p "$DIST"
pkgbuild \
  --root "$PAYLOAD" \
  --scripts "$SCRIPTS" \
  --identifier dev.skystack.installer \
  --version "$VERSION" \
  --install-location / \
  "$PKG"

echo
echo "==> built $PKG"
echo "    size: $(du -h "$PKG" | cut -f1)"
echo "    install:  open \"$PKG\"   (it's unsigned — right-click → Open if Gatekeeper blocks it,"
echo "              or: sudo installer -pkg \"$PKG\" -target /)"
echo
echo "For distribution, sign + notarize:"
echo "    productsign --sign \"Developer ID Installer: <you>\" \"$PKG\" \"\${PKG%.pkg}-signed.pkg\""
echo "    xcrun notarytool submit ... && xcrun stapler staple ..."
