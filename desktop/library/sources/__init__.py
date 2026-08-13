"""Source adapters — what is left of them on the client.

These modules used to be how the catalog got filled: every user's machine
searched archive.org and scraped Plus4World, and what it found became rows in
that machine's library.  That job has moved to fpgago.com, which does it once
for everybody (`library/webdb.py` downloads the result).

What stays here is the other half, which cannot move: the actual game files
are NOT served by fpgago.com — the site carries metadata and screenshots only
— so downloading a release still means going to the archive that hosts it.
That is `resolve()`, turning a catalogued release into concrete download URLs,
plus `fetch.download()`.

So: `resolve()` is live, and `search()` / `list_all()` are only reached by
the copies of these adapters that now run on the server
(`fpgago-web/apps/gamedb/scrape/`).  They are kept here rather than deleted
because both copies are maintained together and a diff between them should be
about imports, not about missing methods.

The registry is built lazily so the CLI works even if an adapter's optional
deps are missing.
"""
from __future__ import annotations

from .base import Source, SearchResult, DownloadItem, REGISTRY, register  # noqa

# Import adapters for their side-effect registration. Wrapped so one broken
# adapter never takes down the whole CLI.
for _mod in ("plus4world", "csdb", "archive", "gb64"):
    try:
        __import__(f"{__name__}.{_mod}", fromlist=["*"])
    except Exception:  # pragma: no cover - adapter optional
        pass


def get(name: str):
    """The adapter that can resolve a download for a given `source` value."""
    return REGISTRY.get(name)


def all_sources():
    return list(REGISTRY.values())


def for_platform(platform: str):
    return [s for s in REGISTRY.values() if platform in s.platforms or not s.platforms]
