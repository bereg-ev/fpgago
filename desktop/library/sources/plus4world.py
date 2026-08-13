"""library/sources/plus4world.py — Plus4World adapter (C16 / Plus/4).

THE database for the 264 family, and the only source with a trustworthy
C16-vs-Plus/4 tag: each game lists a memory requirement (16K = runs on a
C16/C116; 32K/64K/… = Plus/4-only). We map that to the platform directly,
so the ambiguous "264" is resolved at the source.

Host note: plus4world.com is a dead parked domain — the live database is
plus4world.powweb.com. Static HTML, permissive robots (Allow: /), direct
unauthenticated downloads. Enumerate /games/all/0..N (100 games/page).
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
from typing import Iterable, Optional

from .. import config, fetch
from ..db import (normalize_title, PLATFORM_C16, PLATFORM_PLUS4, PLATFORM_264)
from .base import Source, SearchResult, DownloadItem, register

BASE = "https://plus4world.powweb.com"

# One game "card" in a /games/all/<page> listing:
#   <a href="/software/REF" title="Details of ...">TITLE</a><br>YEAR LANG MEM
# The meta line ends at the next tag — <br> (games with a play-online link) or
# </div> (games without one); match up to whichever comes first.
_CARD_RE = re.compile(
    r'<a href="/software/([^"]+)" title="Details[^"]*">([^<]+)</a>\s*<br>\s*'
    r'([^<]*?)\s*<', re.I)
_YEAR_RE = re.compile(r'\b(19|20)\d\d\b')
_MEM_RE = re.compile(r'\b(\d+)K\b')
# Download links on a /software/ detail page.
_DL_RE = re.compile(r'/dl/games/[^"\']+\.(?:prg|d64|tap|zip|c1p|p00)', re.I)


def _platform_from_mem(meta: str) -> str:
    """16K → C16 (also runs on Plus/4); larger → Plus/4-only."""
    m = _MEM_RE.search(meta)
    if not m:
        return PLATFORM_264
    return PLATFORM_C16 if int(m.group(1)) <= 16 else PLATFORM_PLUS4


def _year(meta: str):
    m = _YEAR_RE.search(meta)
    return int(m.group(0)) if m else None


class Plus4World(Source):
    name = "plus4world"
    platforms = (PLATFORM_C16, PLATFORM_PLUS4, PLATFORM_264)

    def _card_to_result(self, ref, title, meta) -> SearchResult:
        title = title.strip()
        letter = title[0].lower() if title and title[0].isalpha() else "0"
        return SearchResult(
            title=title, source=self.name, source_ref=ref,
            platform=_platform_from_mem(meta), year=_year(meta),
            source_url=f"{BASE}/software/{ref}",
            extra={"mem": meta.strip(), "letter": letter})

    def _iter_pages(self) -> Iterable[SearchResult]:
        """Enumerate the whole catalog, page by page, until a page is empty."""
        page = 0
        while True:
            try:
                html = fetch.get(f"{BASE}/games/all/{page}", max_age=7 * 86400)
            except urllib.error.URLError:
                break
            cards = _CARD_RE.findall(html)
            if not cards:
                break
            seen = set()
            for ref, title, meta in cards:
                if ref in seen:              # each card's link appears twice
                    continue
                seen.add(ref)
                yield self._card_to_result(ref, title, meta)
            page += 1
            if page > 200:                    # safety bound (~72 real pages)
                break

    # -- cached full catalog (so search is offline after the first sync) -----

    def _catalog(self, refresh=False):
        cpath = os.path.join(config.cache_dir("plus4world"), "catalog.json")
        if not refresh and os.path.exists(cpath) and \
                (os.path.getmtime(cpath) > 0):
            with open(cpath) as fh:
                return [SearchResult(**d) for d in json.load(fh)]
        rows = []
        for r in self._iter_pages():
            rows.append(r)
        with open(cpath, "w") as fh:
            json.dump([r.__dict__ for r in rows], fh)
        return rows

    def list_all(self, platform: Optional[str] = None) -> Iterable[SearchResult]:
        for r in self._catalog():
            if platform is None or r.platform == platform:
                yield r

    def search(self, query: str,
               platform: str = None) -> list[SearchResult]:
        q = normalize_title(query)
        return [r for r in self._catalog() if q in normalize_title(r.title)]

    def resolve(self, result: SearchResult) -> list[DownloadItem]:
        html = fetch.get(f"{BASE}/software/{result.source_ref}",
                         max_age=7 * 86400)
        items, seen = [], set()
        for m in _DL_RE.finditer(html):
            url = BASE + m.group(0)
            if url in seen:
                continue
            seen.add(url)
            fn = os.path.basename(url)
            items.append(DownloadItem(
                url=url, filename=fn, fmt=os.path.splitext(fn)[1][1:].lower(),
                platform=result.platform))
        return items


register(Plus4World())
