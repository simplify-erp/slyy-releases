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


identity="${SIGN_IDENTITY:--}"
if [ "$identity" = - ]; then
	ts=--timestamp=none # ad-hoc: no timestamp server
else
	ts=--timestamp # Developer ID: secure timestamp (required for notarization)
fi
codesign --force --options runtime "$ts" --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# Notarization (needs a Developer ID signature and an App Store Connect API
# key: NOTARY_KEY = path to the .p8, NOTARY_KEY_ID, NOTARY_ISSUER).
notarize=no
if [ "$identity" != - ] && [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
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
dmg="SlyySnap-$ver.dmg"
(cd dist && ditto -c -k --keepParent "Slyy Snap.app" "$zip")

if [ "$notarize" = yes ]; then
	open_step="2. Open it from Applications."
else
	open_step="2. Open it from Applications. The first time, macOS says the developer
   cannot be verified: open System Settings > Privacy & Security, click
   \"Open Anyway\", then open Slyy Snap again."
fi

# DMG: the app, an Applications shortcut and a short read-me.
stage=dist/dmg
mkdir -p "$stage"
ditto "$app" "$stage/Slyy Snap.app"
ln -s /Applications "$stage/Applications"
cat >"$stage/Read Me.txt" <<TXT
Slyy Snap $ver

1. Drag "Slyy Snap" onto "Applications".
$open_step
3. A camera icon appears in the menu bar:
   Ctrl+Shift+1 area, Ctrl+Shift+2 window, Ctrl+Shift+3 screen.
4. First capture: allow Slyy Snap under Privacy & Security > Screen
   Recording, then quit and reopen it.

Updates: menu > Check for Updates... (also automatic).
TXT
hdiutil create -volname "Slyy Snap $ver" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "dist/$dmg"
rm -rf "$stage"
codesign --force "$ts" --sign "$identity" "dist/$dmg"
if [ "$notarize" = yes ]; then
	submit "dist/$dmg"
	xcrun stapler staple "dist/$dmg"
	spctl --assess --type open --context context:primary-signature --verbose=2 "dist/$dmg"
	spctl --assess --type execute --verbose=2 "$app"
fi
echo "signed: $identity  notarized: $notarize"

(cd dist && shasum -a 256 "$zip" "$dmg" >SHA256SUMS)
cat dist/SHA256SUMS
