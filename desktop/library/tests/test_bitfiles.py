"""Tests for finding the machine bitstreams a checkout has built
(app/bitfiles.py).

Run:  cd desktop && python3 -m pytest library/tests -q

Picking a machine should not mean remembering where `make` put it.  Every
build also writes a timestamped twin, so a raw listing is half duplicates —
this is what folds them.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

pytest.importorskip("serial", reason="desktop venv only")
pytest.importorskip("PySide6", reason="desktop venv only")

from app import bitfiles  # noqa: E402


@pytest.fixture
def tree(tmp_path):
    """A checkout mid-work: /tmp build outputs, the shipped bitstreams, and
    a retro-arch out.bit."""
    tmp = tmp_path / "tmp"
    repo = tmp_path / "repo"
    for d in (tmp, repo / "bitstreams", repo / "retro-arch" / "c64"):
        os.makedirs(d, exist_ok=True)

    def put(path, data, age=0):
        path.write_bytes(data)
        t = time.time() - age
        os.utime(path, (t, t))
        return path

    c64 = b"C64BITSTREAM" * 900
    put(tmp / "c64_v2_iec.bit", c64, age=60)
    put(tmp / "c64_v2_iec_0805-1255.bit", c64, age=120)     # the twin
    put(tmp / "plus4_v2_iec.bit", b"PLUS4" * 900, age=3600)
    put(repo / "bitstreams" / "c16-romless.bit", b"C16" * 900, age=86400)
    put(repo / "retro-arch" / "c64" / "out.bit", b"OTHERC64" * 900, age=30)
    put(repo / "bitstreams" / "plus4-romless.bit", b"P4OLD" * 900, age=99999)
    # things that are not machines
    os.makedirs(repo / "oss-cad-suite" / "share", exist_ok=True)
    put(repo / "oss-cad-suite" / "share" / "angie_bitstream.bit", b"NOPE" * 10)
    put(tmp / "huge.bit", b"x" * (bitfiles.MAX_SIZE + 1))
    put(tmp / "empty.bit", b"")
    return str(repo), str(tmp)


def find(tree, name):
    repo, tmp = tree
    return {b.name: b for b in bitfiles.discover(repo, tmp)}.get(name)


def test_it_finds_builds_everywhere_they_land(tree):
    repo, tmp = tree
    names = {b.name for b in bitfiles.discover(repo, tmp)}
    assert names == {"c64_v2_iec.bit", "plus4_v2_iec.bit",
                     "c16-romless.bit", "out.bit", "plus4-romless.bit"}


def test_the_timestamped_twin_is_folded_in(tree):
    b = find(tree, "c64_v2_iec.bit")
    assert [os.path.basename(d) for d in b.dupes] == ["c64_v2_iec_0805-1255.bit"]


def test_toolchain_files_are_not_machines(tree):
    assert find(tree, "angie_bitstream.bit") is None


def test_absurd_sizes_are_skipped(tree):
    assert find(tree, "huge.bit") is None and find(tree, "empty.bit") is None


def test_newest_first(tree):
    repo, tmp = tree
    got = [b.name for b in bitfiles.discover(repo, tmp)]
    assert got[0] == "out.bit"                    # 30 s old
    assert got[-1] == "plus4-romless.bit"         # a day+


def test_the_machine_comes_from_the_directory_when_the_name_is_generic(tree):
    # retro-arch/c64/out.bit says "c64" nowhere in its filename
    assert find(tree, "out.bit").arch == "c64"


def test_the_machine_comes_from_the_name_otherwise(tree):
    assert find(tree, "plus4_v2_iec.bit").arch == "plus4"
    assert find(tree, "c16-romless.bit").arch == "c16"


def test_the_upload_name_follows_the_boards_convention(tree):
    # the BIOS boots <machine>.bit, and replacing it is the normal intent
    assert find(tree, "plus4_v2_iec.bit").suggested_name == "plus4.bit"
    assert find(tree, "out.bit").suggested_name == "c64.bit"


def test_a_descriptive_name_wins_over_out_bit(tmp_path):
    """Two copies of one build, one called out.bit: show the one that says
    something."""
    repo = tmp_path / "repo"
    os.makedirs(repo / "retro-arch" / "c64", exist_ok=True)
    os.makedirs(tmp_path / "tmp", exist_ok=True)
    same = b"SAME" * 900
    (repo / "retro-arch" / "c64" / "out.bit").write_bytes(same)
    (tmp_path / "tmp" / "c64_v2_iec.bit").write_bytes(same)
    bits = bitfiles.discover(str(repo), str(tmp_path / "tmp"))
    assert len(bits) == 1 and bits[0].name == "c64_v2_iec.bit"


def test_age_reads_like_a_human_wrote_it(tree):
    assert find(tree, "out.bit").age == "just now"        # 30 s old
    assert "hour" in find(tree, "plus4_v2_iec.bit").age
    assert "day" in find(tree, "c16-romless.bit").age


def test_nothing_built_is_not_an_error(tmp_path):
    assert bitfiles.discover(str(tmp_path), str(tmp_path)) == []
