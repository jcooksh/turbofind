"""
serve.py — warm local search server + browser UI for TurboFind.

Spawning `python search.py` per keystroke reloads the embedding model every time
(seconds of cold-start) — fine for the CLI, far too slow for type-as-you-go.
This loopback HTTP server loads the model(s) ONCE and reuses the exact hybrid
`run_search` as the CLI, so queries are instant.

    python serve.py            # then open http://127.0.0.1:8765 in a browser

Routes:
    GET /                 -> the search UI (HTML)
    GET /search?q=&k=     -> JSON results
    GET /reveal?path=     -> reveal that file in Finder (open -R), local only

Loopback-only + a Host-header guard (DNS-rebinding defence) + no CORS, because
results contain absolute home-directory paths. Fully air-gapped otherwise.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import shared
from shared import get_logger
from search import run_search

log = get_logger("turbofind.serve")

HOST = "127.0.0.1"
PORT = 8765

# The embedding models can't run concurrent inferences safely; ThreadingHTTPServer
# would otherwise let type-as-you-go fire overlapping searches that deadlock torch.
# Serialize all searches through one lock — each is sub-second on a warm model.
_SEARCH_LOCK = threading.Lock()


INDEX_HTML = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TurboFind</title>
<style>
 :root{color-scheme:dark}
 *{box-sizing:border-box}
 body{margin:0;font:15px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
      background:#0f1115;color:#e8eaed}
 .wrap{max-width:760px;margin:7vh auto;padding:0 20px}
 h1{font-size:12px;letter-spacing:.2em;text-transform:uppercase;color:#8a8f98;font-weight:700;margin:0 0 14px}
 #q{width:100%;font-size:24px;padding:16px 18px;border-radius:14px;border:1px solid #2a2e37;
    background:#171a21;color:#fff;outline:none}
 #q:focus{border-color:#3b82f6}
 #status{color:#6b7280;font-size:12px;margin:10px 4px;height:14px}
 .row{display:flex;align-items:center;gap:12px;padding:10px 12px;border-radius:10px;cursor:pointer}
 .row:hover,.row.sel{background:#1d2129}
 .ic{font-size:18px;width:24px;text-align:center;flex:none}
 .meta{flex:1;min-width:0}
 .name{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .path{color:#6b7280;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .sc{font:12px ui-monospace,SFMono-Regular,monospace;color:#9aa0aa;flex:none}
 .bar{height:4px;background:#2a2e37;border-radius:2px;margin-top:5px;overflow:hidden}
 .bar>i{display:block;height:100%;background:#3b82f6}
 .tag{font-size:10px;padding:1px 6px;border-radius:20px;background:#2a3550;color:#9ab4ff;margin-left:6px}
</style></head><body>
<div class="wrap">
 <h1>TurboFind</h1>
 <input id="q" placeholder="Search your files by meaning…" autofocus autocomplete="off" spellcheck="false">
 <div id="status">Type to search · ↑↓ to move · ↵ reveals in Finder</div>
 <div id="results"></div>
</div>
<script>
const q=document.getElementById('q'),R=document.getElementById('results'),S=document.getElementById('status');
let timer=null, rows=[], sel=0;
function icon(p){const e=(p.split('.').pop()||'').toLowerCase();
  if(['png','jpg','jpeg'].includes(e))return'\\u{1F5BC}';
  if(['mp4','mov','m4v'].includes(e))return'\\u{1F3AC}';return'\\u{1F4C4}';}
function esc(s){return s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function render(items){rows=items;sel=0;
  if(!items.length){R.innerHTML='';return;}
  R.innerHTML=items.map((h,i)=>{
    const name=h.path.split('/').pop(), dir=h.path.slice(0,h.path.length-name.length);
    const pct=Math.max(0,Math.min(100,Math.round(h.score*100)));
    return '<div class="row'+(i===0?' sel':'')+'" data-i="'+i+'">'+
      '<div class="ic">'+icon(h.path)+'</div>'+
      '<div class="meta"><div class="name">'+esc(name)+(h.filename_match?'<span class="tag">name</span>':'')+'</div>'+
      '<div class="path">'+esc(dir)+'</div>'+
      '<div class="bar"><i style="width:'+pct+'%"></i></div></div>'+
      '<div class="sc">'+h.score.toFixed(2)+'</div></div>';}).join('');
  [...R.children].forEach(el=>el.onclick=()=>reveal(+el.dataset.i));
}
function reveal(i){if(rows[i])fetch('/reveal?path='+encodeURIComponent(rows[i].path));}
function setSel(n){if(!rows.length)return;sel=Math.max(0,Math.min(rows.length-1,n));
  [...R.children].forEach((el,i)=>el.classList.toggle('sel',i===sel));
  if(R.children[sel])R.children[sel].scrollIntoView({block:'nearest'});}
q.addEventListener('input',()=>{clearTimeout(timer);const v=q.value.trim();
  if(!v){R.innerHTML='';S.textContent='';return;}
  timer=setTimeout(async()=>{S.textContent='searching…';const t0=performance.now();
    try{const r=await fetch('/search?q='+encodeURIComponent(v)+'&k=12');const d=await r.json();
      render(d);S.textContent=d.length+' results · '+Math.round(performance.now()-t0)+' ms';}
    catch(e){S.textContent='error: '+e;}},200);});
q.addEventListener('keydown',e=>{
  if(e.key==='ArrowDown'){e.preventDefault();setSel(sel+1);}
  else if(e.key==='ArrowUp'){e.preventDefault();setSel(sel-1);}
  else if(e.key==='Enter'){e.preventDefault();reveal(sel);}});
</script></body></html>"""


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        # Loopback Host guard: binding to 127.0.0.1 blocks off-box TCP, but a
        # hostile page could point a hostname at 127.0.0.1 (DNS rebinding). The
        # Host check defeats that; combined with no-CORS, only our own page calls us.
        host = self.headers.get("Host", "")
        if host.split(":")[0] not in ("127.0.0.1", "localhost"):
            self._send_json(403, {"error": "forbidden host"})
            return

        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            self._send_html(INDEX_HTML)
        elif parsed.path == "/search":
            self._handle_search(parse_qs(parsed.query))
        elif parsed.path == "/reveal":
            self._handle_reveal(parse_qs(parsed.query))
        else:
            self._send_json(404, {"error": "not found"})

    def _handle_search(self, params) -> None:
        query = (params.get("q", [""])[0]).strip()
        try:
            k = max(1, min(50, int(params.get("k", ["12"])[0])))
        except ValueError:
            k = 12
        if not query:
            self._send_json(200, [])
            return
        try:
            with _SEARCH_LOCK:                  # serialize: models aren't concurrent-safe
                hits = run_search(query, k)
            self._send_json(200, [{
                "rank": h.rank, "score": round(h.score, 6),
                "semantic": round(h.semantic, 6), "lexical": round(h.lexical, 6),
                "filename_match": h.filename_hit, "id": h.file_id,
                "path": h.path, "exists": h.exists,
            } for h in hits])
        except Exception as exc:               # never crash the server loop
            log.error("search failed: %s", exc)
            self._send_json(500, {"error": str(exc)})

    def _handle_reveal(self, params) -> None:
        """Reveal (highlight) a file in Finder via `open -R`. Reveal-only — it
        does NOT launch the file with its app — and only for paths that exist.
        Same-origin only (Host guard + no CORS)."""
        path = params.get("path", [""])[0]
        if not path or not os.path.exists(path):
            self._send_json(404, {"ok": False, "error": "path not found"})
            return
        try:
            subprocess.run(["open", "-R", path], check=False, timeout=5)
            self._send_json(200, {"ok": True})
        except Exception as exc:
            self._send_json(500, {"ok": False, "error": str(exc)})

    # -- responses ----------------------------------------------------------

    def _send_json(self, code: int, body) -> None:
        self._send(code, "application/json; charset=utf-8",
                  json.dumps(body).encode("utf-8"))

    def _send_html(self, html: str) -> None:
        self._send(200, "text/html; charset=utf-8", html.encode("utf-8"))

    def _send(self, code: int, ctype: str, data: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        # No CORS header on purpose: results contain absolute home-dir paths; we
        # never want an arbitrary website to read them off loopback.
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args) -> None:
        pass  # quiet; we have our own logger


def main() -> int:
    log.info("warming embedding model(s)...")
    for lane in shared.LANES:                 # warm every lane run_search will use
        try:
            shared.get_embedder(lane).embed_one("warmup")
        except Exception as exc:
            log.warning("warmup for lane %s failed (loads on first query): %s",
                        lane.name, exc)
    server = ThreadingHTTPServer((HOST, PORT), _Handler)
    log.info("TurboFind ready — open http://%s:%d in your browser", HOST, PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
