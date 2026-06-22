"""
shared.py — Global state, configuration, and shared primitives for TurboFind.

TurboFind is a private, fully-local semantic file explorer for macOS. This module
is the single source of truth shared by the ingest daemon (`ingest.py`) and the
search CLI (`search.py`). Centralising it here guarantees that documents and
queries are embedded by the *exact* same model with the *exact* same normalisation,
and that file paths are hashed to ids identically on both sides.

Key design facts (verified empirically against turbovec 0.8.0):

  * `turbovec.IdMapIndex` stores only `(uint64 id -> compressed vector)`. It never
    stores the file path or the file's text. We therefore keep an external
    `paths_mapping.json` sidecar that maps `id -> absolute path`.
  * Vectors passed to the index must be **C-contiguous float32** arrays of shape
    `(n, dim)`; `dim` must be a positive multiple of 8 (384 qualifies).
  * Embeddings are L2-normalised so that the index's inner-product score equals
    cosine similarity in the range [-1, 1], which is what `search.py` displays.

Everything here runs offline. The only network access a stock install needs is the
one-time download of the sentence-transformers model into the local HuggingFace
cache; once cached, `HF_HUB_OFFLINE` keeps the whole pipeline air-gapped.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

import numpy as np

# ---------------------------------------------------------------------------
# Models download from HuggingFace on FIRST use, then load from local cache.
# Only the (public) model weights are ever fetched — your files and queries are
# embedded locally and never leave the machine. For a guaranteed no-network run
# after the first download, set TURBOFIND_OFFLINE=1 (forces HF fully offline).
# ---------------------------------------------------------------------------
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
if os.environ.get("TURBOFIND_OFFLINE", "").strip().lower() in {"1", "true", "yes", "on"}:
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")


# ===========================================================================
# Configuration
# ===========================================================================

def _env_path(name: str, default: Path) -> Path:
    """Read a filesystem path from the environment, falling back to `default`."""
    raw = os.environ.get(name)
    return Path(raw).expanduser().resolve() if raw else default


# Directory whose files we semantically index. Override with TURBOFIND_WATCH_DIR.
WATCH_DIR: Path = _env_path("TURBOFIND_WATCH_DIR", Path.home() / "Documents")

# Where the index + sidecar live. Kept *outside* the watched tree so the daemon
# never indexes its own data files. Override with TURBOFIND_DATA_DIR.
DATA_DIR: Path = _env_path("TURBOFIND_DATA_DIR", Path.home() / ".turbofind")

def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


# ---------------------------------------------------------------------------
# Lanes & modality (HYBRID architecture).
#
# Every indexed file belongs to exactly one "lane" — its own model, vector
# dimension, turbovec index, and sidecar:
#
#   * text lane  — .txt/.md via all-MiniLM-L6-v2 (384-dim). Purpose-built for
#                  document/prose semantics.
#   * media lane — .png/.jpg/.mp4/.mov via a local CLIP model (512-dim), so a
#                  text query matches images and video frames cross-modally.
#
# MULTI_MODAL=False -> text lane only.
# MULTI_MODAL=True  -> BOTH lanes (hybrid). Text files go through MiniLM (sharp
#                      on prose); media goes through CLIP. Search queries every
#                      lane and merges. This beats the old approach of embedding
#                      prose with CLIP's weak caption-grade text encoder.
#
# Each lane has its OWN index file and load_index() hard-validates dim, so the
# 384-dim text index and 512-dim media index can never collide.
# ---------------------------------------------------------------------------
MULTI_MODAL: bool = _env_bool("TURBOFIND_MULTI_MODAL", False)

TEXT_MODEL_NAME: str = "sentence-transformers/all-MiniLM-L6-v2"
TEXT_EMBED_DIM: int = 384
CLIP_MODEL_NAME: str = "laion/CLIP-ViT-B-32-256x256-DataComp-S34B-b86K"
CLIP_EMBED_DIM: int = 512        # ViT-B/32 projection dim

INDEX_BIT_WIDTH: int = 4         # 4-bit TurboQuant compression

TEXT_SUFFIXES: frozenset[str] = frozenset({".txt", ".md", ".markdown", ".text", ".pdf"})
IMAGE_SUFFIXES: frozenset[str] = frozenset({".png", ".jpg", ".jpeg"})
VIDEO_SUFFIXES: frozenset[str] = frozenset({".mp4", ".mov", ".m4v"})


@dataclass(frozen=True)
class Lane:
    """One indexing lane: a model + vector dim + the file types it owns + its
    own on-disk index/sidecar paths."""
    name: str            # "text" | "media"
    kind: str            # "text" (sentence-transformers) | "clip" (open_clip)
    model_name: str
    dim: int
    suffixes: frozenset
    index_path: Path
    mapping_path: Path


TEXT_LANE = Lane(
    "text", "text", TEXT_MODEL_NAME, TEXT_EMBED_DIM, TEXT_SUFFIXES,
    DATA_DIR / "mac_search.tvim", DATA_DIR / "paths_mapping.json",
)
MEDIA_LANE = Lane(
    "media", "clip", CLIP_MODEL_NAME, CLIP_EMBED_DIM, IMAGE_SUFFIXES | VIDEO_SUFFIXES,
    DATA_DIR / "mac_search.clip.tvim", DATA_DIR / "paths_mapping.clip.json",
)

# Hybrid turns on if explicitly requested OR a media (CLIP) index already exists
# on disk. This removes a sharp footgun: once you've built the media lane, every
# command (search / serve / ingest) auto-includes it — you can't half-run by
# forgetting TURBOFIND_MULTI_MODAL=1 and silently get the text lane only.
# (To go back to pure text, delete mac_search.clip.tvim / paths_mapping.clip.json.)
MULTI_MODAL = MULTI_MODAL or MEDIA_LANE.index_path.exists()
LANES: List[Lane] = [TEXT_LANE, MEDIA_LANE] if MULTI_MODAL else [TEXT_LANE]
SUPPORTED_SUFFIXES: frozenset = frozenset().union(*(lane.suffixes for lane in LANES))

# Guard rails for reading files into memory.
MAX_FILE_BYTES: int = 5 * 1024 * 1024        # skip text files larger than 5 MiB
MAX_IMAGE_BYTES: int = 64 * 1024 * 1024      # skip absurdly large images (64 MiB)
MAX_PDF_BYTES: int = 100 * 1024 * 1024       # PDFs can be big; cap at 100 MiB
PDF_MAX_PAGES: int = 100                      # cap pages parsed per PDF (bounds cost)
PDF_MAX_CHARS: int = 400_000                  # stop after this much extracted text

# Video frame sampling (media lane).
VIDEO_FRAME_INTERVAL_SEC: int = 10           # sample one frame every N seconds
VIDEO_MAX_FRAMES: int = 12                   # cap frames per video (bounds cost)

# Sidecar schema version — lets us detect/abort on incompatible old files.
MAPPING_SCHEMA_VERSION: int = 1


def lane_for(path: os.PathLike[str] | str) -> Optional["Lane"]:
    """Return the lane that owns this file's suffix, or None if unindexable."""
    suffix = Path(path).suffix.lower()
    for lane in LANES:
        if suffix in lane.suffixes:
            return lane
    return None


def modality_of(path: os.PathLike[str] | str) -> Optional[str]:
    """Return 'text' | 'image' | 'video' for an indexable file, else None."""
    suffix = Path(path).suffix.lower()
    if suffix in TEXT_SUFFIXES:
        return "text"
    if MULTI_MODAL and suffix in IMAGE_SUFFIXES:
        return "image"
    if MULTI_MODAL and suffix in VIDEO_SUFFIXES:
        return "video"
    return None


# ===========================================================================
# Logging
# ===========================================================================

def get_logger(name: str) -> logging.Logger:
    """Return a process-wide configured logger (idempotent)."""
    logger = logging.getLogger(name)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stderr)
        handler.setFormatter(
            logging.Formatter("%(asctime)s  %(levelname)-7s  %(name)s: %(message)s",
                              datefmt="%H:%M:%S")
        )
        logger.addHandler(handler)
        logger.setLevel(os.environ.get("TURBOFIND_LOG_LEVEL", "INFO").upper())
        logger.propagate = False
    return logger


log = get_logger("turbofind")


# ===========================================================================
# Stable id derivation
# ===========================================================================

def stable_id(path: os.PathLike[str] | str) -> int:
    """
    Map an absolute file path to a stable, collision-resistant uint64 id.

    The same path always yields the same id, so a file modification re-uses the
    id (enabling in-place upsert) and a deletion can recompute the id to remove
    the right entry. We hash the *resolved absolute* path with BLAKE2b and take
    the low 8 bytes => a 64-bit unsigned integer.
    """
    abs_path = str(Path(path).expanduser().resolve())
    digest = hashlib.blake2b(abs_path.encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(digest, "big", signed=False)


# ===========================================================================
# Path mapping sidecar  (id -> absolute path)
# ===========================================================================

class PathMapping:
    """
    Thread-safe, crash-safe key/value store backing `paths_mapping.json`.

    turbovec keeps only `(uint64 id -> vector)`; this class supplies the missing
    `id -> absolute path` half. JSON object keys must be strings, so ids are
    stored as decimal strings on disk and surfaced as `int` in the API.

    Writes are atomic (temp file + `os.replace`) so a crash mid-write can never
    corrupt the sidecar. All mutating operations take an internal lock so the
    watchdog observer thread and any flush thread cannot race.
    """

    def __init__(self, path: Path) -> None:
        self._path = path
        self._lock = threading.RLock()
        self._entries: Dict[int, str] = {}
        self._mtimes: Dict[int, float] = {}      # id -> file st_mtime when indexed

    # -- persistence --------------------------------------------------------

    def load(self) -> "PathMapping":
        """Load the sidecar from disk. Missing file => empty map. Corrupt file
        is logged and treated as empty rather than crashing the caller."""
        with self._lock:
            self._entries = {}
            self._mtimes = {}
            if not self._path.exists():
                return self
            try:
                raw = json.loads(self._path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError) as exc:
                log.error("paths_mapping.json is unreadable (%s); starting empty", exc)
                return self

            entries = raw.get("entries", {}) if isinstance(raw, dict) else {}
            version = raw.get("version") if isinstance(raw, dict) else None
            if version != MAPPING_SCHEMA_VERSION:
                log.warning("paths_mapping.json schema v%s != expected v%s; "
                            "loading best-effort", version, MAPPING_SCHEMA_VERSION)
            for key, value in entries.items():
                try:
                    self._entries[int(key)] = str(value)
                except (TypeError, ValueError):
                    log.warning("dropping malformed mapping entry: %r -> %r", key, value)
            for key, value in (raw.get("mtimes", {}) if isinstance(raw, dict) else {}).items():
                try:
                    self._mtimes[int(key)] = float(value)
                except (TypeError, ValueError):
                    pass
            log.debug("loaded %d path mappings", len(self._entries))
            return self

    def save(self) -> None:
        """Atomically persist the sidecar to disk."""
        with self._lock:
            payload = {
                "version": MAPPING_SCHEMA_VERSION,
                "entries": {str(k): v for k, v in self._entries.items()},
                "mtimes": {str(k): v for k, v in self._mtimes.items()},
            }
            self._path.parent.mkdir(parents=True, exist_ok=True)
            # Write to a temp file in the same dir, then atomically swap it in.
            fd, tmp_name = tempfile.mkstemp(dir=str(self._path.parent),
                                            prefix=".paths_mapping.", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    json.dump(payload, fh, ensure_ascii=False, indent=2)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(tmp_name, self._path)
            except BaseException:
                # Never leave a stray temp file behind on failure.
                try:
                    os.unlink(tmp_name)
                except OSError:
                    pass
                raise

    # -- accessors (all lock-guarded) --------------------------------------

    def put(self, file_id: int, path: str, mtime: float = 0.0) -> None:
        with self._lock:
            self._entries[file_id] = path
            self._mtimes[file_id] = mtime

    def remove(self, file_id: int) -> Optional[str]:
        with self._lock:
            self._mtimes.pop(file_id, None)
            return self._entries.pop(file_id, None)

    def get(self, file_id: int) -> Optional[str]:
        with self._lock:
            return self._entries.get(file_id)

    def get_mtime(self, file_id: int) -> float:
        with self._lock:
            return self._mtimes.get(file_id, 0.0)

    def contains(self, file_id: int) -> bool:
        with self._lock:
            return file_id in self._entries

    def items(self) -> List[Tuple[int, str]]:
        with self._lock:
            return list(self._entries.items())

    def __len__(self) -> int:
        with self._lock:
            return len(self._entries)

    def __iter__(self) -> Iterator[int]:
        with self._lock:
            return iter(list(self._entries.keys()))


# ===========================================================================
# Embedding model (lazy, shared by daemon + CLI)
# ===========================================================================

def _finalize(vectors: np.ndarray, dim: int) -> np.ndarray:
    """Coerce embeddings to the C-contiguous float32 (n, dim) that turbovec
    requires and validate the shape."""
    vectors = np.ascontiguousarray(vectors, dtype=np.float32)
    if vectors.ndim == 1:
        vectors = vectors.reshape(1, -1)
    if vectors.ndim != 2 or vectors.shape[1] != dim:
        raise ValueError(f"expected embeddings of shape (n, {dim}), got {vectors.shape}")
    return vectors


class _TextBackend:
    """sentence-transformers (e.g. all-MiniLM-L6-v2). Text only."""

    def __init__(self, model_name: str) -> None:
        log.info("loading text model %s (first use)...", model_name)
        from sentence_transformers import SentenceTransformer
        self._model = SentenceTransformer(model_name)
        log.info("text model loaded.")

    def encode_text(self, texts: List[str]) -> np.ndarray:
        return self._model.encode(
            texts,
            normalize_embeddings=True,     # => cosine similarity at search time
            convert_to_numpy=True,
            show_progress_bar=False,
        )

    def encode_images(self, images) -> np.ndarray:
        raise RuntimeError("text backend cannot embed images")


class _ClipBackend:
    """
    Local CLIP via open_clip — the canonical loader for laion/OpenCLIP HF
    checkpoints. Text and images land in one shared space, enabling cross-modal
    (text-query -> image/video) search. Used for the media lane only.
    """

    def __init__(self, model_name: str) -> None:
        log.info("loading CLIP model %s (first use)...", model_name)
        import torch
        import open_clip
        self._torch = torch
        # `hf-hub:` pulls the checkpoint from the local HuggingFace cache.
        model, _, preprocess = open_clip.create_model_and_transforms(f"hf-hub:{model_name}")
        model.eval()
        self._model = model
        self._preprocess = preprocess
        self._tokenizer = open_clip.get_tokenizer(f"hf-hub:{model_name}")
        log.info("CLIP model loaded.")

    def _normalize(self, feats) -> np.ndarray:
        feats = feats / feats.norm(dim=-1, keepdim=True).clamp_min(1e-12)
        return feats.cpu().numpy()

    def encode_text(self, texts: List[str]) -> np.ndarray:
        torch = self._torch
        tokens = self._tokenizer(texts)
        with torch.no_grad():
            feats = self._model.encode_text(tokens)
        return self._normalize(feats)

    def encode_images(self, images) -> np.ndarray:
        """images: a list of PIL.Image. Returns normalized (n, dim)."""
        torch = self._torch
        batch = torch.stack([self._preprocess(img.convert("RGB")) for img in images])
        with torch.no_grad():
            feats = self._model.encode_image(batch)
        return self._normalize(feats)


class Embedder:
    """
    Per-LANE embedding facade. Each lane gets its own Embedder bound to that
    lane's model (MiniLM for text, CLIP for media). Weights load lazily on first
    use. Every method returns C-contiguous, L2-normalised float32 of shape
    `(n, lane.dim)`, so turbovec's inner-product score is cosine similarity.
    """

    def __init__(self, lane: "Lane") -> None:
        self._lane = lane
        self._backend = None
        self._lock = threading.Lock()

    def _ensure_backend(self):
        if self._backend is None:
            with self._lock:
                if self._backend is None:  # double-checked under lock
                    self._backend = (_ClipBackend(self._lane.model_name)
                                     if self._lane.kind == "clip"
                                     else _TextBackend(self._lane.model_name))
        return self._backend

    def embed(self, texts: List[str]) -> np.ndarray:
        if not texts:
            return np.empty((0, self._lane.dim), dtype=np.float32)
        with _INFER_LOCK:                        # serialize all model inference
            raw = self._ensure_backend().encode_text(texts)
        return _finalize(raw, self._lane.dim)

    def embed_one(self, text: str) -> np.ndarray:
        """Embed a single string -> (1, dim), ready for `index.search` (2-D)."""
        return self.embed([text])

    def embed_images(self, images) -> np.ndarray:
        """Embed a list of PIL.Image -> float32 (len(images), dim)."""
        if self._lane.kind != "clip":
            raise RuntimeError("image embedding requires the CLIP (media) lane")
        if not images:
            return np.empty((0, self._lane.dim), dtype=np.float32)
        with _INFER_LOCK:                        # serialize all model inference
            raw = self._ensure_backend().encode_images(images)
        return _finalize(raw, self._lane.dim)


# Serializes ALL model inference process-wide. Searches (serve) and the live
# indexer (watcher) share one embedder; concurrent torch forward passes are not
# safe, so every encode goes through this lock. Each call is sub-second.
_INFER_LOCK = threading.Lock()


# One embedder per lane, process-wide, so each model loads at most once (critical
# for the long-lived serve.py — otherwise every query would reload the model).
_EMBEDDERS: Dict[str, "Embedder"] = {}
_EMBEDDER_LOCK = threading.Lock()


def get_embedder(lane: "Lane") -> "Embedder":
    cached = _EMBEDDERS.get(lane.name)
    if cached is None:
        with _EMBEDDER_LOCK:
            cached = _EMBEDDERS.get(lane.name)
            if cached is None:
                cached = Embedder(lane)
                _EMBEDDERS[lane.name] = cached
    return cached


# ===========================================================================
# Index helpers (per lane)
# ===========================================================================

def new_index(lane: "Lane"):
    """Create a fresh, empty IdMapIndex with the lane's geometry."""
    import turbovec
    return turbovec.IdMapIndex(dim=lane.dim, bit_width=INDEX_BIT_WIDTH)


def load_index(lane: "Lane", create_if_missing: bool = False):
    """
    Load the lane's on-disk turbovec index.

    Returns the index, or `None` if absent and not `create_if_missing`. Raises a
    clear `RuntimeError` on a corrupt index or a dim/geometry mismatch.
    """
    import turbovec
    if not lane.index_path.exists():
        if create_if_missing:
            log.info("no index at %s; creating a new one", lane.index_path)
            return new_index(lane)
        return None
    try:
        index = turbovec.IdMapIndex.load(str(lane.index_path))
    except OSError as exc:
        raise RuntimeError(
            f"turbovec index at {lane.index_path} is missing or corrupt ({exc}). "
            f"Delete it (and {lane.mapping_path.name}) and let the daemon rebuild."
        ) from exc
    if index.dim != lane.dim:
        raise RuntimeError(
            f"index at {lane.index_path} has dim {index.dim} but the '{lane.name}' "
            f"lane expects {lane.dim}. Delete the stale index/sidecar and rebuild."
        )
    return index


def _extract_pdf_text(path: Path) -> Optional[str]:
    """Extract text from a PDF with pypdf (capped pages/chars). None on
    encrypted/corrupt/empty PDFs or if pypdf isn't installed."""
    try:
        from pypdf import PdfReader
    except ImportError:
        log.warning("pypdf not installed — PDFs are skipped. `pip install pypdf`")
        return None
    try:
        reader = PdfReader(str(path))
        if getattr(reader, "is_encrypted", False):
            try:
                reader.decrypt("")          # try empty password; bail if it fails
            except Exception:
                return None
        parts: List[str] = []
        total = 0
        for page in reader.pages[:PDF_MAX_PAGES]:
            try:
                chunk = page.extract_text() or ""
            except Exception:
                continue                    # one bad page shouldn't kill the doc
            if chunk:
                parts.append(chunk)
                total += len(chunk)
                if total >= PDF_MAX_CHARS:
                    break
        text = "\n".join(parts).strip()
        return text or None
    except Exception as exc:                # malformed PDF, etc.
        log.warning("could not extract PDF %s: %s", path, exc)
        return None


def read_text_file(path: Path) -> Optional[str]:
    """
    Best-effort extraction of indexable text from a supported file (.txt/.md/.pdf).

    Returns the file's text, or `None` when it should be skipped (wrong type,
    too large, empty, unreadable, encrypted/garbled PDF, or whitespace-only).
    """
    try:
        suffix = path.suffix.lower()
        # ONLY real text types — never read image/video binaries as text. In
        # multimodal mode SUPPORTED_SUFFIXES includes media, so gating on that
        # would let search's BM25 stage decode an .mp4/.png as garbage text.
        if suffix not in TEXT_SUFFIXES:
            return None
        if not path.is_file():
            return None
        size = path.stat().st_size
        if size == 0:
            return None
        if suffix == ".pdf":
            if size > MAX_PDF_BYTES:
                log.debug("skipping %s: %d bytes exceeds PDF cap", path, size)
                return None
            return _extract_pdf_text(path)
        if size > MAX_FILE_BYTES:
            log.debug("skipping %s: %d bytes exceeds cap", path, size)
            return None
        # errors="replace" keeps us robust to odd encodings without throwing.
        text = path.read_text(encoding="utf-8", errors="replace").strip()
        return text or None
    except (OSError, ValueError) as exc:
        log.warning("could not read %s: %s", path, exc)
        return None
