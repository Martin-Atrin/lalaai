#!/usr/bin/env bash
# Packs the notarized build/lalaai.app into a signed, notarized, stapled build/LaLaai.dmg
# (drag-to-Applications layout). Run after ./build-app.sh (with SIGN_IDENTITY) and ./notarize.sh.
set -euo pipefail
cd "$(dirname "$0")"
PROFILE="${NOTARY_PROFILE:-lalaai-notary}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
STAGE="build/dmg"
DMG="build/LaLaai.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/lalaai.app "$STAGE/La Laai.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "La Laai" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
rm -rf "$STAGE"
echo "Notarized: $DMG"
