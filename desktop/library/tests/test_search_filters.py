"""Tests for the two search questions the Library tab can now answer:
"which of these already has a picture?" and "which of these is a cartridge?"

Run:  cd desktop && python3 -m pytest library/tests -q

What is being defended: both filters are answers about the LOCAL catalog, so
they must work with the network unplugged, and neither may hide a game for
the wrong reason — a missing screenshot directory is "nobody has a picture",
not "no games".
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from app import library_backend as lib  # noqa: E402
from library import compat, config, webdb  # noqa: E402
from library.db import Catalog, GameRow, VariantRow  # noqa: E402


@pytest.fixture
def cat(tmp_path, monkeypatch):
    """A three-game catalog: a cartridge release, a disc, and one that has a
    screenshot.  Canon IDs are what a screenshot is filed under."""
    monkeypatch.setenv("FPGAGO_GAMES", str(tmp_path / "games"))
    os.makedirs(config.games_root(), exist_ok=True)
    c = Catalog(config.db_path())
    ids = {}
    for title, canon_id, variant in (
            ("Prince of Persia", 4314, VariantRow(
                platform="c64", source="archive",
                source_ref="Prince_of_Persia_2011_cr_Onslaught_EasyFlash",
                release_name="cr Onslaught EasyFlash 2011-10-16")),
            ("Turrican", 1000, VariantRow(platform="c64", source="archive",
                                          source_ref="Turrican")),
            ("Terra Nova", 1001, VariantRow(platform="plus4", source="p4w",
                                            source_ref="Terra_Nova"))):
        gid = c.upsert_game(GameRow(title))
        c.db.execute("UPDATE game SET canon_id=? WHERE id=?", (canon_id, gid))
        c.upsert_variant(gid, variant)
        ids[title] = gid
    c.commit()
    c.close()
    return ids


def titles(rows):
    return sorted(r["title"] for r in rows)


# ── screenshots ────────────────────────────────────────────────────────────

def test_a_game_with_a_picture_says_so(cat):
    open(os.path.join(webdb.shots_dir(), "4314.png"), "wb").close()
    rows = {r["title"]: r for r in lib.search("")}
    assert rows["Prince of Persia"]["has_shot"] is True
    assert rows["Turrican"]["has_shot"] is False


def test_filtering_on_a_picture_goes_both_ways(cat):
    open(os.path.join(webdb.shots_dir(), "4314.png"), "wb").close()
    assert titles(lib.search("", shot=True)) == ["Prince of Persia"]
    assert titles(lib.search("", shot=False)) == ["Terra Nova", "Turrican"]
    assert len(lib.search("")) == 3                 # "any" is still every game


def test_no_pictures_at_all_is_not_no_games(cat):
    """An install that has never synced has no shots directory; that must
    read as "nobody has a picture", not as an empty library."""
    assert len(lib.search("")) == 3
    assert lib.search("", shot=True) == []


def test_only_a_real_image_counts(cat):
    """Whatever else lands in the cache directory is not a screenshot."""
    for junk in ("4314.txt", "readme.png", ".DS_Store"):
        open(os.path.join(webdb.shots_dir(), junk), "wb").close()
    assert webdb.shot_ids() == set()


# ── EasyFlash ──────────────────────────────────────────────────────────────

def test_a_cartridge_release_is_found_by_what_it_calls_itself(cat):
    """The synced catalog carries no `fmt`; what it does carry is the release
    name the scene gave it, and that is where "EasyFlash" is written."""
    assert titles(lib.search("", easyflash=True)) == ["Prince of Persia"]


def test_a_downloaded_crt_counts_too(cat):
    c = Catalog(config.db_path())
    vid = c.db.execute("SELECT v.id FROM variant v JOIN game g ON g.id="
                       "v.game_id WHERE g.title='Turrican'").fetchone()[0]
    c.db.execute("INSERT INTO file (variant_id, filename, added_at) "
                 "VALUES (?,?,0)", (vid, "turrican.crt"))
    c.commit()
    try:
        assert c.easyflash_game_ids() == {cat["Prince of Persia"],
                                          cat["Turrican"]}
    finally:
        c.close()


def test_the_filters_combine_with_the_platform(cat):
    assert titles(lib.search("", platform="c64", easyflash=True)) \
        == ["Prince of Persia"]
    assert lib.search("", platform="plus4", easyflash=True) == []


# ── "needs the real 1541" ──────────────────────────────────────────────────
# The flag a tester sets when no fastload path serves a game.  Searchable
# because the answer to "which games have to be run on the slow drive?" is
# otherwise a grep through compat.jsonl.


@pytest.fixture
def flags(tmp_path, monkeypatch):
    """A compat database of our own — the real one ships with the checkout
    and would make these assertions depend on it."""
    shared = tmp_path / "compat.jsonl"
    shared.write_text("")
    monkeypatch.setattr(compat, "default_path", lambda: str(shared))
    monkeypatch.setattr(compat, "local_path",
                        lambda: str(tmp_path / "compat-local.jsonl"))

    def report(canon_id, machine="c64", real1541=None, date="2026-08-07",
               local=False):
        return compat.append_report(
            canon_id=canon_id, sub=None, machine=machine, status="works",
            real1541=real1541, by="tester", email="tester@example.com",
            date=date, local=local,
            path=None if local else str(shared))
    return report


def test_only_the_flagged_game_comes_back(cat, flags):
    flags(4314, real1541=True)
    flags(1000, real1541=False)
    assert titles(lib.search("", real1541=True)) == ["Prince of Persia"]
    assert len(lib.search("")) == 3           # unfiltered is still every game


def test_every_row_says_whether_it_needs_the_real_drive(cat, flags):
    flags(4314, real1541=True)
    rows = {r["title"]: r for r in lib.search("")}
    assert rows["Prince of Persia"]["real1541"] is True
    assert rows["Turrican"]["real1541"] is False


def test_your_own_finding_counts_before_it_is_shared(cat, flags):
    """A verdict recorded here goes to the local file first; the filter has
    to see it, or the game you just flagged vanishes from your own search."""
    flags(1000, real1541=True, local=True)
    assert titles(lib.search("", real1541=True)) == ["Turrican"]


def test_clearing_the_flag_takes_the_game_out_again(cat, flags):
    flags(4314, real1541=True, date="2026-08-01")
    flags(4314, real1541=False, date="2026-08-06")
    assert lib.search("", real1541=True) == []


def test_the_filter_combines_with_the_platform(cat, flags):
    flags(4314, real1541=True)
    flags(1001, machine="plus4", real1541=True)
    assert titles(lib.search("", platform="plus4", real1541=True)) \
        == ["Terra Nova"]


def test_an_id_search_ignores_the_filter_but_still_reports_it(cat, flags):
    flags(4314, real1541=True)
    rows = lib.search("#4314-J", real1541=True)
    assert titles(rows) == ["Prince of Persia"]
    assert rows[0]["real1541"] is True


# ── multiplayer ────────────────────────────────────────────────────────────
# A tick in the shared database (webdb sync writes it, the desktop checkbox
# sets it through the API); the filter answers "what can the two of us play?"


def _mark_multiplayer(gid: int):
    c = Catalog(config.db_path())
    try:
        c.db.execute("UPDATE game SET multiplayer=1 WHERE id=?", (gid,))
        c.commit()
    finally:
        c.close()


def test_every_row_says_whether_it_is_multiplayer(cat):
    _mark_multiplayer(cat["Prince of Persia"])
    rows = {r["title"]: r for r in lib.search("")}
    assert rows["Prince of Persia"]["multiplayer"] is True
    assert rows["Turrican"]["multiplayer"] is False


def test_the_multiplayer_filter_keeps_only_the_ticked_games(cat):
    _mark_multiplayer(cat["Turrican"])
    assert titles(lib.search("", multiplayer=True)) == ["Turrican"]
    assert len(lib.search("")) == 3           # unfiltered is still every game


def test_multiplayer_combines_with_the_platform(cat):
    _mark_multiplayer(cat["Prince of Persia"])
    _mark_multiplayer(cat["Terra Nova"])
    assert titles(lib.search("", platform="plus4", multiplayer=True)) \
        == ["Terra Nova"]


def test_an_id_search_ignores_the_multiplayer_filter_but_reports_it(cat):
    rows = lib.search("#4314-J", multiplayer=True)
    assert titles(rows) == ["Prince of Persia"]
    assert rows[0]["multiplayer"] is False


# ── searching by canonical ID ──────────────────────────────────────────────
# "#4314-J" is what the app prints, what a compat report quotes and what the
# CLI takes.  Typing it into the search box has to find that game.

def test_an_id_finds_its_game(cat):
    assert titles(lib.search("#4314")) == ["Prince of Persia"]
    assert titles(lib.search("#4314-J")) == ["Prince of Persia"]


def test_the_check_character_is_verified(cat):
    """The letter exists to catch a mistyped number; an ID that fails it is a
    typo, and saying "0 games" would hide that."""
    with pytest.raises(ValueError, match="check character"):
        lib.search("#4314-X")


def test_a_release_number_comes_back_for_the_variants_list(cat):
    rows = lib.search("#4314-J/1")
    assert rows[0]["want_sub"] == 1
    assert lib.search("#4314")[0]["want_sub"] is None


def test_an_id_ignores_the_other_filters(cat):
    """An ID names one game.  A platform box left on c16, or "only games with
    a picture", must not answer "no such game" about one that plainly is."""
    rows = lib.search("#4314-J", platform="c16", tested="works", shot=True,
                      easyflash=True)
    assert titles(rows) == ["Prince of Persia"]


def test_an_unknown_id_is_simply_no_rows(cat):
    assert lib.search("#9999") == []


# ── a bare number is a title AND an ID ─────────────────────────────────────
# Half the arcade catalog is a number — 1942, 1943, 720° — and every game
# also HAS a number.  Typing one cannot tell the two apart, so the answer is
# both, and the row that matched by number says so.

@pytest.fixture
def numbers(cat):
    """Two games that a search for "1942" could mean: the one CALLED 1942,
    and the one whose canonical ID happens to be #1942."""
    c = Catalog(config.db_path())
    ids = {}
    for title, canon_id in (("1942", 3301), ("Bruce Lee", 1942)):
        gid = c.upsert_game(GameRow(title))
        c.db.execute("UPDATE game SET canon_id=? WHERE id=?", (canon_id, gid))
        c.upsert_variant(gid, VariantRow(platform="c64", source="x",
                                         source_ref=title))
        ids[title] = gid
    c.commit()
    c.close()
    return ids


def test_a_bare_number_searches_both(numbers):
    got = lib.search("1942")
    assert sorted(r["title"] for r in got) == ["1942", "Bruce Lee"]


def test_the_id_hit_comes_first_and_says_it_is_one(numbers):
    """Exactly one row can match the number exactly, so it leads — and it
    carries the flag the list needs to explain why it is there."""
    got = lib.search("1942")
    assert got[0]["title"] == "Bruce Lee"
    assert got[0]["by_id"] is True
    assert got[0]["canon_id"] == 1942
    assert "by_id" not in got[1]                # the title hit is not marked


def test_a_number_is_still_a_title_when_no_game_has_that_id(cat):
    c = Catalog(config.db_path())
    gid = c.upsert_game(GameRow("1942"))
    c.db.execute("UPDATE game SET canon_id=? WHERE id=?", (3301, gid))
    c.upsert_variant(gid, VariantRow(platform="c64", source="x",
                                     source_ref="1942"))
    c.commit()
    c.close()
    assert titles(lib.search("1942")) == ["1942"]
    assert lib.canon_query("1942") is None      # not the '#' form


def test_one_game_that_is_both_is_listed_once(cat):
    """A game called 1942 that is also #1942 must not appear twice."""
    c = Catalog(config.db_path())
    gid = c.upsert_game(GameRow("1942"))
    c.db.execute("UPDATE game SET canon_id=? WHERE id=?", (1942, gid))
    c.upsert_variant(gid, VariantRow(platform="c64", source="x",
                                     source_ref="1942"))
    c.commit()
    c.close()
    got = lib.search("1942")
    assert [r["title"] for r in got] == ["1942"]


def test_the_id_hit_survives_the_other_filters(numbers):
    """An ID is an identity, not a description: a platform box left on plus4
    must not answer "no such game" about the game you named by number."""
    got = lib.search("1942", platform="plus4")
    assert [r["title"] for r in got] == ["Bruce Lee"]
    got = lib.search("1942", shot=True, easyflash=True)
    assert [r["title"] for r in got] == ["Bruce Lee"]


def test_a_word_query_asks_no_id_question(numbers):
    assert titles(lib.search("bruce")) == ["Bruce Lee"]
    assert all("by_id" not in r for r in lib.search("bruce"))
