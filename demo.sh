#!/usr/bin/env bash
# TurboFind one-command demo: set up, index a sample folder, run searches.
# Usage:  ./demo.sh            (uses a tiny built-in sample folder)
#         ./demo.sh ~/Notes    (index your own folder instead)
set -euo pipefail
cd "$(dirname "$0")"

VENV=.venv
PY="$VENV/bin/python"
DEMO_DIR="${1:-$HOME/tf_demo}"

echo "==> 1/4  Python venv + deps"
[ -d "$VENV" ] || python3 -m venv "$VENV"
# core deps (fast); sentence-transformers (+torch) only if missing
"$PY" -c "import turbovec, watchdog, numpy" 2>/dev/null || "$VENV/bin/pip" install -q turbovec watchdog numpy
if ! "$PY" -c "import sentence_transformers" 2>/dev/null; then
  echo "    installing sentence-transformers (pulls torch — large, one time)..."
  "$VENV/bin/pip" install -q sentence-transformers
fi

echo "==> 2/4  Prime embedding model (one-time download, then air-gapped)"
HF_HUB_OFFLINE=0 TRANSFORMERS_OFFLINE=0 "$PY" - <<'PY'
from sentence_transformers import SentenceTransformer
SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
print("    model ready.")
PY

if [ "$DEMO_DIR" = "$HOME/tf_demo" ]; then
  echo "==> 3/4  Create sample files in $DEMO_DIR"
  mkdir -p "$DEMO_DIR"
  printf 'postgres connection pooling, ports, and query tuning\n' > "$DEMO_DIR/database.md"
  printf 'sourdough bread recipe with a rye starter and long proof\n' > "$DEMO_DIR/baking.txt"
  printf 'kubernetes deployment yaml, ingress, and pod autoscaling\n' > "$DEMO_DIR/k8s.txt"
  printf 'notes on tax filing deadlines and quarterly estimates\n' > "$DEMO_DIR/taxes.md"
else
  echo "==> 3/4  Using your folder: $DEMO_DIR"
fi

echo "==> 4/4  Index once (no daemon) — live progress bar below"
# --once shows a [#####] %  count  files/s  ETA  bar while it embeds every file.
TURBOFIND_WATCH_DIR="$DEMO_DIR" "$PY" ingest.py --once "$DEMO_DIR"

run() { echo; echo "    \$ search '$1'"; "$PY" search.py "$1" || true; }
run "database configuration"
run "baking"
run "container orchestration"

echo
echo "Done. Try your own:  $PY search.py \"your query here\""
echo "Live-watch mode:     TURBOFIND_WATCH_DIR=$DEMO_DIR $PY ingest.py   (Ctrl-C to stop)"
