"""Tests for the Board tab's two lists (app/main.py BoardPanel).

Run:  cd desktop && python3 -m pytest library/tests -q   (skips without PySide6)

What is being defended: the tables describe a board that is *there*.  When it
goes away they are emptied, when it comes back they reload themselves, they
are grouped by machine, and picking a machine moves the games cursor to that
machine — the two lists are one thought.
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

from app import serial_manager as sm  # noqa: E402
from app.main import BoardPanel  # noqa: E402

from test_connection import FakeMgr  # noqa: E402


class Entry:
    def __init__(self, arch, name, kind="disk", size=1024):
        self.arch, self.name, self.kind, self.size = arch, name, kind, size


# Deliberately out of order, with an untagged straggler.
FILES = [
    Entry("264", "264.bit", "bitstream"),
    Entry("c64", "turrican2.d64"),
    Entry("c16", "c16.bit", "bitstream"),
    Entry("c64", "armatyle.d64"),
    Entry("?", "wizard.d64"),
    Entry("c64", "c64.bit", "bitstream"),
    Entry("plus4", "plus4.bit", "bitstream"),
    Entry("plus4", "plus4_new_york.prg", "program"),
    Entry("c16", "terranova-c16.prg", "program"),
    Entry("c64", "last-ninja-2.d64"),
    Entry("264", "zeta.prg", "program"),
]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def panel(qapp, boot="c64.bit", files=None):
    p = BoardPanel(FakeMgr(), QThreadPool.globalInstance())
    p._show_status({"files": list(FILES if files is None else files),
                    "info": {"boot": boot, "free_kb": 100, "gap_kb": 90},
                    "version": {"fw": "x", "bit": "y"}})
    return p


def col(table, c):
    return [table.item(r, c).text() for r in range(table.rowCount())]


# ── grouped and alphabetical ───────────────────────────────────────────────

def test_machines_are_alphabetical(qapp):
    p = panel(qapp)
    assert col(p.mach_tbl, 1) == ["264.bit", "c16.bit", "c64.bit",
                                  "plus4.bit"]


def test_games_are_grouped_by_machine_then_alphabetical(qapp):
    p = panel(qapp)
    assert col(p.game_tbl, 0) == ["264", "c16", "c64", "c64", "c64",
                                  "plus4", "?"]
    assert col(p.game_tbl, 1)[2:5] == ["armatyle.d64", "last-ninja-2.d64",
                                       "turrican2.d64"]


def test_files_with_no_machine_go_last(qapp):
    # they belong to no machine, so they must not sit above the ones that do
    p = panel(qapp)
    assert col(p.game_tbl, 1)[-1] == "wizard.d64"


# ── the cursor follows the machine ─────────────────────────────────────────

def test_it_starts_on_the_boot_machine(qapp):
    p = panel(qapp, boot="plus4.bit")
    assert p.mach_tbl.item(p.mach_tbl.currentRow(), 1).text() == "plus4.bit"
    assert p.game_tbl.item(p.game_tbl.currentRow(), 1).text() \
        == "plus4_new_york.prg"


def test_with_no_boot_machine_it_starts_at_the_first_one(qapp):
    p = panel(qapp, boot=None)
    assert p.mach_tbl.item(p.mach_tbl.currentRow(), 1).text() == "264.bit"
    assert p.game_tbl.item(p.game_tbl.currentRow(), 1).text() \
        == "zeta.prg"


def test_picking_a_machine_jumps_to_its_first_game(qapp):
    p = panel(qapp)
    for bit, first in (("264.bit", "zeta.prg"),
                       ("c16.bit", "terranova-c16.prg"),
                       ("c64.bit", "armatyle.d64")):
        row = col(p.mach_tbl, 1).index(bit)
        p.mach_tbl.selectRow(row)
        assert p.game_tbl.item(p.game_tbl.currentRow(), 1).text() == first


def test_a_machine_with_no_games_leaves_no_stale_cursor(qapp):
    p = panel(qapp, files=FILES + [Entry("c128", "c128.bit", "bitstream")])
    p.mach_tbl.selectRow(col(p.mach_tbl, 1).index("c128.bit"))
    assert p.game_tbl.currentRow() < 0        # not somebody else's game


# ── the lists follow the board ─────────────────────────────────────────────

def test_losing_the_board_empties_the_lists(qapp):
    p = panel(qapp)
    assert p.game_tbl.rowCount() and p._loaded
    p._on_link_status(sm.ST_DISCONNECTED, "")
    assert p.mach_tbl.rowCount() == 0 and p.game_tbl.rowCount() == 0
    assert not p._loaded
    assert "no board" in p.info_lbl.text()


def test_a_board_that_stops_responding_also_clears(qapp):
    p = panel(qapp)
    p._on_link_status(sm.ST_OFFLINE, "no response to ping")
    assert p.game_tbl.rowCount() == 0


def test_coming_online_reloads_without_being_asked(qapp):
    p = panel(qapp)
    calls = []
    p.refresh = lambda: calls.append(1)
    p._on_link_status(sm.ST_DISCONNECTED, "")
    p._on_link_status(sm.ST_ONLINE, "hostlink")
    assert calls == [1]


def test_it_does_not_reload_over_and_over_while_online(qapp):
    p = panel(qapp)
    calls = []
    p.refresh = lambda: calls.append(1)
    for _ in range(5):                        # every ping updates the status
        p._on_link_status(sm.ST_ONLINE, "hostlink")
    assert calls == []                        # already loaded


# ── deleting ───────────────────────────────────────────────────────────────

def test_delete_takes_every_selected_row(qapp):
    p = panel(qapp)
    p.game_tbl.selectRow(1)
    p.game_tbl.selectRow(2)                   # extended selection: adds
    p.game_tbl.setRangeSelected(
        __import__("PySide6.QtWidgets", fromlist=["QTableWidgetSelectionRange"])
        .QTableWidgetSelectionRange(2, 0, 4, 3), True)
    names = p._selected_names(p.game_tbl)
    assert names == ["armatyle.d64", "last-ninja-2.d64", "turrican2.d64"]


def test_the_games_list_allows_a_range_selection(qapp):
    from PySide6.QtWidgets import QAbstractItemView
    p = panel(qapp)
    assert p.game_tbl.selectionMode() == QAbstractItemView.ExtendedSelection


def test_the_cursor_survives_a_delete(qapp):
    """Deleting five games in a row must not mean five trips back to the
    list to click again."""
    p = panel(qapp)
    p._keep_cursor = (p.game_tbl, 2)
    p._show_status({"files": [f for f in FILES if f.name != "last-ninja-2.d64"],
                    "info": {"boot": "c64.bit"}, "version": {}})
    assert p.game_tbl.currentRow() == 2       # the row that slid up into place


def test_deleting_the_last_row_leaves_the_cursor_in_range(qapp):
    p = panel(qapp)
    last = p.game_tbl.rowCount() - 1
    p._keep_cursor = (p.game_tbl, last)
    p._show_status({"files": FILES[:3], "info": {"boot": None},
                    "version": {}})
    assert 0 <= p.game_tbl.currentRow() < p.game_tbl.rowCount()


def test_a_normal_refresh_still_lands_on_the_boot_machine(qapp):
    p = panel(qapp)                            # no _keep_cursor set
    assert p.mach_tbl.item(p.mach_tbl.currentRow(), 1).text() == "c64.bit"


class FakeOps:
    def __init__(self):
        self.deleted = []

    def fs_delete(self, name):
        self.deleted.append(name)


def wire(p, ops):
    """Make the panel's background calls synchronous for the test."""
    p.ops = ops

    def run(fn, *a, on_done=None, wants_progress=False, **kw):
        if wants_progress:
            kw["progress"] = lambda _m: None
        r = fn(*a, **kw)
        if on_done:
            on_done(r)
    p._run = run
    return p


def test_deleting_removes_every_selected_file(qapp, monkeypatch):
    from PySide6.QtWidgets import QMessageBox, QTableWidgetSelectionRange
    monkeypatch.setattr(QMessageBox, "question",
                        staticmethod(lambda *a, **k: QMessageBox.Yes))
    p = panel(qapp)
    ops = FakeOps()
    wire(p, ops)
    p.refresh = lambda: None
    p.game_tbl.setRangeSelected(
        QTableWidgetSelectionRange(2, 0, 4, 3), True)
    p._delete(p.game_tbl)
    assert ops.deleted == ["armatyle.d64", "last-ninja-2.d64",
                           "turrican2.d64"]


def test_deleting_asks_for_the_cursor_to_be_kept(qapp, monkeypatch):
    from PySide6.QtWidgets import QMessageBox
    monkeypatch.setattr(QMessageBox, "question",
                        staticmethod(lambda *a, **k: QMessageBox.Yes))
    p = panel(qapp)
    wire(p, FakeOps())
    p.refresh = lambda: None
    p.game_tbl.selectRow(3)
    p._delete(p.game_tbl)
    assert p._keep_cursor == (p.game_tbl, 3)


def test_saying_no_deletes_nothing(qapp, monkeypatch):
    from PySide6.QtWidgets import QMessageBox
    monkeypatch.setattr(QMessageBox, "question",
                        staticmethod(lambda *a, **k: QMessageBox.No))
    p = panel(qapp)
    ops = FakeOps()
    wire(p, ops)
    p.game_tbl.selectRow(1)
    p._delete(p.game_tbl)
    assert ops.deleted == []


# ── which machine is up, and which game it would start ─────────────────────
# The board runs one bitstream and, on it, the game the BIOS remembers (KV
# "game.<arch>", written on every launch).  Both lists say which, because
# "why does Run do nothing?" is nearly always "that game is not this
# machine's" — and the answer has to be visible without pressing anything.

ACTIVE = {"c64": "last-ninja-2.d64", "c16": "terranova-c16.prg"}

MARK_COL = {"mach": 3, "game": 4}


def marks(table, col):
    return {table.item(r, 1).text(): table.item(r, col).text()
            for r in range(table.rowCount())}


def active_panel(qapp, boot="c64.bit", active=None):
    p = BoardPanel(FakeMgr(), QThreadPool.globalInstance())
    p._show_status({"files": list(FILES),
                    "info": {"boot": boot, "free_kb": 1, "gap_kb": 1},
                    "version": {"fw": "x", "bit": "y"},
                    "active": ACTIVE if active is None else active})
    return p


def test_the_running_machine_is_marked(qapp):
    p = active_panel(qapp, boot="plus4.bit")
    assert marks(p.mach_tbl, MARK_COL["mach"])["plus4.bit"] == "● active"
    assert marks(p.mach_tbl, MARK_COL["mach"])["c64.bit"] == ""


def test_a_rom_set_is_never_the_active_machine(qapp):
    """A .roms sits under the bitstream it feeds; it is not something that
    boots, so it keeps saying what it is."""
    p = active_panel(qapp)
    p._show_status({"files": FILES + [Entry("c64", "c64.roms", "roms")],
                    "info": {"boot": "c64.bit"}, "version": {},
                    "active": ACTIVE})
    assert marks(p.mach_tbl, MARK_COL["mach"])["c64.roms"] == "ROMs"


def test_each_machines_own_game_is_marked(qapp):
    """One active game per machine, not one per board: the c64 remembers its
    game and the c16 remembers its own."""
    p = active_panel(qapp)
    m = marks(p.game_tbl, MARK_COL["game"])
    assert m["last-ninja-2.d64"] == "● active"
    assert m["terranova-c16.prg"] == "● active"
    assert m["armatyle.d64"] == ""
    assert p.game_tbl.item(0, 0) is not None      # arch column still filled


def test_the_active_row_is_bold_and_green(qapp):
    """The mark column is narrow and lists are long, so the whole row says
    it."""
    p = active_panel(qapp)
    row = col(p.game_tbl, 1).index("last-ninja-2.d64")
    for c in range(p.game_tbl.columnCount()):
        it = p.game_tbl.item(row, c)
        assert it.font().bold()
        assert it.foreground().color().name() == "#2ecc71"


def test_a_board_that_remembers_nothing_marks_nothing(qapp):
    p = active_panel(qapp, active={})
    assert set(marks(p.game_tbl, MARK_COL["game"]).values()) == {""}


def test_a_remembered_game_that_was_deleted_marks_nothing(qapp):
    p = active_panel(qapp, active={"c64": "gone.d64"})
    assert set(marks(p.game_tbl, MARK_COL["game"]).values()) == {""}


def test_picking_a_machine_jumps_to_its_active_game(qapp):
    """Not merely the first game of that machine: the one it would start."""
    p = active_panel(qapp)
    p.mach_tbl.selectRow(col(p.mach_tbl, 1).index("c64.bit"))
    assert p.game_tbl.item(p.game_tbl.currentRow(), 1).text() \
        == "last-ninja-2.d64"


def test_with_nothing_remembered_it_still_lands_on_the_first_game(qapp):
    p = active_panel(qapp, active={})
    p.mach_tbl.selectRow(col(p.mach_tbl, 1).index("c64.bit"))
    assert p.game_tbl.item(p.game_tbl.currentRow(), 1).text() == "armatyle.d64"


def test_a_board_that_will_not_answer_the_kv_read_still_lists(qapp):
    """The mark is cosmetic; losing it must not cost the file list."""
    class Ops:
        def fs_list(self):
            return list(FILES)

        def boot_info(self):
            return {"boot": "c64.bit", "free_kb": 1, "gap_kb": 1}

        def version(self):
            return {"fw": "x", "bit": "y"}

        def active_games(self, _entries):
            raise IOError("no")

    p = BoardPanel(FakeMgr(), QThreadPool.globalInstance())
    p.ops = Ops()
    p._show_status(p._gather_status())
    assert p.game_tbl.rowCount() == len(FILES) - 4      # minus the bitstreams
    assert set(marks(p.game_tbl, MARK_COL["game"]).values()) == {""}


# ── booting ────────────────────────────────────────────────────────────────

def test_booting_a_machine_asks_nothing_first(qapp, monkeypatch):
    """Booting is what the button is for, and it is undone by booting
    something else; a confirmation stood in front of every machine change."""
    from PySide6.QtWidgets import QMessageBox
    monkeypatch.setattr(QMessageBox, "question", staticmethod(
        lambda *a, **k: pytest.fail("Boot must not ask")))
    programmed = []

    class Ops:
        def fpga_prog(self, name):
            programmed.append(name)

    p = active_panel(qapp)
    wire(p, Ops())
    p.mach_tbl.selectRow(col(p.mach_tbl, 1).index("c16.bit"))
    p._boot_machine()
    assert programmed == ["c16.bit"]
