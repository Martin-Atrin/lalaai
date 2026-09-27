#!/usr/bin/env bash
# Builds La Laai.app into apps/macos/build/.
#   ./build-app.sh            release build, ad-hoc signed (local testing)
#   ./build-app.sh debug      debug build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" ./build-app.sh   hardened-runtime signing for distribution
# Notarize afterwards with ./notarize.sh.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/lalaai"
APP="build/lalaai.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/lalaai"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from the logo SVG
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -s format png -z $sz $sz Resources/AppIcon.svg --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -s format png -z $((sz*2)) $((sz*2)) Resources/AppIcon.svg --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# On-device NLLB helper (source only; its Python env is created on first use in ~/Library/Application Support/La Laai)
mkdir -p "$APP/Contents/Resources/translator"
cp ../translator/pyproject.toml ../translator/server.py "$APP/Contents/Resources/translator/"
[ -f ../translator/uv.lock ] && cp ../translator/uv.lock "$APP/Contents/Resources/translator/"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements Resources/lalaai.entitlements "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --sign - --entitlements Resources/lalaai.entitlements "$APP"
fi
echo "Built $APP"
