"""Tests for getting a user's results back to the project without git
(library/share.py + the local half of compat.py).

Run:  cd desktop && python3 -m pytest library/tests -q

Nothing here talks to the network or to GitHub: `gh` is faked, and the
browser route is only checked as far as the URL it would open.
"""
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from app import library_backend as lib  # noqa: E402
from library import compat, share  # noqa: E402

REP = dict(canon_id=2862, sub=None, machine="c64", status="works")


# ── local reports: separate from the shared database ───────────────────────

def test_a_local_report_does_not_touch_the_shared_file():
    compat.append_report(**REP, local=True)
    assert os.path.exists(compat.local_path())
    assert not os.path.exists(compat.default_path())


def test_the_app_sees_its_own_report_immediately():
    # before it is shared with anyone: load() merges shared + local
    compat.append_report(**REP, local=True)
    reports, errors = compat.load()
    assert not errors
    assert compat.current(reports, 2862)["c64"]["status"] == "works"


def test_a_local_report_wins_over_an_older_shared_one():
    compat.append_report(**dict(REP, status="broken"), date="2026-01-01")
    compat.append_report(**REP, date="2026-06-01", local=True)
    reports, _ = compat.load()
    assert compat.current(reports, 2862)["c64"]["status"] == "works"


def test_load_of_an_explicit_path_stays_single_file():
    compat.append_report(**REP, local=True)
    reports, _ = compat.load(compat.default_path())
    assert reports == []


# ── what is waiting to be shared ───────────────────────────────────────────

def test_unshared_lists_only_what_has_not_been_sent():
    compat.append_report(**REP, local=True)
    assert len(compat.unshared()) == 1
    assert compat.mark_shared() == 1
    assert compat.unshared() == []


def test_marking_shared_keeps_the_reports_readable():
    compat.append_report(**REP, local=True)
    compat.mark_shared("2026-08-05")
    reports, errors = compat.load()
    assert not errors and len(reports) == 1
    assert reports[0]["shared"] == "2026-08-05"


def test_marking_twice_does_not_re_stamp():
    compat.append_report(**REP, local=True)
    compat.mark_shared("2026-08-05")
    compat.append_report(**dict(REP, machine="c16"), local=True)
    assert compat.mark_shared("2026-08-06") == 1        # only the new one


def test_report_lines_are_what_the_database_would_hold():
    compat.append_report(**REP, profile="drive=dos", local=True)
    compat.mark_shared()
    line = compat.report_lines(compat.load()[0])
    rep = json.loads(line)
    assert "shared" not in rep and "_canon" not in rep
    assert rep["profile"] == "drive=dos"
    # and it is a line the shared database accepts verbatim
    assert compat.validate(json.loads(line))


# ── the routes ─────────────────────────────────────────────────────────────

def test_slug_from_every_url_shape_git_uses():
    assert share.slug_from_url("git@github.com:bereg-ev/fpgago.git") \
        == "bereg-ev/fpgago"
    assert share.slug_from_url("https://github.com/bereg-ev/fpgago") \
        == "bereg-ev/fpgago"
    assert share.slug_from_url("https://github.com/bereg-ev/fpgago.git") \
        == "bereg-ev/fpgago"
    assert share.slug_from_url("git@gitlab.com:someone/else.git") is None
    assert share.slug_from_url("") is None


def test_issue_url_carries_the_reports():
    compat.append_report(**REP, profile="drive=dos", local=True)
    url = share.issue_url(compat.unshared(), slug="o/r")
    assert url.startswith("https://github.com/o/r/issues/new?")
    q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    assert "#2862-A" in q["title"][0] and "c64" in q["title"][0]
    assert "drive=dos" in q["body"][0]
    assert q["labels"] == [share.ISSUE_LABEL]


def test_the_issue_body_is_paste_ready_for_a_maintainer():
    compat.append_report(**REP, local=True)
    body = share.issue_body(compat.unshared())
    block = body.split("```jsonl\n", 1)[1].split("\n```", 1)[0]
    assert compat.validate(json.loads(block))       # straight into the DB


def test_routes_always_offer_a_way_out_without_gh(monkeypatch):
    monkeypatch.setattr(share, "have_gh", lambda: False)
    keys = [r["key"] for r in share.routes([])]
    assert keys == ["browser", "copy", "file"]


def test_routes_lead_with_gh_when_it_is_usable(monkeypatch):
    monkeypatch.setattr(share, "have_gh", lambda: True)
    assert share.routes([])[0]["key"] == "gh"


def test_export_writes_loadable_lines(tmp_path):
    compat.append_report(**REP, local=True)
    path = share.export(compat.unshared(), str(tmp_path / "out.jsonl"))
    reports, errors = compat.load(path)
    assert not errors and len(reports) == 1


# ── the app's side of it ───────────────────────────────────────────────────

def test_share_preview_describes_what_would_be_sent():
    compat.append_report(**REP, local=True)
    info = lib.share_preview()
    assert info["n"] == 1 and info["routes"]
    assert "#2862-A" in info["text"] and "/" in info["repo"]


def test_sharing_by_file_stamps_them(tmp_path):
    compat.append_report(**REP, local=True)
    res = lib.share_via("file", str(tmp_path / "r.jsonl"))
    assert "saved" in res["done"]
    assert compat.unshared() == []


def test_a_cancelled_file_dialog_shares_nothing():
    compat.append_report(**REP, local=True)
    assert lib.share_via("file", None)["done"] == "cancelled"
    assert len(compat.unshared()) == 1          # still waiting to be sent


def test_gh_route_only_stamps_after_it_succeeded(monkeypatch):
    compat.append_report(**REP, local=True)

    def boom(_reports, slug=None):
        raise IOError("gh: not logged in")
    monkeypatch.setattr(share, "submit_with_gh", boom)
    with pytest.raises(IOError):
        lib.share_via("gh")
    assert len(compat.unshared()) == 1          # nothing was lost


def test_gh_route_reports_the_issue_url(monkeypatch):
    compat.append_report(**REP, local=True)
    monkeypatch.setattr(share, "submit_with_gh",
                        lambda _r, slug=None: "https://github.com/o/r/issues/7")
    res = lib.share_via("gh")
    assert res["url"].endswith("/issues/7")
    assert compat.unshared() == []


def test_sharing_nothing_is_not_an_error():
    assert lib.share_via("copy")["done"] == "nothing new to share"


def test_an_unknown_route_is_a_programming_error():
    compat.append_report(**REP, local=True)
    with pytest.raises(ValueError):
        lib.share_via("carrier-pigeon")


# ── the online copy of the shared database ─────────────────────────────────

def test_a_fetched_database_is_read_like_the_shipped_one():
    """A checkout that never gets `git pull`ed still learns what other
    people found, including the settings they recorded."""
    import json
    os.makedirs(os.path.dirname(compat.online_path()), exist_ok=True)
    with open(compat.online_path(), "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "works", "date": "2030-01-01",
                             "profile": "drive=dos"}) + "\n")
    reports, errors = compat.load()
    assert not errors
    assert compat.current(reports, 2862)["c64"]["status"] == "works"
    assert compat.current_profile(reports, 2862, "c64") == "drive=dos"


def test_your_own_report_still_wins_over_a_fetched_one():
    import json
    os.makedirs(os.path.dirname(compat.online_path()), exist_ok=True)
    with open(compat.online_path(), "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "broken", "date": "2030-01-01"}) + "\n")
    compat.append_report(**dict(REP, date="2030-01-01"), local=True)
    reports, _ = compat.load()
    assert compat.current(reports, 2862)["c64"]["status"] == "works"


def test_the_synced_database_does_not_double_the_committed_one(tmp_path):
    """Both copies hold the same reports once a sync has happened, and both
    are read — so the overlap has to be collapsed, or every verdict in the
    project's history is listed twice."""
    with open(compat.default_path(), "w") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "works", "date": "2026-01-01"}) + "\n")
    assert compat.shared_paths() == [compat.default_path()]

    with open(compat.online_path(), "w") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "works", "date": "2026-01-01"}) + "\n")
        fh.write(json.dumps({"id": "#4193-U", "machine": "c64",
                             "status": "issues", "date": "2026-08-05"}) + "\n")
    assert compat.shared_paths() == [compat.online_path(),
                                     compat.default_path()]

    reports, _ = compat.load()
    assert len(reports) == 2
    assert len([r for r in reports if r["_canon"] == 2862]) == 1


def test_a_report_only_in_the_committed_file_is_read_back(tmp_path):
    """`compat report` writes to the committed file.  On a synced machine
    that file used to be ignored, so a verdict just recorded vanished from
    `show` / `list` / the app until the server had published it."""
    with open(compat.online_path(), "w") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "works", "date": "2026-01-01"}) + "\n")
    compat.append_report(canon_id=4193, sub=2, machine="c64",
                         status="broken", date="2026-08-05",
                         notes="does not start")

    reports, _ = compat.load()
    assert compat.current(reports, 4193, 2)["c64"]["status"] == "broken"
    assert any(r["_canon"] == 4193 and r["_sub"] == 2 for r in reports)


def test_two_people_reporting_the_same_thing_are_two_reports(tmp_path):
    """Dedup keys on the reporter too — identical verdicts from two testers
    are corroboration, not one line read twice."""
    for path in (compat.online_path(), compat.default_path()):
        with open(path, "w") as fh:
            fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                                 "status": "works", "date": "2026-01-01",
                                 "by": "Ann"}) + "\n")
    with open(compat.default_path(), "a") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "works", "date": "2026-01-01",
                             "by": "Bo"}) + "\n")

    reports, _ = compat.load()
    assert sorted(r["by"] for r in reports) == ["Ann", "Bo"]


def test_an_empty_synced_file_falls_back_to_the_committed_one(tmp_path):
    """A truncated download must not read as "there are no verdicts"."""
    with open(compat.default_path(), "w") as fh:
        fh.write(json.dumps({"id": "#2862-A", "machine": "c64",
                             "status": "works", "date": "2026-01-01"}) + "\n")
    open(compat.online_path(), "w").close()
    assert compat.shared_paths() == [compat.default_path()]
