"""Tests for the shared compatibility database (compat.py). Network-free."""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from library import canon, compat  # noqa: E402


def _report(path, cid=42, sub=None, machine="c64", status="works", **kw):
    return compat.append_report(canon_id=cid, sub=sub, machine=machine,
                                status=status, by="tester",
                                date=kw.pop("date", "2026-07-22"),
                                path=path, **kw)


def test_append_and_load_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p, status="works", mode="fastload", notes="fine")
        _report(p, cid=42, sub=2, machine="plus4", status="broken")
        reports, errors = compat.load(p)
        assert not errors and len(reports) == 2
        assert reports[0]["id"] == canon.format_id(42)
        assert reports[1]["_sub"] == 2


def test_id_requires_check_char():
    with pytest.raises(compat.CompatError):
        compat.validate({"id": "42", "machine": "c64", "status": "works",
                         "date": "2026-07-22"})
    wrong = "A" if canon.check_char(42) != "A" else "B"
    with pytest.raises(compat.CompatError):
        compat.validate({"id": f"42-{wrong}", "machine": "c64",
                         "status": "works", "date": "2026-07-22"})


def test_bad_lines_reported_not_fatal():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p)
        with open(p, "a") as fh:
            fh.write("{ not json\n")
            fh.write(json.dumps({"id": canon.format_id(7),
                                 "machine": "nintendo", "status": "works",
                                 "date": "2026-07-22"}) + "\n")
        reports, errors = compat.load(p)
        assert len(reports) == 1 and len(errors) == 2
        with pytest.raises(compat.CompatError):
            compat.load(p, strict=True)


def test_newest_report_wins():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p, status="broken", date="2026-07-01")
        _report(p, status="works", date="2026-07-20")
        _report(p, machine="plus4", status="issues", date="2026-07-10")
        reports, _ = compat.load(p)
        cur = compat.current(reports, 42)
        assert cur["c64"]["status"] == "works"
        assert cur["plus4"]["status"] == "issues"


def test_variant_scoping():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p, sub=1, status="broken", date="2026-07-02")
        _report(p, sub=2, status="works", date="2026-07-03")
        reports, _ = compat.load(p)
        # asking about variant 1 must not see variant 2's verdict
        assert compat.current(reports, 42, 1)["c64"]["status"] == "broken"
        assert compat.current(reports, 42, 2)["c64"]["status"] == "works"


# ── the real-1541 flag ─────────────────────────────────────────────────────
# "No fastload path works — this needs the cycle-accurate drive" is a fact
# about the GAME, kept apart from `mode` (how one test happened to be run).


def test_the_flag_round_trips_and_shows_in_the_line():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        rep = _report(p, status="works", mode="1541", real1541=True,
                      notes="talks to the drive directly")
        assert rep["real1541"] is True
        reports, errors = compat.load(p)
        assert not errors and reports[0]["real1541"] is True
        assert "REAL-1541" in compat.status_line(reports[0])


def test_the_flag_must_be_a_boolean():
    """"yes" reads as true in one language and as a string in another, and
    this field decides whether a game is listed as real-drive-only."""
    with pytest.raises(compat.CompatError, match="real1541"):
        compat.validate({"id": canon.format_id(42), "machine": "c64",
                         "status": "works", "date": "2026-07-22",
                         "real1541": "yes"})


def test_a_later_report_that_says_nothing_does_not_clear_the_flag():
    """A retest recording only "still works" must not silently drop the
    drive requirement somebody established."""
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p, real1541=True, date="2026-07-01")
        _report(p, status="works", date="2026-07-20")
        reports, _ = compat.load(p)
        assert compat.current_real1541(reports, 42, "c64") is True
        assert compat.real1541_ids(reports) == {42}


def test_an_explicit_false_clears_it():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p, real1541=True, date="2026-07-01")
        _report(p, real1541=False, date="2026-07-20")
        reports, _ = compat.load(p)
        assert compat.current_real1541(reports, 42, "c64") is False
        assert compat.real1541_ids(reports) == set()


def test_the_flag_is_per_machine_but_the_game_is_listed_once():
    """Flagged on the c64, fine on the plus4: the game still belongs in the
    "needs the real 1541" list — the limitation is real somewhere."""
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p, machine="c64", real1541=True)
        _report(p, machine="plus4", real1541=False)
        reports, _ = compat.load(p)
        assert compat.current_real1541(reports, 42, "plus4") is False
        assert compat.real1541_ids(reports) == {42}


def test_nobody_has_said_is_not_false():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        _report(p)
        reports, _ = compat.load(p)
        assert compat.current_real1541(reports, 42, "c64") is None
        assert "real1541" not in reports[0]


# ── who tested it ──────────────────────────────────────────────────────────


def test_the_email_is_stored_with_the_report():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        rep = _report(p, email="tester@example.com")
        assert rep["email"] == "tester@example.com"
        reports, errors = compat.load(p)
        assert not errors and reports[0]["email"] == "tester@example.com"
        assert "<tester@example.com>" in compat.status_line(reports[0])


def test_a_mistyped_address_is_refused():
    """A report nobody can follow up on is the thing the field exists to
    prevent, so it fails validation rather than being stored as typed."""
    for bad in ("nope", "a@b", "two@@example.com", "has space@example.com"):
        with pytest.raises(compat.CompatError, match="email"):
            compat.validate({"id": canon.format_id(42), "machine": "c64",
                             "status": "works", "date": "2026-07-22",
                             "email": bad})
    assert compat.valid_email("a.b+tag@sub.example.co.uk")


def test_an_empty_email_writes_no_field():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        assert "email" not in _report(p, email="")


def test_the_tester_is_remembered_for_the_next_report(tmp_path, monkeypatch):
    monkeypatch.setenv("FPGAGO_GAMES", str(tmp_path / "games"))
    monkeypatch.delenv("FPGAGO_EMAIL", raising=False)
    compat.set_identity(by="Tester Two", email="two@example.com")
    assert compat.default_reporter() == "Tester Two"
    assert compat.default_email() == "two@example.com"
    p = str(tmp_path / "compat.jsonl")
    rep = compat.append_report(canon_id=42, sub=None, machine="c64",
                               status="works", date="2026-07-22", path=p)
    assert rep["by"] == "Tester Two" and rep["email"] == "two@example.com"
    # and it can be taken back
    compat.set_identity(email="")
    assert compat.default_email() == compat._git_config("user.email")


def test_the_environment_wins_over_the_saved_identity(tmp_path, monkeypatch):
    """A shared test rig sets $FPGAGO_EMAIL once and every report from it is
    attributable, whatever is saved on the machine."""
    monkeypatch.setenv("FPGAGO_GAMES", str(tmp_path / "games"))
    compat.set_identity(email="saved@example.com")
    monkeypatch.setenv("FPGAGO_EMAIL", "rig@example.com")
    assert compat.default_email() == "rig@example.com"


def test_comments_and_blank_lines_ok():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "compat.jsonl")
        with open(p, "w") as fh:
            fh.write("# hand-written header comment\n\n")
        _report(p)
        reports, errors = compat.load(p)
        assert not errors and len(reports) == 1
