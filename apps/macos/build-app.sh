#!/usr/bin/env bash
# Builds La Laai.app into apps/macos/build/.
#   ./build-app.sh            release build, ad-hoc signed (local testing)
#   ./build-app.sh debug      debug build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" ./build-app.sh   hardened-runtime signing for distribution
# Notarize afterwards with ./notarize.sh.
# Bundles: the attendee PWA (served by the embedded relay) and cloudflared (Public link), pinned and verified.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product lalaai
BIN="$(swift build -c "$CONFIG" --show-bin-path)/lalaai"
# The attendee PWA, served by the embedded relay (apps/shared/Relay) from Contents/Resources/pwa.
[ -d ../../web/pwa/node_modules ] || pnpm -C ../../web/pwa install --frozen-lockfile
pnpm -C ../../web/pwa build
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

# Attendee PWA for the embedded relay (LinkHost.pwaDir = Resources/pwa)
cp -R ../../web/pwa/dist "$APP/Contents/Resources/pwa"

# On-device NLLB helper (source only; its Python env is created on first use in ~/Library/Application Support/La Laai)
mkdir -p "$APP/Contents/Resources/translator"
cp ../translator/pyproject.toml ../translator/server.py "$APP/Contents/Resources/translator/"
[ -f ../translator/uv.lock ] && cp ../translator/uv.lock "$APP/Contents/Resources/translator/"

# cloudflared (Apache-2.0) for Public link. Pinned + verified by scripts/fetch-cloudflared.sh; its licence ships
# alongside it. The user installs nothing.
./scripts/fetch-cloudflared.sh
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp vendor/cloudflared "$APP/Contents/Helpers/cloudflared"
cp Resources/licenses/cloudflared-LICENSE.txt "$APP/Contents/Resources/Licenses/cloudflared-LICENSE.txt"
cp ../../LICENSE "$APP/Contents/Resources/Licenses/LaLaai-LICENSE.txt"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Distribution: notarization needs every executable on our Developer ID with the hardened runtime and a
  # secure timestamp.
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
else
  sign() { codesign --force --sign - "$@"; }
fi
# Inside-out: the helper first, then the app. Never --deep for signing.
sign "$APP/Contents/Helpers/cloudflared"
sign --entitlements Resources/lalaai.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP"
