"""library/cli.py — headless entry point for the fpgago game library.

    python3 -m library.cli <command> ...

Commands:
    sync [PLATFORM...]          download the latest game database from
                                fpgago.com — only the files that changed
    sync-status                 what the local copy knows (no network)
    stats                       catalog summary
    classify PATH...            print the content classifier's verdict
    import PATH...              classify + register local files into the library
    search QUERY [--platform P] search the local copy of the database
    show ID                     resolve a canon ID (game + variants + files)
    variants ID                 list the variations (cracks/groups) of a game
    download ID [--upload] [--run]
                                fetch a release; optionally push it straight
                                to the board flash and mount+LOAD+RUN it
    upload ID|PATH [--run]      push an already-local file to the board
    compat report ID STATUS     log a works/issues/broken verdict
    compat show ID | list | verify
                                query / integrity-check the compat database
    compat share                send your own reports to the project
    canon-verify                integrity-check a registry file
    patch list | verify | apply local corrections to what the sources say
    sources                     list registered source adapters

Where the data comes from: fpgago.com holds the game database — it does the
scraping, applies the project's corrections and hands out the permanent IDs.
`sync` downloads the result and everything else here works on that local
copy, so searching is instant and works offline.  Game files themselves are
still fetched straight from the archives that host them; the site only ever
serves metadata and screenshots.

Game identity: every game has an absolute, project-wide canon ID like
`#1234-K` (K = check character), variants `#1234-K/2` — the same for every
user.  The ID also names the file in the board's flash (`#1234-K/2` ->
c64-<title>-<group>-1234.2.d64), so a verdict can be tied to the release that
actually ran.
Internal DB row IDs still work as `g123` (game) / `var#123` (variant).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Optional

from . import (canon, classify, compat, config, fetch, ingest, patches,
               profile, sources)
from .db import Catalog, PLATFORMS, PLATFORM_264


def _cat() -> Catalog:
    cat = Catalog(config.db_path())
    try:
        if canon.ensure_imported(cat):
            print("(canon registry imported into local catalog)",
                  file=sys.stderr)
    except canon.CanonError as e:
        print(f"WARNING: canon registry not loaded: {e}", file=sys.stderr)
    return cat


def _gid_str(row) -> str:
    """Display ID for a game row: canon if assigned, else internal g#."""
    return canon.format_id(row["canon_id"]) if row["canon_id"] is not None \
        else f"g{row['id']}"


def _row_get(row, key, default=None):
    """`row[key]` with a default.  sqlite3.Row looks like a mapping but has
    no .get(), and asking it for a column the query did not select raises —
    so every optional-column read goes through here."""
    if row is None:
        return default
    return row[key] if key in row.keys() else default


def _canon_of(v):
    """(game canon ID, variant sub-ID) for a variant row.  The game's ID
    reaches a variant only through the join, as `game_canon` — `variant` has
    no canon_id column of its own, so reading one gives None forever and the
    game's shipped settings are never found."""
    return _row_get(v, "game_canon"), _row_get(v, "canon_sub")


def _vid_str(v) -> str:
    gc, sub = _canon_of(v)
    if gc is not None and sub is not None:
        return canon.format_id(gc, sub)
    return f"var#{v['id']}"


def _resolve_variant(cat: Catalog, text: str):
    """Canon ID / var#N → a fully-joined variant row, or None after printing
    what to do (ambiguous game, unknown ID, bad check char)."""
    m = re.match(r"^var#?(\d+)$", text)
    if m:
        v = cat.get_variant(int(m.group(1)))
        if not v:
            print(f"no variant var#{m.group(1)}", file=sys.stderr)
        return v
    try:
        canon_id, sub = canon.parse_id(text)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return None
    g = cat.game_by_canon(canon_id)
    if not g:
        print(f"no game {canon.format_id(canon_id)} in the catalog "
              "(registry out of date? downloading a release publishes it)",
              file=sys.stderr)
        return None
    if sub is not None:
        v = cat.variant_by_canon(canon_id, sub)
        if not v:
            # An ID is never reassigned, but a release CAN turn out to belong
            # to a different game (a mislabeled source + a patch).  The old
            # entry keeps a pointer, so a report quoting the old ID still
            # leads somewhere instead of dead-ending.
            _, ve = canon.entry_for(canon_id, sub)
            if ve and ve.get("moved"):
                print(f"{canon.format_id(canon_id, sub)} is now "
                      f"{ve['moved']} (the source had it under the wrong "
                      "game) — resolving that instead", file=sys.stderr)
                return _resolve_variant(cat, ve["moved"])
            print(f"{canon.format_id(canon_id)} has no variant /{sub}",
                  file=sys.stderr)
        return v
    vs = cat.variants_for_game(g["id"])
    if len(vs) == 1:
        return cat.get_variant(vs[0]["id"])
    print(f"{canon.format_id(canon_id)} \"{g['title']}\" has {len(vs)} "
          "variants — pick one:", file=sys.stderr)
    for v in vs:
        print(f"  {canon.format_id(canon_id, v['canon_sub'])}  "
              f"{v['platform']:6} {v['group_name'] or '-':18} "
              f"{v['source']:10} {v['fmt'] or ''}", file=sys.stderr)
    return None


def cmd_stats(args):
    cat = _cat()
    s = cat.stats()
    print(f"library: {config.games_root()}")
    print(f"db     : {config.db_path()}")
    print(f"games={s['games']}  variants={s['variants']}  files={s['files']}")
    for p, n in sorted(s["by_platform"].items()):
        print(f"  {p:6} {n}")
    cat.close()


def cmd_classify(args):
    for path in args.paths:
        v = classify.classify_path(path)
        la = f"${v.load_addr:04x}" if v.load_addr is not None else "—"
        inner = f"  [{v.inner_name}]" if v.inner_name else ""
        print(f"{path}{inner}\n    -> {v.platform:6} ({v.confidence})  "
              f"fmt={v.fmt} load={la} mem_top="
              f"{('$%04x' % v.mem_top) if v.mem_top else '—'}  {v.note}")


def cmd_import(args):
    cat = _cat()
    for path in args.paths:
        try:
            r = ingest.ingest_file(cat, path, platform=args.platform,
                                   group_name=args.group, title=args.title,
                                   copy_into_library=not args.no_copy)
        except Exception as e:
            print(f"{path}: ERROR {e}", file=sys.stderr)
            continue
        dup = " (dup)" if r["duplicate"] else ""
        print(f"{path} -> {r['platform']}  crc={r['crc32']} sha1={r['sha1'][:12]}"
              f"  game#{r['game_id']} var#{r['variant_id']}{dup}")
    cat.close()


def cmd_search(args):
    """Search the local copy of the database, which is the whole of it.

    There is no --online any more: `sync` brings down every platform's
    catalog, so the local answer is the complete one and it comes back
    without waiting for anybody's website."""
    cat = _cat()
    rows = cat.search_local(args.query, args.platform)
    if not rows:
        print("(no local matches)")
    for r in rows:
        print(f"{_gid_str(r):>9} {r['title']:40}  [{r['platforms'] or '-'}]  "
              f"{r['n_variants']} variant(s)"
              + (f"  {r['year']}" if r['year'] else ""))
    cat.close()


def cmd_index(args):
    """Index an existing local collection (recursive)."""
    tosec = None
    if args.tosec:
        from .sources.tosec import TosecIndex
        tosec = TosecIndex().load_dir(args.tosec)
        print(f"TOSEC: {tosec.n_entries} entries from {tosec.n_dats} dat(s)")
    cat = _cat()
    st = ingest.index_tree(cat, args.path, tosec=tosec,
                           copy_into_library=args.copy,
                           progress=(print if args.verbose else None))
    cat.close()
    print(f"scanned={st['scanned']} indexed={st['indexed']} "
          f"tosec_hits={st['tosec_hits']} dupes={st['dupes']}")
    for p, n in sorted(st["by_platform"].items()):
        print(f"  {p:6} {n}")


def _find_game(cat: Catalog, text: str):
    """'#42-K' / '42' (canon) or 'g123' (internal row) → game row or None."""
    m = re.match(r"^g(\d+)$", text)
    if m:
        return cat.db.execute("SELECT * FROM game WHERE id=?",
                              (int(m.group(1)),)).fetchone()
    try:
        canon_id, _ = canon.parse_id(text)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return None
    return cat.game_by_canon(canon_id)


def cmd_variants(args):
    cat = _cat()
    g = _find_game(cat, args.game_id)
    if not g:
        print(f"no game {args.game_id}", file=sys.stderr)
        return 2
    cid = g["canon_id"]
    for v in cat.variants_for_game(g["id"]):
        val = {0: "?", 1: "OK", -1: "BROKEN"}.get(v["validated"], "?")
        vid = canon.format_id(cid, v["canon_sub"]) \
            if cid is not None and v["canon_sub"] is not None \
            else f"var#{v['id']}"
        print(f"{vid:>12} {v['platform']:6} {v['group_name'] or '-':18} "
              f"{v['source']:10} files={v['n_files']} [{val}]  "
              f"{v['source_url'] or ''}")
    cat.close()


def _moved_notice(text: str):
    """If `text` names a release that has since been re-filed under another
    game, say so — an ID in an old report must not silently resolve to the
    game it was wrongly published under."""
    try:
        canon_id, sub = canon.parse_id(text)
    except ValueError:
        return
    if sub is None:
        return
    try:
        _, ve = canon.entry_for(canon_id, sub)
    except (canon.CanonError, OSError):
        return
    if ve and ve.get("moved"):
        print(f"NOTE: {canon.format_id(canon_id, sub)} was re-filed as "
              f"{ve['moved']} — the source had it under the wrong game "
              "(see `patch list`)", file=sys.stderr)


def cmd_show(args):
    cat = _cat()
    _moved_notice(args.id)
    g = _find_game(cat, args.id)
    if not g:
        print(f"no game {args.id}", file=sys.stderr)
        return 2
    print(f"{_gid_str(g)}  {g['title']}"
          + (f"  ({g['year']})" if g["year"] else "")
          + (f"  {g['publisher']}" if g["publisher"] else ""))
    for v in cat.variants_for_game(g["id"]):
        vid = canon.format_id(g["canon_id"], v["canon_sub"]) \
            if g["canon_id"] is not None and v["canon_sub"] is not None \
            else f"var#{v['id']}"
        print(f"  {vid:>12} {v['platform']:6} {v['group_name'] or '-':18} "
              f"{v['fmt'] or '?':4} {v['source']:10} {v['source_url'] or ''}")
        for f in cat.files_for_variant(v["id"]):
            here = f["path"] if f["path"] and os.path.exists(f["path"]) \
                else "(not downloaded)"
            print(f"      {f['filename']}  crc={f['crc32'] or '?'} "
                  f"sha1={(f['sha1'] or '?')[:12]}  {here}")
    if g["canon_id"] is not None:
        reports, _ = compat.load()
        cur = compat.current(reports, g["canon_id"])
        if cur:
            print("  compatibility:")
            for m in sorted(cur):
                print(f"    {compat.status_line(cur[m])}")
    cat.close()


def _canon_hash_check(v, sha1: str) -> None:
    """Compare a downloaded file against the hash the canon registry pinned
    for this release (the content half of \"checksum guarded\")."""
    gc = v["game_canon"] if "game_canon" in v.keys() else None
    if gc is None or v["canon_sub"] is None:
        return
    try:
        _, ve = canon.entry_for(gc, v["canon_sub"])
    except (canon.CanonError, OSError):
        return
    vid = canon.format_id(gc, v["canon_sub"])
    if not ve or "sha1" not in ve:
        print(f"    (no canon hash pinned for {vid} yet — this download "
              "pins it)")
    elif ve["sha1"] == sha1:
        print(f"    content VERIFIED against canon {vid}")
    else:
        print(f"    WARNING: content differs from canon {vid} "
              f"(expected sha1 {ve['sha1'][:12]}, got {sha1[:12]}) — "
              "the source changed the file", file=sys.stderr)


def _shipped_profile(canon_id, sub_id, platform, args) -> Optional[str]:
    """The per-game settings recorded for this game+machine in compat.jsonl,
    or None.  This is what makes the compat database the source of shipped
    defaults instead of a note someone has to read and apply by hand."""
    if canon_id is None or not platform or getattr(args, "no_profile", False):
        return None
    reports, _ = compat.load()
    return compat.current_profile(reports, canon_id, platform, sub_id)


def _upload_path(path: str, platform, args, canon_id=None, sub_id=None,
                 variant=None) -> int:
    from . import board
    prof = _shipped_profile(canon_id, sub_id, platform, args)
    # The canon ID in the flash name: two releases of one game usually share a
    # filename, and the FS replaces same-named files (see board_name).  It is
    # also what makes the file on the board matchable against the ID the
    # library, the CLI and the compat database print — the local row id was
    # not, being neither shown anywhere nor stable across machines.
    ident = canon.flash_ident(canon_id, sub_id)
    if ident is None and variant is not None:
        ident = variant["id"]
    try:
        fname = board.upload_file(path, platform=platform,
                                  name=getattr(args, "as_name", None),
                                  run=args.run, port=args.port, profile=prof,
                                  ident=ident,
                                  title=_row_get(variant, "game_title"),
                                  group=_row_get(variant, "group_name"))
    except Exception as e:
        print(f"board upload failed: {e}", file=sys.stderr)
        return 1
    print(("running" if args.run else "on board") + f": {fname}")
    return 0


def cmd_download(args):
    """Download a release into the library; optionally push it to the board."""
    cat = _cat()
    v = _resolve_variant(cat, args.id)
    if not v:
        return 2
    src = sources.get(v["source"])
    if not src:
        print(f"no adapter for source '{v['source']}'", file=sys.stderr)
        return 2
    from .sources.base import SearchResult
    sr = SearchResult(title=v["game_title"], source=v["source"],
                      source_ref=v["source_ref"], platform=v["platform"],
                      group_name=v["group_name"], release_name=v["release_name"],
                      source_url=v["source_url"])
    items = src.resolve(sr)
    if not items:
        print("no downloadable files found for this variant")
        return 1
    dest_dir = config.platform_dir(v["platform"], v["game_title"])
    downloaded = []
    for it in (items if args.all else items[:1]):
        dest = os.path.join(dest_dir, it.filename)
        print(f"  downloading {it.url}")
        try:
            n = fetch.download(it.url, dest)
        except Exception as e:
            print(f"    FAILED: {e}", file=sys.stderr)
            continue
        r = ingest.ingest_file(cat, dest, title=v["game_title"],
                               platform=v["platform"], group_name=v["group_name"],
                               source=v["source"], source_ref=v["source_ref"],
                               copy_into_library=False)
        print(f"    {n} bytes -> {r['platform']}  crc={r['crc32']} "
              f"sha1={r['sha1'][:12]}  {dest}")
        _canon_hash_check(v, r["sha1"])
        downloaded.append(dest)
    if downloaded:
        _publish(cat, v["id"])
    cat.close()
    if not downloaded:
        return 1
    if args.upload or args.run:
        return _upload_path(downloaded[0], v["platform"], args,
                            *_canon_of(v), variant=v)
    return 0


def _publish(cat, variant_id: int):
    """Say which permanent ID this release carries.

    IDs come from fpgago.com now — a release that arrived through `sync`
    already has one, and every client agrees about it.  A release this
    machine found on its own (an imported file, an indexed folder) has none
    until the server has seen it, and falls back on the local row id."""
    v = cat.get_variant(variant_id)
    if v is None:
        return None
    canon_id, sub = _row_get(v, "game_canon"), _row_get(v, "canon_sub")
    if canon_id is None or sub is None:
        print("    not in the shared database yet — using the local id "
              "(run `sync`)", file=sys.stderr)
        return None
    res = {"canon_id": canon_id, "sub": sub,
           "canon": canon.format_id(canon_id, sub)}
    print(f"    canon ID {res['canon']}")
    return res


def cmd_upload(args):
    """Push an already-local file (by path or canon ID) to the board."""
    if os.path.exists(args.id):
        path = args.id
        plat = classify.classify_path(path).platform
        return _upload_path(path,
                            plat if plat in PLATFORMS and plat != PLATFORM_264
                            else None, args)
    cat = _cat()
    v = _resolve_variant(cat, args.id)
    if not v:
        return 2
    path = None
    for f in cat.files_for_variant(v["id"]):
        if f["path"] and os.path.exists(f["path"]):
            path = f["path"]
            break
    if not path:
        cat.close()
        print(f"no local file for {_vid_str(v)} — use "
              f"`download {args.id} --upload` to fetch and push in one go",
              file=sys.stderr)
        return 1
    # a file downloaded before IDs were handed out at download time gets one
    # here, so nothing reaches the board under a name that names nothing
    _publish(cat, v["id"])
    v = cat.get_variant(v["id"])
    cat.close()
    return _upload_path(path, v["platform"], args, *_canon_of(v), variant=v)


def cmd_compat(args):
    if args.action == "verify":
        # The shared file is what CI gates on; the local one is checked too
        # because a report that cannot be parsed cannot be shared either.
        for path, what in ((compat.default_path(), "shared"),
                           (compat.local_path(), "local")):
            if not os.path.exists(path):
                continue
            try:
                reports, _ = compat.load(path, strict=True)
            except compat.CompatError as e:
                print(f"FAIL ({what}): {e}", file=sys.stderr)
                return 1
            print(f"OK: {path}")
            print(f"  {len(reports)} report(s), all IDs check-char valid")
        return 0

    if args.action == "share":
        from . import share as share_mod
        reports = compat.unshared()
        if not reports:
            print("nothing to share — every local report has been sent")
            return 0
        print(f"{len(reports)} report(s) waiting:")
        print(share_mod.summary(reports))
        if args.route == "print":
            print("\n" + compat.report_lines(reports))
            return 0

        route = args.route
        if route == "auto":
            # Signed in? Send them. Otherwise fall back on the route that
            # needs nothing but a browser.
            from . import webapi
            route = "web" if webapi.logged_in() else "url"

        if route == "web":
            from . import webapi
            try:
                res = share_mod.submit_to_web(reports)
            except webapi.WebAPIError as e:
                print(f"FAIL: {e}", file=sys.stderr)
                if isinstance(e, webapi.NotLoggedIn):
                    print("      run `login` first, or use --route url",
                          file=sys.stderr)
                return 1
            bad = res.get("rejected") or []
            print(f"sent {res.get('accepted', 0)} report(s) to fpgago.com")
            for r in bad:
                which = reports[r["index"]]["id"] if "index" in r else "?"
                print(f"  ! {which}: {r.get('error', '?')}", file=sys.stderr)
            refused = {r["index"] for r in bad if "index" in r}
            # A rejected report stays unshared: it is the one worth retrying.
            accepted = [r for i, r in enumerate(reports) if i not in refused]
            if accepted:
                compat.mark_shared(only=accepted)
            return 1 if bad else 0

        if route == "file":
            if not args.out:
                print("--out PATH is required for --route file",
                      file=sys.stderr)
                return 2
            share_mod.export(reports, args.out)
            print(f"saved to {args.out}")
        elif route == "url":
            print(share_mod.issue_url(reports))
        elif route == "gh":
            try:
                url = share_mod.submit_with_gh(reports)
            except Exception as e:                   # noqa: BLE001
                print(f"gh failed: {e}", file=sys.stderr)
                print("open this instead:\n" + share_mod.issue_url(reports))
                return 1
            print(f"reported: {url}")
        compat.mark_shared()
        return 0

    if args.action == "list":
        reports, errors = compat.load()
        for e in errors:
            print(f"WARNING: {e}", file=sys.stderr)
        cat = _cat()
        flagged = compat.real1541_ids(reports)
        who = (args.by or "").lower()
        # newest report per (game, machine) = current verdict
        shown = {}
        for r in reports:
            if args.status and r["status"] != args.status:
                continue
            if args.machine and r["machine"] != args.machine:
                continue
            if args.real1541 and r["_canon"] not in flagged:
                continue
            # --by filters the REPORTS, not the games: what it answers is
            # "what did this tester find", so a game whose current verdict
            # came from somebody else drops out rather than being shown
            # under their name.
            if who and who not in (f"{r.get('by', '')} "
                                   f"{r.get('email', '')}").lower():
                continue
            shown[(r["_canon"], r["machine"])] = r
        for (cid, _m), r in sorted(shown.items()):
            g = cat.game_by_canon(cid)
            title = g["title"] if g else "?"
            print(f"{canon.format_id(cid):>9} {title[:36]:36} "
                  f"{compat.status_line(r)}")
        cat.close()
        return 0

    # report / show need an ID
    try:
        canon_id, sub = canon.parse_id(args.id)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    cat = _cat()
    g = cat.game_by_canon(canon_id)

    if args.action == "profile":
        reports, _ = compat.load()
        title = g["title"] if g else "?"
        print(f"{canon.format_id(canon_id)}  {title}")
        machines = ([args.machine] if args.machine
                    else sorted({r["machine"] for r in reports
                                 if r["_canon"] == canon_id}))
        found = False
        for m in machines:
            blob = compat.current_profile(reports, canon_id, m, sub)
            if blob is None:
                continue
            found = True
            print(f"  {m}:")
            for line in blob.split("\n"):
                print(f"      {line}")
            errs, warns = profile.check(blob)
            for w in errs + warns:
                print(f"      ! {w}", file=sys.stderr)
        if not found:
            print("  (no settings recorded)")
        cat.close()
        return 0

    if args.action == "show":
        reports, errors = compat.load()
        for e in errors:
            print(f"WARNING: {e}", file=sys.stderr)
        title = g["title"] if g else "?"
        print(f"{canon.format_id(canon_id)}  {title}")
        hist = [r for r in reports if r["_canon"] == canon_id
                and (sub is None or r["_sub"] in (None, sub))]
        if not hist:
            print("  (no reports yet)")
        for r in hist:
            v = f"/{r['_sub']}" if r["_sub"] is not None else "  "
            print(f"  {v:3} {compat.status_line(r)}")
        cur = compat.current(reports, canon_id, sub)
        if cur:
            print("  current verdict:")
            for m in sorted(cur):
                print(f"    {compat.status_line(cur[m])}")
        cat.close()
        return 0

    # action == "report"
    machine = args.machine
    if machine is None and sub is not None:
        v = cat.variant_by_canon(canon_id, sub)
        if v and v["platform"] in compat.MACHINES:
            machine = v["platform"]
    cat.close()
    if machine is None:
        print("error: --machine c64|c16|plus4 required (couldn't infer it "
              "from the variant)", file=sys.stderr)
        return 2
    blob = args.profile
    if blob is None and (args.drive or args.speed or args.btn or
                         args.type is not None):
        blob = profile.build(drive=args.drive, speed=args.speed,
                             btn=args.btn, type=args.type)
    if blob is not None:
        errs, warns = profile.check(blob)
        for w in warns:
            print(f"warning: profile: {w}", file=sys.stderr)
        if errs:
            for e in errs:
                print(f"error: profile: {e}", file=sys.stderr)
            return 2
    try:
        rep = compat.append_report(
            canon_id=canon_id, sub=sub, machine=machine, status=args.status,
            mode=args.mode, bit=args.bit, fw=args.fw, notes=args.notes,
            by=args.by, email=args.email, profile=blob,
            real1541=args.real1541,
            local=getattr(args, "local", False))
    except compat.CompatError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"recorded: {rep['id']}  {compat.status_line(rep)}")
    if getattr(args, "local", False):
        print(f"  -> {compat.local_path()}  "
              "(send it with `compat share`)")
    else:
        print(f"  -> {compat.default_path()} (commit it to share)")
    return 0


def cmd_canon_verify(args):
    path = args.file or canon.default_path()
    try:
        entries = canon.load_file(path)
    except (canon.CanonError, OSError) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    nvar = sum(len(e.get("variants", [])) for e in entries)
    nhash = sum(1 for e in entries for ve in e.get("variants", [])
                if "sha1" in ve)
    print(f"OK: {path}")
    print(f"  {len(entries)} games, {nvar} variants "
          f"({nhash} with pinned content hashes)")
    print("  integrity footer, ID check chars, uniqueness: all verified")


def cmd_patch(args):
    """Show / re-apply the committed catalog corrections."""
    path = args.file or patches.default_path()
    try:
        ps = patches.load(path)
    except (patches.PatchError, OSError) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    if args.action == "list":
        print(f"{path}: {len(ps)} correction(s)")
        for p in ps:
            print(f"  {patches.describe(p)}")
            if p.get("note"):
                print(f"      {p['note']}")
        return 0
    if args.action == "verify":
        print(f"OK: {path}\n  {len(ps)} correction(s), all well-formed")
        return 0
    cat = _cat()                                 # opening already applies them
    r = patches.apply(cat, path)
    cat.close()
    print(f"{r['patches']} correction(s): {r['changed']} variant(s) updated, "
          f"{r['moved']} re-filed under a different game")
    return 0


def cmd_sources(args):
    ss = sources.all_sources()
    if not ss:
        print("(no source adapters registered — network features pending)")
    for s in ss:
        print(f"  {s.name:12} platforms={','.join(s.platforms) or 'any'}")


def cmd_sync(args):
    """Bring the local copy of the game database up to date.

    Everything the catalog knows comes from fpgago.com now: one place does
    the scraping, applies the project's corrections and hands out the
    permanent IDs, and every client downloads the result.  Only the files
    whose checksum changed are fetched, so a sync with nothing new costs one
    small request.
    """
    from . import webdb
    bad = [p for p in args.platform if p not in PLATFORMS]
    if bad:
        print(f"unknown platform(s) {', '.join(bad)} — "
              f"choose from {', '.join(PLATFORMS)}", file=sys.stderr)
        return 2
    print(f"checking {webdb.base_url()}…")
    cat = _cat()
    try:
        res = webdb.sync(cat, platforms=args.platform or None,
                         screenshots=not args.no_screenshots,
                         progress=lambda m: print(f"  {m}"))
    except webdb.WebDBError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    finally:
        cat.close()
    if not res["changed"]:
        print(f"already up to date ({len(res['unchanged'])} file(s) checked)")
    else:
        print(f"updated: {', '.join(res['changed'])}")
        print(f"  {res['games']} game(s), {res['new']} new release(s), "
              f"{res['updated']} updated, {res['reports']} verdict(s), "
              f"{res['shots']} screenshot(s)")
    for err in res["errors"]:
        print(f"  ! {err}", file=sys.stderr)
    return 1 if res["errors"] else 0


def cmd_login(args):
    """Sign in with the fpgago.com account, so results can be sent back."""
    import getpass
    from . import webapi
    username = args.username or input("fpgago.com username: ").strip()
    password = args.password or getpass.getpass("password: ")
    try:
        res = webapi.login(username, password)
    except webapi.WebAPIError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        if e.code == "email_unverified":
            print("      finish registering first — the site emailed you a "
                  "6-digit code", file=sys.stderr)
        return 1
    print(f"signed in as {res['user']}")
    print(f"  token stored in {webapi.token_path()} (mode 0600)")
    print("  send your results with `compat share`")
    return 0


def cmd_logout(args):
    from . import webapi
    res = webapi.logout()
    if res.get("error"):
        print(f"token removed locally, but the server was not told: "
              f"{res['error']}", file=sys.stderr)
    else:
        print("signed out")
    return 0


def cmd_whoami(args):
    from . import webapi
    if not webapi.logged_in():
        print("not signed in — run `login`")
        return 1
    try:
        who = webapi.whoami()
    except webapi.WebAPIError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    if who is None:
        print("the stored token is no longer valid — run `login` again")
        return 1
    print(f"signed in as {who['user']} ({who.get('device') or 'this machine'})")
    return 0


def cmd_screenshot(args):
    """Send a picture.

    `#4193-U` is the game's picture, the one everyone's list shows for every
    release of it.  `#4193-U/5` is that release's crack intro instead — extra,
    not a replacement."""
    from . import webapi
    try:
        canon_id, sub = canon.parse_id(args.id)
    except ValueError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 2
    if not os.path.exists(args.path):
        print(f"FAIL: no such file: {args.path}", file=sys.stderr)
        return 2
    try:
        res = webapi.upload_screenshot(canon_id, args.path, sub=sub)
    except webapi.NotLoggedIn:
        print("FAIL: not signed in — run `login` first", file=sys.stderr)
        return 1
    except webapi.WebAPIError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    print(f"{'crack intro' if sub is not None else 'screenshot'} sent for "
          f"{canon.format_id(canon_id, sub)}")
    if not res.get("published", True):
        print("  it reaches other clients at the next publish")
    return 0


def cmd_sync_status(args):
    """What the local copy knows, without touching the network."""
    from . import webdb
    st = webdb.status()
    print(f"server:    {st['base']}")
    if not st["synced"]:
        print("never synced — run `python3 -m library.cli sync`")
        return 0
    print(f"published: {st['generated']}")
    for name, sha1 in sorted(st["files"].items()):
        print(f"  {name:20} {sha1[:12]}")
    return 0


def main(argv=None):
    # Raw: the module docstring is a formatted command list, and the default
    # formatter reflows it into one unreadable paragraph.
    p = argparse.ArgumentParser(
        prog="library", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("stats").set_defaults(func=cmd_stats)

    sp = sub.add_parser("classify"); sp.add_argument("paths", nargs="+")
    sp.set_defaults(func=cmd_classify)

    sp = sub.add_parser("import"); sp.add_argument("paths", nargs="+")
    sp.add_argument("--platform",
                    choices=PLATFORMS)
    sp.add_argument("--group"); sp.add_argument("--title")
    sp.add_argument("--no-copy", action="store_true")
    sp.set_defaults(func=cmd_import)

    sp = sub.add_parser("search"); sp.add_argument("query")
    sp.add_argument("--platform",
                    choices=PLATFORMS)
    # `--online` is accepted and ignored: it was in everybody's shell history
    # and in the README, and failing on it teaches nothing. `sync` is what
    # goes online now.
    sp.add_argument("--online", action="store_true",
                    help=argparse.SUPPRESS)
    sp.set_defaults(func=cmd_search)

    sp = sub.add_parser("index", help="catalog an existing local collection")
    sp.add_argument("path")
    sp.add_argument("--tosec", metavar="DATDIR",
                    help="dir of TOSEC .dat files for hash-based identity")
    sp.add_argument("--copy", action="store_true",
                    help="copy files into the library tree (default: index in place)")
    sp.add_argument("--verbose", "-v", action="store_true")
    sp.set_defaults(func=cmd_index)

    sp = sub.add_parser("variants"); sp.add_argument("game_id",
                                                     metavar="ID")
    sp.set_defaults(func=cmd_variants)

    sp = sub.add_parser("show", help="resolve a canon ID")
    sp.add_argument("id", metavar="ID")
    sp.set_defaults(func=cmd_show)

    def _board_args(sp):
        sp.add_argument("--run", action="store_true",
                        help="after upload: mount + reset + LOAD\"*\",8,1 + RUN")
        sp.add_argument("--port", help="serial port (default: autodetect)")
        sp.add_argument("--as", dest="as_name", metavar="NAME",
                        help="flash file name on the board")
        sp.add_argument("--no-profile", action="store_true",
                        help="do not push the per-game settings recorded for "
                             "this game in compat.jsonl")

    sp = sub.add_parser("download",
                        help="fetch a release (canon ID like 1234-K or "
                             "1234-K/2; var#N for a raw row)")
    sp.add_argument("id", metavar="ID")
    sp.add_argument("--all", action="store_true", help="all files, not just the first")
    sp.add_argument("--upload", action="store_true",
                    help="push the downloaded file to the board flash")
    _board_args(sp)
    sp.set_defaults(func=cmd_download)

    sp = sub.add_parser("upload", help="push a local file / downloaded release "
                                       "to the board")
    sp.add_argument("id", metavar="ID|PATH")
    _board_args(sp)
    sp.set_defaults(func=cmd_upload)

    sp = sub.add_parser("compat", help="shared compatibility database "
                                       "(data/compat.jsonl, git-tracked)")
    csub = sp.add_subparsers(dest="action", required=True)
    cp = csub.add_parser("report", help="log a verdict for a game/release")
    cp.add_argument("id", metavar="ID", help="canon ID with check char "
                                             "(#2862-A or #2862-A/2)")
    cp.add_argument("status", choices=compat.STATUSES)
    cp.add_argument("--machine", choices=compat.MACHINES,
                    help="core it ran on (inferred from a /N variant)")
    cp.add_argument("--mode", choices=compat.MODES,
                    help="drive mode used (fastload/1541/auto)")
    cp.add_argument("--bit", help="bitstream version (console 'C')")
    cp.add_argument("--fw", help="MCU firmware version")
    cp.add_argument("--notes", help="short note; long analysis goes to "
                                    "retro-arch/COMPATIBILITY.md")
    cp.add_argument("--by", help="reporter (default: git user.name)")
    cp.add_argument("--email", help="reporter's email, so results can be "
                                    "reviewed per tester (default: "
                                    "$FPGAGO_EMAIL / git user.email)")
    # Three states, not two: --real1541 flags the game, --no-real1541 takes a
    # flag back, and neither says nothing at all (the field is left out, and
    # whatever an earlier report said still stands).
    cp.add_argument("--real1541", action="store_true", default=None,
                    help="no fastload path works — the game needs the "
                         "cycle-accurate 1541")
    cp.add_argument("--no-real1541", dest="real1541", action="store_false",
                    help="clear the real-1541 flag: fastload does work")
    cp.add_argument("--profile", help="per-game settings blob shipped with "
                                      "this verdict, e.g. 'drive=dos'")
    cp.add_argument("--drive", choices=profile.DRIVE,
                    help="shorthand: build a profile pinning the drive mode")
    cp.add_argument("--speed", choices=profile.SPEED,
                    help="shorthand: pin the CPU speed grade (PC cores)")
    cp.add_argument("--btn", choices=profile.BTN,
                    help="shorthand: pin the button mapping")
    cp.add_argument("--type", metavar="MACRO",
                    help="shorthand: the start-up macro, '' = no autostart")
    cp.add_argument("--local", action="store_true",
                    help="file it under your own reports (compat-local.jsonl, "
                         "gitignored) instead of the shared database — then "
                         "`compat share` sends it")
    cp.set_defaults(func=cmd_compat)

    cp = csub.add_parser("profile",
                         help="show the per-game settings recorded for a game")
    cp.add_argument("id", metavar="ID")
    cp.add_argument("--machine", choices=compat.MACHINES)
    cp.set_defaults(func=cmd_compat)
    cp = csub.add_parser("show", help="history + current verdict for a game")
    cp.add_argument("id", metavar="ID")
    cp.set_defaults(func=cmd_compat)
    cp = csub.add_parser("list", help="current verdicts across the database")
    cp.add_argument("--status", choices=compat.STATUSES)
    cp.add_argument("--machine", choices=compat.MACHINES)
    # Reviewing a tester's work: everything one person reported, by name or
    # by address, matched as a substring so half of either is enough.
    cp.add_argument("--by", metavar="WHO",
                    help="only reports from this tester (name or email, "
                         "substring, case-insensitive)")
    cp.add_argument("--real1541", action="store_true",
                    help="only games flagged as needing the real 1541")
    cp.set_defaults(func=cmd_compat)
    cp = csub.add_parser("verify", help="validate every line (CI-friendly)")
    cp.set_defaults(func=cmd_compat)
    cp = csub.add_parser("share", help="send your own reports to the project "
                                       "(no git needed)")
    cp.add_argument("--route", default="auto",
                    choices=("auto", "web", "url", "gh", "file", "print"),
                    help="auto: send to fpgago.com when signed in, else url "
                         "(default); web: send to fpgago.com; url: print a "
                         "pre-filled GitHub issue link; gh: submit with the "
                         "GitHub CLI; file: write them out; print: just show "
                         "the lines")
    cp.add_argument("--out", help="destination for --route file")
    cp.set_defaults(func=cmd_compat)

    sp = sub.add_parser("canon-verify", help="integrity-check the registry")
    sp.add_argument("--file")
    sp.set_defaults(func=cmd_canon_verify)

    sp = sub.add_parser("patch",
                        help="committed corrections to what the sources say "
                             "(re-applied on every catalog open)")
    sp.add_argument("action", nargs="?", default="list",
                    choices=("list", "verify", "apply"))
    sp.add_argument("--file", help="patch file (default: "
                                   "desktop/library/data/patches.jsonl)")
    sp.set_defaults(func=cmd_patch)

    sub.add_parser("sources").set_defaults(func=cmd_sources)

    sp = sub.add_parser(
        "sync", help="download the latest game database from fpgago.com "
                     "(only what changed)")
    # No `choices=`: argparse validates the empty default against it and
    # rejects the no-argument form. Checked in cmd_sync instead.
    sp.add_argument("platform", nargs="*", default=[],
                    metavar="PLATFORM",
                    help=f"limit to these platforms ({'/'.join(PLATFORMS)}); "
                         f"default: all")
    sp.add_argument("--no-screenshots", action="store_true",
                    help="skip the pictures (metadata only)")
    sp.set_defaults(func=cmd_sync)

    sub.add_parser("sync-status",
                   help="what the local copy knows, without any network"
                   ).set_defaults(func=cmd_sync_status)

    sp = sub.add_parser("login", help="sign in with your fpgago.com account "
                                      "so results can be sent back")
    sp.add_argument("username", nargs="?")
    sp.add_argument("--password", help="prompted for if not given (and not "
                                       "left in your shell history)")
    sp.set_defaults(func=cmd_login)

    sub.add_parser("logout").set_defaults(func=cmd_logout)
    sub.add_parser("whoami").set_defaults(func=cmd_whoami)

    sp = sub.add_parser("screenshot",
                        help="send a picture for a game, or a release's "
                             "crack intro")
    sp.add_argument("id", help="canon ID: #4193-U for the game's picture, "
                               "#4193-U/5 for that release's crack intro")
    sp.add_argument("path", help="PNG / JPEG / GIF / WEBP, at most 2 MB")
    sp.set_defaults(func=cmd_screenshot)

    args = p.parse_args(argv)
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
