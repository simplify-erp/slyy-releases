#!/bin/sh
# Build "Slyy Snap.app" (universal arm64 + x86_64) and the release assets:
#   snap/dist/SlyySnap-<version>.dmg  (double-click install: drag to Applications)
#   snap/dist/SlyySnap-<version>.zip  (used by the self-updater and snap-install.sh)
#   snap/dist/SHA256SUMS
# Usage: snap/scripts/build.sh 1.0.0      (macOS + Xcode command line tools)
# Signing: $SIGN_IDENTITY (a codesigning identity in the keychain) or ad-hoc ("-").
set -eu
ver="${1:?usage: build.sh <version>}"
case "$ver" in
*[!0-9.]* | "" | .* | *. | *..*) echo "invalid version '$ver'" >&2; exit 1 ;;
esac
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SlyySnap"

rm -rf dist
app="dist/Slyy Snap.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/SlyySnap"
sed "s/__VERSION__/$ver/g" Resources/Info.plist >"$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"

zip="SlyySnap-$ver.zip"
dmg="SlyySnap-$ver.dmg"
(cd dist && ditto -c -k --keepParent "Slyy Snap.app" "$zip")

# DMG: the app, an Applications shortcut and a short read-me.
stage=dist/dmg
mkdir -p "$stage"
ditto "$app" "$stage/Slyy Snap.app"
ln -s /Applications "$stage/Applications"
cat >"$stage/Read Me.txt" <<TXT
Slyy Snap $ver

1. Drag "Slyy Snap" onto "Applications".
2. Open it from Applications. The first time, macOS says the developer
   cannot be verified: open System Settings > Privacy & Security, click
   "Open Anyway", then open Slyy Snap again.
3. A camera icon appears in the menu bar:
   Ctrl+Shift+1 area, Ctrl+Shift+2 window, Ctrl+Shift+3 screen.
4. First capture: allow Slyy Snap under Privacy & Security > Screen
   Recording, then quit and reopen it.

Updates: menu > Check for Updates... (also automatic).
TXT
hdiutil create -volname "Slyy Snap $ver" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "dist/$dmg"
codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "dist/$dmg"
rm -rf "$stage"

(cd dist && shasum -a 256 "$zip" "$dmg" >SHA256SUMS)
cat dist/SHA256SUMS
