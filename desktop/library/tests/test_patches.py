"""Tests for library/patches.py — the committed corrections to what the
online sources say about a release.

Run:  cd desktop && python3 -m pytest library/tests -q

The thing being defended: a source can be wrong (archive.org files EA's
platform game *Wizard* under `Wizard_of_Wor_..._cr_ATG`), and finding that
out costs a download, an upload and a confused minute in front of the board.
That knowledge has to survive a re-search, a bulk re-index of the whole
collection, and a fresh checkout — otherwise it is discovered again every
time.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from library import canon, patches  # noqa: E402
from library.db import Catalog, GameRow, VariantRow, FileRow  # noqa: E402


def write_patches(path, *entries):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"patches": patches.FILE_MAGIC, "v": 1}) + "\n")
        for e in entries:
            fh.write(json.dumps(e) + "\n")
    return path


@pytest.fixture
def cat(tmp_path):
    c = Catalog(str(tmp_path / "lib.db"))
    yield c
    c.close()


def seed(cat, ref="mislabeled_ref", title="Wizard Of Wor"):
    gid = cat.upsert_game(GameRow(title))
    vid = cat.upsert_variant(gid, VariantRow(
        platform="c64", source="archive", source_ref=ref))
    cat.commit()
    return gid, vid


# ── file format ────────────────────────────────────────────────────────────

def test_a_missing_patch_file_is_not_an_error(tmp_path):
    assert patches.load(str(tmp_path / "nope.jsonl")) == []


def test_the_shipped_patch_file_is_well_formed():
    """The REAL one — named explicitly, because conftest redirects the
    default path — so a typo in a hand-edited correction is caught here and
    not by a silent no-op six months later."""
    shipped = os.path.join(os.path.dirname(os.path.abspath(patches.__file__)),
                           "data", "patches.jsonl")
    for p in patches.load(shipped):             # raises on anything malformed
        assert (p.get("source") and p.get("ref")) or p.get("sha1")


def test_a_typo_in_a_field_name_is_refused(tmp_path):
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "x", "titel": "Wizard"})
    with pytest.raises(patches.PatchError, match="unknown field"):
        patches.load(f)


def test_a_patch_that_changes_nothing_is_refused(tmp_path):
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "x", "by": "me"})
    with pytest.raises(patches.PatchError, match="changes nothing"):
        patches.load(f)


def test_a_patch_that_matches_nothing_is_refused(tmp_path):
    f = write_patches(str(tmp_path / "p.jsonl"), {"title": "Wizard"})
    with pytest.raises(patches.PatchError, match="match on"):
        patches.load(f)


# ── applying ───────────────────────────────────────────────────────────────

def test_a_mislabeled_release_is_refiled_under_the_right_game(cat, tmp_path):
    gid, vid = seed(cat)
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "mislabeled_ref",
                       "title": "Wizard", "note": "not Wizard of Wor at all"})
    r = patches.apply(cat, f)
    assert r["moved"] == 1

    v = cat.get_variant(vid)
    assert v["game_id"] != gid
    assert v["game_title"] == "Wizard"
    assert v["notes"] == "not Wizard of Wor at all"


def test_refiling_releases_the_canon_sub_of_the_wrong_game(cat, tmp_path):
    """The /n belonged to the game this release is NOT.  Keeping it would
    leave the release answering to an ID for a different work."""
    _gid, vid = seed(cat)
    cat.db.execute("UPDATE variant SET canon_sub=7 WHERE id=?", (vid,))
    cat.commit()
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "mislabeled_ref",
                       "title": "Wizard"})
    patches.apply(cat, f)
    assert cat.get_variant(vid)["canon_sub"] is None


def test_game_canon_pins_the_target_when_titles_collide(cat, tmp_path):
    """Several games can normalise to the same title.  Naming the canon ID
    sends the release to exactly one of them."""
    _gid, vid = seed(cat)
    right = cat.upsert_game(GameRow("Wizard"))
    cat.db.execute("UPDATE game SET canon_id=4188 WHERE id=?", (right,))
    cat.commit()
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "mislabeled_ref",
                       "title": "Wizard", "game_canon": 4188})
    patches.apply(cat, f)
    assert cat.get_variant(vid)["game_id"] == right


def test_a_patch_can_match_on_content_hash(cat, tmp_path):
    """A source that renames its item does not escape a correction that was
    made against the bytes."""
    _gid, vid = seed(cat)
    cat.add_file(vid, FileRow(filename="w.d64", size=174848, sha1="c" * 40,
                              crc32="deadbeef"))
    cat.commit()
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"sha1": "c" * 40, "note": "two games on this disk"})
    assert patches.apply(cat, f)["changed"] == 1
    assert cat.get_variant(vid)["notes"] == "two games on this disk"


def test_drop_hides_a_release_from_the_listings(cat, tmp_path):
    gid, vid = seed(cat)
    cat.upsert_variant(gid, VariantRow(platform="c64", source="archive",
                                       source_ref="good_one"))
    cat.commit()
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "mislabeled_ref",
                       "drop": True, "note": "bad dump"})
    patches.apply(cat, f)
    listed = [v["id"] for v in cat.variants_for_game(gid)]
    assert vid not in listed and len(listed) == 1
    assert vid in [v["id"] for v in cat.variants_for_game(gid,
                                                          include_hidden=True)]


def test_applying_twice_changes_nothing_more(cat, tmp_path):
    _gid, vid = seed(cat)
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "mislabeled_ref",
                       "title": "Wizard"})
    patches.apply(cat, f)
    before = dict(cat.get_variant(vid))
    assert patches.apply(cat, f)["moved"] == 0
    assert dict(cat.get_variant(vid)) == before


def test_a_patch_for_a_release_we_do_not_have_is_harmless(cat, tmp_path):
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "never_heard_of_it",
                       "title": "Wizard"})
    assert patches.apply(cat, f)["changed"] == 0


# ── the whole point: it survives a re-fetch ────────────────────────────────

def test_a_refetch_of_the_whole_catalog_cannot_undo_a_correction(tmp_path,
                                                                 monkeypatch):
    """The source hands back the same wrong row on the next search, and the
    catalog is reopened.  The correction must still be in force — otherwise
    every re-index resurrects the bug."""
    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "mislabeled_ref",
                       "title": "Wizard", "note": "mislabeled at the source"})
    monkeypatch.setattr(patches, "default_path", lambda: f)

    db = str(tmp_path / "lib.db")
    cat = Catalog(db)
    gid, vid = seed(cat)
    cat.close()

    cat = Catalog(db)                         # reopened: the patch applies
    assert cat.get_variant(vid)["game_title"] == "Wizard"

    # now the source says it again, exactly as before
    cat.upsert_game(GameRow("Wizard Of Wor"))
    cat.upsert_variant(gid, VariantRow(platform="c64", source="archive",
                                       source_ref="mislabeled_ref"))
    cat.commit()
    cat.close()

    cat = Catalog(db)
    assert cat.get_variant(vid)["game_title"] == "Wizard", \
        "a re-fetch undid a committed correction"
    assert cat.patch_error is None
    cat.close()


def test_a_broken_patch_file_does_not_make_the_library_unopenable(tmp_path,
                                                                  monkeypatch):
    bad = str(tmp_path / "bad.jsonl")
    with open(bad, "w") as fh:
        fh.write('{"patches":"fpgago-catalog-patches","v":1}\n{ nonsense\n')
    monkeypatch.setattr(patches, "default_path", lambda: bad)
    cat = Catalog(str(tmp_path / "lib.db"))
    assert cat.patch_error and "bad JSON" in cat.patch_error
    cat.close()


# ── the canon registry keeps up ────────────────────────────────────────────

def test_refiling_a_release_releases_the_id_it_wrongly_held(tmp_path):
    """The sub-ID belonged to the game this release is NOT, so re-filing has
    to give it up rather than carry it to the new game.

    (The other half of a re-file — leaving a pointer at the old ID so a
    report that quotes it still resolves — is the server's job now; the
    client reads those pointers in test_webdb.py.)"""
    cat = Catalog(str(tmp_path / "lib.db"))
    gid, vid = seed(cat)
    cat.db.execute("UPDATE game SET canon_id=4188 WHERE id=?", (gid,))
    cat.db.execute("UPDATE variant SET canon_sub=3 WHERE id=?", (vid,))
    cat.commit()

    f = write_patches(str(tmp_path / "p.jsonl"),
                      {"source": "archive", "ref": "mislabeled_ref",
                       "title": "Wizard"})
    patches.apply(cat, f)

    row = cat.db.execute("SELECT game_id, canon_sub FROM variant WHERE id=?",
                         (vid,)).fetchone()
    assert row["game_id"] != gid, "the release should have moved games"
    assert row["canon_sub"] is None
    cat.close()
