"""
serve.py — warm local search server + browser UI for TurboFind.

Loads the model(s) once and reuses the hybrid `run_search` as the CLI, so
queries are instant. The browser UI has a folder tree (scope the search) on the
left and file-type filters (text / pdf / image / video) on the right.

    python serve.py            # then open http://127.0.0.1:8765

Routes:
    GET /                              -> the search UI (HTML)
    GET /folders                       -> indexed directories (for the left tree)
    GET /search?q=&k=&types=&roots=    -> JSON results (filtered)
    GET /reveal?path=                  -> reveal that file in Finder (open -R)

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


INDEX_HTML = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TurboFind</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<style>
 :root{color-scheme:dark}
 *{box-sizing:border-box}
 body{margin:0;height:100vh;display:flex;flex-direction:column;
      font:14px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1115;color:#e8eaed}
 header{padding:12px 20px;border-bottom:1px solid #1f242d;flex:none;display:flex;align-items:center;gap:10px}
 header svg{width:22px;height:22px;flex:none}
 header b{font-size:12px;letter-spacing:.2em;color:#8a8f98}
 .cols{flex:1;display:flex;min-height:0}
 aside{width:152px;flex:none;overflow:auto;padding:12px 10px;border-right:1px solid #1f242d}
 aside.right{border-right:none;border-left:1px solid #1f242d;width:160px;padding:12px 14px}
 .ttl{font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:#6b7280;margin:0 0 10px}
 main{flex:1;display:flex;flex-direction:column;min-width:0;padding:16px 20px;overflow:auto}
 #q{width:100%;font-size:20px;padding:13px 16px;border-radius:12px;border:1px solid #2a2e37;background:#171a21;color:#fff;outline:none}
 #q:focus{border-color:#3b82f6}
 #status{color:#6b7280;font-size:12px;margin:9px 2px;height:14px}
 .row{display:flex;align-items:center;gap:8px;padding:9px 11px;border-radius:9px;cursor:pointer}
 .row:hover,.row.sel{background:#1d2129}
 .ic{font-size:17px;width:22px;text-align:center;flex:none}
 .meta{flex:1;min-width:0}
 .date{font:11px ui-monospace,monospace;color:#6b7280;flex:none;width:50px;text-align:right;margin-right:2px}
 .date b{display:block;color:#9aa0aa;font-weight:600}
 .date span{font-size:9px;letter-spacing:.06em;text-transform:uppercase;color:#4b515c}
 .name{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .path{color:#6b7280;font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .sc{font:11px ui-monospace,monospace;color:#9aa0aa;flex:none}
 .tag{font-size:10px;padding:1px 6px;border-radius:20px;background:#2a3550;color:#9ab4ff;margin-left:6px}
 label.flt{display:flex;align-items:center;gap:8px;padding:6px 4px;cursor:pointer;font-size:13px}
 .fnode{display:flex;align-items:center;gap:4px;font-size:11px;line-height:1.7;white-space:nowrap}
 .fnode input{flex:none}
 .caret{width:12px;display:inline-block;color:#6b7280;cursor:pointer;user-select:none}
 .fname{overflow:hidden;text-overflow:ellipsis;cursor:pointer}
 .cnt{color:#4b515c;font-size:10px}
 .hint{color:#4b515c;font-size:11px;margin-top:8px}
 button.mini{font-size:11px;background:#1d2129;color:#9aa0aa;border:1px solid #2a2e37;border-radius:6px;padding:3px 8px;cursor:pointer;margin-bottom:8px}
</style></head><body>
<header>
  <svg viewBox="0 0 64 64" aria-hidden="true"><path fill="#fff" d="M8 10 L56 10 L52 21 L12 21 Z M34 25 L53 25 L49 35 L30 35 Z M27 10 L45 10 L29 32 L40 32 L18 58 L27 33 L15 33 Z"/></svg>
  <b>TURBOFIND</b>
</header>
<div class="cols">
 <aside class="left">
   <p class="ttl">Folders</p>
   <button class="mini" id="clearF">clear</button>
   <div id="tree"></div>
   <div class="hint">none checked = search everywhere</div>
 </aside>
 <main>
   <input id="q" placeholder="Search by meaning…" autofocus autocomplete="off" spellcheck="false">
   <div id="status">Type · ↓ into results · Space = Quick Look · Enter = open in Finder</div>
   <div id="results"></div>
 </main>
 <aside class="right">
   <p class="ttl">Types</p>
   <label class="flt"><input type="checkbox" class="tfilter" value="text" checked> 📄 Text</label>
   <label class="flt"><input type="checkbox" class="tfilter" value="pdf" checked> 📑 PDF</label>
   <label class="flt"><input type="checkbox" class="tfilter" value="image" checked> 🖼️ Images</label>
   <label class="flt"><input type="checkbox" class="tfilter" value="video" checked> 🎬 Video</label>
 </aside>
</div>
<script>
const q=document.getElementById('q'),R=document.getElementById('results'),S=document.getElementById('status');
let timer=null, rows=[], sel=0;

function icon(p){const e=(p.split('.').pop()||'').toLowerCase();
  if(e==='pdf')return'📑';
  if(['png','jpg','jpeg'].includes(e))return'🖼️';
  if(['mp4','mov','m4v'].includes(e))return'🎬';return'📄';}
function esc(s){return s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
// When the file was added to this machine (creation time). Two-line: day+month
// over year, so users see at a glance how old each result is.
function fmtAdded(ts){if(!ts)return'<span>added</span>—';
  const d=new Date(ts*1000),mo=d.toLocaleString(undefined,{month:'short'});
  return '<b>'+d.getDate()+' '+mo+'</b><span>'+d.getFullYear()+'</span>';}

function render(items){rows=items;sel=0;
  if(!items.length){R.innerHTML='<div class="hint" style="padding:10px">No matches.</div>';return;}
  R.innerHTML=items.map((h,i)=>{
    const name=h.path.split('/').pop(), dir=h.path.slice(0,h.path.length-name.length);
    const pct=Math.max(0,Math.min(100,Math.round(h.score*100)));
    return '<div class="row'+(i===0?' sel':'')+'" data-i="'+i+'">'+
      '<div class="date" title="added to this Mac">'+fmtAdded(h.added)+'</div>'+
      '<div class="ic">'+icon(h.path)+'</div>'+
      '<div class="meta"><div class="name">'+esc(name)+(h.filename_match?'<span class="tag">name</span>':'')+'</div>'+
      '<div class="path">'+esc(dir)+'</div></div>'+
      '<div class="sc">'+h.score.toFixed(2)+'</div></div>';}).join('');
  [...R.children].forEach(el=>{ if(el.dataset.i!==undefined) el.onclick=()=>reveal(+el.dataset.i); });}
function reveal(i){if(rows[i])fetch('/reveal?path='+encodeURIComponent(rows[i].path));}
function preview(i){if(rows[i])fetch('/preview?path='+encodeURIComponent(rows[i].path));}
function setSel(n){if(!rows.length)return;sel=Math.max(0,Math.min(rows.length-1,n));
  [...R.children].forEach((el,i)=>el.classList.toggle('sel',i===sel));
  if(R.children[sel])R.children[sel].scrollIntoView({block:'nearest'});}

function selectedTypes(){const all=[...document.querySelectorAll('.tfilter')];
  const on=all.filter(c=>c.checked).map(c=>c.value);
  return on.length===all.length?[]:on;}              // all on => no filter
function selectedRoots(){return [...document.querySelectorAll('#tree input:checked')].map(c=>c.dataset.path);}

function run(){const v=q.value.trim();
  if(!v){R.innerHTML='';S.textContent='';return;}
  const types=selectedTypes(), roots=selectedRoots();
  let url='/search?q='+encodeURIComponent(v)+'&k=40';
  if(types.length)url+='&types='+types.join(',');
  if(roots.length)url+='&roots='+roots.map(encodeURIComponent).join(',');
  S.textContent='searching…';const t0=performance.now();
  fetch(url).then(r=>r.json()).then(d=>{render(d);
    S.textContent=d.length+' results · '+Math.round(performance.now()-t0)+' ms'
      +(types.length?' · '+types.join('/'):'')+(roots.length?' · '+roots.length+' folder(s)':'');})
   .catch(e=>S.textContent='error: '+e);}
function schedule(){clearTimeout(timer);timer=setTimeout(run,180);}

q.addEventListener('input',schedule);
// Unified keys. While typing, Space types a space (multi-word queries). Press
// Down to step into results — then Space = Quick Look, Enter = open in Finder.
// Enter opens from the box too; a printable key returns you to typing.
document.addEventListener('keydown',e=>{
  const typing = document.activeElement===q;
  if(e.key==='ArrowDown'){e.preventDefault(); setSel(sel+1); if(typing)q.blur();}
  else if(e.key==='ArrowUp'){e.preventDefault(); setSel(sel-1);}
  else if(e.key==='Enter'){e.preventDefault(); reveal(sel);}
  else if(e.key===' '){ if(!typing){e.preventDefault(); preview(sel);} }
  else if(e.key==='Escape'){ if(!typing) q.focus(); }
  else if(!typing && e.key.length===1){ q.focus(); }
});
document.querySelectorAll('.tfilter').forEach(c=>c.addEventListener('change',schedule));

// ---- folder tree ----
function buildTree(dirs){const root={children:{}};
  for(const d of dirs){const parts=d.split('/').filter(Boolean);let node=root,path='';
    for(const part of parts){path+='/'+part;node.children=node.children||{};
      node.children[part]=node.children[part]||{path:path,children:{}};node=node.children[part];}}
  return root;}
function renderTree(node,container,depth){
  const kids=node.children||{};const names=Object.keys(kids).sort();
  for(const name of names){const child=kids[name];
    const hasKids=Object.keys(child.children||{}).length>0;
    const rowEl=document.createElement('div');rowEl.className='fnode';
    rowEl.style.paddingLeft=(depth*12)+'px';
    const caret=document.createElement('span');caret.className='caret';caret.textContent=hasKids?'▸':'';
    const cb=document.createElement('input');cb.type='checkbox';cb.dataset.path=child.path;
    cb.addEventListener('change',schedule);
    const fn=document.createElement('span');fn.className='fname';fn.textContent=name;
    rowEl.append(caret,cb,fn);container.appendChild(rowEl);
    if(hasKids){const sub=document.createElement('div');sub.style.display='none';
      renderTree(child,sub,depth+1);container.appendChild(sub);
      const toggle=()=>{const open=sub.style.display!=='none';sub.style.display=open?'none':'block';caret.textContent=open?'▸':'▾';};
      caret.onclick=toggle;fn.onclick=toggle;}}}
fetch('/folders').then(r=>r.json()).then(dirs=>{
  const t=document.getElementById('tree');renderTree(buildTree(dirs),t,0);
  // auto-open the single-child chain from root down to the first real branch
  let el=t;for(let i=0;i<40;i++){const subs=[...el.children].filter(c=>c.tagName==='DIV'&&c.style&&c.style.display==='none');
    const carets=el.querySelectorAll(':scope > .fnode > .caret');
    if(carets.length===1){carets[0].click();el=el.querySelector(':scope > div[style]');}else break;}
});
document.getElementById('clearF').onclick=()=>{document.querySelectorAll('#tree input:checked').forEach(c=>c.checked=false);schedule();};
</script></body></html>"""


FAVICON_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    '<style>path{fill:#111}@media (prefers-color-scheme:dark){path{fill:#fff}}</style>'
    '<path d="M8 10 L56 10 L52 21 L12 21 Z M34 25 L53 25 L49 35 L30 35 Z '
    'M27 10 L45 10 L29 32 L40 32 L18 58 L27 33 L15 33 Z"/></svg>'
)


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
        if parsed.path in ("/", "/index.html"):
            self._send_html(INDEX_HTML)
        elif parsed.path == "/favicon.svg":
            self._send(200, "image/svg+xml", FAVICON_SVG.encode("utf-8"))
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

    def _send_html(self, html: str) -> None:
        self._send(200, "text/html; charset=utf-8", html.encode("utf-8"))

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
    log.info("TurboFind ready — open http://%s:%d in your browser", HOST, PORT)
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
