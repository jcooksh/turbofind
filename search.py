"""
search.py — TurboFind instant HYBRID search CLI.

Pure dense-embedding search drifts: it matches on fuzzy concept overlap (an
"exam timetable" query hitting a taxes file because both involve schedules/dates).
We fix that with hybrid scoring that blends semantic similarity with a lexical
signal (BM25 over file text + filename/path token matching):

    final = 0.7 * semantic + 0.3 * lexical_boost

and — per requirement — any file whose NAME explicitly contains a query word is
pushed strictly to the top (a hard tier above non-name-matches), not merely
nudged. So typing "budget" always surfaces budget.md first.

    python search.py "my server configurations"
    python search.py -k 10 "quarterly budget"
    python search.py --json "kubernetes deployment yaml"

Pipeline: retrieve a larger candidate POOL from turbovec by cosine, then re-rank
that pool with the hybrid score. BM25 IDF is computed over the candidate pool
(a self-contained reranker — no global term-frequency store needed).
"""

from __future__ import annotations

import argparse
import math
import re
import sys
import time
from pathlib import Path
from typing import Dict, List, NamedTuple

import shared
from shared import PathMapping, get_embedder, get_logger, load_index

# Text formats cheap enough to read at QUERY time for BM25. PDFs are excluded on
# purpose: re-parsing a PDF (pypdf + AES decrypt + many pages) per candidate per
# keystroke is what made the server hang. A PDF's content is already captured in
# its embedding at ingest, so at search time it ranks on semantic + filename.
_CHEAP_TEXT_SUFFIXES = frozenset({".txt", ".md", ".markdown", ".text"})


def _search_text(path: str) -> "str | None":
    p = Path(path)
    if p.suffix.lower() not in _CHEAP_TEXT_SUFFIXES:
        return None
    try:
        if p.stat().st_size > shared.MAX_FILE_BYTES:
            return None
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

log = get_logger("turbofind.search")

# Last query's timing breakdown (embed+model load vs vector scan), for display.
_LAST_TIMING: Dict[str, float] = {}

# Hybrid weights (must sum to 1.0 for an interpretable [0,1] final score).
SEMANTIC_WEIGHT = 0.7
LEXICAL_WEIGHT = 0.3
# How many candidates to pull from the index before re-ranking. Larger pool =
# better recall for the lexical stage to rescue, at negligible cost.
RERANK_POOL = 100
# Standard BM25 hyper-parameters.
BM25_K1 = 1.5
BM25_B = 0.75
# Cap on filename matches unioned into the candidate set (see run_search).
FILENAME_UNION_CAP = 200

_TOKEN_RE = re.compile(r"[a-z0-9]+")

# Dropped from LEXICAL matching so "a"/"of"/"the" can't trigger a filename hit
# (they don't carry search intent). Semantic embedding still uses the full query.
_STOPWORDS = frozenset(
    "a an the of for to in on at by and or is are was were be been being it as "
    "from into with this that these those my your our his her their its i you we "
    "they me about over under how what when where which who whom".split()
)


class Hit(NamedTuple):
    rank: int
    score: float          # final blended score in [0, 1] (headline)
    semantic: float       # cosine-derived component in [0, 1]
    lexical: float        # lexical boost in [0, 1]
    filename_hit: bool    # a query word appears in the filename/path
    file_id: int
    path: str
    exists: bool


# ---------------------------------------------------------------------------
# Lexical scoring: tokeniser + self-contained BM25 over the candidate pool
# ---------------------------------------------------------------------------

def _tokenize(text: str) -> List[str]:
    """Lowercase alphanumeric tokens."""
    return _TOKEN_RE.findall(text.lower()) if text else []


def _content_tokens(query: str) -> List[str]:
    """Query tokens for LEXICAL matching: stopwords + 1-char tokens removed, so a
    query like 'a screenshot of code' contributes only {screenshot, code}."""
    return [t for t in _tokenize(query) if len(t) >= 2 and t not in _STOPWORDS]


class BM25:
    """
    Minimal BM25 ranker built over a fixed list of tokenised documents.

    We treat the retrieved candidate pool as the corpus, so IDF reflects term
    rarity *within the pool*. That is an approximation of global BM25 but is the
    standard, dependency-free way to re-rank a candidate set and is plenty to
    correct semantic drift.
    """

    def __init__(self, docs: List[List[str]]) -> None:
        self._docs = docs
        self._n = len(docs)
        self._doc_len = [len(d) for d in docs]
        # avgdl over TEXT-BEARING docs only. Media candidates enter the corpus as
        # empty token lists; counting them would drag avgdl down and distort —
        # even reorder — the real text docs' BM25 scores.
        nonempty = [n for n in self._doc_len if n > 0]
        self._avgdl = (sum(nonempty) / len(nonempty)) if nonempty else 0.0
        # term frequency per doc + document frequency across the pool
        self._tf: List[Dict[str, int]] = []
        self._df: Dict[str, int] = {}
        for doc in docs:
            freq: Dict[str, int] = {}
            for tok in doc:
                freq[tok] = freq.get(tok, 0) + 1
            self._tf.append(freq)
            for tok in freq:
                self._df[tok] = self._df.get(tok, 0) + 1

    def _idf(self, term: str) -> float:
        # Smoothed IDF; the +1 inside log keeps it strictly positive.
        df = self._df.get(term, 0)
        return math.log(1.0 + (self._n - df + 0.5) / (df + 0.5))

    def score(self, query_tokens: List[str], doc_index: int) -> float:
        if self._n == 0 or self._avgdl == 0.0:
            return 0.0
        freq = self._tf[doc_index]
        dl = self._doc_len[doc_index]
        score = 0.0
        for term in set(query_tokens):
            f = freq.get(term, 0)
            if f == 0:
                continue
            idf = self._idf(term)
            denom = f + BM25_K1 * (1.0 - BM25_B + BM25_B * dl / self._avgdl)
            score += idf * (f * (BM25_K1 + 1.0)) / denom
        return score


def _stem_tokens(path: str) -> set:
    """Whole-word tokens from a file's OWN name (stem) only."""
    return set(_tokenize(Path(path).stem))


def _path_tokens(path: str) -> set:
    """Whole-word tokens from the stem + each parent directory name."""
    p = Path(path)
    toks = set(_tokenize(p.stem))
    for part in p.parent.parts:
        toks.update(_tokenize(part))
    return toks


def _filename_lexical(query_tokens: List[str], path: str) -> tuple[float, bool]:
    """
    Lexical signal from the filename/path.

    Returns (overlap_score in [0,1], filename_hit bool).

    `filename_hit` — the HARD top-tier trigger — fires ONLY when EVERY content
    word is a whole word in the file's OWN name (stem): a strong, near-exact name
    match (e.g. "physics" -> physics.pdf, "tax return" -> tax_return_2024.pdf). A
    single partial word no longer hijacks the top — that's what made
    "a screenshot of code" surface CODE_OF_CONDUCT.md and a file literally named
    "create a link" (the stopword "a"). Parent-folder words and substrings still
    feed the soft `overlap` score (the secondary, blended key).
    """
    if not query_tokens:
        return 0.0, False
    q = set(query_tokens)
    stem_tokens = _stem_tokens(path)
    path_tokens = _path_tokens(path)
    name_lower = Path(path).name.lower()

    hard = q.issubset(stem_tokens)                                  # ALL words, own name
    soft_hits = sum(1 for qt in q if qt in path_tokens or qt in name_lower)
    overlap = soft_hits / len(q)
    return overlap, hard


# ---------------------------------------------------------------------------
# Pretty terminal output (dependency-free; colour only when attached to a TTY)
# ---------------------------------------------------------------------------

class _Style:
    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled

    def _wrap(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.enabled else text

    def bold(self, t: str) -> str:   return self._wrap("1", t)
    def dim(self, t: str) -> str:    return self._wrap("2", t)
    def cyan(self, t: str) -> str:   return self._wrap("36", t)
    def green(self, t: str) -> str:  return self._wrap("32", t)
    def yellow(self, t: str) -> str: return self._wrap("33", t)
    def red(self, t: str) -> str:    return self._wrap("31", t)


def _score_colour(style: _Style, score: float) -> str:
    label = f"{score:.3f}"
    if score >= 0.5:
        return style.green(label)
    if score >= 0.3:
        return style.yellow(label)
    return style.red(label)


def _format_bar(score: float, width: int = 20) -> str:
    """A tiny score bar; final score is already in [0, 1]."""
    filled = max(0, min(width, round(max(0.0, score) * width)))
    return "█" * filled + "·" * (width - filled)


def _kind(path: str) -> str:
    suffix = Path(path).suffix.lower()
    if suffix == ".pdf":
        return "pdf"
    if suffix in shared.IMAGE_SUFFIXES:
        return "image"
    if suffix in shared.VIDEO_SUFFIXES:
        return "video"
    if suffix in shared.TEXT_SUFFIXES:
        return "text"
    return "file"


def render(query: str, hits: List[Hit], style: _Style) -> str:
    lines: List[str] = []
    lines.append("")
    lines.append(style.bold(f'  Top {len(hits)} matches for: ') + style.cyan(f'"{query}"'))
    lines.append(style.dim("  " + "─" * 68))
    if not hits:
        lines.append(style.yellow("  No matching files found. Is the daemon running and the index populated?"))
        lines.append("")
        return "\n".join(lines)

    for hit in hits:
        p = Path(hit.path)
        name = p.name or hit.path
        marker = "" if hit.exists else style.red("  [missing on disk]")
        name_tag = style.green(" ⌕ name match") if hit.filename_hit else ""
        lines.append(
            f"  {style.bold(f'{hit.rank}.')} {style.cyan(name)} "
            f"{style.dim(f'[{_kind(hit.path)}]')}{name_tag}{marker}"
        )
        lines.append(
            f"     {_score_colour(style, hit.score)}  {style.dim(_format_bar(hit.score))}"
            f"   {style.dim(f'sem {hit.semantic:.2f} · lex {hit.lexical:.2f}')}"
        )
        lines.append(f"     {style.dim(str(p.parent) + '/')}")
        lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Core hybrid search
# ---------------------------------------------------------------------------

def run_search(query: str, k: int, types=None, roots=None) -> List[Hit]:
    """`types`: optional set of kinds to keep ('text'/'pdf'/'image'/'video').
    `roots`: optional list of folder path-prefixes to restrict results to."""
    query = query.strip()
    if not query:
        raise ValueError("query is empty")

    content_q = _content_tokens(query)             # stopword-free; for lexical/BM25/name
    pool = max(k, RERANK_POOL)

    candidates: List[dict] = []
    docs: List[List[str]] = []
    have: set = set()

    def _add(file_id: int, path: str, cosine: float, lane_name: str) -> None:
        exists = Path(path).exists()
        text = _search_text(path) if exists else None   # None for PDF/media/missing
        docs.append(_tokenize(text or ""))
        candidates.append({"file_id": file_id, "path": path, "exists": exists,
                          "cosine": float(cosine), "doc_index": len(docs) - 1,
                          "lane": lane_name})
        have.add(file_id)

    embed_s = scan_s = 0.0
    any_index = False

    # Query EVERY lane with its own model + index, then merge. In hybrid mode
    # that's text/MiniLM AND media/CLIP; both emit normalised cosine, blended
    # uniformly below. (A file lives in exactly one lane, so `have` dedups cleanly.)
    for lane in shared.LANES:
        index = load_index(lane, create_if_missing=False)   # RuntimeError if corrupt
        if index is None or len(index) == 0:
            continue
        any_index = True
        mapping = PathMapping(lane.mapping_path).load()
        embedder = get_embedder(lane)

        _t = time.perf_counter()
        query_vec = embedder.embed_one(query)               # (1, lane.dim) float32
        embed_s += time.perf_counter() - _t                 # incl. model load (cold)
        index.prepare()
        _t = time.perf_counter()
        scores, ids = index.search(query_vec, k=pool)
        scan_s += time.perf_counter() - _t
        row_scores = scores[0] if len(scores) else []
        row_ids = ids[0] if len(ids) else []
        for cos, raw_id in zip(row_scores, row_ids):
            file_id = int(raw_id)
            path = mapping.get(file_id)
            if path is None or file_id in have:
                continue                                   # drift / cross-lane dup
            _add(file_id, path, cos, lane.name)

        # Union STRONG name matches the dense stage missed (files whose OWN name
        # contains EVERY content word). Score for REAL via an allowlist search on
        # THIS lane's index so a name match ranks by relevance, never a fake 0.
        if content_q:
            cq = set(content_q)
            union = []
            for fid, path in mapping.items():
                if fid in have:
                    continue
                if cq.issubset(_stem_tokens(path)):
                    union.append((fid, path))
                    if len(union) >= FILENAME_UNION_CAP:
                        break
            if union:
                import numpy as np
                allow = np.array([fid for fid, _ in union], dtype=np.uint64)
                real: Dict[int, float] = {}
                try:
                    us, ui = index.search(query_vec, k=len(union), allowlist=allow)
                    real = {int(i): float(s) for s, i in zip(us[0], ui[0])}
                except Exception as exc:
                    log.debug("allowlist scoring unavailable (%s); using 0.0", exc)
                for fid, path in union:
                    _add(fid, path, real.get(fid, 0.0), lane.name)

    _LAST_TIMING.clear()
    _LAST_TIMING.update(embed=embed_s, scan=scan_s)

    if not any_index:
        log.error("no index yet — run `python ingest.py --once <folder>` first.")
        return []
    if not candidates:
        return []

    # 3) Lexical stage: BM25 over the candidate pool + filename/path matching.
    bm25 = BM25(docs)
    bm25_raw = [bm25.score(content_q, c["doc_index"]) for c in candidates]
    max_bm25 = max(bm25_raw) if bm25_raw else 0.0

    for c, raw in zip(candidates, bm25_raw):
        content_score = (raw / max_bm25) if max_bm25 > 0 else 0.0   # -> [0,1]
        name_overlap, filename_hit = _filename_lexical(content_q, c["path"])
        # Lexical boost: best of content (BM25) and filename overlap.
        lexical = max(content_score, name_overlap)
        # Map cosine [-1,1] -> [0,1] for a coherent blend with the lexical term.
        semantic = max(0.0, min(1.0, (c["cosine"] + 1.0) / 2.0))
        c["semantic"] = semantic
        c["lexical"] = lexical
        c["filename_hit"] = filename_hit
        c["final"] = SEMANTIC_WEIGHT * semantic + LEXICAL_WEIGHT * lexical

    # 3b) UI filters: keep only chosen file types and/or files under chosen
    #     folders (path-prefix). Applied before the merge so ranks reflect the
    #     filtered set.
    if types:
        wanted = set(types)
        candidates = [c for c in candidates if _kind(c["path"]) in wanted]
    if roots:
        prefixes = tuple(roots)
        candidates = [c for c in candidates if c["path"].startswith(prefixes)]
    if not candidates:
        return []

    # 4) Rank by relevance: explicit whole-name matches first (hard tier), then
    #    by blended score. (An earlier cross-lane rank-fusion interleaved
    #    low-relevance images among high-relevance docs — straight score order is
    #    what users expect. The (cos+1)/2 blend keeps text vs media comparable
    #    enough that image queries still surface images near the top.)
    candidates.sort(key=lambda c: (c["filename_hit"], c["final"]), reverse=True)

    hits: List[Hit] = []
    for c in candidates[:k]:
        hits.append(Hit(
            rank=len(hits) + 1,
            score=c["final"],
            semantic=c["semantic"],
            lexical=c["lexical"],
            filename_hit=c["filename_hit"],
            file_id=c["file_id"],
            path=c["path"],
            exists=c["exists"],
        ))
    return hits


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="search.py",
        description="Hybrid semantic + lexical search over your indexed files (TurboFind).",
    )
    parser.add_argument("query", help="natural language search query")
    parser.add_argument("-k", "--top-k", type=int, default=5,
                        help="number of results to return (default: 5)")
    parser.add_argument("--json", action="store_true",
                        help="emit machine-readable JSON instead of pretty output")
    parser.add_argument("--no-color", action="store_true", help="disable ANSI colour")
    args = parser.parse_args(argv)

    if args.top_k < 1:
        parser.error("--top-k must be >= 1")

    t0 = time.perf_counter()
    try:
        hits = run_search(args.query, args.top_k)
    except ValueError as exc:
        parser.error(str(exc))
    except RuntimeError as exc:          # corrupt index, etc.
        log.error("%s", exc)
        return 2
    except Exception as exc:             # model/load failures -> non-zero exit
        log.error("search failed: %s", exc)
        return 1
    total_s = time.perf_counter() - t0

    if args.json:
        import json
        print(json.dumps(
            [{"rank": h.rank, "score": round(h.score, 6),
              "semantic": round(h.semantic, 6), "lexical": round(h.lexical, 6),
              "filename_match": h.filename_hit, "id": h.file_id,
              "path": h.path, "exists": h.exists} for h in hits],
            indent=2,
        ))
    else:
        style = _Style(enabled=sys.stdout.isatty() and not args.no_color)
        print(render(args.query, hits, style))
        embed = _LAST_TIMING.get("embed", 0.0)
        scan = _LAST_TIMING.get("scan", 0.0)
        summary = (f"  {len(hits)} results · vector scan {scan * 1000:.0f} ms"
                  f" · model+embed {embed:.2f} s · total {total_s:.2f} s")
        print(style.dim(summary))
        if embed > 0.5:
            print(style.dim("  (the model load is the cost — run `python serve.py` "
                            "to keep it warm for instant repeat searches)"))

    return 0 if hits else 3   # exit 3 = ran fine but found nothing


if __name__ == "__main__":
    raise SystemExit(main())
