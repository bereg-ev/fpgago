"""library/sources/csdb.py — CSDb (Commodore Scene Database) adapter.

CSDb models every crack/demo/intro by every team as a distinct numbered
Release, each linked to a Group — the canonical "who cracked it" data, i.e.
the variation attribution. Open XML webservice, no key:
    https://csdb.dk/webservice/?type=<release|group>&id=<N>&depth=<1-4>

NOTE: the webservice `type=search` returns "No result" for the open (logged-
out) API, so free-text search is NOT available here — discovery happens via
Plus4World / Archive.org, and CSDb is used for per-ID enrichment (pull a
release's group + download link, or walk a group's releases). robots.txt
disallows /search/ and /release/download.php (we use the getinternalfile URL
from the XML instead), and blocks a list of crawler user-agents — the UA in
fetch.py names this project and is deliberately not one of them.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import Optional

from .. import fetch
from ..db import PLATFORM_C64
from .base import Source, SearchResult, DownloadItem, register

WS = "https://csdb.dk/webservice/"


def _txt(el, tag, default=None):
    return el.findtext(tag, default) if el is not None else default


class CSDb(Source):
    name = "csdb"
    platforms = (PLATFORM_C64,)          # scene DB is overwhelmingly C64

    def _get(self, typ: str, id: int, depth: int = 2):
        xml = fetch.get(f"{WS}?type={typ}&id={id}&depth={depth}",
                        max_age=30 * 86400)
        return ET.fromstring(xml)

    def get_release(self, id: int) -> Optional[SearchResult]:
        root = self._get("release", id, depth=2)
        rel = root.find("Release")
        if rel is None:
            return None
        grp = rel.find("./ReleasedBy/Group")
        year = _txt(rel, "ReleaseYear")
        return SearchResult(
            title=_txt(rel, "Name", f"release {id}"),
            source=self.name, source_ref=f"release/{id}", platform=PLATFORM_C64,
            group_name=_txt(grp, "Name"), release_name=_txt(rel, "Type"),
            year=int(year) if year and year.isdigit() else None,
            source_url=f"https://csdb.dk/release/?id={id}",
            extra={"csdb_type": _txt(rel, "Type")})

    def resolve(self, result: SearchResult) -> list[DownloadItem]:
        if not result.source_ref.startswith("release/"):
            return []
        rid = result.source_ref.split("/")[1]
        root = self._get("release", int(rid), depth=2)
        items = []
        for dl in root.iter("DownloadLink"):
            link = _txt(dl, "Link") or (dl.text or "").strip()
            if link and link.startswith("http"):
                items.append(DownloadItem(
                    url=link, filename=link.rsplit("/", 1)[-1] or f"csdb_{rid}",
                    platform=PLATFORM_C64, group_name=result.group_name,
                    release_name=result.release_name))
        return items

    def group_releases(self, group_id: int) -> list[SearchResult]:
        """All releases by a group — walk the group's release list."""
        root = self._get("group", group_id, depth=2)
        gname = _txt(root.find("Group"), "Name")
        out = []
        for rel in root.iter("Release"):
            rid = _txt(rel, "ID")
            if not rid:
                continue
            out.append(SearchResult(
                title=_txt(rel, "Name", f"release {rid}"), source=self.name,
                source_ref=f"release/{rid}", platform=PLATFORM_C64,
                group_name=gname, release_name=_txt(rel, "Type"),
                source_url=f"https://csdb.dk/release/?id={rid}"))
        return out

    def search(self, query: str, platform: str = None):
        raise NotImplementedError(
            "CSDb open webservice has no free-text search; use get_release(id)/"
            "group_releases(id) for enrichment, or discover via archive/plus4world")


register(CSDb())
