#!/usr/bin/env bash
# TurboFind bootstrap — invoked by the Homebrew cask (jcooksh/homebrew-tap).
#
# TurboFind isn't a self-contained .app: the menu-bar shell drives a Python
# engine (turbovec + local ML models) that lives in ~/turbofind. This sets that
# up: clone the repo, build the venv, install deps, create a stable signing
# identity, build + sign the app, and launch it. Safe to re-run (idempotent).
set -euo pipefail

REPO="${TURBOFIND_HOME:-$HOME/turbofind}"
echo "==> TurboFind: setting up in $REPO"

# 1) source
if [ -d "$REPO/.git" ]; then
  echo "==> updating existing checkout"
  git -C "$REPO" pull --ff-only || true
else
  echo "==> cloning jcooksh/turbofind"
  git clone --depth 1 https://github.com/jcooksh/turbofind "$REPO"
fi
cd "$REPO"

# 2) python venv + deps (first run pulls the ML models lazily on first search)
PY="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
if [ -z "$PY" ]; then echo "!! python3 not found"; exit 1; fi
echo "==> creating venv with $PY"
"$PY" -m venv .venv
./.venv/bin/pip install -U pip >/dev/null
echo "==> installing dependencies (this is the slow part — torch etc.)"
./.venv/bin/pip install -r requirements.txt

# 3) stable code-signing identity + build + sign (so Full Disk Access sticks)
echo "==> building the menu-bar app"
( cd menubar && ./make-cert.sh && ./build.sh )

# 4) launch
open "$REPO/menubar/TurboFind.app" || true

cat <<'DONE'

==> TurboFind installed.
    • Click the bolt in the menu bar (or press ⌥F) to search.
    • One-time: System Settings → Privacy & Security → Full Disk Access →
      add ~/turbofind/menubar/TurboFind.app and switch it on
      (so it can read your files without re-prompting).
    • It indexes your home folder in the background on first launch.
DONE
