"""Tests for the canonical game-ID registry (canon.py). Network-free.

Run:  cd desktop && python3 -m pytest library/tests -q
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from library import canon  # noqa: E402
from library.board import board_name  # noqa: E402
from library.db import Catalog, GameRow, VariantRow, FileRow  # noqa: E402


# ── check character ─────────────────────────────────────────────────────────

def test_check_char_detects_single_digit_errors():
    for n in (7, 42, 1234, 98765):
        good = canon.check_char(n)
        s = str(n)
        for pos in range(len(s)):
            for d in "0123456789":
                if d == s[pos]:
                    continue
                mutated = int(s[:pos] + d + s[pos + 1:])
                if mutated == n:
                    continue
                assert canon.check_char(mutated) != good, \
                    f"{n} -> {mutated} not caught"


def test_check_char_detects_adjacent_transpositions():
    for n in (42, 1234, 5091, 98765):
        good = canon.check_char(n)
        s = str(n)
        for pos in range(len(s) - 1):
            if s[pos] == s[pos + 1]:
                continue
            swapped = s[:pos] + s[pos + 1] + s[pos] + s[pos + 2:]
            if int(swapped) == n:
                continue
            assert canon.check_char(int(swapped)) != good, \
                f"{n} -> {swapped} not caught"


def test_parse_format_roundtrip():
    assert canon.parse_id(canon.format_id(1234)) == (1234, None)
    assert canon.parse_id(canon.format_id(1234, 2)) == (1234, 2)
    assert canon.parse_id("1234") == (1234, None)          # bare, unguarded
    assert canon.parse_id("#1234") == (1234, None)
    chk = canon.check_char(1234)
    assert canon.parse_id(f"1234-{chk.lower()}") == (1234, None)


def test_parse_rejects_bad_check_char():
    chk = canon.check_char(1234)
    wrong = "A" if chk != "A" else "B"
    with pytest.raises(ValueError):
        canon.parse_id(f"1234-{wrong}")
    with pytest.raises(ValueError):
        canon.parse_id("not-an-id")


# ── registry file ───────────────────────────────────────────────────────────

def _entries():
    return [
        {"id": 1, "title": "Boulder Dash", "year": 1984,
         "variants": [{"n": 1, "platform": "c64", "source": "csdb",
                       "ref": "111", "sha1": "a" * 40, "crc32": "12345678"}]},
        {"id": 2, "title": "Elite",
         "variants": [{"n": 1, "platform": "plus4", "source": "plus4world",
                       "ref": "222"}]},
    ]


def test_file_roundtrip_and_integrity():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "canon.jsonl")
        foot = canon.write_file(path, _entries())
        assert foot["games"] == 2 and foot["variants"] == 2
        back = canon.load_file(path)
        assert [e["id"] for e in back] == [1, 2]
        assert back[0]["chk"] == canon.check_char(1)
        assert back[0]["variants"][0]["sha1"] == "a" * 40


def test_tampered_file_refuses_to_load():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "canon.jsonl")
        canon.write_file(path, _entries())
        with open(path) as fh:
            lines = fh.readlines()
        lines[1] = lines[1].replace("Boulder Dash", "Boulder Trash")
        with open(path, "w") as fh:
            fh.writelines(lines)
        with pytest.raises(canon.CanonError):
            canon.load_file(path)


def test_truncated_file_refuses_to_load():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "canon.jsonl")
        canon.write_file(path, _entries())
        with open(path) as fh:
            lines = fh.readlines()
        with open(path, "w") as fh:
            fh.writelines(lines[:1] + lines[2:])   # drop a game line
        with pytest.raises(canon.CanonError):
            canon.load_file(path)


# ── build / import (ID stability across users) ──────────────────────────────

def _seed_catalog(path):
    cat = Catalog(path)
    for title, plat, ref in (("Boulder Dash", "c64", "bd1"),
                             ("Elite", "plus4", "el1"),
                             ("Zork", "c64", "zk1")):
        gid = cat.upsert_game(GameRow(title))
        cat.upsert_variant(gid, VariantRow(platform=plat, source="csdb",
                                           source_ref=ref))
    cat.commit()
    return cat


# ── the registry as a read-only format ─────────────────────────────────────
#
# `build()` and `assign()` used to live in canon.py and minted IDs locally,
# by taking max(id)+1 of a git-committed file.  fpgago.com hands out IDs now
# (see test_webdb.py), so what is left here is reading the format: the
# integrity guards, and the import that seeds a fresh checkout offline.

def test_write_then_load_round_trips():
    with tempfile.TemporaryDirectory() as d:
        reg = os.path.join(d, "canon.jsonl")
        entries = [
            {"id": 7, "title": "Boulder Dash",
             "variants": [{"n": 1, "platform": "c64", "source": "csdb",
                           "ref": "bd1"}]},
            {"id": 4193, "title": "Wizard of Wor", "year": 1983,
             "variants": [{"n": 1, "platform": "c64", "source": "archive",
                           "ref": "wow", "sha1": "b" * 40}]},
        ]
        footer = canon.write_file(reg, entries)
        assert footer["games"] == 2 and footer["variants"] == 2

        back = canon.load_file(reg)
        assert [e["id"] for e in back] == [7, 4193]
        # The check character is derived on write, never carried in by hand.
        assert back[1]["chk"] == canon.check_char(4193) == "U"
        assert canon.read_footer(reg)["sha1"] == footer["sha1"]


def test_import_gives_fresh_catalog_same_ids():
    """A checkout with no network still gets the whole ID space, from the
    frozen registry that ships with it."""
    with tempfile.TemporaryDirectory() as d:
        reg = os.path.join(d, "canon.jsonl")
        canon.write_file(reg, [
            {"id": 7, "title": "Boulder Dash",
             "variants": [{"n": 1, "platform": "c64", "source": "csdb",
                           "ref": "bd1"}]},
            {"id": 12, "title": "Elite",
             "variants": [{"n": 1, "platform": "plus4", "source": "csdb",
                           "ref": "el1"}]},
        ])
        fresh = Catalog(os.path.join(d, "b.db"))
        assert canon.ensure_imported(fresh, reg) is True
        assert canon.ensure_imported(fresh, reg) is False   # idempotent
        for e in canon.load_file(reg):
            g = fresh.game_by_canon(e["id"])
            assert g and g["title"] == e["title"]
            v = fresh.variant_by_canon(e["id"], 1)
            assert v and v["canon_sub"] == 1
        fresh.close()


# ── release tags: which crack is this? ─────────────────────────────────────

def test_parse_release_tags_reads_both_name_forms():
    from library.db import parse_release_tags as tags
    # archive.org squashes the brackets out of its identifiers
    assert tags("Wizard_of_Wor_1983_Commodore_cr_Bandit") == \
        ("Bandit", "cr Bandit")
    assert tags("Wizard of Wor (1983)(Commodore)[cr Bandit]") == \
        ("Bandit", "cr Bandit")
    # the cracker gets the headline over the trainer
    assert tags("Wizard_of_Wor_1983_Commodore_cr_REM_t_3_REM_Docs") == \
        ("REM", "cr REM t 3 REM Docs")
    assert tags("Last Ninja II (1988)[cr Nostalgia][t +2 Fungus]")[0] == \
        "Nostalgia"
    # a hack with no crack credit still names its author
    assert tags("Wizard_of_Wor_1983_Commodore_h_OleanderAngels")[0] == \
        "OleanderAngels"
    # a trainer count is not a group name
    assert tags("Bomb Jack (1986)[t 1 Angels]") == ("Angels", "t 1 Angels")
    # an untagged original dump has nothing to say
    assert tags("d64_Wizard_of_Wor_1983_Commodore") == (None, None)
    assert tags("Wizard_Of_Wor_Cartridge") == (None, None)
    assert tags("") == (None, None)


def test_release_tags_are_backfilled_into_an_existing_library():
    """An existing library has thousands of rows catalogued before the tags
    were parsed; leaving them blank is what made a dozen cracks of one game
    a dozen identical rows."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "a.db")
        cat = Catalog(path)
        gid = cat.upsert_game(GameRow("Wizard of Wor"))
        vid = cat.upsert_variant(gid, VariantRow(
            platform="c64", source="archive",
            source_ref="Wizard_of_Wor_1983_Commodore_cr_Bandit"))
        # simulate the pre-fix row: tags never parsed
        cat.db.execute("UPDATE variant SET group_name=NULL, release_name=NULL "
                       "WHERE id=?", (vid,))
        cat.meta_set("release_tags_backfilled", "0")
        cat.commit()
        cat.close()

        cat = Catalog(path)                       # reopening migrates
        v = cat.db.execute("SELECT * FROM variant WHERE id=?",
                           (vid,)).fetchone()
        assert v["group_name"] == "Bandit" and v["release_name"] == "cr Bandit"
        cat.close()


# ── board naming ────────────────────────────────────────────────────────────

def test_board_name():
    assert board_name("Boulder Dash.D64", "c64") == "c64-boulder_dash.d64"
    assert board_name("c64-game.d64", "c64") == "c64-game.d64"   # no double prefix
    assert board_name("x" * 60 + ".d64", "c16").endswith(".d64")
    assert len(board_name("x" * 60 + ".d64", "c16")) <= 39
    assert board_name("weird name!!.prg", None) == "weird_name_.prg"

    # The variant id keeps two releases of one game apart: without it the
    # second "Send to board" replaced the first (same download filename, and
    # the flash FS replaces same-named files).
    assert board_name("Wizard of Wor.d64", "c64", 23307) == \
        "c64-wizard_of_wor-23307.d64"
    assert board_name("Wizard of Wor.d64", "c64", 23308) != \
        board_name("Wizard of Wor.d64", "c64", 23307)
    # a long title is truncated around the id, never through it
    long = board_name("x" * 60 + ".d64", "c64", 23307)
    assert long.endswith("-23307.d64") and len(long) <= 35
    # and no doubled separator when the truncation lands on one
    assert "_-" not in board_name("weird name!!.prg", None, 7)


def test_board_name_carries_the_canon_id_and_the_group():
    """The name on the board has to be matchable against the ID the desktop
    Library shows, and readable enough to say WHICH crack it is.  The local
    row id was neither: it appears in no list, and the source filename it
    was appended to truncated the group away — twelve cracks of Wizard of
    Wor all landed as 'c64-wizard_of_wor_1983_co-213NN.d64' (board,
    2026-08-05)."""
    name = board_name("Wizard_of_Wor_1983_Commodore_cr_Bandit.d64", "c64",
                      canon.flash_ident(4193, 7),
                      title="Wizard Of Wor (Cartridge)", group="Bandit")
    assert name == "c64-wizard_of_wor-bandit-4193.7.d64"
    # the digits of the ID the Library prints are findable in the name
    assert "4193.7" in name and canon.format_id(4193, 7) == "#4193-U/7"

    # a second crack of the same game differs in BOTH halves
    other = board_name("Wizard_of_Wor_1983_Commodore_cr_ATG.d64", "c64",
                       canon.flash_ident(4193, 8),
                       title="Wizard Of Wor (Cartridge)", group="ATG")
    assert other != name and other.endswith("-4193.8.d64") and "atg" in other

    # the bracketed apparatus is not the title
    assert board_name("x.d64", "c64", "4193.7",
                      title="Wizard of Wor (1983)(Commodore)[cr Bandit]",
                      group="Bandit") == "c64-wizard_of_wor-bandit-4193.7.d64"


def test_board_name_stays_inside_the_flash_name_limit():
    """Long title + long group + long ID still has to fit in 35 characters,
    with the ID intact — a truncated ID collides exactly like no ID at all."""
    for title, group, ident in (
            ("The Great Giana Sisters", "Danish Crackers", "12345.12"),
            ("x" * 60, "y" * 30, "9.9"),
            ("Prince of Persia", None, "1.1")):
        n = board_name("x.d64", "c64", ident, title=title, group=group)
        assert len(n) <= 35, n
        assert n.endswith(f"-{ident}.d64"), n
        assert "-" + "-" not in n and "_-" not in n
    # the group is what gets shortened first (the ID already guarantees
    # uniqueness) so the title stays readable
    n = board_name("x.d64", "c64", "12345.12", title="The Great Giana Sisters",
                   group="Danish Crackers")
    assert n == "c64-the_great_g-danish-12345.12.d64"


def test_flash_ident_matches_the_printed_id():
    assert canon.flash_ident(4193, 7) == "4193.7"
    assert canon.flash_ident(4193) == "4193"
    assert canon.flash_ident(None) is None          # caller falls back
    assert canon.flash_ident(None, 3) is None


# ── upload verification ────────────────────────────────────────────────────
# FS_STAT's "crc32" is a byte SUM over the STORED (compressed) bytes, so
# comparing it to zlib.crc32 of the file reported a CRC error on every upload
# that in fact arrived perfectly (board, 2026-08-05).

def test_verify_upload_accepts_a_good_upload():
    from library.board import verify_upload, sum32, xmodem_padded
    data = bytes(range(256)) * 20
    st = {"size": len(data), "sum32": sum32(data), "crc32": 0xDEADBEEF}
    assert verify_upload(st, data, "x.d64") is True    # exact
    padded = xmodem_padded(data + b"\x01")
    st = {"size": len(padded), "sum32": sum32(padded), "crc32": 0}
    assert verify_upload(st, data + b"\x01", "x.d64") is False   # padded


def test_verify_upload_ignores_the_stored_crc_field():
    """The old code compared zlib.crc32(data) against that field and failed
    every compressible upload.  A correct upload must verify no matter what
    the stored-bytes sum happens to be."""
    from library.board import verify_upload, sum32
    data = b"\x00" * 5000                       # compresses hard
    st = {"size": len(data), "sum32": sum32(data), "crc32": 0x12345678}
    assert verify_upload(st, data, "x.d64") is True


def test_verify_upload_still_catches_real_corruption():
    from library.board import verify_upload, sum32
    data = b"abcd" * 100
    st = {"size": len(data), "sum32": sum32(data) ^ 0xFF, "crc32": 0}
    with pytest.raises(IOError) as e:
        verify_upload(st, data, "x.d64")
    assert "corrupted" in str(e.value)


def test_verify_upload_on_old_firmware_checks_the_size_and_says_so():
    """No sum32 in the reply: verify what can be verified and do not claim
    more than that."""
    from library.board import verify_upload
    data = b"abcd" * 100
    msgs = []
    assert verify_upload({"size": len(data), "crc32": 0}, data, "x.d64",
                         msgs.append) is True
    assert "size only" in " ".join(msgs)
    with pytest.raises(IOError):
        verify_upload({"size": 7, "crc32": 0}, data, "x.d64")
