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

if ! command -v git >/dev/null 2>&1; then
  echo "!! 'git' not found. Run:  xcode-select --install"
  echo "   then re-run this installer."
  exit 1
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
