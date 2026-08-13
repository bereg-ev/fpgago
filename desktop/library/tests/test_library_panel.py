"""Tests for how the Library tab shows a verdict (app/main.py).

Run:  cd desktop && python3 -m pytest library/tests -q   (skips without PySide6)

The claim being made visible: "it works" from your own board and "it works"
from the project's database are different statements, and when they disagree
that is the most useful thing the list can say.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

pytest.importorskip("serial", reason="desktop venv only")
pytest.importorskip("PySide6", reason="desktop venv only")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QThreadPool  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from app import library_backend as lib  # noqa: E402
from app.main import (SHOT_MARK, LibraryPanel, _best_verdict,  # noqa: E402
                      _tested_on_text, _verdict_item, _verdict_tip)

from test_connection import FakeMgr  # noqa: E402

V = lib.Verdict


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


# ── the words ──────────────────────────────────────────────────────────────

def test_it_says_whose_verdict_it_is():
    assert _tested_on_text({"c64": V(yours="works")}) == "c64 ✓ yours"
    assert _tested_on_text({"c64": V(online="broken")}) == "c64 ✗ online"


def test_a_disagreement_shows_both_sides():
    text = _tested_on_text({"c64": V(yours="works", online="broken")})
    assert text == "c64 ✓ yours ≠ ✗ online"


def test_several_machines_are_listed_in_order():
    text = _tested_on_text({"c64": V(yours="works"),
                            "c16": V(online="issues")})
    assert text == "c16 ! online   c64 ✓ yours"


def test_the_tooltip_spells_the_conflict_out():
    tip = _verdict_tip({"c64": V(yours="works", online="broken")})
    assert "YOU say works" in tip and "database says broken" in tip


# ── the mark ───────────────────────────────────────────────────────────────

def test_your_own_result_is_shown_upright(qapp):
    verdicts = {"c64": V(yours="works")}
    it = _verdict_item(_best_verdict(verdicts), verdicts)
    assert it.text() == "✓" and not it.font().italic()


def test_someone_elses_result_is_shown_in_italic(qapp):
    verdicts = {"c64": V(online="works")}
    it = _verdict_item(_best_verdict(verdicts), verdicts)
    assert it.text() == "✓" and it.font().italic()


def test_a_conflict_gets_its_own_mark(qapp):
    verdicts = {"c64": V(yours="works", online="broken")}
    it = _verdict_item(_best_verdict(verdicts), verdicts)
    assert it.text() == "≠"
    assert "YOU say" in it.toolTip()


def test_an_untested_game_has_no_mark(qapp):
    it = _verdict_item(_best_verdict({}), {})
    assert it.text() == "" and not it.toolTip()


def test_your_verdict_decides_the_mark(qapp):
    # you tested it and it worked; the database's older "broken" does not
    # get to be the headline
    verdicts = {"c64": V(yours="works", online="broken")}
    assert _best_verdict(verdicts) == "works"


def test_the_best_machine_wins_across_machines(qapp):
    verdicts = {"c64": V(online="works"), "c16": V(online="broken")}
    assert _best_verdict(verdicts) == "works"


# ── the variants list ──────────────────────────────────────────────────────

class FakeBoardPanel:
    def __init__(self):
        self.refreshed = 0

    def refresh(self):
        self.refreshed += 1


def _panel(board_panel=None):
    return LibraryPanel(FakeMgr(), QThreadPool.globalInstance(),
                        board_panel=board_panel)


def test_a_variant_row_names_its_canon_id(qapp):
    """Without the ID on screen there is no way to say *which* release the
    test result you just got belongs to."""
    p = _panel()
    p._show_variants([{"id": 7, "canon": "#2862-D/1", "release": "cr Nostalgia",
                       "platform": "c64",
                       "group_name": "Nostalgia", "source": "csdb",
                       "fmt": "d64", "n_files": 1}])
    assert p.var_tbl.item(0, p.V_ID).text() == "#2862-D/1"
    # who made this dump, right next to the ID — the two things that tell a
    # dozen releases of one game apart
    assert p.var_tbl.item(0, p.V_RELEASE).text() == "cr Nostalgia"
    assert p.var_tbl.item(0, p.V_RELEASE + 1).text() == "c64"   # nothing shifted


def test_sending_a_game_rereads_the_board_listing(qapp):
    bp = FakeBoardPanel()
    p = _panel(bp)
    p._show_sent({"file": "pirates-7.d64", "profile": "drive=dos"})
    assert bp.refreshed == 1


def test_a_failed_send_leaves_the_board_listing_alone(qapp):
    bp = FakeBoardPanel()
    p = _panel(bp)
    p._show_sent({"error": "upload failed"})
    assert bp.refreshed == 0


def test_a_corrected_release_is_marked_and_explains_itself(qapp):
    """A committed patch knows the source mislabeled this release, or that
    the disk holds two games.  Finding that out costs a download and a
    confused minute at the board, so it goes on the row, not in a file."""
    p = _panel()
    p._show_variants([{"id": 7, "canon": "#4193-U/5", "release": "cr Bandit",
                       "platform": "c64", "group_name": "Bandit",
                       "source": "archive", "fmt": "d64", "n_files": 1,
                       "note": "Two games on one disk."}])
    assert "⚠" in p.var_tbl.item(0, p.V_RELEASE).text()
    assert p.var_tbl.item(0, p.V_ID).toolTip() == "Two games on one disk."


def test_an_ordinary_release_is_not_marked(qapp):
    p = _panel()
    p._show_variants([{"id": 8, "canon": "#4193-U/2", "release": "",
                       "platform": "c64", "source": "archive", "fmt": "d64",
                       "n_files": 1}])
    assert "⚠" not in p.var_tbl.item(0, p.V_RELEASE).text()
    assert not p.var_tbl.item(0, p.V_ID).toolTip()


# ── running work off the GUI thread ────────────────────────────────────────

def test_a_caller_can_handle_its_own_failure(qapp, monkeypatch):
    """`_run(..., on_error=...)` must reach start_task, not the function
    being run.  It used to land in **kwargs and be passed to `fn`, so signing
    in died as "login() got an unexpected keyword argument 'on_error'" — a
    TypeError blamed on the library call it was meant to protect."""
    from app import main as appmain

    seen = {}
    monkeypatch.setattr(appmain, "start_task",
                        lambda pool, task, **kw: seen.update(task=task, **kw))
    p = _panel()
    mine = lambda tb: None                                    # noqa: E731
    p._run(lib.login, "someone", "secret", on_error=mine)

    assert "on_error" not in seen["task"].kwargs
    assert seen["task"].args == ("someone", "secret")
    assert seen["on_error"] is mine


def test_without_one_a_failure_still_reaches_the_log(qapp, monkeypatch):
    from app import main as appmain

    seen = {}
    monkeypatch.setattr(appmain, "start_task",
                        lambda pool, task, **kw: seen.update(kw))
    p = _panel()
    p._run(lib.stats)
    seen["on_error"]("Traceback…\nValueError: nope")
    assert "ValueError: nope" in p.log.toPlainText()


# ── the picture column ─────────────────────────────────────────────────────
# "Which of these has somebody photographed?" is asked while scanning the
# list, so it is answered in the list — one glyph per row, not a thumbnail
# per row (at four thousand games that is four thousand files read to draw
# twenty).

def test_a_game_with_a_picture_carries_the_mark(qapp):
    p = _panel()
    p._show_games([{"id": 1, "title": "Prince of Persia", "canon_id": 4314,
                    "platforms": "c64", "has_shot": True},
                   {"id": 2, "title": "Turrican", "canon_id": 5,
                    "platforms": "c64", "has_shot": False}])
    assert p.games_tbl.item(0, p.C_SHOT).text() == SHOT_MARK
    assert p.games_tbl.item(1, p.C_SHOT).text() == ""
    # and the row says what the empty cell means, rather than nothing
    assert "no screenshot" in p.games_tbl.item(1, p.C_SHOT).toolTip()


def test_the_mark_column_did_not_push_the_text_columns_over(qapp):
    p = _panel()
    p._show_games([{"id": 1, "title": "Turrican", "platforms": "c64",
                    "n_variants": 3, "year": 1990,
                    "verdicts": {"c64": V(yours="works")}}])
    assert p.games_tbl.item(0, p.C_TITLE).text() == "Turrican"
    assert p.games_tbl.item(0, p.C_PLAT).text() == "c64"
    assert p.games_tbl.item(0, p.C_TESTED).text() == "c64 ✓ yours"
    assert p.games_tbl.item(0, p.C_VERDICT).text() == "✓"


def test_uploading_a_picture_updates_the_row_it_was_for(qapp, monkeypatch):
    """The list must not still say "no picture" about the game whose picture
    is showing in the pane beside it."""
    monkeypatch.setattr(lib, "screenshot_for",
                        lambda cid, sub=None: "/cache/4314.png"
                        if sub is None else None)
    p = _panel()
    p._show_games([{"id": 1, "title": "Prince of Persia", "canon_id": 4314,
                    "platforms": "c64", "has_shot": False}])
    p.games_tbl.selectRow(0)
    p._shot_canon = 4314
    p._after_shot_sync()
    assert p.games_tbl.item(0, p.C_SHOT).text() == SHOT_MARK


def test_an_intro_upload_does_not_claim_the_game_has_a_picture(qapp,
                                                               monkeypatch):
    """A cracktro is not a picture of the game — the column that says "you
    can see what this game looks like" must keep telling the truth."""
    monkeypatch.setattr(lib, "screenshot_for", lambda cid, sub=None: None)
    monkeypatch.setattr(lib, "intro_subs", lambda cid: {5})
    p = _panel()
    p._show_games([{"id": 1, "title": "Wizard of Wor", "canon_id": 4193,
                    "platforms": "c64", "has_shot": False}])
    p.games_tbl.selectRow(0)
    p._shot_canon = 4193
    p._after_shot_sync()
    assert p.games_tbl.item(0, p.C_SHOT).text() == ""


# ── the game's picture vs one release's crack intro ────────────────────────
# One pane, one picture: going down a list of four thousand games, a second
# image beside the first is one image too many.  So the pane has a target —
# the game, or the intro of the release selected below — and both buttons,
# the file one and the board grab, follow it.

def _with_variant(p, monkeypatch, sub=5):
    monkeypatch.setattr(lib, "intro_subs", lambda cid: set())
    p._show_games([{"id": 1, "title": "Wizard of Wor", "canon_id": 4193,
                    "platforms": "c64", "has_shot": True}])
    p.games_tbl.selectRow(0)
    p._show_variants([{"id": 7, "canon": f"#4193-U/{sub}", "canon_sub": sub,
                       "release": "cr Bandit", "platform": "c64",
                       "source": "csdb", "n_files": 1}])
    p.var_tbl.selectRow(0)
    return p


def test_without_a_release_the_intro_box_is_dead(qapp, monkeypatch):
    monkeypatch.setattr(lib, "screenshot_for", lambda cid, sub=None: None)
    p = _panel()
    p._show_games([{"id": 1, "title": "Wizard of Wor", "canon_id": 4193,
                    "platforms": "c64", "has_shot": True}])
    p.games_tbl.selectRow(0)
    assert not p.intro_chk.isEnabled()
    assert "belongs to one release" in p.intro_chk.toolTip()


def test_a_release_with_no_id_of_its_own_cannot_have_an_intro(qapp,
                                                              monkeypatch):
    """A row still showing 'var#12' is not in the shared database, so there
    is nothing to hang a picture on."""
    monkeypatch.setattr(lib, "screenshot_for", lambda cid, sub=None: None)
    p = _with_variant(_panel(), monkeypatch, sub=None)
    assert not p.intro_chk.isEnabled()


def test_ticking_the_box_aims_the_pane_at_that_release(qapp, monkeypatch):
    asked = []
    monkeypatch.setattr(lib, "screenshot_for",
                        lambda cid, sub=None: asked.append((cid, sub)))
    p = _with_variant(_panel(), monkeypatch)
    assert p.intro_chk.isEnabled()
    p.intro_chk.setChecked(True)
    assert asked[-1] == (4193, 5)
    assert p._shot_sub == 5
    p.intro_chk.setChecked(False)
    assert asked[-1] == (4193, None)
    assert p._shot_sub is None


def test_the_upload_goes_where_the_pane_is_aimed(qapp, monkeypatch):
    monkeypatch.setattr(lib, "screenshot_for", lambda cid, sub=None: None)
    p = _with_variant(_panel(), monkeypatch)
    p._account = "tester"
    p.intro_chk.setChecked(True)
    assert p._shot_target() == (4193, 5)
    p.intro_chk.setChecked(False)
    assert p._shot_target() == (4193, None)


def test_leaving_the_release_drops_the_intro_target(qapp, monkeypatch):
    """The box must not stay ticked and silently aim at a release that is no
    longer selected."""
    monkeypatch.setattr(lib, "screenshot_for", lambda cid, sub=None: None)
    p = _with_variant(_panel(), monkeypatch)
    p.intro_chk.setChecked(True)
    p._show_variants([])
    p._show_shot(4193)
    assert not p.intro_chk.isChecked() and not p.intro_chk.isEnabled()
    assert p._shot_sub is None


def test_the_variants_list_marks_the_releases_with_an_intro(qapp, monkeypatch):
    monkeypatch.setattr(lib, "screenshot_for", lambda cid, sub=None: None)
    monkeypatch.setattr(lib, "intro_subs", lambda cid: {5})
    p = _panel()
    p._shot_canon = 4193
    p._show_variants([
        {"id": 7, "canon": "#4193-U/2", "canon_sub": 2, "platform": "c64",
         "release": "cr ATG", "source": "csdb", "n_files": 1},
        {"id": 8, "canon": "#4193-U/5", "canon_sub": 5, "platform": "c64",
         "release": "cr Bandit", "source": "csdb", "n_files": 1}])
    assert p.var_tbl.item(0, p.V_INTRO).text() == ""
    assert p.var_tbl.item(1, p.V_INTRO).text() == SHOT_MARK
    assert "crack intro" in p.var_tbl.item(1, p.V_INTRO).toolTip()


# ── the search filters ─────────────────────────────────────────────────────

def _searched(p, monkeypatch):
    """The arguments do_search() would hand the backend."""
    seen = []
    monkeypatch.setattr(p, "_run",
                        lambda fn, *a, **kw: seen.append((fn, a)))
    p.do_search()
    return seen[0][1]


def test_the_picture_filter_goes_both_ways(qapp, monkeypatch):
    p = _panel()
    assert _searched(p, monkeypatch)[3] is None          # "any"
    p.pic.setCurrentIndex(1)
    assert _searched(p, monkeypatch)[3] is True
    p.pic.setCurrentIndex(2)
    assert _searched(p, monkeypatch)[3] is False


def test_the_cartridge_filter_is_live_on_every_shipped_machine(qapp):
    """Every machine here is a Commodore, so the box is always usable; it
    greys out only for a platform with no cartridge port."""
    p = _panel()
    for i in range(p.plat.count()):
        p.plat.setCurrentIndex(i)
        assert p.easyflash.isEnabled(), p.plat.itemData(i)


def test_the_cartridge_filter_reaches_the_search(qapp, monkeypatch):
    p = _panel()
    p.easyflash.setChecked(True)
    assert _searched(p, monkeypatch)[4] is True


# ── the way in ─────────────────────────────────────────────────────────────
# Reading the database needs no account; sending anything back does.  Finding
# that out at the bottom of the tab after taking a screenshot is too late, so
# while nobody is signed in the invitation is the first thing on the tab.

def test_signed_out_puts_the_invitation_on_top_in_red(qapp):
    p = _panel()
    p._show_account({"user": None, "server": "https://fpgago.com"})
    assert p.login_bar.isVisibleTo(p)
    assert not p.account_btn.isVisibleTo(p)
    assert "#e74c3c" in p.login_btn.styleSheet()
    # first in the layout, above the database header and the search row
    assert p.layout().itemAt(0).widget() is p.login_bar


def test_signing_in_takes_the_bar_away(qapp):
    p = _panel()
    p._show_account({"user": "someone", "server": "https://fpgago.com"})
    assert not p.login_bar.isVisibleTo(p)
    assert p.account_btn.isVisibleTo(p)
    assert "someone" in p.account_btn.text()


def test_the_red_button_signs_in(qapp, monkeypatch):
    """Same action as the quiet one — two buttons, one way in."""
    p = _panel()
    called = []
    monkeypatch.setattr(p, "do_account", lambda: called.append(1))
    p.login_btn.clicked.disconnect()
    p.login_btn.clicked.connect(p.do_account)
    p.login_btn.click()
    assert called == [1]


def test_nothing_red_flashes_before_the_account_is_known(qapp):
    """The check is a network call; a signed-in user must not see a red "not
    signed in" bar on every start while it runs."""
    p = _panel()
    assert not p.login_bar.isVisibleTo(p)


def test_a_server_that_will_not_answer_still_leaves_a_way_in(qapp):
    """Neither a "log in" nor a "signed in as" is a tab nobody can sign in
    from — and an unreachable server is exactly when that would happen."""
    p = _panel()
    p._account_unknown("Traceback…\nWebAPIError: cannot reach fpgago.com")
    assert p.login_bar.isVisibleTo(p)
    assert "Could not reach" in p.login_lbl.text()
    assert "cannot reach fpgago.com" in p.log.toPlainText()


def test_the_error_text_does_not_stick_around(qapp):
    p = _panel()
    p._account_unknown("Traceback…\nWebAPIError: down")
    p._show_account({"user": None, "server": "https://fpgago.com"})
    assert p.login_lbl.text() == LibraryPanel.SIGNED_OUT


# ── the screenshot buttons say when they cannot be used ────────────────────
# Pressing one with nothing selected used to answer "this game is not in the
# shared database yet" — a complaint about a game the user had not picked.

def test_with_no_game_selected_the_buttons_are_dead(qapp):
    p = _panel()
    assert not p.shot_btn.isEnabled() and not p.grab_btn.isEnabled()
    assert "pick a game" in p.shot_btn.toolTip()
    assert "pick a game" in p.grab_btn.toolTip()


def test_an_empty_search_leaves_them_dead(qapp):
    p = _panel()
    p._show_games([{"id": 1, "title": "Turrican", "canon_id": 5,
                    "platforms": "c64"}])
    p.games_tbl.selectRow(0)
    assert p.shot_btn.isEnabled()
    p._show_games([])
    assert not p.shot_btn.isEnabled()
    assert "pick a game" in p.shot_btn.toolTip()


def test_a_game_the_database_does_not_know_says_which_problem_it_is(qapp):
    p = _panel()
    p._show_games([{"id": 1, "title": "Homebrew", "canon_id": None,
                    "platforms": "c64"}])
    p.games_tbl.selectRow(0)
    assert not p.shot_btn.isEnabled()
    assert "not in the shared database" in p.shot_btn.toolTip()


def test_a_game_with_an_id_gets_the_buttons_back(qapp):
    p = _panel()
    p._show_games([{"id": 1, "title": "Turrican", "canon_id": 5,
                    "platforms": "c64"}])
    p.games_tbl.selectRow(0)
    assert p.shot_btn.isEnabled() and p.grab_btn.isEnabled()
    assert p.shot_btn.toolTip() == LibraryPanel._SHOT_TIP


# ── searching by ID lands on the thing you named ───────────────────────────

def test_an_id_search_selects_the_one_row(qapp):
    p = _panel()
    p.query.setText("#4314-J")
    p._show_games([{"id": 1, "title": "Prince of Persia", "canon_id": 4314,
                    "platforms": "c64", "want_sub": None}])
    assert p.games_tbl.currentRow() == 0
    assert p._shot_canon == 4314              # and the screenshot pane follows


def test_a_title_search_selects_nothing(qapp):
    """Several hits and no cursor: picking one is the user's next move."""
    p = _panel()
    p.query.setText("prince")
    p._show_games([{"id": 1, "title": "Prince of Persia", "canon_id": 4314},
                   {"id": 2, "title": "Prince Clumsy", "canon_id": 7}])
    assert p.games_tbl.currentRow() < 0
    assert not p.shot_btn.isEnabled()


def test_an_id_that_names_a_release_selects_that_release(qapp):
    p = _panel()
    p._want_sub = 5
    p._show_variants([
        {"id": 7, "canon": "#4193-U/2", "canon_sub": 2, "platform": "c64",
         "release": "cr ATG", "source": "csdb", "n_files": 1},
        {"id": 8, "canon": "#4193-U/5", "canon_sub": 5, "platform": "c64",
         "release": "cr Bandit", "source": "csdb", "n_files": 1}])
    assert p.var_tbl.currentRow() == 1
    assert p._want_sub is None                # consumed, not sticky


def test_a_release_number_that_does_not_exist_says_so(qapp):
    p = _panel()
    p._want_sub = 9
    p._show_variants([{"id": 7, "canon": "#4193-U/2", "canon_sub": 2,
                       "platform": "c64", "source": "csdb", "n_files": 1}])
    assert "no release /9" in p.log.toPlainText()


def test_an_id_nobody_has_synced_explains_itself(qapp):
    p = _panel()
    p.query.setText("#9999-A")
    p._show_games([])
    assert "Sync now" in p.log.toPlainText()


def test_the_list_shows_each_games_id(qapp):
    p = _panel()
    p._show_games([{"id": 1, "title": "Prince of Persia", "canon_id": 4314},
                   {"id": 2, "title": "Homebrew", "canon_id": None}])
    assert p.games_tbl.item(0, p.C_ID).text() == "#4314-J"
    assert p.games_tbl.item(1, p.C_ID).text() == ""     # no ID yet, no lie
    assert p.games_tbl.item(0, p.C_TITLE).text() == "Prince of Persia"


def test_a_row_that_matched_by_number_says_so(qapp):
    """Search "1942", get a game called Bruce Lee: without the ID marked,
    that row reads as a broken search."""
    p = _panel()
    p.query.setText("1942")
    p._show_games([{"id": 2, "title": "Bruce Lee", "canon_id": 1942,
                    "by_id": True},
                   {"id": 1, "title": "1942", "canon_id": 3301}])
    marked = p.games_tbl.item(0, p.C_ID)
    assert marked.font().bold()
    assert "matched by this ID" in marked.toolTip()
    assert not p.games_tbl.item(1, p.C_ID).font().bold()
    assert "the game with that ID" in p.log.toPlainText()
    assert "Bruce Lee" in p.log.toPlainText()


# ── results that leave by themselves ───────────────────────────────────────
# A verdict sitting in compat-local.jsonl is one person's evening on one
# laptop.  The app sends them unasked; the only thing the user ever has to
# be told is that it could NOT — which is why that is the loud part.

def test_saving_a_verdict_sends_it_without_being_asked(qapp, monkeypatch):
    p = _panel()
    sent = []
    monkeypatch.setattr(p, "_auto_share", lambda *a, **k: sent.append(True))
    monkeypatch.setattr(p, "_refresh_share", lambda: None)
    p._show_saved({"report": {"id": "#4193-U", "machine": "c64",
                              "status": "works", "profile": ""},
                   "unshared": 1})
    assert sent == [True]


def test_a_result_that_did_not_get_out_is_shouted_about(qapp, monkeypatch):
    p = _panel()
    monkeypatch.setattr(lib, "unshared_reports", lambda: [{}, {}, {}])
    p._auto_shared({"sent": 0, "pending": 3, "ok": False,
                    "why": "not signed in to fpgago.com"})
    assert p.alert_bar.isVisibleTo(p)
    assert "3 test results" in p.alert_lbl.text()
    assert "NOT sent" in p.alert_lbl.text()
    assert "not signed in" in p.alert_lbl.text()


def test_once_they_are_out_the_notice_goes_away(qapp, monkeypatch):
    p = _panel()
    monkeypatch.setattr(p, "do_refresh", lambda *a, **k: None)
    monkeypatch.setattr(lib, "unshared_reports", lambda: [{}, {}])
    p._auto_shared({"sent": 0, "pending": 2, "ok": False, "why": "offline"})
    assert p.alert_bar.isVisibleTo(p)
    monkeypatch.setattr(lib, "unshared_reports", lambda: [])
    p._auto_shared({"sent": 2, "pending": 0, "ok": True, "why": ""})
    assert not p.alert_bar.isVisibleTo(p)
    assert "sent 2 test result(s)" in p.log.toPlainText()


def test_sending_a_result_pulls_the_merged_database_back(qapp, monkeypatch):
    """Our own report is part of the shared database the moment the server
    takes it — so the ticks have to stop saying "yours" and start saying
    what everybody else will see."""
    p = _panel()
    seen = []
    monkeypatch.setattr(p, "do_refresh", lambda *a, **k: seen.append(k))
    monkeypatch.setattr(lib, "unshared_reports", lambda: [])
    p._auto_shared({"sent": 1, "pending": 0, "ok": True, "why": ""})
    assert seen and seen[0].get("auto") is True


# ── a database that keeps itself up to date ────────────────────────────────

def test_the_tab_syncs_itself_on_a_timer(qapp):
    from app.main import AUTO_SYNC_MS

    p = _panel()
    assert p._auto_timer is None            # not until the window says so
    p.start_auto_sync()
    assert p._auto_timer.isActive()
    assert p._auto_timer.interval() == AUTO_SYNC_MS
    p._auto_timer.stop()


def test_a_quiet_sync_does_not_disturb_the_list(qapp, monkeypatch):
    """Nothing changed on the server, so nothing may change on screen — a
    background refresh that re-runs the search under the cursor every
    quarter of an hour is worse than no refresh at all."""
    p = _panel()
    searched = []
    monkeypatch.setattr(p, "do_search", lambda: searched.append(True))
    monkeypatch.setattr(p, "refresh_stats", lambda: None)
    p.log.clear()
    p._refresh_done({"changed": [], "errors": []}, auto=True)
    assert searched == []
    assert p.log.toPlainText() == ""


def test_a_sync_that_brought_something_keeps_your_place(qapp, monkeypatch):
    p = _panel()
    monkeypatch.setattr(p, "refresh_stats", lambda: None)
    p._show_games([{"id": 1, "title": "Turrican", "canon_id": 5},
                   {"id": 2, "title": "Pirates!", "canon_id": 9}])
    p.games_tbl.selectRow(1)
    monkeypatch.setattr(p, "do_search", lambda: p._show_games(
        [{"id": 3, "title": "Bruce Lee", "canon_id": 7},
         {"id": 1, "title": "Turrican", "canon_id": 5},
         {"id": 2, "title": "Pirates!", "canon_id": 9}]))
    p._refresh_done({"changed": ["c64.jsonl"], "games": 3, "new": 1,
                     "reports": 0, "errors": []}, auto=True)
    assert p.games_tbl.item(p.games_tbl.currentRow(),
                            p.C_TITLE).text() == "Pirates!"


def test_a_database_it_could_not_read_is_shouted_about(qapp):
    p = _panel()
    p.log.clear()
    p._refresh_error("Traceback…\nWebDBError: cannot reach fpgago.com",
                     auto=True)
    assert p.alert_bar.isVisibleTo(p)
    assert "could not read the game database" in p.alert_lbl.text()
    assert "cannot reach fpgago.com" in p.alert_lbl.text()
    # …and quietly: a timer tick that failed must not spam the log
    assert p.log.toPlainText() == ""


def test_a_sync_that_worked_clears_the_notice(qapp, monkeypatch):
    p = _panel()
    monkeypatch.setattr(p, "do_search", lambda: None)
    monkeypatch.setattr(p, "refresh_stats", lambda: None)
    monkeypatch.setattr(lib, "unshared_reports", lambda: [])
    p._refresh_error("Traceback…\nWebDBError: offline", auto=True)
    assert p.alert_bar.isVisibleTo(p)
    p._refresh_done({"changed": ["c64.jsonl"], "errors": []}, auto=True)
    assert not p.alert_bar.isVisibleTo(p)


def test_a_screenshot_upload_waits_for_the_running_sync(qapp, monkeypatch):
    """Two syncs write the same sqlite catalog, so the pane's "show me what
    everyone else will get" has to ride the one already in flight."""
    from app import main as appmain

    p = _panel()
    monkeypatch.setattr(p, "do_search", lambda: None)
    monkeypatch.setattr(p, "refresh_stats", lambda: None)
    monkeypatch.setattr(appmain, "start_task", lambda pool, task, **kw: None)
    done = []
    p._refreshing = True
    p.do_refresh(auto=True, then=lambda: done.append(True))
    assert done == []                       # not run twice, not run early
    p._refresh_done({"changed": [], "errors": []}, auto=True)
    assert done == [True]
