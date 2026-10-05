#!/usr/bin/env bash
# Fetches the pinned cloudflared (Apache-2.0) that ships inside La Laai.app (Public link), verified three ways:
#   1. archive SHA256 == GitHub's recorded asset digest
#   2. binary  SHA256 == checksum published in Cloudflare's release notes
#   3. binary is signed by Cloudflare's Developer ID (team 68WVV388M8)
# Output: apps/macos/vendor/cloudflared (gitignored). build-app.sh copies + re-signs it into the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="2026.9.3"
ARCH="${CLOUDFLARED_ARCH:-arm64}"
case "$ARCH" in
  arm64) TGZ_SHA="587c2cfb1c230fe36c7fa7727da78be459dae028cabe8c001291999350f07095"
         BIN_SHA="5472c1a01c84bc31b3021056a73b4e5774ddddefc572124ea8fdf6c340639f32" ;;
  amd64) TGZ_SHA="d1155d0837487f261183b15c1eab6c4ebcad9dc49b94675f1524c3564cea3977"
         BIN_SHA="ab588b3b4db9cdb4476c30a3db2a72635b1d8327d44741fee6799a0f37b0ec07" ;;
  *) echo "unknown arch $ARCH" >&2; exit 1 ;;
esac
OUT="vendor/cloudflared"
if [ -x "$OUT" ] && echo "$BIN_SHA  $OUT" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "cloudflared $VERSION ($ARCH) already present and verified"; exit 0
fi
mkdir -p vendor
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/cf.tgz" "https://github.com/cloudflare/cloudflared/releases/download/$VERSION/cloudflared-darwin-$ARCH.tgz"
echo "$TGZ_SHA  $TMP/cf.tgz" | shasum -a 256 -c - >/dev/null
tar -xzf "$TMP/cf.tgz" -C "$TMP" cloudflared
echo "$BIN_SHA  $TMP/cloudflared" | shasum -a 256 -c - >/dev/null
SIG="$(codesign -dvv "$TMP/cloudflared" 2>&1 || true)"
case "$SIG" in *"TeamIdentifier=68WVV388M8"*) ;; *) echo "cloudflared is not signed by Cloudflare (68WVV388M8)" >&2; exit 1 ;; esac
mv "$TMP/cloudflared" "$OUT" && chmod +x "$OUT"
echo "cloudflared $VERSION ($ARCH) verified: archive digest, binary checksum, Cloudflare signature"
