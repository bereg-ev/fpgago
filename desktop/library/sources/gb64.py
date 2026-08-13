"""library/sources/gb64.py — GameBase64 local-database adapter (C64).

GB64 is the most complete C64 metadata set (name, year, publisher, programmer,
musician, genre, and crucially Cracker/Version), but it ships as a bulk MS
Access .mdb (~15 GB with media; game binaries ~755 MB) — the site 403s bots,
so this is NOT a scraper: point it at a LOCAL copy.

Supported inputs (auto-detected under the library root or via $GB64_DB):
  * gb64.sqlite  — the community SQLite conversion (preferred; queried directly)
  * GBC_v*.mdb   — needs `mdbtools` (mdb-export) on PATH to read

Value here is metadata enrichment (Cracker → variation group, Year/Publisher/
Genre) for C64 titles discovered/owned elsewhere. Schema varies by converter,
so column lookup is introspective and defensive.
"""

from __future__ import annotations

import glob
import os
import sqlite3
from typing import Optional

from .. import config
from ..db import PLATFORM_C64
from .base import Source, SearchResult, register


def _find_db() -> Optional[str]:
    env = os.environ.get("GB64_DB")
    if env and os.path.exists(env):
        return env
    for pat in ("gb64.sqlite", "GBC_v*.sqlite", "*.sqlite"):
        hits = glob.glob(os.path.join(config.games_root(), pat)) + \
            glob.glob(os.path.join(config.games_root(), "gb64", pat))
        for h in hits:
            if "library.db" not in h:
                return h
    return None


# Candidate column names across GB64 converters (case-insensitive match).
_COLS = {
    "name": ("Name", "GA_Name", "Title"),
    "year": ("Year", "GA_Year"),
    "cracker": ("Cracker", "CracksExtraInfo", "Crack"),
    "publisher": ("Publisher", "PU_Name"),
    "genre": ("Genre", "GE_Name"),
    "filename": ("Filename", "GA_Filename", "FileToRun"),
}


class GB64(Source):
    name = "gb64"
    platforms = (PLATFORM_C64,)

    def __init__(self):
        self._db = _find_db()
        self._map = None
        self._table = None

    def available(self) -> bool:
        return self._db is not None

    def _resolve_schema(self, con):
        if self._map is not None:
            return
        cur = con.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [r[0] for r in cur.fetchall()]
        # Prefer a table literally called Games.
        table = next((t for t in tables if t.lower() == "games"), None) or \
            (tables[0] if tables else None)
        self._table = table
        colmap = {}
        if table:
            cols = [r[1] for r in con.execute(f'PRAGMA table_info("{table}")')]
            low = {c.lower(): c for c in cols}
            for key, cands in _COLS.items():
                for cand in cands:
                    if cand.lower() in low:
                        colmap[key] = low[cand.lower()]
                        break
        self._map = colmap

    def search(self, query: str,
               platform: str = None) -> list[SearchResult]:
        if not self._db:
            raise NotImplementedError(
                "GB64 database not found — put gb64.sqlite under "
                f"{config.games_root()} or set $GB64_DB (convert the .mdb with "
                "mdbtools). GB64 is C64 metadata enrichment, not a scraper.")
        con = sqlite3.connect(self._db)
        try:
            self._resolve_schema(con)
            m, t = self._map, self._table
            if not t or "name" not in m:
                return []
            sel = ", ".join(f'"{m[k]}"' for k in m)
            rows = con.execute(
                f'SELECT {sel} FROM "{t}" WHERE "{m["name"]}" LIKE ? LIMIT 200',
                (f"%{query}%",)).fetchall()
            keys = list(m.keys())
            out = []
            for r in rows:
                d = dict(zip(keys, r))
                yr = str(d.get("year", "") or "")
                out.append(SearchResult(
                    title=d.get("name", "?"), source=self.name,
                    source_ref=str(d.get("filename") or d.get("name")),
                    platform=PLATFORM_C64, group_name=d.get("cracker") or None,
                    year=int(yr) if yr.isdigit() else None,
                    publisher=d.get("publisher") or None,
                    genre=d.get("genre") or None,
                    extra={"gb64_file": d.get("filename")}))
            return out
        finally:
            con.close()


register(GB64())
