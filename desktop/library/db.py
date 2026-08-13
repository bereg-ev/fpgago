"""
library/db.py — local SQLite catalog for the fpgago game library.

The library separates three levels so that "the same game with different
intros by different cracker teams" is a first-class concept:

  game     — the abstract work, matched across sources by a normalised title
             (e.g. "Boulder Dash").  Platform-agnostic.
  variant  — one released/cracked variation on ONE platform: the (group,
             release-name, platform, source) tuple.  This is what you pick
             when a game "needs a specific version to run" during validation.
  file     — a concrete local file for a variant, with its content hashes and
             the classifier's verdict (load address, machine, memory top).

Identity of a variation is ultimately the file **content hash** (sha1 for
exact dedup, crc32 to cross-reference TOSEC / GameBase64 which key on CRC32).
Two dumps with the same sha1 are the same release; a different sha1 for the
same title is a different intro/crack.

Populated two ways (see PLAN.md D4):
  * search-on-demand — a search caches source results into `search_cache`
    and materialises matching game/variant rows (C64/Plus4 flow);
  * bulk sync — the full C16 set from Plus4World (small, enumerable).

Stdlib only (sqlite3); no PySide6 import, so the CLI works headless.
"""

from __future__ import annotations

import os
import re
import sqlite3
import time
from dataclasses import dataclass, field
from typing import Optional

SCHEMA_VERSION = 3

# Canonical platform tokens used throughout the library.
PLATFORM_C64 = "c64"
PLATFORM_C16 = "c16"
PLATFORM_PLUS4 = "plus4"
PLATFORM_264 = "264"      # c16-or-plus4, not yet disambiguated
PLATFORMS = (PLATFORM_C64, PLATFORM_C16, PLATFORM_PLUS4, PLATFORM_264)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);

-- The abstract work, matched across sources by title_norm.
CREATE TABLE IF NOT EXISTS game (
    id         INTEGER PRIMARY KEY,
    title      TEXT NOT NULL,
    title_norm TEXT NOT NULL,
    year       INTEGER,
    publisher  TEXT,
    genre      TEXT,
    canon_id   INTEGER,                  -- absolute project-wide ID (canon.py)
    multiplayer INTEGER NOT NULL DEFAULT 0,  -- server says: seats 2+ players
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_game_norm ON game(title_norm);

-- One released variation on one platform (the "which crack/intro" unit).
CREATE TABLE IF NOT EXISTS variant (
    id           INTEGER PRIMARY KEY,
    game_id      INTEGER NOT NULL REFERENCES game(id) ON DELETE CASCADE,
    platform     TEXT NOT NULL,          -- c64 / c16 / plus4 / 264
    group_name   TEXT,                   -- cracker / release group
    release_name TEXT,                   -- the release's own title, if any
    year         INTEGER,
    fmt          TEXT,                    -- prg / d64 / tap / t64 / crt
    source       TEXT NOT NULL,          -- plus4world / csdb / gb64 / archive / local
    source_ref   TEXT,                   -- stable id at the source
    source_url   TEXT,
    validated    INTEGER DEFAULT 0,      -- 0 unknown, 1 runs, -1 broken (validation)
    canon_sub    INTEGER,                -- variant number inside the canon game
    hidden       INTEGER NOT NULL DEFAULT 0,  -- a patch says: not worth listing
    notes        TEXT,
    added_at     REAL NOT NULL,
    UNIQUE(source, source_ref)
);
CREATE INDEX IF NOT EXISTS ix_variant_game ON variant(game_id, platform);

-- A concrete local file for a variant + the classifier's verdict.
CREATE TABLE IF NOT EXISTS file (
    id               INTEGER PRIMARY KEY,
    variant_id       INTEGER REFERENCES variant(id) ON DELETE CASCADE,
    filename         TEXT NOT NULL,
    path             TEXT,               -- absolute local path, NULL until downloaded
    size             INTEGER,
    sha1             TEXT,
    crc32            TEXT,               -- 8-hex-digit, TOSEC/GB64 convention
    load_addr        INTEGER,            -- e.g. 0x0801 / 0x1001, NULL if n/a
    mem_top          INTEGER,            -- highest byte the first file occupies
    machine_detected TEXT,              -- classifier verdict (may differ from variant.platform)
    confidence       TEXT,               -- high / medium / low
    status           TEXT DEFAULT 'pending',  -- pending/downloaded/verified/missing
    added_at         REAL NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ix_file_sha1 ON file(sha1) WHERE sha1 IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_file_crc ON file(crc32);
CREATE INDEX IF NOT EXISTS ix_file_variant ON file(variant_id);

-- Raw cached source responses, so a repeated search is offline + cheap.
CREATE TABLE IF NOT EXISTS search_cache (
    id         INTEGER PRIMARY KEY,
    source     TEXT NOT NULL,
    query      TEXT NOT NULL,
    raw        TEXT,                     -- raw JSON/HTML the adapter returned
    fetched_at REAL NOT NULL,
    UNIQUE(source, query)
);
"""


# ── title normalisation (cross-source matching) ─────────────────────────────

_ROMAN = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5"}
_PAREN = re.compile(r"[\(\[\{].*?[\)\]\}]")       # (1984), [Nostalgia], ...
_NONWORD = re.compile(r"[^a-z0-9]+")


def normalize_title(title: str) -> str:
    """Fold a raw title to a stable matching key.

    Lowercases, drops bracketed tags (year / group / TOSEC flags), strips a
    leading article, maps small roman numerals, and squashes punctuation:
        "The Last Ninja II (1988) [Nostalgia]" -> "last ninja 2"
    """
    t = title.lower()
    t = _PAREN.sub(" ", t)
    t = _NONWORD.sub(" ", t).strip()
    if t.startswith("the "):
        t = t[4:]
    if t.startswith("a "):
        t = t[2:]
    words = [_ROMAN.get(w, w) for w in t.split()]
    return " ".join(words)


# ── release tags (which crack is this?) ────────────────────────────────────
# The one thing that tells two dumps of a game apart in a list is who made
# them: "cr Bandit" vs "cr ATG" vs "h OleanderAngels".  Sources carry that in
# a TOSEC-style name, but archive.org's identifiers have been through a
# filename-safe squash that turns every bracket into an underscore:
#     Wizard of Wor (1983)(Commodore)[cr Bandit]
#     Wizard_of_Wor_1983_Commodore_cr_Bandit
# Both forms are read here, so twelve releases of one game stop rendering as
# twelve identical rows.
#
# This is a DISPLAY/NAMING heuristic, never an identity one: a game is
# identified by its canon ID and its content hash, so a tag misread out of an
# unusual title costs a slightly wrong label and nothing else.

# TOSEC-ish dump flags: cr=cracked, h=hacked, t=trained, f=fixed, tr=
# translated, m=modified, p=pirate, a=alternate, b=bad dump.
_TAG_FLAGS = ("cr", "h", "t", "f", "tr", "m", "p", "a", "b")
# The flags that name a scene group, in credit order: whoever cracked it is
# the headline, and a trainer's author (`t 3 REM Docs`) only gets the credit
# when nobody else is named.
_GROUP_FLAGS = ("cr", "h", "f", "tr", "p", "t")
_BRACKET = re.compile(r"\[([^\]]+)\]")
_UNDERSCORE_TAG = re.compile(
    r"_(" + "|".join(_TAG_FLAGS) + r")_(?=[A-Za-z0-9])")


def parse_release_tags(name: str) -> tuple[Optional[str], Optional[str]]:
    """(group_name, release_name) read out of a source's release name.

    `release_name` is the whole tag chain as one readable string ("cr REM t 3
    REM Docs"); `group_name` is the scene group that gets the headline credit
    ("REM").  (None, None) when the name carries no tags — an original dump.
    """
    if not name:
        return None, None
    tags = [t.strip() for t in _BRACKET.findall(name) if t.strip()]
    if not tags:
        m = _UNDERSCORE_TAG.search(name)
        if not m:
            return None, None
        # Everything from the first flag on is tag text; the squash lost the
        # bracket boundaries, so it comes back as one chain, not a list.
        tags = [name[m.start() + 1:].replace("_", " ").strip()]
    release = " ".join(tags)
    words = release.split()
    group = None
    for flag in _GROUP_FLAGS:
        if flag in words:
            rest = words[words.index(flag) + 1:]
            while rest and rest[0].isdigit():
                rest = rest[1:]          # "t 1 Angels" — 1 is the trainer count
            # stop at the next flag: "cr Angels t 1 Angels" -> "Angels"
            take = []
            for w in rest:
                if w in _TAG_FLAGS or w.isdigit():
                    break
                take.append(w)
            if take:
                group = " ".join(take)
                break
    return group, (release or None)


# ── dataclasses (thin, for adapter/classifier hand-off) ─────────────────────

@dataclass
class GameRow:
    title: str
    year: Optional[int] = None
    publisher: Optional[str] = None
    genre: Optional[str] = None


@dataclass
class VariantRow:
    platform: str
    source: str
    source_ref: str
    group_name: Optional[str] = None
    release_name: Optional[str] = None
    year: Optional[int] = None
    fmt: Optional[str] = None
    source_url: Optional[str] = None
    notes: Optional[str] = None


@dataclass
class FileRow:
    filename: str
    path: Optional[str] = None
    size: Optional[int] = None
    sha1: Optional[str] = None
    crc32: Optional[str] = None
    load_addr: Optional[int] = None
    mem_top: Optional[int] = None
    machine_detected: Optional[str] = None
    confidence: Optional[str] = None
    status: str = "pending"


# ── the catalog ─────────────────────────────────────────────────────────────

class Catalog:
    """Thin wrapper over the SQLite file; safe to open per-process."""

    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(_SCHEMA)
        self._migrate()
        self.db.execute(
            "INSERT OR REPLACE INTO meta(key,value) VALUES('schema',?)",
            (str(SCHEMA_VERSION),),
        )
        self.db.commit()
        self._apply_patches()

    def _apply_patches(self):
        """Re-apply the committed corrections (library/patches.py).

        Here, on every open, and not once at import time: a source can hand
        the same wrong row back on any search, any bulk index, any fresh
        checkout, and a correction that only ran once would be undone by the
        next fetch.  One indexed lookup per patch, so it stays cheap on a
        catalog of tens of thousands of rows.  Never fatal — a broken patch
        file must not make the library unopenable.
        """
        self.patch_error = None
        try:
            from . import patches
            patches.apply(self)
        except Exception as e:                   # noqa: BLE001
            self.patch_error = str(e)            # `patch verify` reports it

    def _migrate(self):
        """v1 → v2: canon ID columns; v2 → v3: the multiplayer flag (CREATE
        IF NOT EXISTS won't alter an existing table, so probe the columns and
        ALTER in place)."""
        def cols(table):
            return {r["name"] for r in
                    self.db.execute(f"PRAGMA table_info({table})")}
        if "canon_id" not in cols("game"):
            self.db.execute("ALTER TABLE game ADD COLUMN canon_id INTEGER")
        if "multiplayer" not in cols("game"):
            self.db.execute("ALTER TABLE game ADD COLUMN multiplayer "
                            "INTEGER NOT NULL DEFAULT 0")
        if "canon_sub" not in cols("variant"):
            self.db.execute("ALTER TABLE variant ADD COLUMN canon_sub INTEGER")
        if "hidden" not in cols("variant"):
            self.db.execute("ALTER TABLE variant ADD COLUMN hidden "
                            "INTEGER NOT NULL DEFAULT 0")
        self.db.execute("""CREATE UNIQUE INDEX IF NOT EXISTS ix_game_canon
                           ON game(canon_id) WHERE canon_id IS NOT NULL""")
        self._backfill_release_tags()

    def _backfill_release_tags(self):
        """Fill group/release for variants catalogued before the tags were
        parsed.  Without this every archive.org row in an existing library
        shows a blank group, so a dozen cracks of one game are a dozen
        indistinguishable rows (board, 2026-08-05).  One pass, then a meta
        marker — the source_ref of an existing row never changes."""
        if self.meta_get("release_tags_backfilled") == "1":
            return
        rows = self.db.execute(
            """SELECT id, source_ref FROM variant
               WHERE group_name IS NULL AND release_name IS NULL
                 AND source_ref IS NOT NULL""").fetchall()
        for r in rows:
            group, release = parse_release_tags(r["source_ref"])
            if group or release:
                self.db.execute(
                    "UPDATE variant SET group_name=?, release_name=? WHERE id=?",
                    (group, release, r["id"]))
        self.meta_set("release_tags_backfilled", "1")
        self.db.commit()

    def close(self):
        self.db.close()

    # -- meta ------------------------------------------------------------------

    def meta_get(self, key: str) -> Optional[str]:
        row = self.db.execute("SELECT value FROM meta WHERE key=?",
                              (key,)).fetchone()
        return row["value"] if row else None

    def meta_set(self, key: str, value: str):
        self.db.execute(
            "INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (key, value))

    # -- games ---------------------------------------------------------------

    def upsert_game(self, g: GameRow) -> int:
        """Find-or-create a game by normalised title; enrich blank fields."""
        norm = normalize_title(g.title)
        cur = self.db.execute(
            "SELECT id, year, publisher, genre FROM game WHERE title_norm=?",
            (norm,),
        )
        row = cur.fetchone()
        if row:
            gid = row["id"]
            # Fill in any fields the existing row is missing.
            self.db.execute(
                """UPDATE game SET year=COALESCE(year,?),
                       publisher=COALESCE(publisher,?),
                       genre=COALESCE(genre,?) WHERE id=?""",
                (g.year, g.publisher, g.genre, gid),
            )
            return gid
        cur = self.db.execute(
            """INSERT INTO game(title,title_norm,year,publisher,genre,created_at)
               VALUES(?,?,?,?,?,?)""",
            (g.title, norm, g.year, g.publisher, g.genre, time.time()),
        )
        return cur.lastrowid

    # -- variants ------------------------------------------------------------

    def upsert_variant(self, game_id: int, v: VariantRow) -> int:
        """Find-or-create by (source, source_ref)."""
        cur = self.db.execute(
            "SELECT id FROM variant WHERE source=? AND source_ref=?",
            (v.source, v.source_ref),
        )
        row = cur.fetchone()
        if row:
            return row["id"]
        cur = self.db.execute(
            """INSERT INTO variant(game_id,platform,group_name,release_name,
                   year,fmt,source,source_ref,source_url,notes,added_at)
               VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
            (game_id, v.platform, v.group_name, v.release_name, v.year, v.fmt,
             v.source, v.source_ref, v.source_url, v.notes, time.time()),
        )
        return cur.lastrowid

    def set_variant_platform(self, variant_id: int, platform: str):
        self.db.execute("UPDATE variant SET platform=? WHERE id=?",
                        (platform, variant_id))

    def set_validated(self, variant_id: int, state: int, notes: str = None):
        self.db.execute(
            "UPDATE variant SET validated=?, notes=COALESCE(?,notes) WHERE id=?",
            (state, notes, variant_id))

    # -- files ---------------------------------------------------------------

    def add_file(self, variant_id: Optional[int], f: FileRow) -> int:
        """Insert a file; if its sha1 already exists, return that row instead
        (identical dumps are the same release — the dedup key)."""
        if f.sha1:
            cur = self.db.execute("SELECT id FROM file WHERE sha1=?", (f.sha1,))
            row = cur.fetchone()
            if row:
                return row["id"]
        crc = f"{f.crc32:08x}" if isinstance(f.crc32, int) else f.crc32
        cur = self.db.execute(
            """INSERT INTO file(variant_id,filename,path,size,sha1,crc32,
                   load_addr,mem_top,machine_detected,confidence,status,added_at)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            (variant_id, f.filename, f.path, f.size, f.sha1, crc,
             f.load_addr, f.mem_top, f.machine_detected, f.confidence,
             f.status, time.time()),
        )
        return cur.lastrowid

    def find_by_hash(self, sha1: str = None, crc32: str = None):
        if sha1:
            return self.db.execute("SELECT * FROM file WHERE sha1=?",
                                   (sha1,)).fetchone()
        if crc32:
            return self.db.execute("SELECT * FROM file WHERE crc32=?",
                                   (crc32,)).fetchone()
        return None

    # -- search cache --------------------------------------------------------

    def cache_get(self, source: str, query: str, max_age: float = None):
        row = self.db.execute(
            "SELECT raw, fetched_at FROM search_cache WHERE source=? AND query=?",
            (source, query)).fetchone()
        if not row:
            return None
        if max_age is not None and (time.time() - row["fetched_at"]) > max_age:
            return None
        return row["raw"]

    def cache_put(self, source: str, query: str, raw: str):
        self.db.execute(
            """INSERT INTO search_cache(source,query,raw,fetched_at)
               VALUES(?,?,?,?)
               ON CONFLICT(source,query) DO UPDATE SET raw=excluded.raw,
                   fetched_at=excluded.fetched_at""",
            (source, query, raw, time.time()))

    # -- queries -------------------------------------------------------------

    def search_local(self, query: str, platform: str = None):
        """Local catalog search: games whose normalised title contains EVERY
        word of the normalised query, in any order and anywhere in the title.

        Matching the query as one contiguous substring is what a user's typing
        never is: "wizard wor" found nothing, because "wizard of wor" does not
        contain those two words side by side.  Per-word AND fixes that, and it
        is also what makes a partial last word ("wor") behave like the prefix
        the user meant.  Titles that DO contain the whole phrase still sort
        first, so the obvious hit stays at the top."""
        norm = normalize_title(query)
        words = norm.split()
        sql = """SELECT g.id, g.title, g.year, g.publisher, g.canon_id,
                        g.multiplayer,
                        COUNT(v.id) AS n_variants,
                        GROUP_CONCAT(DISTINCT v.platform) AS platforms
                 FROM game g LEFT JOIN variant v ON v.game_id=g.id
                 WHERE 1=1"""
        args = []
        for w in words:
            sql += " AND g.title_norm LIKE ?"
            args.append(f"%{w}%")
        if platform:
            sql += " AND v.platform=?"
            args.append(platform)
        # Sort keys, not filters.  Whole phrase first, then titles that BEGIN
        # with the first word — without that second key "wizard wor" led with
        # "Crossword Wizard" purely because C sorts before W.
        sql += " GROUP BY g.id ORDER BY"
        if norm:
            sql += " (CASE WHEN g.title_norm LIKE ? THEN 0 ELSE 1 END),"
            args.append(f"%{norm}%")
        if words:
            sql += " (CASE WHEN g.title_norm LIKE ? THEN 0 ELSE 1 END),"
            args.append(f"{words[0]}%")
        sql += " g.title"
        return self.db.execute(sql, args).fetchall()

    def search_canon(self, canon_id: int):
        """The one game with this canonical ID, shaped like search_local()'s
        rows so the caller cannot tell which of the two answered."""
        return self.db.execute(
            """SELECT g.id, g.title, g.year, g.publisher, g.canon_id,
                      g.multiplayer,
                      COUNT(v.id) AS n_variants,
                      GROUP_CONCAT(DISTINCT v.platform) AS platforms
               FROM game g LEFT JOIN variant v ON v.game_id=g.id
               WHERE g.canon_id=? GROUP BY g.id""", (canon_id,)).fetchall()

    def easyflash_game_ids(self) -> set:
        """The games that have an EasyFlash cartridge release.

        Nothing in the schema records "this is a cartridge": `fmt` is only
        filled in for releases this machine has classified itself, and the
        synced catalog leaves it NULL.  What the catalog does carry is how the
        release calls itself — "cr Onslaught EasyFlash 2011-10-16" — and, once
        a release is downloaded, its file names.  So both are searched, plus
        the local `fmt` for anything classify.py has already labelled.

        Only the c64 has an EasyFlash port (retro-arch/c64/README.md);
        the platform filter is left to the caller so a mis-tagged release
        still turns up rather than silently vanishing.
        """
        rows = self.db.execute(
            """SELECT DISTINCT v.game_id FROM variant v
               LEFT JOIN file f ON f.variant_id=v.id
               WHERE v.fmt LIKE '%crt%'
                  OR v.release_name LIKE '%easyflash%'
                  OR v.group_name   LIKE '%easyflash%'
                  OR v.source_ref   LIKE '%easyflash%'
                  OR v.source_url   LIKE '%easyflash%'
                  OR v.notes        LIKE '%easyflash%'
                  OR f.filename     LIKE '%.crt'""").fetchall()
        return {r[0] for r in rows}

    def get_variant(self, variant_id: int):
        """A variant joined to its game title (for download/resolve)."""
        return self.db.execute(
            """SELECT v.*, g.title AS game_title, g.canon_id AS game_canon
               FROM variant v
               JOIN game g ON g.id=v.game_id WHERE v.id=?""",
            (variant_id,)).fetchone()

    def game_by_canon(self, canon_id: int):
        return self.db.execute("SELECT * FROM game WHERE canon_id=?",
                               (canon_id,)).fetchone()

    def variant_by_canon(self, canon_id: int, sub: int):
        return self.db.execute(
            """SELECT v.*, g.title AS game_title, g.canon_id AS game_canon
               FROM variant v JOIN game g ON g.id=v.game_id
               WHERE g.canon_id=? AND v.canon_sub=?""",
            (canon_id, sub)).fetchone()

    def files_for_variant(self, variant_id: int):
        return self.db.execute(
            "SELECT * FROM file WHERE variant_id=? ORDER BY id",
            (variant_id,)).fetchall()

    def variants_for_game(self, game_id: int, include_hidden: bool = False):
        """The releases of a game.  Ones a patch has marked `drop` (a bad
        dump, or not a game at all) are left out: the whole point of saying
        so in the patch file is not to be offered them again."""
        sql = ("""SELECT v.*, (SELECT COUNT(*) FROM file f WHERE f.variant_id=v.id)
                         AS n_files
                  FROM variant v WHERE v.game_id=?""")
        if not include_hidden:
            sql += " AND v.hidden=0"
        sql += " ORDER BY v.platform, v.group_name"
        return self.db.execute(sql, (game_id,)).fetchall()

    def stats(self):
        def n(t):
            return self.db.execute(f"SELECT COUNT(*) c FROM {t}").fetchone()["c"]
        by_plat = dict(self.db.execute(
            "SELECT platform, COUNT(*) c FROM variant GROUP BY platform"
        ).fetchall())
        return {"games": n("game"), "variants": n("variant"),
                "files": n("file"), "by_platform": by_plat}

    def commit(self):
        self.db.commit()
