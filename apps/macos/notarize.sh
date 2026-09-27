#!/usr/bin/env bash
# Notarizes and staples build/lalaai.app. One-time setup (stores credentials in your keychain):
#   xcrun notarytool store-credentials "lalaai-notary" --apple-id <you@example.com> --team-id UMNF8B5TA2
# then:  SIGN_IDENTITY="Developer ID Application: …" ./build-app.sh && ./notarize.sh
set -euo pipefail
cd "$(dirname "$0")"
PROFILE="${NOTARY_PROFILE:-lalaai-notary}"
APP="build/lalaai.app"
ZIP="build/LaLaai.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
ditto -c -k --keepParent "$APP" "$ZIP" # re-zip with the stapled ticket for distribution
echo "Notarized: $APP  (distributable zip: $ZIP)"
