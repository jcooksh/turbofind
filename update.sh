#!/usr/bin/env bash
# TurboFind self-update: pull the latest code, rebuild the menu-bar app only if
# its sources changed (Python changes don't need it), and restart whatever
# engine is running so the new code goes live. Safe to run anytime.
#
#   ~/turbofind/update.sh
set -euo pipefail
cd "$(dirname "$0")"

before="$(git rev-parse HEAD)"
echo "==> pulling latest…"
git pull --ff-only
after="$(git rev-parse HEAD)"

if [ "$before" = "$after" ]; then
  echo "already up to date — nothing to restart."
  exit 0
fi

# Rebuild the .app only when its own sources moved; Python changes are picked up
# just by relaunching the engine.
if git diff --name-only "$before" "$after" | grep -q '^menubar/'; then
  echo "==> menu-bar app sources changed — rebuilding"
  ( cd menubar && ./build.sh )
fi

echo "==> restarting engine"
if pgrep -f "TurboFind.app/Contents/MacOS/TurboFind" >/dev/null 2>&1; then
  # The app owns serve.py; quit + reopen so it spawns a fresh engine with new code.
  osascript -e 'quit app "TurboFind"' 2>/dev/null || true
  sleep 1
  open menubar/TurboFind.app
  echo "    menu-bar app restarted."
elif pgrep -f "serve.py" >/dev/null 2>&1; then
  pkill -f "serve.py" || true
  sleep 1
  if [ -x .venv/bin/python ]; then
    TURBOFIND_MULTI_MODAL=1 nohup .venv/bin/python serve.py >/tmp/turbofind-serve.log 2>&1 &
    echo "    serve.py restarted (log: /tmp/turbofind-serve.log)."
  else
    echo "    .venv missing — start manually: python serve.py"
  fi
else
  echo "    engine not running. Start the app, or: python serve.py"
fi

echo "==> done."
