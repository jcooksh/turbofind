#!/usr/bin/env bash
# Build TurboFind.app — a menu-bar app shell around the Python search engine.
set -euo pipefail
cd "$(dirname "$0")"

APP="TurboFind.app"
echo "==> compiling TurboFind.swift"
swiftc TurboFind.swift -O -o TurboFind -framework AppKit -framework WebKit

echo "==> assembling $APP bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
mv TurboFind "$APP/Contents/MacOS/TurboFind"
# (optional) drop an .icns into Resources and add CFBundleIconFile to Info.plist
echo "APPL????" > "$APP/Contents/PkgInfo"

echo "==> done.  open $APP   (it appears in the menu bar, not the Dock)"
echo "    First launch: the app starts serve.py in the background (model warms,"
echo "    a few seconds), then the bolt is clickable. Right-click the bolt for"
echo "    Re-index / Quit."
