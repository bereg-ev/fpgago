"""library/canon.py — the canonical (absolute) game-ID registry.

Every game in the library gets one permanent, project-wide ID so that any
two users (forum posts, COMPATIBILITY.md, bug reports, the BIOS one day)
can refer to exactly the same thing:

    #1234-K        the game (the abstract work)
    #1234-K/2      one specific release/crack of it (a variant)

The registry is a committed text file, `desktop/library/data/canon.jsonl`
— pure metadata (titles, years, groups, source URLs, content hashes), no
game content, so it carries no copyright payload.  It is append-only: an
ID, once published, is never reassigned or deleted; rebuilding only adds
new entries at the end.

Checksum guards, three layers:
  * ID check character — `1234-K`: K is a weighted mod-23 check over the
    digits (alphabet skips I/L/O), so a typo'd or transposed ID is caught
    at parse time instead of silently naming the wrong game.
  * file integrity footer — the last line of canon.jsonl holds counts and
    the sha1 of every preceding byte; a corrupted or hand-mangled registry
    refuses to load.
  * content hashes — entries record sha1/crc32 of the actual release file
    once known, so a download can be verified as byte-identical to what
    the ID was assigned to.

File layout (JSON Lines):
    {"canon": "fpgago-games", "v": 1}                      header
    {"id": 1, "chk": "…", "title": "…", "variants": […]}   one line per game
    …
    {"games": N, "variants": M, "sha1": "…"}               integrity footer
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from typing import Optional

from .db import Catalog, GameRow, VariantRow, normalize_title

# 23 letters (prime modulus), visually unambiguous: no I, L, O.
ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ"

FILE_MAGIC = "fpgago-games"
FILE_VERSION = 1


def default_path() -> str:
    """<repo>/desktop/library/data/canon.jsonl (lives in git)."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "data", "canon.jsonl")


# ── ID check character ──────────────────────────────────────────────────────

def check_char(canon_id: int) -> str:
    """Weighted digit sum mod 23 → letter.  Weights grow from the least
    significant digit so every single-digit error and every adjacent
    transposition of unequal digits changes the result."""
    total = 0
    for i, ch in enumerate(reversed(str(int(canon_id)))):
        total += (i + 1) * int(ch)
    return ALPHABET[total % len(ALPHABET)]


def format_id(canon_id: int, sub: Optional[int] = None) -> str:
    s = f"#{canon_id}-{check_char(canon_id)}"
    return f"{s}/{sub}" if sub is not None else s


def flash_ident(canon_id: Optional[int], sub: Optional[int] = None):
    """The canon ID as it goes into a board flash name: '4193.7'.

    Same identity as format_id's '#4193-U/7', spelled for a 35-character
    filename — '#' and '/' are not filename material, and the check character
    is redundant in a name nobody retypes.  Returning None (no ID yet) is the
    caller's cue to fall back on the local row id."""
    if canon_id is None:
        return None
    return f"{canon_id}.{sub}" if sub is not None else str(canon_id)


_ID_RE = re.compile(r"^#?(\d+)(?:-([A-Za-z]))?(?:/(\d+))?$")


def parse_id(text: str):
    """'#1234-K/2' | '1234-K' | '1234' → (canon_id, sub_or_None).

    A present check character is verified (ValueError on mismatch); a bare
    number is accepted for convenience but gets no typo protection."""
    m = _ID_RE.match(text.strip())
    if not m:
        raise ValueError(f"not a canon ID: {text!r}")
    canon_id = int(m.group(1))
    chk, sub = m.group(2), m.group(3)
    if chk is not None and chk.upper() != check_char(canon_id):
        raise ValueError(
            f"bad check character in {text!r}: expected "
            f"{format_id(canon_id)} — typo in the number or the letter")
    return canon_id, (int(sub) if sub is not None else None)


# ── registry file I/O ───────────────────────────────────────────────────────

class CanonError(Exception):
    """The registry file is corrupt or inconsistent."""


def _dump(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def read_footer(path: str) -> Optional[dict]:
    """Cheap peek at the integrity footer (last line) without a full parse."""
    try:
        with open(path, "rb") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    if not lines:
        return None
    try:
        foot = json.loads(lines[-1])
    except ValueError:
        return None
    return foot if "sha1" in foot and "games" in foot else None


def load_file(path: str) -> list[dict]:
    """Parse + verify the registry.  Returns the game entries (dicts)."""
    with open(path, "rb") as fh:
        raw = fh.read()
    lines = raw.splitlines(keepends=True)
    if len(lines) < 2:
        raise CanonError(f"{path}: too short to be a canon registry")
    body, footer_line = lines[:-1], lines[-1]
    try:
        footer = json.loads(footer_line)
    except ValueError as e:
        raise CanonError(f"{path}: unreadable integrity footer: {e}") from e
    digest = hashlib.sha1(b"".join(body)).hexdigest()
    if footer.get("sha1") != digest:
        raise CanonError(
            f"{path}: integrity check FAILED — file modified or truncated "
            f"(footer sha1 {footer.get('sha1')}, actual {digest})")
    try:
        header = json.loads(body[0])
    except ValueError as e:
        raise CanonError(f"{path}: bad header: {e}") from e
    if header.get("canon") != FILE_MAGIC:
        raise CanonError(f"{path}: not a {FILE_MAGIC} registry")

    entries, seen = [], set()
    nvar = 0
    for i, line in enumerate(body[1:], start=2):
        try:
            e = json.loads(line)
        except ValueError as exc:
            raise CanonError(f"{path}:{i}: bad JSON: {exc}") from exc
        cid = e.get("id")
        if not isinstance(cid, int) or cid in seen:
            raise CanonError(f"{path}:{i}: missing or duplicate id {cid!r}")
        if e.get("chk") != check_char(cid):
            raise CanonError(f"{path}:{i}: id {cid} check char is "
                             f"{e.get('chk')!r}, expected {check_char(cid)!r}")
        seen.add(cid)
        nvar += len(e.get("variants", []))
        entries.append(e)
    if footer.get("games") != len(entries) or footer.get("variants") != nvar:
        raise CanonError(f"{path}: footer counts ({footer.get('games')} games, "
                         f"{footer.get('variants')} variants) don't match body "
                         f"({len(entries)}/{nvar})")
    return entries


def write_file(path: str, entries: list[dict]) -> dict:
    """Write the registry with header + integrity footer.  Returns the footer."""
    entries = sorted(entries, key=lambda e: e["id"])
    body_lines = [_dump({"canon": FILE_MAGIC, "v": FILE_VERSION})]
    nvar = 0
    for e in entries:
        e["chk"] = check_char(e["id"])
        nvar += len(e.get("variants", []))
        body_lines.append(_dump(e))
    body = ("\n".join(body_lines) + "\n").encode("utf-8")
    footer = {"games": len(entries), "variants": nvar,
              "sha1": hashlib.sha1(body).hexdigest()}
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(body)
        fh.write((_dump(footer) + "\n").encode("utf-8"))
    os.replace(tmp, path)
    return footer


# ── writing (frozen) ───────────────────────────────────────────────────────
#
# `build()` and `assign()` used to live here: they minted IDs locally, by
# taking max(id)+1 of a git-committed file and appending to it.  That only
# ever worked because everybody agreed to commit the same append-only file in
# the same order — and two people downloading the same evening got the same
# number.  fpgago.com hands out IDs now (library/webdb.py), so the client
# reads this format and no longer writes it.  `write_file` stays because the
# tests and any future export need to be able to produce one.

# ── import: registry → local catalog ───────────────────────────────────────

def ensure_imported(cat: Catalog, path: Optional[str] = None) -> bool:
    """Sync the committed registry into the local catalog (idempotent, cheap
    when already in sync — compares the footer sha1 against a meta marker).
    This is how a fresh checkout gets the full ID space without any
    downloads.  Returns True if an import ran."""
    path = path or default_path()
    footer = read_footer(path)
    if footer is None:
        return False
    if cat.meta_get("canon_sha1") == footer["sha1"]:
        return False
    for e in load_file(path):
        gid = cat.upsert_game(GameRow(e["title"], year=e.get("year"),
                                      publisher=e.get("publisher"),
                                      genre=e.get("genre")))
        cat.db.execute("UPDATE game SET canon_id=? WHERE id=?", (e["id"], gid))
        for ve in e.get("variants", []):
            vid = cat.upsert_variant(gid, VariantRow(
                platform=ve.get("platform", "264"),
                source=ve.get("source", "canon"),
                source_ref=ve.get("ref") or f"canon:{e['id']}/{ve['n']}",
                group_name=ve.get("group"), release_name=ve.get("release"),
                year=ve.get("year"), fmt=ve.get("fmt"),
                source_url=ve.get("url")))
            cat.db.execute("UPDATE variant SET canon_sub=? WHERE id=?",
                           (ve["n"], vid))
    cat.meta_set("canon_sha1", footer["sha1"])
    cat.commit()
    return True


# ── lookups ─────────────────────────────────────────────────────────────────

def entry_for(canon_id: int, sub: Optional[int] = None,
              path: Optional[str] = None):
    """(game_entry, variant_entry|None) straight from the registry file."""
    for e in load_file(path or default_path()):
        if e["id"] == canon_id:
            if sub is None:
                return e, None
            for ve in e.get("variants", []):
                if ve["n"] == sub:
                    return e, ve
            return e, None
    return None, None
