#!/usr/bin/env bash
# Build TurboFind.app — a menu-bar app shell around the Python search engine.
set -euo pipefail
cd "$(dirname "$0")"

APP="TurboFind.app"
echo "==> compiling TurboFind.swift"
swiftc TurboFind.swift -O -o TurboFind -framework AppKit -framework Carbon -framework ServiceManagement -framework Quartz

echo "==> assembling $APP bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
mv TurboFind "$APP/Contents/MacOS/TurboFind"
echo "APPL????" > "$APP/Contents/PkgInfo"

# App icon: use the committed AppIcon.icns; regenerate from the logo if missing
# (needs Pillow + macOS sips/iconutil).
if [ ! -f AppIcon.icns ] && [ -x ../.venv/bin/python ]; then
  ../.venv/bin/python make_icon.py || true
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" \
  && echo "    bundled AppIcon.icns" || echo "    (no AppIcon.icns — building without a custom icon)"

# Code-sign with a STABLE identity so macOS remembers Full Disk Access / file
# permissions across rebuilds. swiftc only ad-hoc-signs (a hash that changes
# every build → TCC forgets and re-prompts). Use $TURBOFIND_SIGN_ID, else the
# self-signed "TurboFind Local" identity from make-cert.sh, else stay ad-hoc.
KC="$HOME/Library/Keychains/turbofind.keychain-db"
SIGN_ID="${TURBOFIND_SIGN_ID:-}"
KCARG=()
# Prefer the dedicated TurboFind keychain (no login-password prompt). NB: no -v —
# a self-signed identity is untrusted, so it only lists without -v.
if [ -z "$SIGN_ID" ] && [ -f "$KC" ]; then
  security unlock-keychain -p turbofind "$KC" 2>/dev/null || true
  if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "TurboFind Local"; then
    SIGN_ID="TurboFind Local"; KCARG=(--keychain "$KC")
  fi
elif [ -z "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q "TurboFind Local"; then
  SIGN_ID="TurboFind Local"
fi
if [ -n "$SIGN_ID" ]; then
  echo "==> signing $APP with: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "${KCARG[@]}" "$APP" \
    && echo "    signed (stable identity — file permissions will persist)" \
    || echo "    sign failed — app stays ad-hoc"
else
  echo "==> no stable signing identity — app is ad-hoc."
  echo "    macOS will re-ask for file access after updates/restarts."
  echo "    Run ./make-cert.sh once to fix that, then rebuild."
fi

echo "==> done.  open $APP   (it appears in the menu bar, not the Dock)"
echo "    First launch: the app starts serve.py in the background (model warms,"
echo "    a few seconds), then the bolt is clickable. Right-click the bolt for"
echo "    Re-index / Quit."
