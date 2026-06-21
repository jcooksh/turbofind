"""
ingest.py — TurboFind background indexing daemon (the "daemon" referred to in
the brief; this project has no separate daemon.py).

Watches a folder (default ~/Documents) with `watchdog` and keeps the turbovec
semantic index in lock-step with the filesystem:

  * create / modify  -> embed, upsert into the index, mirror into Spotlight
  * delete           -> O(1) `index.remove(id)` + drop from the sidecar + Spotlight
  * move / rename     -> treated as delete(src) + upsert(dest)

Modality (see shared.MULTI_MODAL):
  * text-only   -> .txt/.md via all-MiniLM-L6-v2 (384-dim)
  * multimodal  -> additionally .png/.jpg images and .mp4/.mov video (one frame
                   every VIDEO_FRAME_INTERVAL_SEC sampled with ffmpeg) through
                   the CLIP vision encoder, plus text via the CLIP text encoder,
                   all in one 512-dim space for cross-modal search.

Correctness details learned from turbovec 0.8.0:

  * `add_with_ids` raises `ValueError` if the id is already present, so a *modify*
    must `remove(id)` first. We always do remove-then-add (a true upsert).
  * `prepare()` (re)builds the TurboQuant search structure and must be called
    after mutations; `write()` then persists an already-search-ready index.

Filesystem events are noisy — editors emit several `modified` events per save —
so each path is debounced, and the expensive `prepare() + write() + save()`
flush is coalesced so a burst of edits costs a single persist.

The big initial scan runs on a low-priority background thread (real macOS
`QOS_CLASS_BACKGROUND` + a sleep throttle) so indexing millions of files leaves
the machine responsive; live watch events are handled immediately in parallel.

Run with:  python ingest.py            (watches WATCH_DIR from shared.py)
           python ingest.py ~/Notes    (override the watched directory)
"""

from __future__ import annotations

import ctypes
import logging
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional

from watchdog.events import (
    DirDeletedEvent,
    DirModifiedEvent,
    FileSystemEvent,
    FileSystemEventHandler,
)
from watchdog.observers import Observer

import shared
import spotlight
from shared import (
    PathMapping,
    get_logger,
    load_index,
    modality_of,
    read_text_file,
    stable_id,
)

log = get_logger("turbofind.ingest")

# Debounce window for per-file events, and the coalescing window for persists.
DEBOUNCE_SECONDS = 0.75
FLUSH_SECONDS = 1.0

# Background scan throttle: sleep this long after each batch of files so the
# scan never saturates the CPU (mimics qos_class_background on top of the real
# thread QoS set in _enter_background_qos).
SCAN_BATCH = 64
SCAN_THROTTLE_SEC = 0.05

# ffmpeg subprocess timeout per video (seconds).
FFMPEG_TIMEOUT_SEC = 120

# Directories never worth indexing — dev junk, OS-protected, caches. Pruned
# during the walk (along with any hidden dir) so a full-home scan stays sane.
IGNORE_DIRS = frozenset({
    "node_modules", ".git", ".venv", "venv", "env", "__pycache__", ".turbofind",
    "site-packages", "Library", ".Trash", ".cache", ".npm", ".cargo", ".rustup",
    "DerivedData", ".gradle", ".m2", "Caches", "Pods", ".next", "dist", "build",
    ".tox", ".mypy_cache", ".pytest_cache", "target",
})

# macOS package/bundle directories — opaque, full of resource noise. Pruned by
# suffix so we never index inside an .app, .framework, photo library, etc.
IGNORE_DIR_SUFFIXES = (
    ".app", ".bundle", ".framework", ".photoslibrary", ".xcodeproj",
    ".xcworkspace", ".lproj", ".plugin", ".kext", ".pkg",
)


# ===========================================================================
# Progress bar (dependency-free; only draws to a real TTY)
# ===========================================================================

class _Progress:
    """A tiny carriage-return progress bar: percent, count, rate, ETA, current
    file. No-op when the stream isn't a terminal (e.g. piped/redirected)."""

    def __init__(self, total: int, stream=None, width: int = 30) -> None:
        self.total = total
        self.n = 0
        self.width = width
        self.stream = stream or sys.stderr
        self.start = time.monotonic()
        self._last_draw = 0.0
        self.enabled = (total > 0 and hasattr(self.stream, "isatty")
                        and self.stream.isatty())

    def update(self, step: int = 1, label: str = "") -> None:
        self.n += step
        if not self.enabled:
            return
        now = time.monotonic()
        # Throttle redraws to ~10/s so drawing never dominates the work.
        if now - self._last_draw < 0.1 and self.n < self.total:
            return
        self._last_draw = now
        frac = self.n / self.total if self.total else 1.0
        filled = int(frac * self.width)
        bar = "█" * filled + "░" * (self.width - filled)
        elapsed = max(1e-6, now - self.start)
        rate = self.n / elapsed
        remaining = (self.total - self.n) / rate if rate > 0 else 0.0
        eta = f"{int(remaining) // 60:02d}:{int(remaining) % 60:02d}"
        line = (f"\r  [{bar}] {frac * 100:5.1f}%  {self.n}/{self.total}"
                f"  {rate:5.0f} files/s  ETA {eta}  {label[:28]}")
        # ljust to overwrite any leftover characters from a longer prior line.
        self.stream.write(line.ljust(96)[:120])
        self.stream.flush()

    def finish(self) -> None:
        if self.enabled:
            self.stream.write("\n")
            self.stream.flush()


# ===========================================================================
# Low-priority thread context (real macOS background QoS + throttle)
# ===========================================================================

# qos_class_t values from <sys/qos.h>.
_QOS_CLASS_BACKGROUND = 0x09


def _enter_background_qos() -> None:
    """Demote the *current* thread to macOS QOS_CLASS_BACKGROUND so the kernel
    schedules it behind interactive work (and throttles its I/O). Best-effort:
    a no-op on non-Darwin or if the symbol is missing."""
    try:
        libc = ctypes.CDLL(None)
        fn = libc.pthread_set_qos_class_self_np
        fn.restype = ctypes.c_int
        rc = fn(ctypes.c_uint(_QOS_CLASS_BACKGROUND), ctypes.c_int(0))
        if rc != 0:
            log.debug("pthread_set_qos_class_self_np returned %d", rc)
    except Exception as exc:
        log.debug("could not set background QoS: %s", exc)


# ===========================================================================
# Media decoding (multimodal mode)
# ===========================================================================

def _load_image(path: Path):
    """Load an image file as a PIL.Image, or None if unreadable/too large."""
    try:
        if path.stat().st_size > shared.MAX_IMAGE_BYTES:
            log.debug("skipping oversized image %s", path)
            return None
        from PIL import Image
        with Image.open(path) as img:
            img.load()              # force decode while the file handle is open
            return img.convert("RGB")
    except Exception as exc:
        log.warning("could not load image %s: %s", path, exc)
        return None


def _terminate(proc) -> None:
    """Stop an ffmpeg subprocess promptly (TERM, then KILL)."""
    try:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
    except Exception:
        pass


def _extract_video_frames(path: Path, should_stop=None) -> List[Path]:
    """Sample one frame every VIDEO_FRAME_INTERVAL_SEC (capped) using ffmpeg.

    Returns a list of JPEG frame paths inside a freshly-created temp directory
    that the CALLER must clean up. Returns [] (and cleans up its own temp dir)
    on ANY failure — ffmpeg missing, bad video, timeout, permission error, fd
    exhaustion — or if `should_stop()` becomes true (the ffmpeg child is killed
    so shutdown stays responsive)."""
    if should_stop is None:
        should_stop = lambda: False
    tmpdir = Path(tempfile.mkdtemp(prefix="turbofind_frames_"))
    pattern = str(tmpdir / "f_%05d.jpg")
    cmd = [
        "ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(path),
        "-vf", f"fps=1/{shared.VIDEO_FRAME_INTERVAL_SEC}",
        "-frames:v", str(shared.VIDEO_MAX_FRAMES),
        pattern,
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        log.warning("ffmpeg not found on PATH; cannot index video %s", path)
        _rmtree(tmpdir)
        return []
    except Exception as exc:   # PermissionError, EMFILE/ENOMEM (OSError), ...
        log.warning("could not launch ffmpeg for %s: %s", path, exc)
        _rmtree(tmpdir)
        return []

    try:
        start = time.monotonic()
        while True:
            try:
                proc.wait(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                pass
            if should_stop():
                log.info("aborting ffmpeg for %s (shutdown requested)", path)
                _terminate(proc)
                _rmtree(tmpdir)
                return []
            if time.monotonic() - start > FFMPEG_TIMEOUT_SEC:
                log.warning("ffmpeg timed out for %s", path)
                _terminate(proc)
                _rmtree(tmpdir)
                return []
        if proc.returncode != 0:
            log.warning("ffmpeg exited %s for %s", proc.returncode, path)
            _rmtree(tmpdir)
            return []
    except Exception as exc:
        log.warning("ffmpeg error for %s: %s", path, exc)
        _terminate(proc)
        _rmtree(tmpdir)
        return []

    frames = sorted(tmpdir.glob("f_*.jpg"))
    if not frames:
        _rmtree(tmpdir)
    return frames


def _rmtree(directory: Path) -> None:
    import shutil
    shutil.rmtree(directory, ignore_errors=True)


# ===========================================================================
# Index manager — owns the index + sidecar and all mutations to them.
# ===========================================================================

class IndexManager:
    """
    Owns ONE lane's turbovec index + sidecar and all mutations to them.

    Every mutation goes through here under one lock, so the watchdog observer
    thread and the debounce/flush timer threads can never corrupt shared state.
    Persistence is coalesced: mutations set a dirty flag and (re)arm a short
    timer; one flush then does `prepare()` + `index.write()` + `mapping.save()`.
    In hybrid mode there is one IndexManager per lane (text/MiniLM + media/CLIP),
    coordinated by `Coordinator`.
    """

    def __init__(self, lane: shared.Lane) -> None:
        self._lane = lane
        self._lock = threading.RLock()
        self._embedder = shared.get_embedder(lane)
        self._mapping = PathMapping(lane.mapping_path).load()
        # Create the index if it does not exist yet so the very first file works.
        self._index = load_index(lane, create_if_missing=True)
        self._dirty = False
        self._flush_timer: Optional[threading.Timer] = None

    # -- mutations ----------------------------------------------------------

    def upsert(self, path: Path, should_stop=None) -> None:
        """Embed `path` (routed by modality) and insert/replace its vector. No-op
        for unsupported/empty/unreadable files. Mirrors the item into Spotlight.

        `should_stop` (used by the background scanner) lets a long video decode
        abort promptly on shutdown."""
        modality = modality_of(path)
        if modality is None:
            return
        vector = self._embed_path(path, modality, should_stop)   # (1, DIM) or None
        if vector is None:
            return
        file_id = stable_id(path)
        abs_path = str(path.resolve())
        ids = self._as_id_array(file_id)
        with self._lock:
            try:
                # turbovec rejects a duplicate id -> remove first for a clean upsert.
                if self._index.contains(file_id):
                    self._index.remove(file_id)
                self._index.add_with_ids(vector, ids)
            except Exception as exc:
                log.error("index add failed for %s (id=%d): %s", path, file_id, exc)
                return
            self._mapping.put(file_id, abs_path)
            self._mark_dirty()
            # Issue the best-effort Spotlight mirror UNDER the lock so that an
            # add and a delete for the same path are submitted to CoreSpotlight
            # in the same order their index mutations committed (no stale-item
            # race). The pyobjc call is async and returns immediately. Never
            # raises into the daemon.
            spotlight.index_item(
                file_id, abs_path,
                keywords=spotlight.keywords_for(abs_path, extra=[modality]),
                description=f"{modality} file indexed by TurboFind",
            )
        log.info("indexed  [%s] %s", modality, abs_path)

    def delete(self, path: Path) -> None:
        """Remove `path`'s vector, mapping entry, and Spotlight item, if present."""
        file_id = stable_id(path)
        with self._lock:
            if not self._mapping.contains(file_id) and not self._index.contains(file_id):
                return
            try:
                self._index.remove(file_id)   # O(1); silent if absent
            except Exception as exc:
                log.error("index remove failed (id=%d): %s", file_id, exc)
            self._mapping.remove(file_id)
            self._mark_dirty()
            spotlight.delete_item(file_id)    # ordered with the mutation (see upsert)
        log.info("removed  %s", path)

    # -- per-modality embedding --------------------------------------------

    def _embed_path(self, path: Path, modality: str, should_stop=None):
        """Return a (1, DIM) float32 vector for `path`, or None to skip. Any
        decode/model failure is logged and swallowed so the daemon survives."""
        try:
            if modality == "text":
                text = read_text_file(path)
                if text is None:
                    return None
                return self._embedder.embed_one(text)
            if modality == "image":
                img = _load_image(path)
                if img is None:
                    return None
                return self._embedder.embed_images([img])
            if modality == "video":
                return self._embed_video(path, should_stop)
        except Exception as exc:   # embedding/model failure must not kill the daemon
            log.error("embedding failed for %s: %s", path, exc)
        return None

    def _embed_video(self, path: Path, should_stop=None):
        """Sample frames with ffmpeg, embed each via CLIP, mean-pool + renormalise
        into a single representative (1, DIM) vector for the video."""
        frames = _extract_video_frames(path, should_stop)
        if not frames:
            return None
        tmpdir = frames[0].parent
        try:
            import numpy as np
            images = [img for img in (_load_image(fp) for fp in frames) if img is not None]
            if not images:
                return None
            frame_vecs = self._embedder.embed_images(images)     # (n, DIM), normalised
            pooled = frame_vecs.mean(axis=0, keepdims=True)      # average the frames
            pooled = pooled / np.clip(np.linalg.norm(pooled, axis=1, keepdims=True),
                                      1e-12, None)
            return np.ascontiguousarray(pooled, dtype=np.float32)
        finally:
            _rmtree(tmpdir)

    # -- reconciliation helpers (driven by Coordinator) --------------------

    def needs_index(self, file_id: int) -> bool:
        """True if this id is missing from EITHER the index or the sidecar. Read
        under the lock — the watcher/timer threads may be mutating the native
        index concurrently and a raw native read racing add/remove is undefined."""
        with self._lock:
            return not (self._index.contains(file_id) and self._mapping.contains(file_id))

    def prune_missing(self, seen: set) -> int:
        """Drop mapping/index entries (of THIS lane) for files not in `seen` whose
        path no longer exists. Returns the count pruned."""
        pruned = 0
        for file_id, mapped_path in self._mapping.items():
            if file_id in seen:
                continue
            if not Path(mapped_path).exists():
                with self._lock:
                    try:
                        self._index.remove(file_id)
                    except Exception:
                        pass
                    self._mapping.remove(file_id)
                    self._mark_dirty()
                spotlight.delete_item(file_id)
                pruned += 1
        return pruned

    def __len__(self) -> int:
        return len(self._mapping)

    # -- persistence (coalesced) -------------------------------------------

    def _mark_dirty(self) -> None:
        """Mark state dirty and ensure a coalescing flush is scheduled. Caller
        holds the lock.

        The timer is armed only when none is already pending and is *not*
        re-armed on subsequent dirty marks. This is a ceiling — a flush happens
        within FLUSH_SECONDS of the *first* unflushed mutation — not a debounce.
        A debounce would let a sustained mutation stream (e.g. a bulk copy or
        `git checkout` into WATCH_DIR) perpetually defer persistence and never
        flush at all."""
        self._dirty = True
        if self._flush_timer is None:
            self._flush_timer = threading.Timer(FLUSH_SECONDS, self.flush)
            self._flush_timer.daemon = True
            self._flush_timer.start()

    def flush(self, force: bool = False) -> None:
        """Persist the index + sidecar to disk if dirty (or `force`)."""
        with self._lock:
            # Drop the handle first so the next dirty mark arms a fresh ceiling
            # (this also runs on the timer thread, which is about to terminate).
            self._flush_timer = None
            if not (self._dirty or force):
                return
            try:
                self._index.prepare()        # rebuild search structure
                self._write_index_atomic()   # persist index (crash-safe swap)
                self._mapping.save()         # persist id->path map (atomic+fsync)
                self._dirty = False
                log.debug("flushed index (%d vectors) + mapping (%d paths)",
                          len(self._index), len(self._mapping))
            except Exception as exc:
                log.error("flush failed; will retry on next change: %s", exc)

    def close(self) -> None:
        """Cancel any pending flush timer, wait for it to finish, then do a final
        synchronous flush. Call only after the watcher and its debounce timers
        have been drained (see TurboFindEventHandler.cancel_all), so no late
        mutation can re-dirty state after this returns."""
        with self._lock:
            timer = self._flush_timer
            self._flush_timer = None
        if timer is not None:
            timer.cancel()
            timer.join(timeout=10)   # let an already-firing flush complete
        self.flush(force=True)       # runs on the caller (main) thread

    # -- helpers ------------------------------------------------------------

    def _write_index_atomic(self) -> None:
        """Write the index to a sibling temp file then atomically swap it in, so
        a crash mid-write can never leave a truncated/corrupt .tvim. (turbovec's
        own write() is not atomic; PathMapping.save already is.)"""
        target = self._lane.index_path
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".tmp")
        self._index.write(str(tmp))
        os.replace(tmp, target)   # atomic within the same directory

    @staticmethod
    def _as_id_array(file_id: int):
        import numpy as np
        return np.array([file_id], dtype=np.uint64)


def iter_supported_files(root: Path):
    """Yield indexable files under `root`. Uses os.walk (not rglob) so we can
    (a) prune junk/protected/package dirs in place and (b) survive permission
    errors per-directory instead of aborting the whole walk on the first
    unreadable folder (e.g. ~/Library). followlinks=False avoids symlink loops."""
    suffixes = shared.SUPPORTED_SUFFIXES
    for dirpath, dirnames, filenames in os.walk(
            root, topdown=True, onerror=lambda _e: None, followlinks=False):
        dirnames[:] = [d for d in dirnames
                       if d not in IGNORE_DIRS and not d.startswith(".")
                       and not d.lower().endswith(IGNORE_DIR_SUFFIXES)]
        for name in filenames:
            if name.startswith("."):
                continue                       # skip hidden/temp files (e.g. .DS_Store)
            if os.path.splitext(name)[1].lower() in suffixes:
                yield Path(dirpath) / name


# ===========================================================================
# Coordinator — one IndexManager per lane; single walk, dispatched by suffix.
# ===========================================================================

class Coordinator:
    """
    Fans files out to the right lane's IndexManager and runs a single shared scan
    (one progress bar, one walk) across all lanes. In text-only mode it wraps one
    manager; in hybrid mode it wraps the text (MiniLM) and media (CLIP) managers.
    """

    def __init__(self) -> None:
        # One manager per active lane. May raise RuntimeError on a dim mismatch.
        self._managers: Dict[str, IndexManager] = {
            lane.name: IndexManager(lane) for lane in shared.LANES
        }

    def _manager_for(self, path: Path) -> Optional[IndexManager]:
        lane = shared.lane_for(path)
        return self._managers.get(lane.name) if lane else None

    def upsert(self, path: Path, should_stop=None) -> None:
        m = self._manager_for(path)
        if m is not None:
            m.upsert(path, should_stop=should_stop)

    def delete(self, path: Path) -> None:
        m = self._manager_for(path)
        if m is not None:
            m.delete(path)

    def total_indexed(self) -> int:
        return sum(len(m) for m in self._managers.values())

    def scan(self, root: Path, should_stop=None,
            batch: int = SCAN_BATCH, throttle: float = SCAN_THROTTLE_SEC,
            progress: bool = False) -> None:
        """Reconcile every lane with `root` in a single walk. Files dispatch to
        their lane by suffix. Pruning happens per-lane and ONLY on a complete
        walk (a partial scan must not delete files it never reached)."""
        if should_stop is None:
            should_stop = lambda: False
        log.info("scan of %s starting ...", root)

        prog: Optional[_Progress] = None
        saved_level: Optional[int] = None
        if progress:
            total = sum(1 for _ in iter_supported_files(root))
            log.info("indexing %d files under %s", total, root)
            prog = _Progress(total)
            if prog.enabled:
                saved_level = log.level
                log.setLevel(logging.WARNING)

        seen: Dict[str, set] = {name: set() for name in self._managers}
        indexed = scanned = 0
        completed = True
        try:
            for path in iter_supported_files(root):
                if should_stop():
                    completed = False
                    log.info("scan interrupted after %d files", scanned)
                    break
                lane = shared.lane_for(path)
                if lane is None:
                    continue
                m = self._managers[lane.name]
                file_id = stable_id(path)
                seen[lane.name].add(file_id)
                if m.needs_index(file_id):
                    m.upsert(path, should_stop=should_stop)
                    indexed += 1
                scanned += 1
                if prog:
                    prog.update(1, path.name)
                if throttle and scanned % batch == 0:
                    time.sleep(throttle)   # yield CPU/IO to interactive work
        finally:
            if prog:
                prog.finish()
            if saved_level is not None:
                log.setLevel(saved_level)

        pruned = 0
        if completed:
            for name, m in self._managers.items():
                pruned += m.prune_missing(seen[name])
        for m in self._managers.values():
            m.flush(force=True)
        total = self.total_indexed()
        log.info("scan done: %d new, %d pruned, %d total (%s)",
                 indexed, pruned, total, "complete" if completed else "interrupted")
        # Tiny index = bad first impression: every query returns the same handful
        # of files. Usually means an almost-empty folder (e.g. iCloud moved your
        # Documents). Steer the user at a folder with real content.
        if completed and total < 25:
            log.warning(
                "only %d files indexed under %s — too few for useful semantic "
                "search (every query returns the same few). Point ingest at a "
                "folder with your actual files, e.g. your whole home:  "
                "TURBOFIND_MULTI_MODAL=1 python ingest.py --once ~", total, root)

    def initial_sync(self, root: Path, progress: bool = False) -> None:
        """Synchronous, unthrottled full scan (foreground / tests)."""
        self.scan(root, should_stop=None, throttle=0.0, progress=progress)

    def close(self) -> None:
        for m in self._managers.values():
            m.close()


# ===========================================================================
# Background scanner — runs the big initial scan off the main thread.
# ===========================================================================

class BackgroundScanner(threading.Thread):
    """
    Runs the initial reconciliation scan on a low-priority background thread.

    The thread demotes itself to real macOS QOS_CLASS_BACKGROUND and the scan
    throttles itself (sleeps after every batch), so indexing a huge tree — think
    two million files — stays off the critical path and the machine remains
    responsive for normal use. The watcher runs concurrently, so files changed
    during the scan are still picked up live.
    """

    def __init__(self, coordinator: "Coordinator", root: Path,
                batch: int = SCAN_BATCH, throttle: float = SCAN_THROTTLE_SEC) -> None:
        super().__init__(name="turbofind-scan", daemon=True)
        self._coordinator = coordinator
        self._root = root
        self._batch = batch
        self._throttle = throttle
        self._stop = threading.Event()

    def run(self) -> None:
        _enter_background_qos()
        try:
            self._coordinator.scan(self._root, should_stop=self._stop.is_set,
                                   batch=self._batch, throttle=self._throttle)
        except Exception as exc:
            log.exception("background scan crashed: %s", exc)

    def stop(self) -> None:
        self._stop.set()


# ===========================================================================
# Watchdog event handler -> debounced dispatch into the IndexManager.
# ===========================================================================

class TurboFindEventHandler(FileSystemEventHandler):
    """
    Translates raw watchdog events into debounced upsert/delete calls.

    Per-path debouncing collapses the storm of `modified` events an editor emits
    on save into a single re-embed. Directory events are ignored; only supported
    file types reach the index.
    """

    def __init__(self, coordinator: "Coordinator") -> None:
        super().__init__()
        self._coordinator = coordinator
        self._lock = threading.Lock()
        self._timers: Dict[str, threading.Timer] = {}

    # -- watchdog callbacks (run on the observer thread) -------------------

    def on_created(self, event: FileSystemEvent) -> None:
        if not event.is_directory:
            self._schedule(event.src_path, self._coordinator.upsert)

    def on_modified(self, event: FileSystemEvent) -> None:
        if not event.is_directory:
            self._schedule(event.src_path, self._coordinator.upsert)

    def on_deleted(self, event: FileSystemEvent) -> None:
        if not isinstance(event, DirDeletedEvent):
            self._schedule(event.src_path, self._coordinator.delete)

    def on_moved(self, event: FileSystemEvent) -> None:
        # A rename is a delete of the old path and an upsert of the new one.
        if not event.is_directory:
            self._schedule(event.src_path, self._coordinator.delete)
            dest = getattr(event, "dest_path", None)
            if dest:
                self._schedule(dest, self._coordinator.upsert)

    # -- debounce -----------------------------------------------------------

    def _schedule(self, raw_path: str, action) -> None:
        """Debounce `action(path)` per (path, action-kind)."""
        path = Path(raw_path)
        if path.suffix.lower() not in shared.SUPPORTED_SUFFIXES:
            return
        key = f"{action.__name__}:{path}"

        def run() -> None:
            try:
                action(path)
            except Exception as exc:  # a handler crash must not stop the watcher
                log.exception("handler error for %s: %s", path, exc)
            finally:
                # Remove ourselves only if we're still the registered timer for
                # this key (a newer event may have replaced us). Removing at the
                # END — not the start — keeps an in-flight action visible to
                # cancel_all() so shutdown can wait for it to finish.
                with self._lock:
                    if self._timers.get(key) is timer:
                        self._timers.pop(key, None)

        with self._lock:
            existing = self._timers.get(key)
            if existing is not None:
                existing.cancel()
            timer = threading.Timer(DEBOUNCE_SECONDS, run)
            timer.daemon = True
            self._timers[key] = timer
            timer.start()

    def cancel_all(self) -> None:
        """Cancel pending debounce timers and wait for any in-flight action to
        finish, so no upsert/delete is still mutating the index after this
        returns. Joins are done outside the lock to avoid deadlocking against
        run()'s finally block."""
        with self._lock:
            timers = list(self._timers.values())
            self._timers.clear()
        for timer in timers:
            timer.cancel()
        for timer in timers:
            timer.join(timeout=10)


# ===========================================================================
# Entry point
# ===========================================================================

def main(argv: Optional[list[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    once = "--once" in argv                       # index once and exit (no watch)
    positionals = [a for a in argv if not a.startswith("-")]
    watch_dir = Path(positionals[0]).expanduser().resolve() if positionals else shared.WATCH_DIR

    if not watch_dir.is_dir():
        log.error("watch directory does not exist: %s", watch_dir)
        return 1

    shared.DATA_DIR.mkdir(parents=True, exist_ok=True)
    log.info("TurboFind %s starting", "one-shot index" if once else "daemon")
    log.info("  watching : %s", watch_dir)
    log.info("  mode     : %s", "hybrid (MiniLM text + CLIP media)"
             if shared.MULTI_MODAL else "text (MiniLM)")
    for lane in shared.LANES:
        log.info("  lane %-5s: %s", lane.name, lane.index_path)

    try:
        coordinator = Coordinator()
    except RuntimeError as exc:   # e.g. dim mismatch on a stale index
        log.error("%s", exc)
        return 2

    # One-shot: synchronously scan the tree, persist, and exit — no watcher, no
    # second terminal. Ideal for a quick try.
    if once:
        try:
            coordinator.initial_sync(watch_dir, progress=True)   # live progress bar
        finally:
            coordinator.close()
        log.info("done.")
        return 0

    # Start the watcher FIRST so live changes are captured even while the big
    # initial scan is still running on its low-priority background thread.
    handler = TurboFindEventHandler(coordinator)
    observer = Observer()
    observer.schedule(handler, str(watch_dir), recursive=True)
    observer.start()
    log.info("watching for changes (Ctrl-C to stop)...")

    scanner = BackgroundScanner(coordinator, watch_dir)
    scanner.start()

    stop = threading.Event()

    def _shutdown(signum, _frame):
        log.info("signal %s received; shutting down...", signum)
        stop.set()

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    try:
        while not stop.is_set():
            stop.wait(1.0)
    finally:
        # Join the scanner to COMPLETION before closing the manager: a bounded
        # join could return while an in-flight upsert is still running, letting
        # it mutate the index after the "final" flush. should_stop aborts the
        # long ffmpeg step, so the unbounded join still returns promptly.
        scanner.stop()
        scanner.join()
        observer.stop()
        observer.join()
        handler.cancel_all()
        coordinator.close()        # final flush so nothing is lost
        log.info("stopped cleanly.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
