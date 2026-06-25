#!/usr/bin/env bash
# TurboFind installer — no Homebrew required.
#
#   curl -fsSL https://raw.githubusercontent.com/jcooksh/turbofind/main/install.sh | bash
#
# Clones the repo to ~/turbofind, builds the Python venv, installs deps, creates a
# stable signing identity, builds + signs the menu-bar app, and launches it.
# Needs Apple's Command Line Tools (git + python3) — macOS will offer to install
# them if missing. Re-running updates an existing install. Everything stays local.
set -euo pipefail

REPO="${TURBOFIND_HOME:-$HOME/turbofind}"
echo "==> TurboFind: installing into $REPO"

# 0) Apple Command Line Tools (git + python3). On a Mac that's never had them,
# the first `git` call pops a macOS install dialog and FAILS immediately — so we
# trigger the install ourselves and WAIT for it to finish, then continue.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "==> One-time: TurboFind needs Apple's Command Line Tools (git + python3)."
  echo "    A macOS dialog is opening — click \"Install\" and wait a few minutes."
  echo "    This window will continue on its own once they're ready."
  xcode-select --install >/dev/null 2>&1 || true
  tries=0
  until xcode-select -p >/dev/null 2>&1; do
    sleep 5
    tries=$((tries + 1))
    if [ "$tries" -ge 360 ]; then          # ~30 min
      echo "!! Command Line Tools didn't finish installing."
      echo "   Finish the macOS installer (or run: xcode-select --install),"
      echo "   then re-run this command."
      exit 1
    fi
  done
  echo "==> Command Line Tools ready — continuing."
fi

# 1) source
if [ -d "$REPO/.git" ]; then
  echo "==> updating existing checkout"
  git -C "$REPO" pull --ff-only || true
else
  echo "==> cloning jcooksh/turbofind"
  git clone --depth 1 https://github.com/jcooksh/turbofind "$REPO"
fi
cd "$REPO"

# 2) python venv + deps
PY="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "!! 'python3' not found. Run:  xcode-select --install  (then re-run)."
  exit 1
fi
echo "==> creating venv + installing dependencies (slow: downloads torch etc.)"
"$PY" -m venv .venv
./.venv/bin/pip install -U pip >/dev/null
./.venv/bin/pip install -r requirements.txt

# 3) stable signing identity + build + sign
echo "==> building the menu-bar app"
( cd menubar && ./make-cert.sh && ./build.sh )

# 4) launch
open "$REPO/menubar/TurboFind.app" || true

cat <<'DONE'

==> TurboFind installed.
    • Click the bolt in the menu bar (or press ⌥F) to search.
    • One-time: System Settings → Privacy & Security → Full Disk Access →
      add ~/turbofind/menubar/TurboFind.app and switch it on.
    • It indexes your home folder in the background on first launch.
    • Update later from the bolt's right-click menu (or re-run this installer).
DONE
