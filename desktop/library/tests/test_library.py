"""Tests for the fpgago game library core (classifier + DB). Network-free.

Run:  cd desktop && python3 -m pytest library/tests -q
      (or: python3 library/tests/test_library.py  -- runs a plain assert suite)
"""
import os
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

from library import classify, db  # noqa: E402


def _prg(load, n):
    return bytes([load & 0xff, load >> 8]) + b"\x00" * n


def test_load_address_platform():
    assert classify.sniff_prg(_prg(0x0801, 300)).platform == "c64"
    assert classify.sniff_prg(_prg(0x1001, 300)).platform == "c16"      # small
    assert classify.sniff_prg(_prg(0x1001, 40000)).platform == "plus4"  # >16K
    # C64 is always high confidence; 264 split carries a hint confidence.
    assert classify.sniff_prg(_prg(0x0801, 300)).confidence == "high"
    assert classify.sniff_prg(_prg(0x1001, 40000)).confidence == "high"
    # The ≤16K "it's a C16" call is only a weak hint (RAM mirroring/banking).
    assert classify.sniff_prg(_prg(0x1001, 300)).confidence == "low"


def test_platform_from_name():
    pf = classify.platform_from_name
    assert pf("/roms/Commodore Plus4 TOSEC/Elite (1986).d64")[0] == "plus4"
    # Combined TOSEC set folder → ambiguous 264, NOT plus4.
    assert pf("/x/Commodore C16, C116 & Plus-4/game.prg")[0] == "264"
    # A "c64 crack" note inside a Plus4 folder is still Plus4.
    assert pf("/games/Plus4/foo (c64 crack).prg")[0] == "plus4"
    assert pf("games/c64/boulder.prg")[0] == "c64"
    assert pf("games/c16/tetris.prg")[0] == "c16"
    assert pf("no/hint/here.prg")[0] is None


def test_non_basic_load_is_unknown():
    assert classify.sniff_prg(_prg(0xC000, 100)).platform == "unknown"


def test_zip_pick_and_classify():
    buf = tempfile.mktemp(suffix=".zip")
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("readme.txt", "hi")
        z.writestr("game.prg", _prg(0x0801, 500))
    v = classify.classify_path(buf)
    assert v.platform == "c64" and v.inner_name == "game.prg"
    os.remove(buf)


def test_hashes_stable_and_distinct():
    a1, c1 = classify.hashes(_prg(0x0801, 10))
    a2, c2 = classify.hashes(_prg(0x0801, 10))
    b1, d1 = classify.hashes(_prg(0x0801, 11))
    assert (a1, c1) == (a2, c2)          # deterministic
    assert a1 != b1 and c1 != d1         # different content -> different id
    assert len(c1) == 8                  # crc32 as 8 hex digits


def test_normalize_title_matches_variants():
    n = db.normalize_title
    assert n("The Last Ninja II (1988) [Nostalgia]") == "last ninja 2"
    assert n("Last Ninja 2") == n("The Last Ninja II")
    assert n("A Boulder Dash!") == "boulder dash"


def test_db_dedup_by_sha1():
    f = tempfile.mktemp(suffix=".db")
    cat = db.Catalog(f)
    gid = cat.upsert_game(db.GameRow("Zzz"))
    vid = cat.upsert_variant(gid, db.VariantRow(platform="c64", source="s",
                                                source_ref="1"))
    id1 = cat.add_file(vid, db.FileRow("a.prg", sha1="deadbeef", crc32="00000000"))
    id2 = cat.add_file(vid, db.FileRow("b.prg", sha1="deadbeef", crc32="00000000"))
    assert id1 == id2                    # same hash -> same row
    cat.close()
    os.remove(f)


def test_db_variants_and_validation():
    f = tempfile.mktemp(suffix=".db")
    cat = db.Catalog(f)
    gid = cat.upsert_game(db.GameRow("Boulder Dash"))
    v1 = cat.upsert_variant(gid, db.VariantRow(platform="c64", source="csdb",
                            source_ref="r1", group_name="Nostalgia"))
    v2 = cat.upsert_variant(gid, db.VariantRow(platform="c64", source="csdb",
                            source_ref="r2", group_name="Remember"))
    assert v1 != v2                      # two cracks -> two variants
    cat.set_validated(v2, 1, "runs via real 1541")
    rows = cat.variants_for_game(gid)
    assert len(rows) == 2
    cat.close()
    os.remove(f)


if __name__ == "__main__":
    fns = [g for n, g in sorted(globals().items()) if n.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")
