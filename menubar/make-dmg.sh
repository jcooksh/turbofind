#!/usr/bin/env bash
# Package TurboFind.app into a drag-to-Applications DMG, signed with the stable
# self-signed identity. Without Apple notarization the download is still
# quarantined, so users open it the first time via right-click → Open (not a
# clean double-click). The app sets up its engine on first launch.
#
#   ./build.sh && ./make-dmg.sh    # -> TurboFind.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP="TurboFind.app"
DMG="TurboFind.dmg"
[ -d "$APP" ] || { echo "build first: ./build.sh"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # drag-to-install

echo "==> building $DMG"
rm -f "$DMG"
hdiutil create -volname "TurboFind" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Sign the disk image too (best effort, same stable identity).
KC="$HOME/Library/Keychains/turbofind.keychain-db"
ARGS=(--force --sign "TurboFind Local")
if [ -f "$KC" ]; then
  security unlock-keychain -p turbofind "$KC" 2>/dev/null || true
  ARGS+=(--keychain "$KC")
fi
codesign "${ARGS[@]}" "$DMG" 2>/dev/null || true

echo "==> wrote $DMG ($(du -h "$DMG" | cut -f1))"
