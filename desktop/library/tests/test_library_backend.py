"""Tests for the desktop app's library backend — the per-game settings it
reads out of the compat database, and the one-click "send to board" that
carries them.  Network-free, board-free (a fake BoardOps records the calls).

Run:  cd desktop && python3 -m pytest library/tests -q

The point being defended: a game's settings must travel WITH the game.
Downloading reports them, uploading writes them to the board's KV store, and
both happen without anyone retyping a drive mode.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from app import library_backend as lib  # noqa: E402
from library import canon, compat, config, ingest, profile  # noqa: E402
from library.db import Catalog, GameRow, VariantRow  # noqa: E402

PROFILE = 'drive=dos\ntype=@boot;load"*",8,1\\r;@load;run\\r'


@pytest.fixture
def libdir(tmp_path, monkeypatch):
    """An isolated game library.  The compat files are already redirected
    for every test by conftest.py's autouse fixture."""
    monkeypatch.setenv("FPGAGO_GAMES", str(tmp_path / "games"))
    os.makedirs(config.games_root(), exist_ok=True)
    return tmp_path


@pytest.fixture
def game(libdir):
    """A c64 game with one variant and one downloaded .prg.  Returns
    (variant_id, canon_id)."""
    prg = libdir / "pirates.prg"
    prg.write_bytes(b"\x01\x08" + b"\x00" * 256)          # $0801 -> c64
    cat = Catalog(config.db_path())
    gid = cat.upsert_game(GameRow("Pirates"))
    cat.db.execute("UPDATE game SET canon_id=? WHERE id=?", (2862, gid))
    vid = cat.upsert_variant(gid, VariantRow(
        platform="c64", source="local", source_ref="t1"))
    cat.db.execute("UPDATE variant SET canon_sub=1 WHERE id=?", (vid,))
    ingest.ingest_file(cat, str(prg), title="Pirates", platform="c64",
                       source="local", source_ref="t1",
                       copy_into_library=False)
    cat.commit()
    cat.close()
    return vid, 2862


class FakeOps:
    """Just enough BoardOps for upload_with_ops()."""

    def __init__(self):
        self.files, self.kv, self.ran = {}, {}, []

    def fs_upload(self, name, data, progress=None, ftype=None, platform=None):
        self.files[name] = (data, ftype, platform)

    def fs_stat(self, name):
        import zlib
        data = self.files[name][0]
        return {"size": len(data), "crc32": zlib.crc32(data) & 0xFFFFFFFF}

    def kv_set(self, key, val):
        self.kv[key] = val

    def run_game(self, name, progress=None):
        self.ran.append(name)


# ── machines a profile can be filed under ──────────────────────────────────

def test_machines_for_accepts_the_comma_string_the_db_returns():
    assert lib.machines_for("c64,c16") == ["c64", "c16"]


def test_machines_for_drops_a_platform_compat_does_not_know():
    # a report for an unknown machine would not validate — better to offer
    # nothing than to write a line that breaks `compat verify` in CI
    assert lib.machines_for(["c64", "vic20"]) == ["c64"]


def test_machines_for_deduplicates():
    assert lib.machines_for("c64,c64,plus4") == ["c64", "plus4"]


# ── reading / writing a game's settings ────────────────────────────────────

def test_no_profile_recorded_yet(libdir):
    assert lib.game_profile(2862, "c64")["profile"] is None


def test_a_game_without_a_canon_id_has_no_settings(libdir):
    assert lib.game_profile(None, "c64")["profile"] is None


def test_save_then_read_back(libdir):
    lib.save_game_profile(2862, None, "c64", PROFILE, "works")
    got = lib.game_profile(2862, "c64")
    assert got["profile"] == PROFILE
    assert got["status"] == "works"


def test_saved_line_is_a_valid_compat_report(libdir):
    res = lib.save_game_profile(2862, 1, "c64", PROFILE, "issues")
    assert res["report"]["id"] == "#2862-A/1"
    reports, errors = compat.load(res["path"])
    assert not errors and len(reports) == 1


def test_saving_appends_rather_than_rewrites(libdir):
    lib.save_game_profile(2862, None, "c64", "drive=1541", "works")
    lib.save_game_profile(2862, None, "c64", PROFILE, "works")
    with open(compat.local_path(), encoding="utf-8") as fh:
        lines = [json.loads(x) for x in fh if x.strip()]
    assert len(lines) == 2                      # history is never rewritten
    assert lib.game_profile(2862, "c64")["profile"] == PROFILE


def test_settings_are_per_machine(libdir):
    lib.save_game_profile(2862, None, "c64", "drive=dos", "works")
    lib.save_game_profile(2862, None, "c16", "drive=1541", "works")
    assert lib.game_profile(2862, "c64")["profile"] == "drive=dos"
    assert lib.game_profile(2862, "c16")["profile"] == "drive=1541"


def test_a_malformed_profile_is_refused(libdir):
    with pytest.raises(ValueError):
        lib.save_game_profile(2862, None, "c64", "type=@bogus", "works")


# ── the download carries the settings ──────────────────────────────────────

def test_download_result_would_carry_the_profile(libdir, game):
    vid, cid = game
    lib.save_game_profile(cid, None, "c64", PROFILE, "works")
    cat = Catalog(config.db_path())
    try:
        blob = lib._profile_for_variant(cat, cat.get_variant(vid))
    finally:
        cat.close()
    assert blob == PROFILE


def test_variant_rows_without_the_game_join_still_resolve(libdir, game):
    """variants_for_game() selects no canon column — the lookup has to reach
    the game row itself, or the GUI's settings would silently be empty."""
    vid, cid = game
    lib.save_game_profile(cid, None, "c64", PROFILE, "works")
    cat = Catalog(config.db_path())
    try:
        v = [r for r in cat.variants_for_game(
            cat.get_variant(vid)["game_id"])][0]
        assert "game_canon" not in v.keys()      # the trap this guards
        assert lib._profile_for_variant(cat, v) == PROFILE
    finally:
        cat.close()


# ── the CLI reads the same ID off the same row ─────────────────────────────

def test_the_cli_reads_the_games_canon_from_the_join(libdir, game):
    """`variant` has no canon_id column — the game's ID arrives through the
    join as `game_canon`.  And sqlite3.Row has no .get(), so asking it the
    convenient way raises instead of returning None: both halves of this
    are why `download --upload` has to go through _row_get()."""
    from library import cli
    vid, cid = game
    cat = Catalog(config.db_path())
    try:
        v = cat.get_variant(vid)
        assert not hasattr(v, "get")
        assert cli._row_get(v, "canon_id") is None
        assert cli._canon_of(v) == (cid, 1)      # what upload/download feed
        assert cli._vid_str(v) == "#2862-A/1"
    finally:
        cat.close()


def test_the_cli_ships_the_recorded_profile(libdir, game):
    import argparse
    from library import cli
    _vid, cid = game
    lib.save_game_profile(cid, None, "c64", PROFILE, "works")
    assert cli._shipped_profile(
        cid, None, "c64", argparse.Namespace(no_profile=False)) == PROFILE
    assert cli._shipped_profile(
        cid, None, "c64", argparse.Namespace(no_profile=True)) is None


# ── one click: file + settings onto the board ──────────────────────────────

def test_send_uploads_the_file_and_the_settings(libdir, game):
    vid, cid = game
    lib.save_game_profile(cid, None, "c64", PROFILE, "works")
    ops = FakeOps()
    res = lib.send_variant(ops, vid)
    # The CANON id is part of the flash name (board_name(ident=…)): it keeps a
    # second release of the same game from overwriting the first, AND it is
    # the same string the Library's ID column and the compat database use, so
    # the file on the board can be matched back to the row that sent it.
    assert res["file"] == "c64-pirates-2862.1.prg"
    assert lib.canon.format_id(cid, 1) == "#2862-A/1"    # same identity
    assert res["file"] in ops.files
    assert ops.kv[profile.kv_key(res["file"])].decode() == PROFILE
    assert not ops.ran                           # run=False


def test_send_and_run_writes_the_settings_before_starting(libdir, game):
    vid, cid = game
    lib.save_game_profile(cid, None, "c64", PROFILE, "works")
    ops = FakeOps()
    order = []
    ops.kv_set = lambda k, v: order.append("kv")
    real_run = ops.run_game
    ops.run_game = lambda n, progress=None: (order.append("run"), real_run(n))
    res = lib.send_variant(ops, vid, run=True)
    # a profile written after the launch would miss the launch it configures
    assert order == ["kv", "run"]
    # a .prg is wrapped into a bootable .d64 on the way, and the KV key
    # follows the name that actually landed in flash
    assert res["ran"] and res["file"].endswith(".d64")


def test_send_without_a_profile_still_uploads(libdir, game):
    vid, _cid = game
    ops = FakeOps()
    res = lib.send_variant(ops, vid)
    assert res["file"] in ops.files and res["profile"] is None
    assert ops.kv == {}


def test_send_reports_an_unknown_variant(libdir):
    assert "error" in lib.send_variant(FakeOps(), 999)


def test_a_mountable_image_beats_the_archive_it_came_in(libdir, game):
    """A release can arrive as a .zip alongside the disk image itself; the
    mountable file is the one the board can run."""
    vid, _cid = game
    zip_path = libdir / "game.zip"
    zip_path.write_bytes(b"PK\x03\x04" + b"\x00" * 64)
    d64 = libdir / "game.d64"
    d64.write_bytes(b"\x00" * 174848)
    cat = Catalog(config.db_path())
    try:
        for p in (zip_path, d64):
            cat.db.execute(
                "INSERT INTO file (variant_id, filename, path, added_at) "
                "VALUES (?,?,?,0)", (vid, p.name, str(p)))
        cat.commit()
        v = cat.get_variant(vid)
        assert lib._local_file(cat, v).endswith(".d64")
    finally:
        cat.close()


def test_best_verdict_prefers_the_machine_it_works_on():
    assert lib.best_verdict({"c64": "works", "c16": "broken"}) == "works"
    assert lib.best_verdict({"c16": "broken", "c64": "issues"}) == "issues"
    assert lib.best_verdict({}) is None
    assert lib.best_verdict({"c64": "nonsense"}) is None


def test_verdict_map_keeps_the_newest_report_per_machine(libdir):
    compat.append_report(canon_id=2862, sub=None, machine="c64",
                         status="broken", date="2029-01-01")
    compat.append_report(canon_id=2862, sub=None, machine="c64",
                         status="works", date="2030-01-01")
    compat.append_report(canon_id=2862, sub=None, machine="c16",
                         status="issues", date="2030-01-01")
    got = lib.verdict_map()[2862]
    assert got["c64"].online == "works" and got["c16"].online == "issues"


def test_search_rows_carry_their_verdicts(libdir, game):
    _vid, cid = game
    compat.append_report(canon_id=cid, sub=None, machine="c64",
                         status="works")
    row = [r for r in lib.search("pirates") if r["canon_id"] == cid][0]
    assert row["verdicts"]["c64"] == lib.Verdict(online="works")


# ── whose verdict is it? ───────────────────────────────────────────────────

def test_a_verdict_knows_where_it_came_from(libdir, game):
    _vid, cid = game
    compat.append_report(canon_id=cid, sub=None, machine="c64",
                         status="broken")                     # the project's
    lib.save_game_profile(cid, None, "c16", "", "works")      # your own
    got = lib.verdict_map()[cid]
    assert got["c64"].source == "online" and got["c64"].yours is None
    assert got["c16"].source == "yours" and got["c16"].online is None


def test_your_own_result_outranks_the_online_one(libdir, game):
    _vid, cid = game
    compat.append_report(canon_id=cid, sub=None, machine="c64",
                         status="broken", date="2030-01-01")
    lib.save_game_profile(cid, None, "c64", "", "works")
    v = lib.verdict_map()[cid]["c64"]
    assert v.status == "works" and v.source == "yours"
    assert v.disagrees                       # ...and the clash is visible


def test_agreement_is_not_a_disagreement(libdir, game):
    _vid, cid = game
    compat.append_report(canon_id=cid, sub=None, machine="c64",
                         status="works")
    lib.save_game_profile(cid, None, "c64", "", "works")
    assert not lib.verdict_map()[cid]["c64"].disagrees


def test_the_conflict_filter_finds_exactly_those(libdir, game):
    _vid, cid = game
    compat.append_report(canon_id=cid, sub=None, machine="c64",
                         status="broken")
    lib.save_game_profile(cid, None, "c64", "", "works")
    rows = lib.search("pirates", tested="conflict")
    assert [r["canon_id"] for r in rows] == [cid]
    assert lib.search("pirates", tested="untested") == []


def test_a_downloaded_online_database_counts_as_online(libdir, game):
    """A checkout that is never `git pull`ed still learns what other people
    found — the fetched copy is read like the shipped one."""
    _vid, cid = game
    import json
    with open(compat.online_path(), "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "issues", "date": "2030-01-01"}) + "\n")
    v = lib.verdict_map()[cid]["c64"]
    assert v.online == "issues" and v.source == "online"


def test_search_can_filter_to_what_works_and_what_is_untried(libdir, game):
    _vid, cid = game
    cat = Catalog(config.db_path())
    gid = cat.upsert_game(GameRow("Pirates Adventure"))     # never tested
    cat.db.execute("UPDATE game SET canon_id=4193 WHERE id=?", (gid,))
    cat.commit(); cat.close()
    compat.append_report(canon_id=cid, sub=None, machine="c64",
                         status="broken")

    def titles(tested):
        return sorted(r["title"] for r in lib.search("pirates", tested=tested))
    assert titles("broken") == ["Pirates"]
    assert titles("works") == []
    assert titles("untested") == ["Pirates Adventure"]
    assert len(titles(None)) == 2


def test_variants_carry_their_own_verdict_and_settings(libdir, game):
    vid, cid = game
    compat.append_report(canon_id=cid, sub=1, machine="c64", status="works",
                         profile=PROFILE)
    cat = Catalog(config.db_path())
    gid = cat.get_variant(vid)["game_id"]
    cat.close()
    v = lib.variants(gid)[0]
    assert v["verdict"].status == "works" and v["profile"] == PROFILE


def test_variants_carry_the_id_you_report_a_result_under(libdir, game):
    """The Library tab lists releases; a verdict is recorded against the
    canon ID, so the list has to be able to show it."""
    vid, cid = game
    cat = Catalog(config.db_path())
    gid = cat.get_variant(vid)["game_id"]
    cat.close()
    assert lib.variants(gid)[0]["canon"] == canon.format_id(cid, 1)


def test_an_unregistered_variant_falls_back_to_its_row_id(libdir, game):
    """A game the canon registry has not caught up with still needs a name
    in the list — the same var#N the CLI accepts."""
    vid, _cid = game
    cat = Catalog(config.db_path())
    gid = cat.get_variant(vid)["game_id"]
    cat.db.execute("UPDATE game SET canon_id=NULL WHERE id=?", (gid,))
    cat.commit()
    cat.close()
    assert lib.variants(gid)[0]["canon"] == f"var#{vid}"


def test_releases_without_their_own_id_are_still_told_apart(libdir, game):
    """THE bug this list had: a release with no /n of its own showed the bare
    game ID, so every crack of one game rendered as the same '#4193-U' — you
    could not say which row you had downloaded, let alone which one reached
    the board.  Rows must never share a name."""
    vid, cid = game
    cat = Catalog(config.db_path())
    gid = cat.get_variant(vid)["game_id"]
    for ref, group in (("cr_Bandit", "Bandit"), ("cr_ATG", "ATG")):
        cat.upsert_variant(gid, VariantRow(
            platform="c64", source="archive",
            source_ref=f"Pirates_1987_Firebird_{ref}"))
    cat.commit()
    cat.close()

    rows = lib.variants(gid)
    ids = [r["canon"] for r in rows]
    assert len(set(ids)) == len(ids), f"two rows share a name: {ids}"
    assert canon.format_id(cid, 1) in ids            # the published one
    # and the unpublished ones say who made them, which is the whole point
    releases = {r["release"] for r in rows}
    assert "cr Bandit" in releases and "cr ATG" in releases


def test_sending_uses_the_id_the_database_handed_out(libdir, game):
    """The flash name carries the canon ID, so a file on the board can be
    matched back to the row in the Library that produced it."""
    vid, cid = game
    res = lib.send_variant(FakeOps(), vid)
    assert res["canon"] == f"{cid}.1"
    assert res["file"].endswith(f"-{cid}.1.prg")


def test_sending_a_release_the_database_has_never_seen(libdir, game):
    """A release this machine found by itself — an imported file, an indexed
    folder — has no canon ID until the server has seen it.  IDs are minted on
    fpgago.com now, so the client cannot invent one; it falls back on the
    local row id rather than refusing to send the game."""
    vid, _cid = game
    cat = Catalog(config.db_path())
    cat.db.execute("UPDATE variant SET canon_sub=NULL WHERE id=?", (vid,))
    cat.db.execute("UPDATE game SET canon_id=NULL WHERE id=("
                   "SELECT game_id FROM variant WHERE id=?)", (vid,))
    cat.commit()
    cat.close()

    res = lib.send_variant(FakeOps(), vid)
    assert res["file"].endswith(f"-{vid}.prg")
    # ...and nothing was invented: the row still has no ID.
    cat = Catalog(config.db_path())
    try:
        assert cat.get_variant(vid)["canon_sub"] is None
    finally:
        cat.close()


# ── results that send themselves ───────────────────────────────────────────
# The desktop app calls this after every saved verdict and on a timer, so
# it has one hard requirement beyond being right: it must never raise.  A
# laptop on a train is a normal state, not a crash, and the app has to be
# able to say *why* rather than show a traceback.

def _queue_one(machine="c64", canon_id=4193):
    compat.append_report(canon_id=canon_id, sub=None, machine=machine,
                         status="works", profile="drive=dos", local=True)


def test_nothing_queued_is_not_a_failure(libdir):
    assert lib.auto_share() == {"sent": 0, "pending": 0, "ok": True,
                                "why": ""}


def test_without_an_account_it_says_so_and_keeps_the_report(libdir,
                                                            monkeypatch):
    _queue_one()
    monkeypatch.setattr(lib.webapi, "logged_in", lambda: False)
    res = lib.auto_share()
    assert res["ok"] is False and res["sent"] == 0
    assert res["pending"] == 1
    assert "not signed in" in res["why"]
    # still queued: the next attempt, or the manual Share dialog, gets it
    assert len(compat.unshared()) == 1


def test_an_unreachable_server_never_raises(libdir, monkeypatch):
    _queue_one()
    monkeypatch.setattr(lib.webapi, "logged_in", lambda: True)

    def boom(_reports):
        raise IOError("cannot reach fpgago.com: Connection refused")

    monkeypatch.setattr(lib.share, "submit_to_web", boom)
    res = lib.auto_share()
    assert res["ok"] is False and res["pending"] == 1
    assert "cannot reach fpgago.com" in res["why"]
    assert len(compat.unshared()) == 1


def test_what_the_server_took_stops_being_queued(libdir, monkeypatch):
    _queue_one()
    monkeypatch.setattr(lib.webapi, "logged_in", lambda: True)
    monkeypatch.setattr(lib.share, "submit_to_web",
                        lambda reports: {"accepted": len(reports),
                                         "rejected": []})
    res = lib.auto_share()
    assert res == {"sent": 1, "pending": 0, "ok": True, "why": "",
                   "rejected": []}
    assert compat.unshared() == []


def test_a_refused_report_stays_queued_and_says_why(libdir, monkeypatch):
    """Nine of ten accepted must not mark the tenth as sent — it is the one
    the user most needs offered again, and told about."""
    _queue_one("c64")
    _queue_one("c16", canon_id=4194)
    monkeypatch.setattr(lib.webapi, "logged_in", lambda: True)
    monkeypatch.setattr(lib.share, "submit_to_web",
                        lambda reports: {"accepted": 1,
                                         "rejected": [{"index": 1,
                                                       "error": "no such "
                                                                "game"}]})
    res = lib.auto_share()
    assert res["sent"] == 1 and res["pending"] == 1
    assert res["ok"] is False and "no such game" in res["why"]
    assert len(compat.unshared()) == 1
