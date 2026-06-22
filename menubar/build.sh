#!/usr/bin/env bash
# Build TurboFind.app — a menu-bar app shell around the Python search engine.
set -euo pipefail
cd "$(dirname "$0")"

APP="TurboFind.app"
echo "==> compiling TurboFind.swift"
swiftc TurboFind.swift -O -o TurboFind -framework AppKit -framework WebKit -framework Carbon

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

echo "==> done.  open $APP   (it appears in the menu bar, not the Dock)"
echo "    First launch: the app starts serve.py in the background (model warms,"
echo "    a few seconds), then the bolt is clickable. Right-click the bolt for"
echo "    Re-index / Quit."
