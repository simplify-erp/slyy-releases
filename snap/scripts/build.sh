#!/bin/sh
# Build "Slyy Snap.app" (universal arm64 + x86_64) and the release assets:
#   snap/dist/SlyySnap-<version>.zip  and  snap/dist/SHA256SUMS
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
(cd dist && ditto -c -k --keepParent "Slyy Snap.app" "$zip" && shasum -a 256 "$zip" >SHA256SUMS)
cat dist/SHA256SUMS
