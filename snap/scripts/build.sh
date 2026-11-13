#!/bin/sh
# Build "Slyy Shot.app" (universal arm64 + x86_64) and the release assets:
#   snap/dist/SlyyShot-<version>.dmg  (double-click install: drag to Applications)
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
app="dist/Slyy Shot.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/SlyySnap"
sed "s/__VERSION__/$ver/g" Resources/Info.plist >"$app/Contents/Info.plist"

# App icon (Slyy logo, 1024 px PNG) -> AppIcon.icns
iconset=dist/AppIcon.iconset
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
	sips -z "$s" "$s" Resources/AppIcon.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
	d=$((s * 2))
	sips -z "$d" "$d" Resources/AppIcon.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"
plutil -lint "$app/Contents/Info.plist"


identity="${SIGN_IDENTITY:--}"
# SIGN_IDENTITY may be a SHA-1 fingerprint; SIGN_NAME then carries the name.
case "${SIGN_NAME:-$identity}" in
"Developer ID"*) ts=--timestamp ;; # secure timestamp (required for notarization)
*) ts=--timestamp=none ;;          # ad-hoc or self-signed
esac
codesign --force --options runtime "$ts" --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# Notarization (needs a Developer ID signature and an App Store Connect API
# key: NOTARY_KEY = path to the .p8, NOTARY_KEY_ID, NOTARY_ISSUER).
notarize=no
if [ "$ts" = --timestamp ] && [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
	notarize=yes
fi
submit() {
	xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
		--wait --timeout 30m --output-format json >dist/notary.json || true
	cat dist/notary.json
	id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' dist/notary.json 2>/dev/null || true)
	status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' dist/notary.json 2>/dev/null || true)
	if [ "$status" != Accepted ]; then
		[ -z "$id" ] || xcrun notarytool log "$id" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" || true
		echo "notarization of $1 failed: ${status:-no status}" >&2
		exit 1
	fi
	rm -f dist/notary.json
}
if [ "$notarize" = yes ]; then
	ditto -c -k --keepParent "$app" dist/notarize.zip
	submit dist/notarize.zip
	rm -f dist/notarize.zip
	xcrun stapler staple "$app"
	xcrun stapler validate "$app"
fi

zip="SlyySnap-$ver.zip"
dmg="SlyyShot-$ver.dmg"
# The zip keeps the pre-1.3 bundle name "Slyy Snap.app" (1.2.x updaters look for it); the app renames itself.
(cd dist && ditto "Slyy Shot.app" "z/Slyy Snap.app" && ditto -c -k --keepParent "z/Slyy Snap.app" "$zip" && rm -rf z)

if [ "$notarize" = yes ]; then
	open_step="2. Open it from Applications."
else
	open_step="2. Open it from Applications. The first time, macOS says the developer
   cannot be verified: open System Settings > Privacy & Security, click
   \"Open Anyway\", then open Slyy Shot again."
fi

# DMG: the app, an Applications shortcut and a short read-me.
stage=dist/dmg
mkdir -p "$stage"
ditto "$app" "$stage/Slyy Shot.app"
ln -s /Applications "$stage/Applications"
cat >"$stage/Read Me.txt" <<TXT
Slyy Shot $ver

1. Drag "Slyy Shot" onto "Applications".
$open_step
3. A camera icon appears in the menu bar:
   Ctrl+Shift+1 area, Ctrl+Shift+2 window, Ctrl+Shift+3 screen.
4. First capture: allow Slyy Shot under Privacy & Security > Screen
   Recording, then quit and reopen it.

Updates: menu > Check for Updates... (also automatic).
TXT
hdiutil create -volname "Slyy Shot $ver" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "dist/$dmg"
rm -rf "$stage"
codesign --force "$ts" --sign "$identity" "dist/$dmg"
if [ "$notarize" = yes ]; then
	submit "dist/$dmg"
	xcrun stapler staple "dist/$dmg"
	spctl --assess --type open --context context:primary-signature --verbose=2 "dist/$dmg"
	spctl --assess --type execute --verbose=2 "$app"
fi
echo "signed: ${SIGN_NAME:-$identity}  notarized: $notarize"

(cd dist && shasum -a 256 "$zip" "$dmg" >SHA256SUMS)
cat dist/SHA256SUMS
