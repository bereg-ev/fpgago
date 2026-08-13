"""Tests for ResponsiveTable (app/main.py) — the tables that size their own
columns, so nobody drags a divider after every refresh.

Needs PySide6, which only the desktop venv has — SKIPPED elsewhere:

    desktop/.venv/bin/python3 -m pytest library/tests -q
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

pytest.importorskip("PySide6", reason="desktop venv only")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication, QTableWidgetItem  # noqa: E402

from app.main import ResponsiveTable  # noqa: E402

HEADERS = ["arch", "name", "size", "kind"]
ROWS = [
    ("c64", "c64-a-really-quite-long-game-file-name.d64", "174848", "disk"),
    ("c64", "c64-pirates.d64", "174848", "disk"),
    ("plus4", "plus4-treasure-island.prg", "9002", "program"),
]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def table(qapp, headers=HEADERS, rows=ROWS, width=800):
    t = ResponsiveTable(headers)
    t.resize(width, 300)
    for r, row in enumerate(rows):
        t.insertRow(r)
        for c, v in enumerate(row):
            t.setItem(r, c, QTableWidgetItem(v))
    t.show()
    qapp.processEvents()
    return t


def widths(t):
    return [t.columnWidth(c) for c in range(t.columnCount())]


def test_the_wide_column_gets_the_room(qapp):
    w = widths(table(qapp))
    assert w[1] > 3 * max(w[0], w[2], w[3])


def test_the_slack_goes_to_the_named_column_not_the_widest_one(qapp):
    # `source_ref` measures widest here, but `name` is the one worth
    # reading — that is what the WIDE list is for
    t = table(qapp, headers=["source_ref", "name"],
              rows=[("archive.org/details/" + "a" * 40, "x.d64")], width=900)
    w = widths(t)
    assert w[1] > w[0]


def test_the_columns_fill_the_viewport_exactly(qapp):
    t = table(qapp)
    assert sum(widths(t)) == t.viewport().width()


def test_it_re_fits_when_the_window_shrinks(qapp):
    t = table(qapp)
    t.resize(420, 300)
    qapp.processEvents()
    # the whole point: no horizontal scrollbar just because the window moved
    assert sum(widths(t)) <= t.viewport().width()


def test_narrow_columns_stay_narrow_when_there_is_room(qapp):
    t = table(qapp, width=1400)
    qapp.processEvents()
    assert widths(t)[0] < 100        # "arch" holds 5-char values


def test_a_very_long_cell_is_capped(qapp):
    t = table(qapp, headers=["id", "url"],
              rows=[("1", "https://archive.org/details/" + "x" * 400)])
    assert widths(t)[1] <= t.viewport().width()


def test_a_table_with_no_named_wide_column_still_fills(qapp):
    t = table(qapp, headers=["a", "b"], rows=[("1", "2"), ("3", "4")])
    assert sum(widths(t)) == t.viewport().width()


def test_a_column_the_user_dragged_is_left_alone(qapp):
    t = table(qapp)
    t.setColumnWidth(0, 220)         # what a drag does
    t.resize(600, 300)
    qapp.processEvents()
    assert t.columnWidth(0) == 220
    assert sum(widths(t)) == t.viewport().width()


def test_unpin_goes_back_to_measuring(qapp):
    t = table(qapp)
    t.setColumnWidth(0, 220)
    qapp.processEvents()
    t.unpin()
    qapp.processEvents()
    assert t.columnWidth(0) < 220


def test_an_empty_table_still_shows_its_headers(qapp):
    t = table(qapp, rows=[])
    assert min(widths(t)) >= ResponsiveTable.MIN_W
