"""library/patches.py — committed corrections to what the sources tell us.

The online sources are the catalog's raw material, and some of what they say
is wrong.  archive.org's `Wizard_of_Wor_1983_Commodore_cr_ATG` is not Wizard
of Wor at all — the disk holds none of the game's files and boots the EA
platform game *Wizard* instead.  Downloading it, sending it to the board and
watching the wrong game come up is how that gets discovered, and that
knowledge has to survive:

  * a re-search, which re-inserts the row from the source verbatim;
  * a bulk `index` / `sync` of an entire collection;
  * a fresh checkout on another machine, which downloads nothing from us.

So corrections live HERE, in `data/patches.jsonl`, committed to git next to
the canon registry and the compat database, and they are re-applied every
time a catalog is opened.  The source can say what it likes; the patch wins.

A patch line matches a variant and sets fields on it:

    {"source":"archive","ref":"Wizard_of_Wor_1983_Commodore_cr_ATG",
     "title":"Wizard","game_canon":4188,
     "note":"mislabeled at the source: ...","by":"disk directory"}

Matching (at least one required):
    source + ref     the source's own stable id for the release
    sha1             the content hash — survives a source renaming its item

Fields that can be set:
    title            re-file the release under a different GAME (the fix for
                     "this is a different game entirely")
    game_canon       pin that game by canon ID, so a title that several games
                     share cannot send the release to the wrong one
    platform         the machine it is really for
    group / release  who made this dump
    year, publisher
    note             free text, kept on the variant and shown in the UI
    drop             true = not a game / unusable dump; hide it from listings

Nothing here carries game content — titles, ids and notes only, like every
other committed data file in this directory.
"""

from __future__ import annotations

import json
import os
from typing import Optional

FILE_MAGIC = "fpgago-catalog-patches"
FILE_VERSION = 1

# Everything a patch is allowed to say, so a typo is an error at load time
# rather than a correction that silently does nothing.
_MATCH_KEYS = {"source", "ref", "sha1"}
_SET_KEYS = {"title", "game_canon", "platform", "group", "release", "year",
             "publisher", "note", "drop"}
_META_KEYS = {"by", "date", "why"}          # provenance, not applied


class PatchError(Exception):
    """The patch file is malformed."""


def default_path() -> str:
    """<repo>/desktop/library/data/patches.jsonl (lives in git)."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "data", "patches.jsonl")


def load(path: Optional[str] = None) -> list[dict]:
    """Parse + validate the patch file.  [] when there is none."""
    path = path or default_path()
    if not os.path.exists(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8") as fh:
        for n, line in enumerate(fh, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                e = json.loads(line)
            except ValueError as exc:
                raise PatchError(f"{path}:{n}: bad JSON: {exc}") from exc
            if n == 1 or "patches" in e:
                if e.get("patches") != FILE_MAGIC:
                    raise PatchError(f"{path}:{n}: not a {FILE_MAGIC} file")
                continue
            _validate(e, f"{path}:{n}")
            out.append(e)
    return out


def _validate(e: dict, where: str):
    unknown = set(e) - _MATCH_KEYS - _SET_KEYS - _META_KEYS
    if unknown:
        raise PatchError(f"{where}: unknown field(s) {sorted(unknown)}")
    if not ((e.get("source") and e.get("ref")) or e.get("sha1")):
        raise PatchError(f"{where}: needs source+ref or sha1 to match on")
    if not (set(e) & _SET_KEYS):
        raise PatchError(f"{where}: matches something but changes nothing")


# ── applying ───────────────────────────────────────────────────────────────

def _target_variants(cat, p: dict) -> list[int]:
    """Variant row ids this patch matches.  Indexed lookups only — this runs
    on every catalog open, and the catalog has tens of thousands of rows."""
    if p.get("sha1"):
        rows = cat.db.execute(
            "SELECT DISTINCT variant_id FROM file WHERE sha1=? "
            "AND variant_id IS NOT NULL", (p["sha1"],)).fetchall()
        return [r[0] for r in rows]
    rows = cat.db.execute(
        "SELECT id FROM variant WHERE source=? AND source_ref=?",
        (p["source"], p["ref"])).fetchall()
    return [r[0] for r in rows]


def _game_for(cat, p: dict) -> Optional[int]:
    """The game row a re-filing patch points at, created if need be."""
    if p.get("game_canon") is not None:
        g = cat.game_by_canon(int(p["game_canon"]))
        if g is not None:
            return g["id"]
        # The registry knows this ID but this catalog has not imported it —
        # fall through to the title, and let canon reconcile them later.
    if not p.get("title"):
        return None
    from .db import GameRow
    return cat.upsert_game(GameRow(p["title"], year=p.get("year"),
                                   publisher=p.get("publisher")))


def apply(cat, path: Optional[str] = None) -> dict:
    """Re-apply every correction to `cat`.  Idempotent, and cheap enough to
    run on every open: one indexed lookup per patch.  Returns a summary."""
    try:
        patches = load(path)
    except PatchError:
        raise
    except OSError:
        return {"patches": 0, "changed": 0, "moved": 0}

    changed = moved = 0
    for p in patches:
        vids = _target_variants(cat, p)
        if not vids:
            continue                       # nothing of this release here yet
        gid = _game_for(cat, p) if (p.get("title") or p.get("game_canon")) \
            else None
        sets, args = [], []
        for key, col in (("platform", "platform"), ("group", "group_name"),
                         ("release", "release_name"), ("year", "year"),
                         ("note", "notes")):
            if p.get(key) is not None:
                sets.append(f"{col}=?")
                args.append(p[key])
        if p.get("drop") is not None:
            sets.append("hidden=?")
            args.append(1 if p["drop"] else 0)
        for vid in vids:
            row = cat.db.execute("SELECT game_id FROM variant WHERE id=?",
                                 (vid,)).fetchone()
            if gid is not None and row["game_id"] != gid:
                # Re-filing under the right game also has to release the
                # canon sub-ID: it belonged to the game this release is NOT.
                cat.db.execute(
                    "UPDATE variant SET game_id=?, canon_sub=NULL WHERE id=?",
                    (gid, vid))
                moved += 1
            if sets:
                cat.db.execute(f"UPDATE variant SET {', '.join(sets)} "
                               "WHERE id=?", (*args, vid))
            changed += 1
    if changed:
        cat.commit()
    return {"patches": len(patches), "changed": changed, "moved": moved}


def describe(p: dict) -> str:
    """One line for `patch list`."""
    who = f"{p['source']}:{p['ref']}" if p.get("ref") else f"sha1:{p['sha1'][:12]}"
    fixes = [f"{k}={p[k]!r}" for k in sorted(_SET_KEYS & set(p)) if k != "note"]
    return f"{who}  {'  '.join(fixes)}"
