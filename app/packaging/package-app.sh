#!/usr/bin/env bash
# Builds SkyStack.app — a self-contained macOS bundle with the SwiftUI front-end
# AND the `skystack` CLI embedded, so it runs with no separate toolchain.
#
# Ad-hoc signed with the hardened runtime and the App Sandbox OFF (the embedded
# terminal needs a real PTY + child process). For distribution, re-sign with a
# Developer ID and notarize (see the end of this script).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
SKYSTACK_SRC="$ROOT/skystack"
DIST="$APP_DIR/dist"
APP="$DIST/SkyStack.app"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
# Build/sign in a local temp dir: ~/Desktop is iCloud-managed and its file
# provider keeps re-stamping com.apple.FinderInfo, which codesign --strict
# rejects. We do all the work outside iCloud, then copy the finished bundle in.
APP_BUILD="$STAGING/SkyStack.app"

echo "==> building skystack CLI (arm64)"
( cd "$SKYSTACK_SRC" && go build -trimpath -o "$STAGING/skystack" ./cmd/skystack )

echo "==> building SkyStackApp (release)"
( cd "$APP_DIR" && swift build -c release >/dev/null )
APP_BIN="$APP_DIR/.build/release/SkyStackApp"
[ -x "$APP_BIN" ] || { echo "error: $APP_BIN missing" >&2; exit 1; }

echo "==> assembling bundle"
mkdir -p "$APP_BUILD/Contents/MacOS" "$APP_BUILD/Contents/Resources"
cp "$APP_BIN" "$APP_BUILD/Contents/MacOS/SkyStack"
cp "$STAGING/skystack" "$APP_BUILD/Contents/Resources/skystack"

# Copy our SwiftPM resource bundle (brand icons) into Resources so the app finds
# them via Bundle.main.resourceURL/SkyStackApp_SkyStackApp.bundle. (SwiftTerm's
# bundle isn't needed at runtime and its read-only Shaders.metal breaks xattr.)
RES_BUNDLE="$APP_DIR/.build/release/SkyStackApp_SkyStackApp.bundle"
if [ -e "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP_BUILD/Contents/Resources/"
  chmod -R u+w "$APP_BUILD/Contents/Resources/SkyStackApp_SkyStackApp.bundle"
fi
cp "$HERE/Info.plist" "$APP_BUILD/Contents/Info.plist"
printf 'APPL????' > "$APP_BUILD/Contents/PkgInfo"

echo "==> generating icon (best-effort)"
if swift "$HERE/make-icon.swift" "$STAGING/icon_1024.png" 2>/dev/null; then
  ICONSET="$STAGING/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"       "$STAGING/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png"     >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$STAGING/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  if iconutil -c icns "$ICONSET" -o "$APP_BUILD/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    icon embedded"
  fi
else
  echo "    (icon generation skipped — app still works)"
fi

echo "==> code signing (ad-hoc, hardened runtime, sandbox off)"
xattr -cr "$APP_BUILD"
codesign --force --options runtime --timestamp=none \
  --sign - "$APP_BUILD/Contents/Resources/skystack"
codesign --force --options runtime --timestamp=none \
  --entitlements "$HERE/SkyStack.entitlements" \
  --sign - "$APP_BUILD"

echo "==> verifying"
plutil -lint "$APP_BUILD/Contents/Info.plist" >/dev/null && echo "    Info.plist OK"
codesign --verify --strict --verbose=2 "$APP_BUILD" 2>&1 | sed 's/^/    /'

echo "==> installing to $APP"
rm -rf "$APP"
mkdir -p "$DIST"
cp -R "$APP_BUILD" "$APP"
xattr -cr "$APP" 2>/dev/null || true # best-effort; iCloud may re-stamp later

echo
echo "==> built $APP"
echo "    open it:  open \"$APP\""
echo "    (first launch from Finder: right-click → Open, since it's ad-hoc signed)"
echo
echo "For distribution, re-sign + notarize with your Apple Developer ID:"
echo "    codesign --force --deep --options runtime --entitlements \"$HERE/SkyStack.entitlements\" \\"
echo "      --sign \"Developer ID Application: <you>\" \"$APP\""
echo "    ditto -c -k --keepParent \"$APP\" SkyStack.zip"
echo "    xcrun notarytool submit SkyStack.zip --apple-id <id> --team-id <team> --password <app-pw> --wait"
echo "    xcrun stapler staple \"$APP\""
