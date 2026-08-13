"""Tests for the desktop app's per-game settings dialog (app/main.py
GameSettingsDialog).

Needs PySide6, which only the desktop venv has — SKIPPED elsewhere, so the
plain `python3 -m pytest library/tests` run stays green:

    desktop/.venv/bin/python3 -m pytest library/tests -q

The dialog is pure UI over a profile blob (the board I/O lives in
the panels), which is what makes it testable headless: build one, poke the
widgets, read `.blob()` back.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from library import profile  # noqa: E402

pytest.importorskip("PySide6", reason="desktop venv only")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication  # noqa: E402

from app.main import GameSettingsDialog  # noqa: E402

BLOB = 'drive=dos\nbtn=joy2\ntype=@boot;load"pirates",8,1\\r;@load;run\\r'


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def dlg(qapp, blob=""):
    return GameSettingsDialog(None, "c64-pirates.d64", blob)


def test_empty_profile_stays_empty(qapp):
    d = dlg(qapp)
    assert d.blob() == ""
    assert not d.macro_ed.isEnabled()        # Default = nothing to edit


def test_widgets_show_a_loaded_profile(qapp):
    d = dlg(qapp, BLOB)
    assert d.cb_drive.currentData() == "dos"
    assert d.cb_btn.currentData() == "joy2"
    assert d.cb_speed.currentData() is None  # not pinned -> Use global
    assert d.cb_start.currentIndex() == d._AS_CUSTOM
    assert d.macro_ed.isEnabled()
    assert d.macro_ed.macro() == '@boot;load"pirates",8,1\\r;@load;run\\r' 


def test_round_trips_unchanged(qapp):
    assert profile.parse(dlg(qapp, BLOB).blob()) == profile.parse(BLOB)


def test_one_edit_changes_one_key(qapp):
    d = dlg(qapp, BLOB)
    d.cb_drive.setCurrentIndex(d.cb_drive.findData("1541"))
    s = profile.parse(d.blob())
    assert s["drive"] == "1541" and s["btn"] == "joy2"


def test_use_global_removes_the_key(qapp):
    d = dlg(qapp, "drive=dos")
    d.cb_drive.setCurrentIndex(0)
    assert d.blob() == ""


def test_autostart_off_is_an_explicit_empty_macro(qapp):
    d = dlg(qapp)
    d.cb_start.setCurrentIndex(d._AS_OFF)
    assert d.blob() == "type="


def test_a_key_the_app_does_not_know_survives_an_edit(qapp):
    # the forward-compatibility promise, on the GUI side this time
    d = dlg(qapp, "drive=dos\ndf0=disk2.adf")
    d.cb_btn.setCurrentIndex(d.cb_btn.findData("joy1"))
    assert profile.parse(d.blob())["df0"] == "disk2.adf"


def test_the_board_dialog_has_no_library_fields(qapp):
    d = dlg(qapp, BLOB)
    assert d.machine() is None and d.verdict() is None
    assert d.btn_write.text() == "Write to board"


# ── library mode: the same settings, filed in the compat database ──────────

def _lib_dlg(machines=("c64", "c16"), status=None, lookup=None, **db):
    return GameSettingsDialog(None, "Pirates", "drive=dos",
                              db={"machines": list(machines),
                                  "status": status, "lookup": lookup, **db})


def test_library_dialog_offers_the_machines_and_a_verdict(qapp):
    d = _lib_dlg(status="issues")
    assert [d.cb_machine.itemData(i) for i in range(d.cb_machine.count())] \
        == ["c64", "c16"]
    assert d.machine() == "c64" and d.verdict() == "issues"
    assert d.btn_write.text() == "Save settings"


def test_library_dialog_defaults_to_works_when_untested(qapp):
    assert _lib_dlg().verdict() == "works"


def test_switching_machine_shows_that_machines_settings(qapp):
    # half-edited settings from the previous machine must not leak across
    per = {"c64": {"profile": "drive=dos", "status": "works"},
           "c16": {"profile": "btn=joy1", "status": "broken"}}
    d = _lib_dlg(lookup=per.get)
    d.cb_machine.setCurrentIndex(d.cb_machine.findData("c16"))
    assert d.blob() == "btn=joy1"
    assert d.verdict() == "broken"


def test_switching_to_an_untested_machine_resets_the_verdict(qapp):
    per = {"c64": {"profile": "drive=dos", "status": "issues"},
           "c16": {"profile": None, "status": None}}
    d = _lib_dlg(status="issues", lookup=per.get)
    d.cb_machine.setCurrentIndex(d.cb_machine.findData("c16"))
    # it has never been tried on a c16 — do not inherit the c64 verdict
    assert d.verdict() == "works" and d.blob() == ""


# ── reviewing a game: the drive flag, the notes, and who tested it ─────────


def test_the_board_dialog_has_none_of_the_review_fields(qapp):
    d = dlg(qapp, BLOB)
    assert d.real1541() is None and d.notes() == "" and d.email() == ""


def test_the_review_fields_show_what_was_recorded(qapp):
    d = _lib_dlg(real1541=True, notes="only loads on the real drive",
                 by="Tester", email="tester@example.com")
    assert d.real1541() is True
    assert d.notes() == "only loads on the real drive"
    assert d.reviewer() == "Tester" and d.email() == "tester@example.com"


def test_an_unticked_box_on_an_unflagged_game_says_nothing(qapp):
    """Not ticking it is not a claim that fastload works — the tester may
    never have tried it — so the report leaves the field out."""
    assert _lib_dlg().real1541() is None


def test_unticking_a_flag_that_was_set_clears_it_explicitly(qapp):
    d = _lib_dlg(real1541=True)
    d.chk_1541.setChecked(False)
    assert d.real1541() is False           # not None: silence would not clear


def test_ticking_the_flag_pins_the_drive_to_the_real_1541(qapp):
    """The settings the board gets must not contradict the verdict just
    recorded — "needs the real drive" plus drive=fastload is nonsense."""
    d = _lib_dlg()
    d._select(d.cb_drive, "fastload")
    d.chk_1541.setChecked(True)
    assert d.cb_drive.currentData() == "1541"
    assert profile.parse(d.blob())["drive"] == "1541"


def test_ticking_it_leaves_a_deliberate_drive_choice_alone(qapp):
    d = _lib_dlg()
    d._select(d.cb_drive, "dos")
    d.chk_1541.setChecked(True)
    assert d.cb_drive.currentData() == "dos"


def test_switching_machine_switches_the_notes_and_the_flag(qapp):
    per = {"c64": {"profile": "drive=dos", "status": "works",
                   "notes": "c64 note", "real1541": True},
           "c16": {"profile": None, "status": None, "notes": None,
                   "real1541": None}}
    d = _lib_dlg(real1541=True, notes="c64 note", lookup=per.get)
    d.cb_machine.setCurrentIndex(d.cb_machine.findData("c16"))
    assert d.notes() == "" and d.real1541() is None
    # and switching machines is not a user edit, so nothing was auto-pinned
    assert d.blob() == ""


def test_a_mistyped_email_stops_the_save(qapp):
    d = _lib_dlg(email="tester@example.com")
    d.email_ed.setText("tester@")
    assert not d.btn_write.isEnabled()
    d.email_ed.setText("tester@example.com")
    assert d.btn_write.isEnabled()
    d.email_ed.setText("")                 # blank is fine — it is a courtesy
    assert d.btn_write.isEnabled()


def test_an_oversized_sequence_disables_the_write_button(qapp):
    d = dlg(qapp)
    d.cb_start.setCurrentIndex(d._AS_CUSTOM)
    d.macro_ed.set_steps([profile.Step(profile.TEXT, "x" * 300)])
    d._sync()
    assert not d.btn_write.isEnabled()
    d.macro_ed.set_steps([profile.Step(profile.WAIT_BOOT),
                          profile.Step(profile.TEXT, "run\\r")])
    d._sync()
    assert d.btn_write.isEnabled()
