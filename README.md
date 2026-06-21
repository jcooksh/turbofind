# TurboFind

A private, blazing-fast, **fully local** semantic file explorer for macOS.

It watches a folder, embeds your files, stores the vectors in a
[`turbovec`](https://pypi.org/project/turbovec/) TurboQuant index, and lets you
search by *meaning* from the terminal. No file content ever leaves your machine.

## Architecture

| File | Role |
|------|------|
| `shared.py` | Config + modality toggle, paths, id hashing, the `id -> path` sidecar, the modality-aware embedder (shared singleton), and turbovec helpers. |
| `ingest.py` | Background `watchdog` daemon — keeps the index in sync (create/modify/delete/move), media pipeline, low-priority initial scan. |
| `search.py` | Instant CLI — **hybrid** (semantic + lexical) ranking; prints / `--json` top-k. |
| `serve.py` | Optional warm localhost HTTP server (model stays loaded) for the GUI. Loopback-only + Host-guarded; no CORS. |
| `spotlight.py` | Best-effort bridge mirroring indexed items into native macOS CoreSpotlight. |
| `Launcher.swift` | Spotlight/Raycast-style floating search bar (Option+Space) that drives the backend and reveals files in Finder. |

## Hybrid scoring

`final = 0.7 · semantic + 0.3 · lexical`, where `semantic` is cosine mapped to
[0,1] and `lexical = max(BM25-over-candidate-pool, filename/path word-overlap)`.
Any file whose **name** contains a query *word* (whole-token, not substring) is
forced to a hard top tier — even if its content embedding falls outside the
dense top-50, name matches are unioned back in (an O(N) mapping scan per query;
a persistent name-token index is the fix for very large corpora). This kills the
"exam timetable → taxes file" semantic drift.

## GUI launcher

Build: `swiftc Launcher.swift -o TurboFind -framework SwiftUI -framework AppKit && ./TurboFind`.
Edit `Config` in `Launcher.swift` to point at your venv + repo and pick the
backend: `.process` (zero setup, spawns `search.py` per query) or `.httpServer`
(run `python serve.py` first — model stays warm for instant per-keystroke
results). Option+Space is a Carbon `RegisterEventHotKey` (consumes the chord, no
Accessibility permission needed); Enter reveals the file in Finder.

`turbovec` stores only `(uint64 id -> compressed vector)`. The `id -> absolute path`
half lives in the sidecar JSON; ids are a BLAKE2b hash of the resolved path, so
the same file always maps to the same id (enabling in-place upserts and O(1) deletes).

## Modality toggle

`shared.MULTI_MODAL` (env `TURBOFIND_MULTI_MODAL=1`) switches the backend:

| Mode | Model | Dim | Indexes | Index files |
|------|-------|-----|---------|-------------|
| text (default) | `all-MiniLM-L6-v2` | 384 | `.txt .md` | `mac_search.tvim` / `paths_mapping.json` |
| multimodal | `laion/CLIP-ViT-B-32-256x256-DataComp-S34B-b86K` | 512 | `.txt .md` + `.png .jpg` + `.mp4 .mov` | `mac_search.clip.tvim` / `paths_mapping.clip.json` |

The two modes use **separate** index files because a 512-dim vector cannot live
in a 384-dim index; `load_index` hard-validates the on-disk dimension and refuses
a mismatch. In multimodal mode a single CLIP space lets a *text* query match
images and video frames (e.g. `"a dog on a beach"` surfaces `beach.jpg`).

> CLIP's text encoder is caption-grade (~77 tokens); long documents are
> truncated. For pure text search, leave `MULTI_MODAL` off.

### Media pipeline (multimodal)

- **Images** (`.png/.jpg`) → CLIP vision encoder.
- **Video** (`.mp4/.mov`) → `ffmpeg` samples one frame every
  `VIDEO_FRAME_INTERVAL_SEC` (default 10s, capped at `VIDEO_MAX_FRAMES`),
  each frame is CLIP-encoded, then mean-pooled + renormalised into one vector.
  Requires the `ffmpeg` binary on PATH (`brew install ffmpeg`).

## Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # text mode

# multimodal mode also needs: open_clip_torch torch pillow + ffmpeg binary
# Spotlight bridge also needs: pyobjc-framework-CoreSpotlight

# One-time model prime (needs network ONCE; then HF_HUB_OFFLINE keeps it air-gapped):
python -c "from sentence_transformers import SentenceTransformer as S; S('sentence-transformers/all-MiniLM-L6-v2')"
# multimodal prime:
# python -c "import open_clip; open_clip.create_model_and_transforms('hf-hub:laion/CLIP-ViT-B-32-256x256-DataComp-S34B-b86K')"
```

## Usage

```bash
# Terminal 1 — daemon (defaults to ~/Documents)
python ingest.py
TURBOFIND_MULTI_MODAL=1 python ingest.py ~/Pictures   # multimodal

# Terminal 2 — search any time
python search.py "my server configurations"
python search.py -k 10 "quarterly budget notes"
TURBOFIND_MULTI_MODAL=1 python search.py "a dog on a beach"
```

## Configuration (environment variables)

| Variable | Default | Meaning |
|----------|---------|---------|
| `TURBOFIND_WATCH_DIR` | `~/Documents` | folder to index |
| `TURBOFIND_DATA_DIR`  | `~/.turbofind` | where the index + sidecar live |
| `TURBOFIND_MULTI_MODAL` | `0` | `1` enables CLIP image/video indexing |
| `TURBOFIND_LOG_LEVEL` | `INFO` | logging verbosity |

## Background safety (large trees)

The initial reconciliation scan runs on a dedicated thread that demotes itself to
real macOS `QOS_CLASS_BACKGROUND` (via `pthread_set_qos_class_self_np`) and sleeps
after every `SCAN_BATCH` files, so indexing millions of files stays off the
critical path. The watcher runs concurrently, so live edits are still indexed
immediately. An interrupted scan never prunes (it can't tell "gone" from "not yet
reached").

## Spotlight / Finder bridge — honest caveat

`spotlight.py` mirrors each indexed item into `CSSearchableIndex` via pyobjc. But
**CoreSpotlight is not the index Finder uses for file search** — Finder uses
filesystem metadata importers, while CoreSpotlight surfaces app content in the
⌘-Space Spotlight UI, and Apple expects an entitled, code-signed **app bundle**.
From a plain Python CLI `defaultSearchableIndex()` may return nil and items often
won't appear in Finder. The bridge is therefore best-effort: if pyobjc/CoreSpotlight
is unavailable or the call fails, it logs once and no-ops — it never breaks indexing.
To make it genuinely surface, ship TurboFind inside a signed `.app` with the
`com.apple.developer.corespotlight` entitlement.

## Notes & limits

- Text files > 5 MiB and images > 64 MiB are skipped.
- At ~2M files the JSON sidecar (rewritten on each flush) becomes the scaling
  bottleneck; a future revision should move it to SQLite/LMDB. The background QoS
  + throttle keep CPU free, but flush cost grows with the mapping size.
- `bit_width=4` trades a little recall for a much smaller, faster index.
