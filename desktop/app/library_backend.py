"""library_backend.py — GUI-friendly wrapper over the headless library engine.

Every call opens its own sqlite connection (sqlite3 objects are not shareable
across threads) and returns plain Python data (dicts / lists), so results can be
handed straight to Qt worker signals. Network calls (online search, download,
sync) live here too — the GUI always runs these off the main thread.
"""

from __future__ import annotations

import os
import sys
from typing import Callable, Optional

# Make the sibling `library` package importable regardless of CWD.
_DESKTOP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _DESKTOP not in sys.path:
    sys.path.insert(0, _DESKTOP)

from library import (canon, classify, compat, config, fetch,         # noqa: E402
                     ingest, profile as profile_mod, share, sources, webapi,
                     webdb)
from library.db import (Catalog, GameRow, VariantRow,                 # noqa: E402
                        parse_release_tags)


def db_info() -> dict:
    return {"root": config.games_root(), "db": config.db_path()}


def _row(row, key, default=None):
    """sqlite3.Row indexing with a default — Row has no .get() and raises
    for a column the query did not select."""
    return row[key] if row is not None and key in row.keys() else default


def stats() -> dict:
    cat = Catalog(config.db_path())
    try:
        return cat.stats()
    finally:
        cat.close()


def canon_query(query: str):
    """'#1234' | '#1234-K' | '#1234-K/2' → (canon_id, sub|None), else None.

    The '#' means "this is an ID and nothing else" — the spelling the app
    itself prints (canon.format_id), so it can be pasted back in from a
    compat report or a flash name.  A wrong check character raises
    ValueError, which is the whole point of having one: "#4193-X" is a typo,
    not an empty result set."""
    q = (query or "").strip()
    if not q.startswith("#"):
        return None
    return canon.parse_id(q)


def _id_also(cat, query: str, rows: list, vmap: dict, have_shot: set,
             need_1541: set = frozenset()) -> list:
    """Add the game whose canonical ID is this number, when the query is one.

    "1942" is a title (the arcade game) and an ID (#1942-B, whichever game
    that turned out to be), and which one somebody meant is not knowable —
    so the answer is both.  The ID hit goes first: there is exactly one of
    it, and it is an exact match against the number that was typed.

    Only bare digits do this.  "#1942" already means the ID alone, and
    anything with a check character or a /release is spelled with the '#'.

    The ID hit is exempt from the platform / verdict / picture filters, for
    the same reason the '#' form is: an ID is an identity, not a
    description, and filtering it away answers "no such game" about a game
    that demonstrably exists.
    """
    q = (query or "").strip()
    if not q.isdigit():
        return rows
    have = {r["id"] for r in rows}
    extra = []
    for row in cat.search_canon(int(q)):
        r = dict(row)
        if r["id"] in have:
            continue                  # the title search already found it
        r["verdicts"] = vmap.get(r.get("canon_id"), {})
        r["has_shot"] = r.get("canon_id") in have_shot
        r["real1541"] = r.get("canon_id") in need_1541
        r["multiplayer"] = bool(r.get("multiplayer"))
        r["by_id"] = True             # so the list can say why it is here
        extra.append(r)
    return extra + rows


def search(query: str, platform: Optional[str] = None,
           tested: Optional[str] = None, shot: Optional[bool] = None,
           easyflash: bool = False, real1541: bool = False,
           multiplayer: bool = False) -> list[dict]:
    """Search the catalog.  Every row carries `verdicts` — {machine: Verdict}
    — so the list can show at a glance what has been tried, what worked, and
    whether that is your own finding or the project's, and `has_shot`, so it
    can show which games already have a picture.

    A query that is a canonical ID — "#4314", "#4314-J", "#4314-J/1" — looks
    that one game up instead, and the other filters are ignored: an ID names
    exactly one game, and a platform box left on "c16" must not answer "no
    such game" about a game that plainly exists.  A "/n" is carried back as
    `want_sub` so the caller can put the cursor on that release too.

    A bare number is both — "1942" is a title and an ID — so it searches
    titles AND looks the ID up, the ID hit first; see _id_also().

    Local only, and complete: the whole database is synced from fpgago.com
    (library/webdb.py), so there is nothing an online pass could add and no
    reason to make anybody wait for the network to type a search.
    `tested` filters: a status name keeps games with that verdict on any
    machine, "untested" keeps the rest, "conflict" keeps the games where
    your result and the online database disagree.  `shot` True/False keeps
    only the games that do / do not have a screenshot; `easyflash` keeps only
    the ones with a cartridge release; `real1541` keeps only the ones somebody
    has flagged as needing the cycle-accurate 1541 (no fastload path works);
    `multiplayer` keeps only the games ticked as multiplayer in the shared
    database.
    """
    ident = canon_query(query)
    cat = Catalog(config.db_path())
    try:
        if ident is not None:
            rows = [dict(r) for r in cat.search_canon(ident[0])]
        else:
            rows = [dict(r) for r in cat.search_local(query, platform or None)]
        # One pass over the verdicts feeds both maps: at 17k games a second
        # parse of the whole compat database per keystroke-search is real.
        reports = compat.load_tagged()
        vmap = verdict_map(reports)
        have_shot = webdb.shot_ids()
        need_1541 = real1541_ids(reports)
        for r in rows:
            r["verdicts"] = vmap.get(r.get("canon_id"), {})
            r["has_shot"] = r.get("canon_id") in have_shot
            r["real1541"] = r.get("canon_id") in need_1541
            r["multiplayer"] = bool(r.get("multiplayer"))
        if ident is not None:
            for r in rows:
                r["want_sub"] = ident[1]
            return rows
        rows = filter_by_verdict(rows, tested)
        if shot is not None:
            rows = [r for r in rows if r["has_shot"] is shot]
        if real1541:
            rows = [r for r in rows if r["real1541"]]
        if multiplayer:
            rows = [r for r in rows if r["multiplayer"]]
        if easyflash:
            ef = cat.easyflash_game_ids()
            rows = [r for r in rows if r["id"] in ef]
        return _id_also(cat, query, rows, vmap, have_shot, need_1541)
    finally:
        cat.close()


def filter_by_verdict(rows, tested: Optional[str]):
    if not tested:
        return rows
    if tested == "untested":
        return [r for r in rows if not r["verdicts"]]
    if tested == "conflict":
        return [r for r in rows if any_disagreement(r["verdicts"])]
    return [r for r in rows
            if any(v.status == tested for v in r["verdicts"].values())]


def sync_web(progress: Optional[Callable[[str], None]] = None,
             platforms=None) -> dict:
    """Bring the local copy of the game database up to date.

    One button's worth of work: the catalog, everyone's verdicts and the
    screenshots, all from fpgago.com, and only the files that actually
    changed since last time."""
    say = progress or (lambda _m: None)
    say(f"checking {webdb.base_url()} for updates…")
    cat = Catalog(config.db_path())
    try:
        res = webdb.sync(cat, platforms=platforms, progress=say)
    finally:
        cat.close()
    if not res["changed"]:
        say("already up to date")
    else:
        say(f"updated {len(res['changed'])} file(s): "
            f"{res['games']} game(s), {res['new']} new release(s), "
            f"{res['reports']} verdict(s)")
    return res


def web_status() -> dict:
    """What the local copy knows about its last sync, without any network."""
    return webdb.status()


# ── the fpgago.com account ─────────────────────────────────────────────────
# Only needed to send something back; reading the database never asks.

def account() -> dict:
    """Who this machine is signed in as: {"user": name} or {"user": None}."""
    who = webapi.whoami() if webapi.logged_in() else None
    return {"user": who.get("user") if who else None,
            "server": webdb.base_url()}


def login(username: str, password: str) -> dict:
    """Sign in with the account already registered on the website."""
    return webapi.login(username, password)


def screenshot_for(canon_id: Optional[int],
                   sub: Optional[int] = None) -> Optional[str]:
    """The cached picture for a game, or for one release's crack intro."""
    return webdb.shot_path(canon_id, sub)


def intro_subs(canon_id: Optional[int]) -> set:
    """Which releases of this game have a crack intro on file."""
    return webdb.intro_subs(canon_id)


def upload_screenshot(canon_id: int, path: str,
                      sub: Optional[int] = None) -> dict:
    """Send a picture.  With no `sub` it becomes the game's picture — the one
    everybody's list shows for every release of it.  With a `sub` it becomes
    that release's crack intro, and leaves the game's picture alone."""
    res = webapi.upload_screenshot(canon_id, path, sub=sub)
    what = "crack intro" if sub is not None else "screenshot"
    return {"done": f"{what} sent for {canon.format_id(canon_id, sub)}"
                    + ("" if res.get("published", True)
                       else " (it reaches clients at the next publish)"),
            **res}


def set_multiplayer(canon_id: int, on: bool) -> dict:
    """Tick or untick a game's multiplayer flag.

    The server is told first — the flag is a fact about the game, and facts
    about games live on fpgago.com — and only then is the local row updated,
    so the list shows the change immediately instead of after the next
    Refresh.  If the server refuses (not signed in, no such game), nothing
    changes anywhere and the caller puts the checkbox back."""
    res = webapi.set_multiplayer(canon_id, on)
    cat = Catalog(config.db_path())
    try:
        cat.db.execute("UPDATE game SET multiplayer=? WHERE canon_id=?",
                       (1 if on else 0, canon_id))
        cat.commit()
    finally:
        cat.close()
    word = "multiplayer" if on else "not multiplayer"
    return {"done": f"{canon.format_id(canon_id)} marked {word}", **res}


def logout() -> dict:
    return webapi.logout()


# Worst to best.  A title that works on the c64 and is broken on the c16 is
# worth showing as playable, so a game's headline verdict is its best one.
VERDICT_RANK = ("broken", "issues", "works")


def best_verdict(verdicts: dict) -> Optional[str]:
    """The friendliest verdict a game has on any machine, or None."""
    got = [v.status if isinstance(v, Verdict) else v
           for v in (verdicts or {}).values()]
    got = [s for s in got if s in VERDICT_RANK]
    return max(got, key=VERDICT_RANK.index) if got else None


def any_disagreement(verdicts: dict) -> bool:
    return any(isinstance(v, Verdict) and v.disagrees
               for v in (verdicts or {}).values())


def real1541_ids(reports=None) -> set:
    """Games flagged as "no fastload path works — needs the real 1541", from
    everyone's verdicts and this user's own.  `reports` is for a caller that
    has already loaded them — one search must not parse the database twice."""
    return compat.real1541_ids(compat.load_tagged() if reports is None
                               else reports)


def verdict_map(reports=None) -> dict:
    """{canon_id: {machine: Verdict}} for the whole compat database, in one
    pass — a per-row lookup would re-read the file for every game.

    A Verdict keeps **both** sides: what this user found and what everyone
    else reports.  They are different claims, and when they disagree that is
    the single most useful thing the list can tell someone — "the database
    says broken, but you got it working" is how a fix gets found.
    """
    reports = compat.load_tagged() if reports is None else reports
    best: dict = {}
    for i, r in enumerate(reports):
        key = (r["_canon"], r["machine"], r["_src"])
        cur = best.get(key)
        if cur is None or (r["date"], i) >= (cur[0], cur[1]):
            best[key] = (r["date"], i, r["status"])
    out: dict = {}
    for (canon_id, machine, src), (_d, _i, status) in best.items():
        v = out.setdefault(canon_id, {}).setdefault(machine, Verdict())
        setattr(v, src, status)
    return out


class Verdict:
    """One machine's verdict for one game, from both sides."""

    __slots__ = ("yours", "online")

    def __init__(self, yours=None, online=None):
        self.yours, self.online = yours, online

    @property
    def status(self):
        """What to act on: your own testing beats a stranger's."""
        return self.yours or self.online

    @property
    def source(self):
        return compat.SRC_YOURS if self.yours else (
            compat.SRC_ONLINE if self.online else None)

    @property
    def disagrees(self) -> bool:
        return bool(self.yours and self.online and self.yours != self.online)

    def __repr__(self):
        return f"Verdict(yours={self.yours!r}, online={self.online!r})"

    def __eq__(self, other):
        return (isinstance(other, Verdict) and self.yours == other.yours
                and self.online == other.online)


def canon_label(canon_id: Optional[int]) -> str:
    """'#1234-K' — how a game is named everywhere the user can see it."""
    return canon.format_id(canon_id) if canon_id is not None else ""


def variant_id_str(canon_id: Optional[int], sub: Optional[int],
                   row_id: Optional[int]) -> str:
    """What to call a variant on screen: the canon ID it was published under
    ('#1234-K/2'), or the internal row ID until the registry catches up.  The
    same string the CLI prints and the compat database keys on — a test result
    is only trackable if the list you tested from names the game the same
    way.

    A release with no /n of its own must NOT show the bare game ID: that is
    the same string for every release of the game, so a dozen cracks listed
    as a dozen '#4193-U' rows with nothing to pick between them (board,
    2026-08-05).  'var#N' is at least unique, and is what the CLI accepts as
    an argument; downloading or sending it turns it into a real ID."""
    if canon_id is not None and sub is not None:
        return canon.format_id(canon_id, sub)
    if row_id is not None:
        return f"var#{row_id}"
    return canon_label(canon_id)


def variants(game_id: int) -> list[dict]:
    """The releases of a game.  Each row carries `canon` (its display ID),
    `verdict` (the compat status for that release on its own platform, or
    None) and `profile`."""
    cat = Catalog(config.db_path())
    try:
        rows = [dict(v) for v in cat.variants_for_game(game_id)]
        g = cat.db.execute("SELECT canon_id FROM game WHERE id=?",
                           (game_id,)).fetchone()
        canon_id = _row(g, "canon_id")
        for r in rows:
            r["canon"] = variant_id_str(canon_id, r.get("canon_sub"),
                                        r.get("id"))
            # What actually tells these rows apart on screen.  A source that
            # never filled the column still carries the tags in its own
            # release ref, so read them from there rather than show a dozen
            # blank cells.
            if not r.get("group_name") and not r.get("release_name"):
                r["group_name"], r["release_name"] = \
                    parse_release_tags(r.get("source_ref") or "")
            r["release"] = r.get("release_name") or r.get("group_name") or ""
            # What a committed correction has to say about this release (a
            # mislabeled item, two games on one disk) — library/patches.py.
            r["note"] = r.get("notes") or ""
        if canon_id is None:
            for r in rows:
                r["verdict"], r["profile"] = None, None
            return rows
        reports, _ = compat.load()
        tagged = compat.load_tagged()
        for r in rows:
            sub = r.get("canon_sub")
            v = Verdict()
            for src in (compat.SRC_YOURS, compat.SRC_ONLINE):
                mine = [x for x in tagged if x["_src"] == src]
                cur = compat.current(mine, canon_id, sub).get(r["platform"])
                if cur:
                    setattr(v, src, cur["status"])
            r["verdict"] = v
            r["profile"] = compat.current_profile(
                reports, canon_id, r["platform"], sub)
        return rows
    finally:
        cat.close()


def classify_paths(paths: list[str]) -> list[dict]:
    out = []
    for path in paths:
        try:
            v = classify.classify_path(path)
            out.append({"path": path, "platform": v.platform,
                        "confidence": v.confidence, "fmt": v.fmt,
                        "load_addr": v.load_addr, "note": v.note})
        except Exception as e:                       # noqa: BLE001
            out.append({"path": path, "error": str(e)})
    return out


def import_files(paths: list[str], platform: Optional[str] = None,
                 copy: bool = True) -> list[dict]:
    cat = Catalog(config.db_path())
    out = []
    try:
        for path in paths:
            try:
                r = ingest.ingest_file(cat, path, platform=platform,
                                       copy_into_library=copy)
                out.append({"path": path, **r})
            except Exception as e:                   # noqa: BLE001
                out.append({"path": path, "error": str(e)})
        return out
    finally:
        cat.close()


def index_tree(path: str, tosec_dir: Optional[str] = None, copy: bool = False,
               progress: Optional[Callable[[str], None]] = None) -> dict:
    tosec = None
    if tosec_dir:
        from library.sources.tosec import TosecIndex
        tosec = TosecIndex().load_dir(tosec_dir)
    cat = Catalog(config.db_path())
    try:
        return ingest.index_tree(cat, path, tosec=tosec,
                                 copy_into_library=copy, progress=progress)
    finally:
        cat.close()


def list_sources() -> list[dict]:
    return [{"name": s.name, "platforms": list(s.platforms)}
            for s in sources.all_sources()]


def download_variant(variant_id: int, all_files: bool = False,
                     progress: Optional[Callable[[str], None]] = None) -> dict:
    cat = Catalog(config.db_path())
    try:
        v = cat.get_variant(variant_id)
        if not v:
            return {"error": f"no variant #{variant_id}"}
        src = sources.get(v["source"])
        if not src:
            return {"error": f"no adapter for source '{v['source']}'"}
        from library.sources.base import SearchResult
        sr = SearchResult(title=v["game_title"], source=v["source"],
                          source_ref=v["source_ref"], platform=v["platform"],
                          group_name=v["group_name"],
                          release_name=v["release_name"],
                          source_url=v["source_url"])
        items = src.resolve(sr)
        if not items:
            return {"error": "no downloadable files found"}
        dest_dir = config.platform_dir(v["platform"], v["game_title"])
        got = []
        for it in (items if all_files else items[:1]):
            dest = os.path.join(dest_dir, it.filename)
            if progress:
                progress(f"downloading {it.filename}")
            n = fetch.download(it.url, dest)
            r = ingest.ingest_file(cat, dest, title=v["game_title"],
                                   platform=v["platform"],
                                   group_name=v["group_name"],
                                   source=v["source"], source_ref=v["source_ref"],
                                   copy_into_library=False)
            entry = {"dest": dest, "bytes": n, **r}
            got.append(entry)
        # Downloading is what makes a release real, so it is where the release
        # earns its permanent ID — the same string the board file, the compat
        # database and the ID column will all use from here on.  Before this,
        # IDs only ever came from a whole-catalog `canon-build` nobody ran, so
        # every fresh find showed the bare game ID and nothing identified
        # which of a dozen cracks had reached the board.
        cid = _publish(cat, variant_id, progress)
        # A game's settings travel with it: whatever the compat database has
        # recorded for this game on this machine comes down with the file and
        # goes up to the board on the next upload, instead of being a note
        # someone has to read and re-apply by hand.
        prof = _profile_for_variant(cat, cat.get_variant(variant_id))
        if prof and progress:
            progress(f"settings for this game: {profile_mod.describe(prof)}")
        return {"downloaded": got, "profile": prof, "canon": cid}
    finally:
        cat.close()


def _publish(cat, variant_id: int,
             progress: Optional[Callable[[str], None]] = None):
    """Report the release's canon ID.

    Nothing is assigned here any more.  IDs are minted on fpgago.com when a
    release enters the catalog, so everything that arrived through a sync
    already carries one and every client agrees about it — which is exactly
    what a locally-minted `max(id)+1` could not promise.

    A release with no ID is one this machine found by itself (an imported
    file, a folder index) and the server has never seen.  That still works:
    the flash name falls back on the local row id, and the release gets a
    real ID once it exists upstream.
    """
    v = cat.get_variant(variant_id)
    if v is None:
        return None
    canon_id, sub = _row(v, "game_canon"), _row(v, "canon_sub")
    if canon_id is None or sub is None:
        if progress:
            progress("this release is not in the shared database yet — the "
                     "flash name will use the local id (try Refresh)")
        return None
    res = {"canon_id": canon_id, "sub": sub,
           "canon": canon.format_id(canon_id, sub)}
    if progress:
        progress(f"canon ID {res['canon']}")
    return res


def flash_ident_for(cat, v):
    """(ident, title, group) for the flash name of a variant row: the canon
    ID when the release has one, the local row id when it does not."""
    canon_id = _row(v, "game_canon")
    if canon_id is None:
        g = cat.db.execute("SELECT canon_id FROM game WHERE id=?",
                           (v["game_id"],)).fetchone()
        canon_id = _row(g, "canon_id")
    ident = canon.flash_ident(canon_id, _row(v, "canon_sub"))
    return (ident if ident is not None else v["id"],
            _row(v, "game_title"), _row(v, "group_name"))


# Mountable formats beat the archive they came in.
_RUNNABLE = (".d64", ".prg", ".t64", ".tap", ".crt", ".bin")


def local_file_for(variant_id: int) -> Optional[str]:
    """The best already-downloaded file for a variant, or None."""
    cat = Catalog(config.db_path())
    try:
        v = cat.get_variant(variant_id)
        return _local_file(cat, v) if v else None
    finally:
        cat.close()


def _local_file(cat, v) -> Optional[str]:
    paths = [f["path"] for f in cat.files_for_variant(v["id"])
             if f["path"] and os.path.exists(f["path"])]
    if not paths:
        return None
    ranked = sorted(paths, key=lambda p: (
        _RUNNABLE.index(os.path.splitext(p)[1].lower())
        if os.path.splitext(p)[1].lower() in _RUNNABLE else len(_RUNNABLE)))
    return ranked[0]


def send_variant(ops, variant_id: int, run: bool = False,
                 progress: Optional[Callable[[str], None]] = None) -> dict:
    """One click, whole loop: make sure the game is on disk (download it if
    not), push it to the board with the settings recorded for it, optionally
    start it.  `ops` is the app's already-open BoardOps — the CLI opens its
    own port instead (library.board.upload_file)."""
    say = progress or (lambda _m: None)
    cat = Catalog(config.db_path())
    try:
        v = cat.get_variant(variant_id)
        if not v:
            return {"error": f"no variant #{variant_id}"}
        path = _local_file(cat, v)
        platform = v["platform"]
    finally:
        cat.close()

    if not path:
        say("not downloaded yet — fetching it first…")
        res = download_variant(variant_id, progress=progress)
        if "error" in res:
            return res
        got = res["downloaded"][0]
        path = got["dest"]

    cat = Catalog(config.db_path())
    try:
        # Sending is the other moment a release becomes real — a file already
        # on disk from before IDs were handed out at download time gets one
        # here, so nothing reaches the board nameless.
        _publish(cat, variant_id, say)
        v = cat.get_variant(variant_id)
        prof = _profile_for_variant(cat, v)
        ident, title, group = flash_ident_for(cat, v)
    finally:
        cat.close()

    from library import board as libboard
    # The canon ID goes into the flash name: two releases of one game very
    # often share a filename, and the FS replaces same-named files, so
    # without it the second "Send to board" silently overwrote the first.
    # Using the canon ID (not the local row id) is what lets the board file
    # be matched back to the row in the Library that produced it.
    fname = libboard.upload_with_ops(ops, path, platform=platform, run=run,
                                     profile=prof, ident=ident, title=title,
                                     group=group, progress=say)
    return {"file": fname, "path": path, "profile": prof, "ran": bool(run),
            "canon": ident}


# ── per-game settings (profiles) ───────────────────────────────────────────
# The library's copy of a game's settings lives in the compat database
# (data/compat.jsonl), keyed by canon ID + machine — so it is shared through
# git like every other verdict, and a download can bring it along.  The
# board's copy lives in the MCU KV store under `g.<flash-name>`; upload is
# what carries one to the other.

def machines_for(platforms) -> list[str]:
    """Which machines a game's settings can be recorded for.  A platform the
    compat database does not know (a brand-new core) yields nothing rather
    than a report that will not validate."""
    if isinstance(platforms, str):
        platforms = [p for p in platforms.split(",") if p]
    return [p for p in dict.fromkeys(platforms) if p in compat.MACHINES]


def game_profile(canon_id: Optional[int], machine: str,
                 sub: Optional[int] = None) -> dict:
    """The settings + current verdict the database holds for (game, machine).
    `profile` is None when nothing has been recorded; `real1541` is None when
    nobody has said anything about the drive."""
    if canon_id is None or machine not in compat.MACHINES:
        return {"profile": None, "status": None, "notes": None,
                "real1541": None}
    reports, _ = compat.load()
    cur = compat.current(reports, canon_id, sub).get(machine)
    return {"profile": compat.current_profile(reports, canon_id, machine, sub),
            "status": cur["status"] if cur else None,
            "notes": cur.get("notes") if cur else None,
            "real1541": compat.current_real1541(reports, canon_id, machine,
                                                sub)}


def reporter_identity() -> dict:
    """Who this machine reports as: {"by": …, "email": …}.  Either may be ""
    — the email in particular, until somebody types one."""
    return {"by": compat.default_reporter(), "email": compat.default_email()}


def save_game_profile(canon_id: int, sub: Optional[int], machine: str,
                      blob: str, status: str = "works",
                      notes: Optional[str] = None,
                      real1541: Optional[bool] = None,
                      by: Optional[str] = None,
                      email: Optional[str] = None) -> dict:
    """Record settings + a verdict for (game, machine) as a new compat report.

    A profile is only ever *added* — append-only is what makes the database
    merge cleanly through PRs — so this writes one more line rather than
    editing the old one.  An empty blob is stored as an explicit empty
    profile, which reads back as "no settings" without erasing history.

    Who reported it is remembered on this machine (compat.set_identity), so
    the next verdict — and every one after — carries the same name and
    address without asking again.
    """
    errs, warns = profile_mod.check(blob)
    if errs:
        raise ValueError("; ".join(errs))
    # None means "whoever this machine reports as"; a string — including the
    # empty one — is the user having just said, so it is obeyed and kept.
    if email is not None:
        email = email.strip()
        if email and not compat.valid_email(email):
            raise ValueError(f"{email!r} is not an email address")
    if by is not None or email is not None:
        compat.set_identity(by=by, email=email)
    # Into the user's OWN file, not the shared database: the app must never
    # need git to work, and a local write can never conflict with a pull.
    rep = compat.append_report(canon_id=canon_id, sub=sub, machine=machine,
                               status=status, notes=notes, profile=blob,
                               real1541=real1541, by=by or None,
                               email=email, local=True)
    return {"report": rep, "warnings": warns,
            "path": compat.local_path(),
            "unshared": len(compat.unshared())}


# ── sharing what this user found out ───────────────────────────────────────

def unshared_reports() -> list[dict]:
    return compat.unshared()


def share_preview() -> dict:
    """Everything the share dialog needs: what would be sent, and how."""
    reports = compat.unshared()
    return {"reports": reports, "n": len(reports),
            "routes": share.routes(reports) if reports else [],
            "text": share.preview(reports) if reports else "",
            "repo": share.repo_slug()}


def auto_share() -> dict:
    """Send this machine's unsent test results to fpgago.com, quietly.

    A verdict that sits in `compat-local.jsonl` helps nobody: it is one
    person's evening of testing, on one laptop, invisible to everyone who
    would have been saved the same evening.  So the app sends them by itself
    — after every save and on a timer — and only tells the user when it
    *cannot*, which is the one case they have to act on.

    Never raises.  It runs unasked, and being on a train is not a crash:
    the failure comes back as {"ok": False, "why": …} for the red notice to
    say out loud, with the reports still queued for the next attempt.

    Returns {"sent", "pending", "ok", "why"}.
    """
    reports = compat.unshared()
    if not reports:
        return {"sent": 0, "pending": 0, "ok": True, "why": ""}
    if not webapi.logged_in():
        return {"sent": 0, "pending": len(reports), "ok": False,
                "why": "not signed in to fpgago.com"}
    try:
        res = share_via("web")
    except Exception as exc:                             # noqa: BLE001
        return {"sent": 0, "pending": len(reports), "ok": False,
                "why": str(exc) or exc.__class__.__name__}
    bad = res.get("rejected") or []
    # Asked of the file again rather than computed: share_via stamps only
    # what the server actually took, so this is the honest backlog.
    pending = len(compat.unshared())
    why = ""
    if bad:
        why = "; ".join(str(r.get("error") or "refused") for r in bad)
    elif pending:
        why = f"{pending} result(s) were not accepted"
    return {"sent": res.get("accepted", 0), "pending": pending,
            "ok": not pending, "why": why, "rejected": bad}


def share_via(route: str, target: Optional[str] = None) -> dict:
    """Run one of share.routes()'s keys.  Returns {"done": str} on success;
    the reports are stamped as shared only when the route actually
    delivered them (a cancelled file dialog must not mark anything)."""
    reports = compat.unshared()
    if not reports:
        return {"done": "nothing new to share"}
    if route == "web":
        res = share.submit_to_web(reports)
        n, bad = res.get("accepted", 0), res.get("rejected") or []
        # Only what the server actually took is stamped; a rejected line stays
        # unshared, because it is the one the user most needs offered again.
        refused = {r["index"] for r in bad if "index" in r}
        accepted = [r for i, r in enumerate(reports) if i not in refused]
        if accepted:
            compat.mark_shared(only=accepted)
        done = f"{n} report(s) sent to fpgago.com"
        if bad:
            done += f" — {len(bad)} not accepted:\n" + "\n".join(
                f"  {reports[r['index']]['id'] if 'index' in r else '?'}: "
                f"{r.get('error', '?')}" for r in bad)
        return {"done": done, "accepted": n, "rejected": bad}
    if route == "gh":
        url = share.submit_with_gh(reports)
        compat.mark_shared()
        return {"done": f"reported: {url}", "url": url}
    if route == "browser":
        url = share.issue_url(reports)
        import webbrowser
        webbrowser.open(url)
        compat.mark_shared()
        return {"done": "opened GitHub in your browser — press Submit there",
                "url": url}
    if route == "copy":
        compat.mark_shared()
        return {"done": f"{len(reports)} report(s) copied",
                "text": share.preview(reports)}
    if route == "file":
        if not target:
            return {"done": "cancelled"}
        share.export(reports, target)
        compat.mark_shared()
        return {"done": f"saved to {target}"}
    raise ValueError(f"unknown share route {route!r}")


def _profile_for_variant(cat, v) -> Optional[str]:
    reports, _ = compat.load()
    canon_id = _row(v, "game_canon")
    if canon_id is None:                    # variants_for_game has no join
        g = cat.db.execute("SELECT canon_id FROM game WHERE id=?",
                           (v["game_id"],)).fetchone()
        canon_id = _row(g, "canon_id")
    if canon_id is None or v["platform"] not in compat.MACHINES:
        return None
    return compat.current_profile(reports, canon_id, v["platform"],
                                  _row(v, "canon_sub"))
