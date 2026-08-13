"""library/webdb.py — the game database, synced from fpgago.com.

Where the catalog used to come from a dozen scrapers running on every user's
machine, it now comes from one place that does the scraping once:

    GET  /api/v1/manifest       what exists, and the sha1 of each file
    GET  /media/gamedb/c64.jsonl   …only the files whose sha1 changed

The files are the same JSON-Lines format the committed `canon.jsonl` always
had — header, one game per line, integrity footer over every preceding byte —
so `canon.load_file` verifies them unchanged, and a corrupted or truncated
download is refused before a single row reaches the catalog.

Why per-platform files: a C64 user should not download another machine's catalog to
find out it did not change.  Each file is self-contained (a game that exists
on two platforms is written into both, carrying only that platform's
releases), and the local catalog merges them by canon ID.

Nothing here needs credentials.  Reading the database is free; only sending
something back (library/webapi.py) asks who you are.

Stdlib only, like the rest of `library/`.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.error
from typing import Callable, Optional

from . import canon, compat, config, fetch
from .db import Catalog, GameRow, VariantRow, normalize_title

#DEFAULT_BASE = "https://fpgago.com"
DEFAULT_BASE = "http://127.0.0.1:8000"
MANIFEST_PATH = "/api/v1/manifest"

# Files the sync knows how to import.  Anything else in the manifest is a
# newer server talking about something this client does not understand yet,
# and is skipped rather than treated as an error.
COMPAT_FILE = "compat.jsonl"
SHOTS_FILE = "screenshots.jsonl"

# Where the last-synced state is remembered, in the catalog's meta table.
META_PREFIX = "webdb:"
META_GENERATED = META_PREFIX + "generated"
META_BASE = META_PREFIX + "base"
META_MOVED = META_PREFIX + "moved"


class WebDBError(Exception):
    """The server is unreachable, or answered with something unusable."""


def base_url() -> str:
    """The server to sync from.  $FPGAGO_WEB_URL points a development client
    at a local runserver."""
    return os.environ.get("FPGAGO_WEB_URL", DEFAULT_BASE).rstrip("/")


def api_url(path: str) -> str:
    return base_url() + (path if path.startswith("/") else "/" + path)


def cache_dir() -> str:
    return config.cache_dir("webdb")


def _absolute(url: str) -> str:
    """Manifest URLs are site-relative ('/media/gamedb/c64.jsonl') so the same
    published tree works under any hostname."""
    return url if url.startswith(("http://", "https://")) else api_url(url)


# ── the manifest ───────────────────────────────────────────────────────────

def manifest(timeout: float = 30.0) -> dict:
    """What the server currently publishes.  Never cached — it is the one
    request whose whole job is to be fresher than the cache."""
    url = api_url(MANIFEST_PATH)
    try:
        body = fetch.get(url, cache=False, timeout=timeout)
    except urllib.error.HTTPError as e:
        # The server answered, and its answer says what is wrong — "nothing
        # has been published yet" is a different problem from a network
        # failure, and reporting both as "cannot reach" sends people to look
        # at their wifi.
        raise WebDBError(_http_reason(e, url)) from e
    except Exception as e:                               # noqa: BLE001
        raise WebDBError(f"cannot reach {url}: {e}") from e
    try:
        data = json.loads(body)
    except ValueError as e:
        raise WebDBError(f"{url}: not JSON: {e}") from e
    if data.get("manifest") != "fpgago-gamedb":
        raise WebDBError(f"{url}: not an fpgago game database manifest")
    if not isinstance(data.get("files"), list):
        raise WebDBError(f"{url}: manifest lists no files")
    return data


def _http_reason(e, url: str) -> str:
    """Turn an HTTPError into what the server actually said.

    The API answers failures with {"error": …, "code": …}; urllib throws that
    body away unless it is read off the exception."""
    try:
        payload = json.loads(e.read())
    except Exception:                                    # noqa: BLE001
        payload = {}
    said = payload.get("error")
    code = payload.get("code")
    if code == "not_published":
        return (f"{url}: the server has no game database published yet — "
                f"run `manage.py gamedb_publish` on it (and the "
                f"gamedb_seed_* commands first, if it is a new install)")
    if said:
        return f"{url}: {said}" + (f" [{code}]" if code else "")
    return f"{url}: HTTP {e.code} {e.reason}"


def _sha1_file(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _download_verified(entry: dict, dest: str,
                       progress: Optional[Callable[[str], None]] = None) -> str:
    """Fetch one snapshot file and check it against the manifest's sha1.

    A mismatch is far more likely to mean "the server published while we were
    reading" than corruption, so it is worth exactly one retry — the second
    attempt re-reads the manifest's file from scratch and, if it still
    disagrees, the sync stops rather than importing something nobody vouched
    for."""
    url = _absolute(entry["url"])
    want = entry.get("sha1")
    for attempt in (1, 2):
        try:
            fetch.download(url, dest)
        except Exception as e:                           # noqa: BLE001
            raise WebDBError(f"{entry['name']}: download failed: {e}") from e
        got = _sha1_file(dest)
        if not want or got == want:
            return dest
        if attempt == 1 and progress:
            progress(f"{entry['name']}: checksum moved under us, retrying")
            time.sleep(1.0)
    raise WebDBError(
        f"{entry['name']}: sha1 mismatch (manifest {want}, downloaded {got}) "
        f"— nothing imported")


# ── importing a platform catalog ───────────────────────────────────────────

def _game_for(cat: Catalog, entry: dict) -> int:
    """The local row id for a published game, created if need be.

    Matched by canon ID FIRST and by title only as a fallback: the server is
    free to retitle a game, and a title-first match would answer that by
    creating a second row for a game that already has an ID."""
    row = cat.game_by_canon(entry["id"])
    if row is not None:
        gid = row["id"]
        # `multiplayer` is overwritten, not COALESCEd: absent from the file
        # means the flag is off, and an uncheck on the server has to be able
        # to clear a local tick, not politely leave it.
        cat.db.execute(
            """UPDATE game SET title=?, title_norm=?,
                   year=COALESCE(?, year), publisher=COALESCE(?, publisher),
                   genre=COALESCE(?, genre), multiplayer=? WHERE id=?""",
            (entry["title"], normalize_title(entry["title"]),
             entry.get("year"), entry.get("publisher"), entry.get("genre"),
             1 if entry.get("multiplayer") else 0, gid))
        return gid

    gid = cat.upsert_game(GameRow(entry["title"], year=entry.get("year"),
                                  publisher=entry.get("publisher"),
                                  genre=entry.get("genre")))
    # A local row that matched by title may already carry a DIFFERENT canon
    # ID (it was published under one before a correction moved it).  The
    # server's ID wins — it is the one every other client will use.
    cat.db.execute("UPDATE game SET canon_id=?, multiplayer=? WHERE id=?",
                   (entry["id"], 1 if entry.get("multiplayer") else 0, gid))
    return gid


# Fields the server is authoritative for.  Unlike the old scrape-and-merge
# path, these OVERWRITE what is in the catalog: a correction made on the
# server ("this is not Wizard of Wor, and the group is ATG") has to be able to
# fix a row a local search got wrong, not politely decline to.
def _import_variant(cat: Catalog, gid: int, entry: dict, ve: dict) -> str:
    source = ve.get("source") or "canon"
    ref = ve.get("ref") or f"canon:{entry['id']}/{ve['n']}"
    row = cat.db.execute(
        "SELECT id, game_id FROM variant WHERE source=? AND source_ref=?",
        (source, ref)).fetchone()

    if row is None:
        vid = cat.upsert_variant(gid, VariantRow(
            platform=ve.get("platform", "264"), source=source, source_ref=ref,
            group_name=ve.get("group"), release_name=ve.get("release"),
            year=ve.get("year"), fmt=ve.get("fmt"),
            source_url=ve.get("url")))
        created = "new"
    else:
        vid = row["id"]
        cat.db.execute(
            """UPDATE variant SET game_id=?, platform=?, group_name=?,
                   release_name=?, year=?, fmt=?, source_url=? WHERE id=?""",
            (gid, ve.get("platform", "264"), ve.get("group"),
             ve.get("release"), ve.get("year"), ve.get("fmt"),
             ve.get("url"), vid))
        created = "updated"

    cat.db.execute("UPDATE variant SET canon_sub=?, hidden=? WHERE id=?",
                   (ve["n"], 1 if ve.get("hidden") else 0, vid))

    # The published hashes let a download be verified against what the ID was
    # assigned to, and let an already-downloaded file be recognised as this
    # release.  `path` stays NULL — this row is a description, not a file.
    if ve.get("sha1"):
        existing = cat.db.execute("SELECT id, variant_id FROM file WHERE sha1=?",
                                  (ve["sha1"],)).fetchone()
        if existing is None:
            cat.db.execute(
                """INSERT INTO file(variant_id,filename,path,size,sha1,crc32,
                       status,added_at)
                   VALUES(?,?,NULL,?,?,?,'pending',?)""",
                (vid, ve.get("filename") or "", ve.get("size"), ve["sha1"],
                 ve.get("crc32"), time.time()))
        elif existing["variant_id"] is None:
            cat.db.execute("UPDATE file SET variant_id=? WHERE id=?",
                           (vid, existing["id"]))
    return created


def import_catalog(cat: Catalog, path: str) -> dict:
    """Import one published platform file into the local catalog.

    `canon.load_file` does the verifying: header magic, the integrity footer's
    sha1 over every preceding byte, and every line's check character.  Nothing
    is written if any of that fails."""
    entries = canon.load_file(path)
    stats = {"games": 0, "new": 0, "updated": 0, "moved": 0}
    moved = {}
    for entry in entries:
        gid = _game_for(cat, entry)
        stats["games"] += 1
        for ve in entry.get("variants", []):
            if ve.get("moved"):
                # Not a release any more — a redirect for an ID somebody may
                # still quote.  It cannot become a row: it shares its
                # (source, source_ref) with the release it points at, and the
                # catalog holds those unique.
                moved[f"{entry['id']}/{ve['n']}"] = ve["moved"]
                stats["moved"] += 1
                continue
            stats[_import_variant(cat, gid, entry, ve)] += 1
    cat.commit()
    stats["redirects"] = moved
    return stats


def _save_moved(cat: Catalog, redirects: dict):
    """Remember the ID redirects so an old `#4188-X/3` still resolves.

    A handful of entries in the whole registry, so one JSON blob in `meta`
    beats a table."""
    if not redirects:
        return
    try:
        have = json.loads(cat.meta_get(META_MOVED) or "{}")
    except ValueError:
        have = {}
    have.update(redirects)
    cat.meta_set(META_MOVED, json.dumps(have, separators=(",", ":")))
    cat.commit()


def resolve_moved(cat: Catalog, canon_id: int, sub: Optional[int]):
    """Follow a re-filing: (canon_id, sub) -> where that release lives now,
    or None if it was never moved."""
    if sub is None:
        return None
    try:
        table = json.loads(cat.meta_get(META_MOVED) or "{}")
    except ValueError:
        return None
    target = table.get(f"{canon_id}/{sub}")
    if not target:
        return None
    try:
        return canon.parse_id(target)
    except ValueError:
        return None


# ── screenshots ────────────────────────────────────────────────────────────

SHOT_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp")

# Two kinds of picture, told apart by the file name and by nothing else:
#
#   4193.png     the GAME's picture.  Every release under an ID is the same
#                game, so this one stands for all of them — it is what the
#                browser shows while you arrow down the list, and the only
#                one the "has a picture" filter counts.
#   4193.5.png   one RELEASE's crack intro.  What differs between two dumps
#                of a game is exactly what must not be used to recognise the
#                game, so an intro is never shown in the list and never
#                stands in for a missing game picture.


def shots_dir() -> str:
    return config.cache_dir("shots")


def shot_stem(canon_id: int, sub: Optional[int] = None) -> str:
    return f"{canon_id}" if sub is None else f"{canon_id}.{sub}"


def shot_path(canon_id: Optional[int],
              sub: Optional[int] = None) -> Optional[str]:
    """The cached picture, or None if there is not one yet.

    `sub` None asks for the game's own picture; a `sub` asks for that
    release's crack intro.  A missing intro is NOT answered with the game's
    picture: "this crack has no intro on file" and "here is the game" are
    different answers, and only the caller knows which one is useful."""
    if canon_id is None:
        return None
    stem = shot_stem(canon_id, sub)
    for ext in SHOT_EXTS:
        path = os.path.join(shots_dir(), f"{stem}{ext}")
        if os.path.exists(path):
            return path
    return None


def shot_ids() -> set:
    """Every canonical id we hold a GAME picture for.

    One directory listing rather than shot_path() per row: the search list
    asks this about thousands of games at a time, and five os.path.exists()
    calls each is the difference between a search that is instant and one
    that is not.

    Intros (`4193.5.png`) are deliberately not counted: a game whose only
    picture is somebody's cracktro still needs a picture of the game."""
    out = set()
    try:
        names = os.listdir(shots_dir())
    except OSError:                      # nothing synced yet
        return out
    for n in names:
        stem, ext = os.path.splitext(n)
        if ext.lower() in SHOT_EXTS and stem.isdigit():
            out.add(int(stem))
    return out


def intro_subs(canon_id: Optional[int]) -> set:
    """Which releases of this game we hold a crack intro for: {sub, …}.

    One listing for the whole variants table, for the same reason shot_ids()
    does one for the games list."""
    out = set()
    if canon_id is None:
        return out
    prefix = f"{canon_id}."
    try:
        names = os.listdir(shots_dir())
    except OSError:
        return out
    for n in names:
        stem, ext = os.path.splitext(n)
        if ext.lower() not in SHOT_EXTS or not stem.startswith(prefix):
            continue
        tail = stem[len(prefix):]
        if tail.isdigit():
            out.add(int(tail))
    return out


def import_screenshots(path: str,
                       progress: Optional[Callable[[str], None]] = None) -> dict:
    """Fetch the pictures that changed.  Each line carries its own sha1, so a
    single new screenshot costs one image, not the whole set.

    A line with a `sub` is a release's crack intro rather than the game's
    picture; it is cached under its own name so the two can never overwrite
    each other."""
    stats = {"shots": 0, "intros": 0, "fetched": 0, "failed": 0}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            stats["shots"] += 1
            cid, url, want = rec.get("id"), rec.get("url"), rec.get("sha1")
            sub = rec.get("sub")
            if cid is None or not url:
                continue
            if sub is not None:
                stats["intros"] += 1
            ext = os.path.splitext(url)[1].lower() or ".png"
            dest = os.path.join(shots_dir(), f"{shot_stem(cid, sub)}{ext}")
            if os.path.exists(dest) and want and _sha1_file(dest) == want:
                continue
            try:
                fetch.download(_absolute(url), dest)
                stats["fetched"] += 1
            except Exception as e:                       # noqa: BLE001
                # A missing picture is a cosmetic loss; it must never cost the
                # user the catalog sync that came with it.
                stats["failed"] += 1
                if progress:
                    progress(f"screenshot for "
                             f"#{shot_stem(cid, sub)} not fetched: {e}")
    return stats


# ── the sync ───────────────────────────────────────────────────────────────

def sync(cat: Optional[Catalog] = None, *, platforms=None,
         progress: Optional[Callable[[str], None]] = None,
         screenshots: bool = True) -> dict:
    """Bring the local catalog up to date with the server.

    Downloads only the files whose sha1 differs from what was imported last
    time, so a sync with nothing new costs one small request.  Returns a
    summary; raises WebDBError only when the server itself is unusable —
    an individual file that fails is reported and the rest still land.
    """
    say = progress or (lambda _m: None)
    close = cat is None
    cat = cat or Catalog(config.db_path())
    try:
        data = manifest()
        # Pointing a client at a different server invalidates every remembered
        # sha1: the files may be identical by luck but the ID space is not
        # guaranteed to be.
        if cat.meta_get(META_BASE) not in (None, base_url()):
            say("server changed — re-importing everything")
            for row in cat.db.execute(
                    "SELECT key FROM meta WHERE key LIKE ?",
                    (META_PREFIX + "%",)).fetchall():
                cat.db.execute("DELETE FROM meta WHERE key=?", (row["key"],))

        wanted = set(platforms) if platforms else None
        summary = {"checked": 0, "changed": [], "unchanged": [], "errors": [],
                   "games": 0, "new": 0, "updated": 0, "reports": 0,
                   "shots": 0}

        for entry in data["files"]:
            name = entry.get("name") or ""
            if not name.endswith(".jsonl"):
                continue
            platform = name[:-len(".jsonl")]
            if wanted and name not in (COMPAT_FILE, SHOTS_FILE) \
                    and platform not in wanted:
                continue
            if name == SHOTS_FILE and not screenshots:
                continue
            summary["checked"] += 1

            key = f"{META_PREFIX}{name}:sha1"
            if cat.meta_get(key) == entry.get("sha1"):
                summary["unchanged"].append(name)
                continue

            dest = os.path.join(cache_dir(), name)
            try:
                _download_verified(entry, dest, progress=say)
            except WebDBError as e:
                summary["errors"].append(str(e))
                say(str(e))
                continue

            try:
                if name == COMPAT_FILE:
                    n = _install_compat(dest)
                    summary["reports"] += n
                    say(f"{name}: {n} verdict(s)")
                elif name == SHOTS_FILE:
                    st = import_screenshots(dest, progress=say)
                    summary["shots"] += st["fetched"]
                    say(f"{name}: {st['shots']} picture(s) "
                        f"({st['intros']} crack intro(s)), "
                        f"{st['fetched']} fetched")
                else:
                    st = import_catalog(cat, dest)
                    _save_moved(cat, st.pop("redirects", {}))
                    for k in ("games", "new", "updated"):
                        summary[k] += st[k]
                    say(f"{name}: {st['games']} game(s), {st['new']} new, "
                        f"{st['updated']} updated")
            except Exception as e:                       # noqa: BLE001
                summary["errors"].append(f"{name}: {e}")
                say(f"{name}: NOT imported — {e}")
                continue

            # Recorded only after a successful import, so a crash half way
            # through means the next sync does the file again.
            cat.meta_set(key, entry.get("sha1") or "")
            cat.commit()
            summary["changed"].append(name)

        cat.meta_set(META_BASE, base_url())
        cat.meta_set(META_GENERATED, data.get("generated") or "")
        cat.commit()
        summary["generated"] = data.get("generated")
        return summary
    finally:
        if close:
            cat.close()


def _install_compat(downloaded: str) -> int:
    """Put the shared verdict database where compat.py already looks for it.

    That path (`cache/compat/compat.jsonl`) is one of the three files
    `compat.load_tagged()` merges, so everything downstream — the yours/online
    tagging, the disagreement highlighting, `current_profile()` — keeps
    working with no changes at all."""
    dest = compat.online_path()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(downloaded, encoding="utf-8") as src, \
            open(dest, "w", encoding="utf-8") as out:
        out.write(src.read())
    reports, _errors = compat._load_one(dest)
    return len(reports)


def status(cat: Optional[Catalog] = None) -> dict:
    """What the local copy knows about its last sync, without touching the
    network."""
    close = cat is None
    cat = cat or Catalog(config.db_path())
    try:
        files = {}
        for row in cat.db.execute("SELECT key, value FROM meta WHERE key LIKE ?",
                                  (META_PREFIX + "%",)).fetchall():
            if row["key"].endswith(":sha1"):
                name = row["key"][len(META_PREFIX):-len(":sha1")]
                files[name] = row["value"]
        return {"base": cat.meta_get(META_BASE) or base_url(),
                "generated": cat.meta_get(META_GENERATED),
                "files": files, "synced": bool(files)}
    finally:
        if close:
            cat.close()
