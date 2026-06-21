"""
spotlight.py — best-effort bridge from TurboFind into native macOS CoreSpotlight.

Whenever a file's vector is added/updated, we also push a `CSSearchableItem`
(title, keywords, description, file URL) into
`CSSearchableIndex.defaultSearchableIndex()` so the file's labels become
discoverable through the system Spotlight UI; on delete we remove it again.

  ────────────────────────────────────────────────────────────────────────────
  HONEST CAVEAT — please read.
  ────────────────────────────────────────────────────────────────────────────
  CoreSpotlight is NOT the same index Finder uses for file search. Finder file
  results come from the filesystem metadata importers (mdimporter / `mdfind`),
  whereas CoreSpotlight surfaces *app content* in the Spotlight (⌘-Space) UI.
  Apple also expects the caller to be a code-signed **app bundle** with the
  CoreSpotlight entitlement; from a plain Python CLI,
  `defaultSearchableIndex()` may return nil and indexed items often will NOT
  appear in Finder. This bridge is therefore written defensively: if pyobjc /
  CoreSpotlight is unavailable, or the default index is nil, or any call fails,
  it logs once and becomes a silent no-op. It never raises into the daemon.

  To make this genuinely surface system-wide, ship TurboFind inside a signed
  .app bundle with `com.apple.developer.corespotlight` and call from there.
  ────────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import List, Optional

from shared import get_logger

log = get_logger("turbofind.spotlight")

DOMAIN_IDENTIFIER = "com.turbofind.files"

# Resolved lazily on first use: (CoreSpotlight, Foundation) modules + the index.
_lock = threading.Lock()
_state: Optional[dict] = None
_warned = False


def _warn_once(message: str) -> None:
    # A developer-facing WARNING (not info): the bridge is off and the operator
    # likely wants to know why and how to fix it.
    global _warned
    if not _warned:
        log.warning("Spotlight bridge inactive — %s", message)
        _warned = True


def _resolve():
    """Return a dict with the CoreSpotlight handles, or None if unavailable.

    Cached after the first attempt so we don't repeatedly pay the import cost or
    re-log. Any import / nil-index problem degrades to a no-op with a clear,
    actionable developer warning."""
    global _state
    if _state is not None:
        return _state.get("index") and _state
    with _lock:
        if _state is not None:
            return _state.get("index") and _state
        state: dict = {"index": None}

        # Base pyobjc. Cocoa re-exports Foundation + AppKit. We `import Cocoa`
        # rather than `from Cocoa import *` because a star-import is only legal
        # at module scope and would pollute this module's namespace; importing
        # the module still proves the base pyobjc stack is present and gives us
        # NSURL via Foundation below.
        try:
            import Cocoa            # noqa: F401  (pyobjc-framework-Cocoa)
            import Foundation
        except Exception as exc:
            _warn_once(
                "base pyobjc (Cocoa/Foundation) not importable (%s). "
                "Install with:  pip install pyobjc" % exc
            )
            _state = state
            return None

        # CoreSpotlight is a SEPARATE pyobjc framework wrapper — this is exactly
        # the previous 'No module named CoreSpotlight' failure.
        try:
            import CoreSpotlight
        except Exception as exc:
            _warn_once(
                "CoreSpotlight framework not found (%s).\n"
                "      fix 1 — install the wrapper:\n"
                "              pip install pyobjc-framework-CoreSpotlight\n"
                "      fix 2 — grant Full Disk Access:\n"
                "              System Settings > Privacy & Security > Full Disk "
                "Access > add your Terminal (or the python binary).\n"
                "      TurboFind keeps indexing/searching normally; only the "
                "native Spotlight mirror is disabled." % exc
            )
            _state = state
            return None

        try:
            index = CoreSpotlight.CSSearchableIndex.defaultSearchableIndex()
        except Exception as exc:
            _warn_once("CSSearchableIndex.defaultSearchableIndex() raised (%s)" % exc)
            _state = state
            return None

        if index is None:
            _warn_once(
                "CSSearchableIndex.defaultSearchableIndex() returned nil. "
                "CoreSpotlight indexing from a plain CLI requires a code-signed "
                ".app bundle with the com.apple.developer.corespotlight "
                "entitlement (and Full Disk Access in System Settings > Privacy "
                "& Security). Unbundled, the bridge stays a safe no-op."
            )
            _state = state
            return None

        state.update(Cocoa=Cocoa, CoreSpotlight=CoreSpotlight,
                    Foundation=Foundation, index=index)
        _state = state
        log.info("Spotlight bridge active (CSSearchableIndex ready).")
        return state


def is_available() -> bool:
    return bool(_resolve())


def _completion(error) -> None:
    if error is not None:
        log.debug("CoreSpotlight completion error: %s", error)


def index_item(file_id: int, path: str, keywords: List[str],
              title: Optional[str] = None, description: Optional[str] = None) -> None:
    """Push/refresh a searchable item for `path`. Best-effort; never raises."""
    state = _resolve()
    if not state:
        return
    try:
        CoreSpotlight = state["CoreSpotlight"]
        Foundation = state["Foundation"]
        p = Path(path)

        # Initialise WITH a content type: a nil contentType can make
        # CoreSpotlight silently drop the item on some macOS versions. Fall back
        # to a bare init() if the (deprecated) string initializer is unavailable.
        try:
            attrs = CoreSpotlight.CSSearchableItemAttributeSet.alloc(
                ).initWithItemContentType_("public.item")
        except Exception:
            attrs = CoreSpotlight.CSSearchableItemAttributeSet.alloc().init()
        attrs.setTitle_(title or p.name)
        attrs.setDisplayName_(p.name)
        if keywords:
            attrs.setKeywords_(list(keywords))
        attrs.setContentDescription_(description or str(p))
        try:
            attrs.setContentURL_(Foundation.NSURL.fileURLWithPath_(str(p)))
        except Exception:
            pass  # contentURL is a nicety, not required

        item = CoreSpotlight.CSSearchableItem.alloc().initWithUniqueIdentifier_domainIdentifier_attributeSet_(
            str(file_id), DOMAIN_IDENTIFIER, attrs,
        )
        state["index"].indexSearchableItems_completionHandler_([item], _completion)
    except Exception as exc:
        log.debug("index_item failed for %s: %s", path, exc)


def delete_item(file_id: int) -> None:
    """Remove a previously indexed item by id. Best-effort; never raises."""
    state = _resolve()
    if not state:
        return
    try:
        state["index"].deleteSearchableItemsWithIdentifiers_completionHandler_(
            [str(file_id)], _completion,
        )
    except Exception as exc:
        log.debug("delete_item failed for id %d: %s", file_id, exc)


def keywords_for(path: str, extra: Optional[List[str]] = None) -> List[str]:
    """Derive conceptual tags from a file path: filename stem tokens + the last
    two parent folder names + caller-supplied extras (e.g. modality). These are
    the keywords injected into the CSSearchableItem so the file surfaces under
    its name and folder context."""
    p = Path(path)
    raw_parts = p.stem.replace("_", " ").replace("-", " ").split()
    raw_parts += list(p.parent.parts[-2:])     # nearest folders for context
    tokens: List[str] = []
    for raw in raw_parts:
        tok = raw.strip().lower()
        if len(tok) >= 2 and tok not in tokens and tok not in {"/", "."}:
            tokens.append(tok)
    if extra:
        tokens.extend(t for t in extra if t and t not in tokens)
    return tokens
