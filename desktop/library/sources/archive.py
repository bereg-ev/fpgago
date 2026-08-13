"""library/sources/archive.py — Internet Archive adapter.

Open JSON APIs, anonymous downloads, and item metadata that already carries
crc32/md5/sha1 (so downloads verify without re-hashing). The main online
discovery + download source, and how we fetch the TOSEC .dat packs and the
GB64 database itself.

    search:   /advancedsearch.php?q=...&output=json
    metadata: /metadata/<identifier>          (files[] with crc32/sha1)
    download: /download/<identifier>/<file>

Be polite: IA returns HTTP 429 under load (fetch.py throttles + caches). For
huge bulk pulls the `internetarchive` Python lib with backoff is better; this
adapter targets search + per-item download.
"""

from __future__ import annotations

import os
import urllib.parse
from typing import Iterable, Optional

from .. import fetch
from ..db import (PLATFORM_C64, PLATFORM_C16, PLATFORM_PLUS4, PLATFORM_264,
                  parse_release_tags)
from .base import Source, SearchResult, DownloadItem, register

BASE = "https://archive.org"
GAME_EXTS = (".prg", ".d64", ".g64", ".d81", ".tap", ".t64", ".crt", ".zip")

# Verified working collections (checked live 2026-07-12; the old TOSEC
# collection identifiers 404 now). Archive.org is our C64 online source; the
# 264 family is served by Plus4World, so no 264 collection is scoped here — a
# 264 query falls back to broad free-text.
# _games misses most commercial titles: cracked disks (the form nearly every
# playable dump takes) are filed under _cracks — e.g. every "Supremacy
# (1991)(Virgin Mastertronic)" release. Searching only _games surfaced a
# same-named scene demo instead of the game.
COLLECTIONS = {
    PLATFORM_C64: ("softwarelibrary_c64_games", "softwarelibrary_c64_cracks"),
}


def _tags(title: str, identifier: str):
    """(group, release) for an item.  The title keeps the TOSEC brackets when
    the uploader left them ("…[cr Bandit]"); the identifier has had them
    squashed to underscores, so it is the fallback, not the first choice.
    Without this every crack of a game lists with a blank group and a dozen
    releases are a dozen identical-looking rows."""
    group, release = parse_release_tags(title)
    return (group, release) if release else parse_release_tags(identifier)


def _collection_platform(colls) -> str:
    s = (" ".join(colls) if isinstance(colls, (list, tuple)) else str(colls)).lower()
    if "c64" in s:
        return PLATFORM_C64
    return PLATFORM_264


class Archive(Source):
    name = "archive"
    platforms = ()                        # any (collection-scoped per query)
    DEEP_PAGE_LIMIT = 10000               # advancedsearch rows*page ceiling

    def _advanced(self, q: str, rows: int = 50, page: int = 1,
                  sort: Optional[str] = None):
        url = (f"{BASE}/advancedsearch.php?q={urllib.parse.quote(q)}"
               f"&fl[]=identifier&fl[]=title&fl[]=year&fl[]=collection"
               f"&rows={rows}&page={page}&output=json")
        if sort:
            url += f"&sort[]={urllib.parse.quote(sort)}"
        return fetch.get_json(url, max_age=7 * 86400)

    def _q_for(self, query: str, platform: Optional[str]) -> str:
        # Free-text (all-fields) beats title: — these items keep the game name
        # in the identifier, not a clean title field.
        colls = COLLECTIONS.get(platform) if platform else \
            sum(COLLECTIONS.values(), ())
        q = query or "*"
        if colls:
            coll_q = " OR ".join(f'collection:{c}' for c in dict.fromkeys(colls))
            return f'({q}) AND ({coll_q})'
        # No scoped collection (264): keep it Commodore-ish to cut noise.
        return f'({q}) AND subject:(commodore)'

    def search(self, query: str, platform: str = None) -> list[SearchResult]:
        data = self._advanced(self._q_for(query, platform))
        out = []
        for doc in data.get("response", {}).get("docs", []):
            colls = doc.get("collection", [])
            title = doc.get("title", doc["identifier"])
            group, release = _tags(title, doc["identifier"])
            out.append(SearchResult(
                title=title,
                source=self.name, source_ref=doc["identifier"],
                platform=platform or _collection_platform(colls),
                group_name=group, release_name=release,
                year=int(doc["year"]) if str(doc.get("year", "")).isdigit() else None,
                source_url=f"{BASE}/details/{doc['identifier']}",
                extra={"collection": colls}))
        return out

    def list_all(self, platform: Optional[str] = None) -> Iterable[SearchResult]:
        """Enumerate whole collections via the advancedsearch page API.

        NOT the scrape API: archive.org's CDN caches the scrape endpoint
        ignoring the `cursor` query param, so every page comes back identical
        and pagination loops forever (23M+ dupes before it's noticed). The
        advancedsearch page/rows API genuinely advances; a stable
        `identifier asc` sort keeps paging deterministic so nothing is skipped
        or repeated as the index shifts. Its price is a hard deep-paging cap
        (rows*page must stay under ~10000): a collection larger than that has
        its tail truncated — surfaced loudly, never silently dropped."""
        colls = COLLECTIONS.get(platform) or sum(COLLECTIONS.values(), ())
        rows = 200
        for c in dict.fromkeys(colls):
            page, seen, total = 1, 0, None
            while page * rows <= self.DEEP_PAGE_LIMIT:
                data = self._advanced(f"collection:{c}", rows=rows, page=page,
                                      sort="identifier asc")
                resp = data.get("response", {})
                docs = resp.get("docs", [])
                if total is None:
                    total = resp.get("numFound", 0)
                if not docs:
                    break
                for doc in docs:
                    title = doc.get("title", doc["identifier"])
                    group, release = _tags(title, doc["identifier"])
                    yield SearchResult(
                        title=title,
                        source=self.name, source_ref=doc["identifier"],
                        platform=platform or _collection_platform(c),
                        group_name=group, release_name=release,
                        year=(int(doc["year"])
                              if str(doc.get("year", "")).isdigit() else None),
                        source_url=f"{BASE}/details/{doc['identifier']}")
                    seen += 1
                if seen >= (total or 0):
                    break
                page += 1
            if total and seen < total:
                import sys
                print(f"archive: WARNING collection {c} has {total} items but "
                      f"advancedsearch deep-paging caps this pull at {seen} "
                      f"(~{self.DEEP_PAGE_LIMIT} limit); {total - seen} not "
                      f"fetched.", file=sys.stderr)

    def resolve(self, result: SearchResult) -> list[DownloadItem]:
        meta = fetch.get_json(f"{BASE}/metadata/{result.source_ref}",
                              max_age=7 * 86400)
        ident = result.source_ref
        md = meta.get("metadata", {})
        # `emulator_start` is the item's own launch path when it has an
        # in-browser emulator — it also marks which file is the payload.
        start = md.get("emulator_start") or ""
        items = []
        for f in meta.get("files", []):
            name = f.get("name", "")
            ext = os.path.splitext(name)[1].lower()
            if ext not in GAME_EXTS:
                continue
            items.append(DownloadItem(
                url=f"{BASE}/download/{ident}/{urllib.parse.quote(name)}",
                filename=os.path.basename(name),
                fmt=ext[1:],
                platform=result.platform,
                extra={"start": start} if start else {}))
        # The playable payload first: an emulator item's zip is the game, the
        # other archives (source, extras) are not.
        if start:
            want = (md.get("emulator_ext") or "zip").lower()
            items.sort(key=lambda i: (i.fmt != want, i.filename.lower()))
        return items


register(Archive())
