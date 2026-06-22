"""
serve.py — warm local search engine (JSON API) for TurboFind.

The hidden backend the native menu-bar app drives. Loads the model(s) once and
reuses the hybrid `run_search`, so queries are instant, and live-indexes the
watched tree in-process (new/changed/deleted files). There is NO browser UI —
the front end is the native AppKit app in menubar/; this just answers JSON.

    python serve.py            # listens on 127.0.0.1:8765 (the app starts it)

Routes (all JSON):
    GET /  ·  /health                  -> {"service":"turbofind","ok":true}
    GET /folders                       -> indexed directories
    GET /search?q=&k=&types=&roots=    -> ranked results (each with an "added" date)
    GET /reveal?path=                  -> reveal that file in Finder (open -R + activate)
    GET /preview?path=                 -> Quick Look the file (qlmanage)

Loopback-only + Host-header guard + no CORS (results contain home-dir paths).
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import shared
from shared import get_logger
from search import run_search

log = get_logger("turbofind.serve")

HOST = "127.0.0.1"
PORT = 8765

# Models can't run concurrent inferences safely; serialize searches (each is
# sub-second warm) so type-as-you-go overlapping requests can't deadlock torch.
_SEARCH_LOCK = threading.Lock()


def _file_added(path: str) -> float:
    """When the file landed on this machine: birth time (creation) if the OS
    tracks it (macOS APFS does), else mtime. Epoch seconds; 0 if unstatable."""
    try:
        st = os.stat(path)
    except OSError:
        return 0.0
    return float(getattr(st, "st_birthtime", 0.0) or st.st_mtime)


def _folders() -> dict:
    """Directories that contain indexed files (across all lanes) -> count."""
    counts: dict = {}
    for lane in shared.LANES:
        try:
            mapping = shared.PathMapping(lane.mapping_path).load()
        except Exception:
            continue
        for _fid, path in mapping.items():
            d = str(Path(path).parent)
            counts[d] = counts.get(d, 0) + 1
    return counts


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        host = self.headers.get("Host", "")
        if host.split(":")[0] not in ("127.0.0.1", "localhost"):
            self._send_json(403, {"error": "forbidden host"})
            return
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/health"):
            # JSON-only engine: no browser UI lives here anymore (the native
            # menu-bar app is the front end). This is just a readiness ping.
            self._send_json(200, {"service": "turbofind", "ok": True})
        elif parsed.path == "/folders":
            self._send_json(200, sorted(_folders().keys()))
        elif parsed.path == "/search":
            self._handle_search(parse_qs(parsed.query))
        elif parsed.path == "/reveal":
            self._handle_reveal(parse_qs(parsed.query))
        elif parsed.path == "/preview":
            self._handle_preview(parse_qs(parsed.query))
        else:
            self._send_json(404, {"error": "not found"})

    def _handle_search(self, params) -> None:
        query = (params.get("q", [""])[0]).strip()
        try:
            k = max(1, min(100, int(params.get("k", ["12"])[0])))
        except ValueError:
            k = 12
        types = [t for t in params.get("types", [""])[0].split(",") if t]
        roots = [r for r in params.get("roots", [""])[0].split(",") if r]
        if not query:
            self._send_json(200, [])
            return
        try:
            with _SEARCH_LOCK:                  # serialize: models aren't concurrent-safe
                hits = run_search(query, k, types=types or None, roots=roots or None)
            self._send_json(200, [{
                "rank": h.rank, "score": round(h.score, 6),
                "filename_match": h.filename_hit, "path": h.path, "exists": h.exists,
                "added": _file_added(h.path),
            } for h in hits])
        except Exception as exc:
            log.error("search failed: %s", exc)
            self._send_json(500, {"error": str(exc)})

    def _handle_reveal(self, params) -> None:
        """Reveal a file in Finder (select + scroll to it) AND bring Finder to the
        front as the active window. Reveal-only; existing paths."""
        path = params.get("path", [""])[0]
        if not path or not os.path.exists(path):
            self._send_json(404, {"ok": False, "error": "path not found"})
            return
        try:
            subprocess.run(["open", "-R", path], check=False, timeout=5)
            # open -R selects/scrolls; activate guarantees Finder becomes frontmost.
            subprocess.run(["osascript", "-e", 'tell application "Finder" to activate'],
                          check=False, timeout=5)
            self._send_json(200, {"ok": True})
        except Exception as exc:
            self._send_json(500, {"ok": False, "error": str(exc)})

    def _handle_preview(self, params) -> None:
        """Quick Look preview a file (the macOS spacebar preview), via qlmanage.
        Fire-and-forget so the request returns while the panel stays open."""
        path = params.get("path", [""])[0]
        if not path or not os.path.exists(path):
            self._send_json(404, {"ok": False, "error": "path not found"})
            return
        try:
            subprocess.Popen(["qlmanage", "-p", path],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self._send_json(200, {"ok": True})
        except Exception as exc:
            self._send_json(500, {"ok": False, "error": str(exc)})

    # -- responses ----------------------------------------------------------

    def _send_json(self, code: int, body) -> None:
        self._send(code, "application/json; charset=utf-8",
                  json.dumps(body).encode("utf-8"))

    def _send(self, code: int, ctype: str, data: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()                      # no CORS: results carry home-dir paths
        self.wfile.write(data)

    def log_message(self, *_args) -> None:
        pass


def _start_live_indexer():
    """Watch the tree in-process so new/changed/deleted files are indexed while
    the server runs — otherwise the index goes stale the moment you add a file.
    Reuses the same loaded model as search; all inference is serialized by
    shared._INFER_LOCK, so a background embed can't race a query. Returns a
    zero-arg shutdown callable (or None if live indexing couldn't start)."""
    try:
        import ingest
        from watchdog.observers import Observer
    except Exception as exc:
        log.warning("live indexing unavailable (%s) — index won't auto-update", exc)
        return None

    root = Path(os.environ.get("TURBOFIND_WATCH_DIR", str(Path.home()))).expanduser()
    if not root.is_dir():
        log.warning("watch dir %s missing — live indexing off", root)
        return None
    try:
        coordinator = ingest.Coordinator()
    except Exception as exc:
        log.warning("live indexing off (%s)", exc)
        return None

    handler = ingest.TurboFindEventHandler(coordinator)
    observer = Observer()
    observer.schedule(handler, str(root), recursive=True)
    observer.start()                               # live edits captured immediately
    scanner = ingest.BackgroundScanner(coordinator, root)
    scanner.start()                                # low-QoS reconcile of what changed offline
    log.info("live indexing on — watching %s", root)

    def shutdown() -> None:
        try:
            scanner.stop(); scanner.join()
            observer.stop(); observer.join()
            handler.cancel_all()
            coordinator.close()                    # final flush
        except Exception as exc:
            log.warning("live indexer shutdown: %s", exc)
    return shutdown


def main() -> int:
    log.info("warming embedding model(s)...")
    for lane in shared.LANES:
        try:
            shared.get_embedder(lane).embed_one("warmup")
        except Exception as exc:
            log.warning("warmup for lane %s failed (loads on first query): %s",
                        lane.name, exc)
    stop_indexer = _start_live_indexer()
    server = ThreadingHTTPServer((HOST, PORT), _Handler)
    log.info("TurboFind engine ready on http://%s:%d (JSON API — use the menu-bar app)", HOST, PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down.")
    finally:
        server.server_close()
        if stop_indexer:
            stop_indexer()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
