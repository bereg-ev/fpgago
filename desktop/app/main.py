"""main.py — fpgago desktop companion app (PySide6).

Round 1 features:
  * Connection    — finds the board (fpgago USB ids only), connects itself,
                   and carries the live machine controls: keyboard, F-keys,
                   volume, drive mode, reset (see serial_manager.py).
  * Board tab    — what is in the board's flash: machines and games, with the
                   upload/download/delete actions for each.
  * Library tab  — the full game-library engine on a GUI: stats, local + online
                   search, per-game variants, file import, collection indexing,
                   C16 bulk sync, variant download, and a game's screenshot —
                   from a file or grabbed off the board (shotgrab.py).
                   It keeps itself in step with fpgago.com without being
                   asked: verdicts leave this machine the moment they are
                   recorded, the database is re-read on a timer and after
                   anything the user changes, and the only thing said out
                   loud is a red bar when either could not happen.

There used to be a Screen tab beside these — a raw 800×480 grab of the LCD
with a wire trace, from the weeks when the grab path itself was the thing
under test.  It is gone: the grab works, and the only grab anyone actually
wants is the one the Library tab takes ("Grab from board"), cropped to the
machine's own screen and offered as the game's picture.  The wire side it
was built around still lives in app/shotgrab.py.

Launched by `make desktop`, which provisions desktop/.venv with PySide6.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time

from PySide6.QtCore import Qt, QObject, QThreadPool, Signal
from PySide6.QtGui import QColor, QImage, QPixmap, QTextCursor
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox,
    QDoubleSpinBox, QFileDialog, QFormLayout, QFrame,
    QGridLayout, QGroupBox, QHBoxLayout, QHeaderView, QLabel, QLineEdit,
    QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
    QSlider, QSpinBox, QSplitter, QTabWidget, QTableWidget, QTableWidgetItem,
    QVBoxLayout, QWidget,
)

from . import board_backend as board
from . import library_backend as lib          # also puts `library` on sys.path
from library import compat as gcompat         # noqa: E402  (needs lib first)
from library import profile as gprofile       # noqa: E402  (needs lib first)
from .serial_manager import (
    ST_DISCONNECTED, ST_CONNECTING, ST_ONLINE, ST_OFFLINE, SerialManager,
)
from .shotgrab import ShotSession, crop_active, screen_name
from .tasks import Task, start_task

PLATFORMS = ["", "c64", "c16", "plus4", "264"]

# How often the Library tab re-reads the game database and pushes out any
# test results still queued.  A person who has to remember to press Refresh
# is a person running a months-old catalog and sitting on verdicts nobody
# else will ever see — so nobody has to remember.  Only changed files are
# fetched (webdb.sync), so a quiet tick costs one small request.
AUTO_SYNC_MS = 15 * 60 * 1000
# Not at construction: the window has to come up first, and the very first
# sync is the one most likely to be slow.
FIRST_SYNC_MS = 4000

# What the board does on its own when a game starts, spelled out — shown as
# the starting point when a user switches to a custom sequence.  Mirrors
# GP_DEFAULT_DISC_MACRO in the board firmware.
GP_DEFAULT_MACRO = '@boot;load"*",8,1\\r;@load;run\\r'

# DRIVE_MODE in the firmware (qspi cmd 0x0B) — index is the wire value.
DRIVE_MODE_NAMES = {0: "FASTLOAD (QSPI)", 1: "REAL 1541 (IEC)", 2: "AUTO",
                    3: "DOS 1541 (IEC)", 4: "FPGA 1541 (FABRIC)"}


# ── tables that size themselves ─────────────────────────────────────────────
class ResponsiveTable(QTableWidget):
    """A QTableWidget that sizes its own columns, and re-sizes them whenever
    the rows or the window change.

    Every column asks for the width its content actually needs (clamped both
    ways), and the free-form ones — a title, a file name, a URL — share out
    whatever space is left over.  So `size` and `arch` stay narrow, `name`
    gets the room, and nobody drags a divider after every refresh.

    Drag one anyway and that column is pinned: a width the user chose beats
    anything measured, for as long as the app is open.
    """

    #: header names that deserve the leftover width (lower case, exact)
    WIDE = frozenset({
        "title", "name", "game", "file", "filename", "path", "url",
        "source_url", "detail", "notes", "value", "value (hex)", "component",
    })
    MIN_W = 44          # a 3-char column still needs its header to be legible
    MAX_W = 460         # a long URL must not push everything else off-screen
    PAD = 24            # cell margins + sort indicator + a little air
    SAMPLE = 250        # rows measured per column; a full catalog is 10k+

    def __init__(self, headers, parent=None):
        super().__init__(0, len(headers), parent)
        self._names = [h.strip().lower() for h in headers]
        self.setHorizontalHeaderLabels(list(headers))
        self.setEditTriggers(QTableWidget.NoEditTriggers)
        self.setSelectionBehavior(QTableWidget.SelectRows)
        self.setSelectionMode(QTableWidget.SingleSelection)
        self.verticalHeader().setVisible(False)
        hdr = self.horizontalHeader()
        hdr.setSectionResizeMode(QHeaderView.Interactive)
        # We hand out the slack ourselves; stretchLastSection would fight us
        # (and always feeds it to the last column, which is rarely the one
        # that wants it).
        hdr.setStretchLastSection(False)
        self._pinned: set[int] = set()
        self._applying = False
        hdr.sectionResized.connect(self._section_resized)
        # Fills are `setRowCount(0)` + insertRow + setItem in a loop, so
        # re-sizing per signal would be O(cells).  Coalesce into one pass on
        # the next event-loop turn instead.
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.setInterval(0)
        self._timer.timeout.connect(self.autosize)
        m = self.model()
        for sig in (m.rowsInserted, m.rowsRemoved, m.modelReset,
                    m.dataChanged):
            sig.connect(lambda *_a: self._timer.start())

    # -- the user's width wins ----------------------------------------------
    def _section_resized(self, idx, _old, _new):
        if not self._applying:
            self._pinned.add(idx)

    def unpin(self):
        """Forget the widths the user dragged and go back to measuring."""
        self._pinned.clear()
        self.autosize()

    # -- sizing --------------------------------------------------------------
    def _content_width(self, col: int) -> int:
        """Widest text in the column, header included.  Measured with the
        font rather than sizeHintForColumn() because that one walks every
        row — fine for a file list, not for a synced catalog."""
        hitem = self.horizontalHeaderItem(col)
        fm_h = self.horizontalHeader().fontMetrics()
        w = fm_h.horizontalAdvance(hitem.text()) if hitem else 0
        fm = self.fontMetrics()
        for r in range(min(self.rowCount(), self.SAMPLE)):
            it = self.item(r, col)
            if it is not None:
                w = max(w, fm.horizontalAdvance(it.text()))
        return w

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self._timer.start()

    def autosize(self):
        cols = self.columnCount()
        if not cols or self._applying:
            return
        want = [self.columnWidth(c) if c in self._pinned
                else max(self.MIN_W,
                         min(self.MAX_W, self._content_width(c) + self.PAD))
                for c in range(cols)]
        free = [c for c in range(cols) if c not in self._pinned]
        slack = self.viewport().width() - sum(want)
        # Named wide columns take the slack; if this table names none, the
        # widest free column does, so no table is left with a ragged edge.
        take = [c for c in free if self._names[c] in self.WIDE]
        if not take and free:
            take = [max(free, key=lambda c: want[c])]
        if slack and take:
            if slack < 0:                    # too narrow: squeeze widest first
                take.sort(key=lambda c: -want[c])
            share, rem = divmod(abs(slack), len(take))
            for i, c in enumerate(take):
                d = share + (1 if i < rem else 0)
                want[c] = max(self.MIN_W,
                              want[c] + (d if slack > 0 else -d))
        self._applying = True
        try:
            for c, w in enumerate(want):
                if self.columnWidth(c) != w:
                    self.setColumnWidth(c, w)
        finally:
            self._applying = False


# How a compat verdict looks in a list: a glyph you can scan a column for,
# not a word you have to read.  Order is worst-to-best for _best_verdict().
VERDICT_MARK = {"works": ("✓", "#2ecc71"), "issues": ("!", "#f39c12"),
                "broken": ("✗", "#e74c3c")}
_best_verdict = lib.best_verdict          # the ranking rule, Qt-free


_VERDICT_WORD = {"works": "works", "issues": "has issues", "broken": "broken"}


def _verdict_item(status, verdicts=None) -> QTableWidgetItem:
    """The tick column.  A verdict of your own is shown filled; one that
    only comes from the online database is shown in outline, because "I
    tested this" and "someone says" are not the same claim."""
    mark, color = VERDICT_MARK.get(status, ("", None))
    mine = any(isinstance(v, lib.Verdict) and v.status == status and v.yours
               for v in (verdicts or {}).values())
    clash = lib.any_disagreement(verdicts or {})
    it = QTableWidgetItem(("≠" if clash else mark) if mark else "")
    it.setTextAlignment(Qt.AlignCenter)
    if not mark:
        return it
    it.setForeground(QColor("#8e44ad" if clash else color))
    if not mine and not clash:
        f = it.font()
        f.setItalic(True)                      # not yours — someone else's
        it.setFont(f)
    it.setToolTip(_verdict_tip(verdicts or {}))
    return it


def _verdict_tip(verdicts: dict) -> str:
    lines = []
    for m, v in sorted(verdicts.items()):
        if not isinstance(v, lib.Verdict):
            continue
        if v.disagrees:
            lines.append(f"{m}: YOU say {_VERDICT_WORD[v.yours]}, the online "
                         f"database says {_VERDICT_WORD[v.online]}")
        elif v.yours:
            lines.append(f"{m}: {_VERDICT_WORD[v.yours]} — your own result")
        elif v.online:
            lines.append(f"{m}: {_VERDICT_WORD[v.online]} — from the online "
                         "database")
    return "\n".join(lines)


def _tested_on_text(verdicts: dict) -> str:
    """The 'tested on' column: machine, verdict, and whose verdict it is."""
    bits = []
    for m, v in sorted(verdicts.items()):
        if not isinstance(v, lib.Verdict):
            continue
        if v.disagrees:
            bits.append(f"{m} {VERDICT_MARK[v.yours][0]} yours ≠ "
                        f"{VERDICT_MARK[v.online][0]} online")
        elif v.yours:
            bits.append(f"{m} {VERDICT_MARK[v.yours][0]} yours")
        elif v.online:
            bits.append(f"{m} {VERDICT_MARK[v.online][0]} online")
    return "   ".join(bits)


# A game with a picture, in one column-scannable glyph.  Beside the verdict
# tick rather than a thumbnail per row: at four thousand games a thumbnail
# column is four thousand files read to draw twenty rows.
SHOT_MARK = "🖼"


# A game no fastload path can serve.  Written out rather than a glyph: it is
# the name of the drive mode the user has to pick, and half the point of the
# flag is that it tells them which one.
REAL1541_MARK = "1541 only"


def _shot_item(has: bool) -> QTableWidgetItem:
    it = QTableWidgetItem(SHOT_MARK if has else "")
    it.setTextAlignment(Qt.AlignCenter)
    it.setToolTip("somebody has uploaded a screenshot of this game"
                  if has else "no screenshot yet — pick this game and press "
                              "\"Add screenshot…\" or \"Grab from board\"")
    return it


# The board runs one machine and, on it, one game: the bitstream it booted
# and the file the BIOS last started there.  Both lists say so the same way —
# a mark you can scan the column for, in the same green as a working verdict.
ACTIVE_MARK = "● active"
ACTIVE_COLOR = "#2ecc71"


def _paint_active(table, row: int, tip: str):
    """Make one row read as the live one: the mark coloured, the whole row
    bold.  Colour alone is not enough — the mark column is narrow and a green
    dot at the far right of a forty-row list is easy to miss."""
    for c in range(table.columnCount()):
        it = table.item(row, c)
        if it is None:
            continue
        f = it.font()
        f.setBold(True)
        it.setFont(f)
        it.setForeground(QColor(ACTIVE_COLOR))
        it.setToolTip(tip)


def _status_color(state: str) -> QColor:
    return {
        ST_ONLINE: QColor("#2ecc71"),
        ST_CONNECTING: QColor("#f39c12"),
        ST_OFFLINE: QColor("#e74c3c"),
        ST_DISCONNECTED: QColor("#7f8c8d"),
    }.get(state, QColor("#7f8c8d"))


# ── sending your results back to the project ───────────────────────────────
class LoginDialog(QDialog):
    """Sign in with the account the user already has on fpgago.com.

    Nothing in the app needs this to read the game database; it is asked for
    only when somebody wants to send something back.  The password is used
    once, traded for a token, and never stored.
    """

    def __init__(self, parent):
        super().__init__(parent)
        self.setWindowTitle("Sign in to fpgago.com")
        self.setMinimumWidth(420)

        root = QVBoxLayout(self)
        head = QLabel(
            "Use the same username and password you registered with on "
            "<b>fpgago.com</b>. Signing in lets you send your test results, "
            "game settings and screenshots back — everything else in the app "
            "works without an account.")
        head.setWordWrap(True)
        root.addWidget(head)

        form = QFormLayout()
        self._user = QLineEdit()
        self._pass = QLineEdit()
        self._pass.setEchoMode(QLineEdit.Password)
        form.addRow("Username", self._user)
        form.addRow("Password", self._pass)
        root.addLayout(form)

        note = QLabel(f"<small>server: {lib.webdb.base_url()}</small>")
        note.setStyleSheet("color:#888;")
        root.addWidget(note)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Ok).setText("Sign in")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)
        self._ok = buttons.button(QDialogButtonBox.Ok)
        self._ok.setEnabled(False)
        for field in (self._user, self._pass):
            field.textChanged.connect(self._validate)
        self._user.setFocus()

    def _validate(self):
        self._ok.setEnabled(bool(self._user.text().strip()
                                 and self._pass.text()))

    def username(self) -> str:
        return self._user.text().strip()

    def password(self) -> str:
        return self._pass.text()


class ShareDialog(QDialog):
    """Offer every way of sending test results that does not involve git.

    The database is a git-tracked file, which is fine for the project and
    useless for a person who tested three games tonight: "fork, commit, open
    a PR" is where their evening ends.  So the app keeps their reports in a
    local file and this dialog hands them to GitHub — through the `gh` CLI
    if it is there, through a pre-filled issue in the browser otherwise —
    or just gives them the text to send however they like.

    The list of routes comes from library/share.py, so what is offered
    depends on what is actually installed.
    """

    def __init__(self, parent, info: dict):
        super().__init__(parent)
        self.setWindowTitle("Share your test results")
        self.setMinimumWidth(620)
        self.chosen = None
        self._info = info

        root = QVBoxLayout(self)
        n = info["n"]
        head = QLabel(
            f"<b>{n} test result{'s' if n != 1 else ''}</b> ready to send to "
            f"<b>{info['repo']}</b>. This is how other people find out which "
            "games work — and your start-up key sequences come with it, so "
            "nobody has to work them out twice.")
        head.setWordWrap(True)
        root.addWidget(head)

        prev = QPlainTextEdit(info["text"])
        prev.setReadOnly(True)
        prev.setStyleSheet("font-family:monospace; font-size:11px;")
        prev.setMinimumHeight(220)
        root.addWidget(prev)

        for route in info["routes"]:
            b = QPushButton(route["label"])
            b.setToolTip(route["hint"])
            b.clicked.connect(lambda _c=False, k=route["key"]: self._pick(k))
            row = QHBoxLayout()
            row.addWidget(b)
            hint = QLabel(f"<i>{route['hint']}</i>")
            hint.setStyleSheet("color:#666; font-size:11px;")
            hint.setWordWrap(True)
            row.addWidget(hint, 1)
            root.addLayout(row)

        bb = QDialogButtonBox(QDialogButtonBox.Close)
        bb.rejected.connect(self.reject)
        root.addWidget(bb)

    def _pick(self, key):
        self.chosen = key
        self.accept()


class GrabPreviewDialog(QDialog):
    """What the board just showed, before it becomes everybody's picture of
    this game.  A screenshot upload replaces the current one for every user
    syncing the database, so the grab gets looked at first."""

    def __init__(self, img: QImage, label: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"Screenshot for {label}")
        root = QVBoxLayout(self)

        view = QLabel()
        view.setAlignment(Qt.AlignCenter)
        view.setStyleSheet("background:#202020;")
        pm = QPixmap.fromImage(img)
        if img.width() <= 400:          # pixel-double for a look at it
            pm = pm.scaled(img.width() * 2, img.height() * 2,
                           Qt.KeepAspectRatio, Qt.FastTransformation)
        view.setPixmap(pm)
        root.addWidget(view, 1)

        what = QLabel(f"{img.width()}×{img.height()} PNG — uploading it "
                      f"makes it the picture everyone sees for {label}.")
        what.setStyleSheet("color:#888; font-size:11px;")
        what.setWordWrap(True)
        root.addWidget(what)

        bb = QDialogButtonBox(QDialogButtonBox.Cancel)
        up = bb.addButton("Upload", QDialogButtonBox.AcceptRole)
        up.setDefault(True)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        root.addWidget(bb)


# ── Library tab ─────────────────────────────────────────────────────────────
class LibraryPanel(QWidget):
    SIGNED_OUT = ("Not signed in — reading the database needs no account, "
                  "but screenshots and test results can only be sent with "
                  "one.")
    _SHOT_TIP = ("Upload a picture of this game for everyone — needs you to "
                 "be signed in to fpgago.com.")
    _GRAB_TIP = ("Take a picture of what the board is showing right now and "
                 "use it as this game's screenshot — the Commodore screen "
                 "itself, not the whole 800×480 panel.")
    # Two pictures, two questions.  The game's picture answers "is this the
    # game I mean?", so it has to be the same for every release under the ID
    # and it is the only one this list shows.  A crack intro answers "which
    # crack is this?" — it belongs to one release, and using it in the list
    # would make one game look like a dozen different ones.
    _INTRO_TIP = ("Show and upload the CRACK INTRO of the release selected "
                  "below, instead of the picture that stands for the game.\n"
                  "The game's picture is what the list shows for every "
                  "release of it; an intro belongs to one release only.")
    _MP_TIP = ("This game can be played by two or more players.\n"
               "Ticking it records that in the shared database for everyone "
               "— it needs a game the database knows, and you signed in to "
               "fpgago.com.")

    def __init__(self, mgr, pool: QThreadPool, board_panel=None):
        super().__init__()
        self.mgr = mgr
        self.ops = board.BoardOps(mgr)
        self.pool = pool
        # Sending a game writes a file to the board's flash; the Board tab is
        # showing the listing from before that, so it gets re-read here.
        self.board_panel = board_panel
        self._games = []
        self._variants = []
        self._settings_row = None
        self._grab = ShotSession(mgr, pool, self)
        self._grab_canon = None
        self._grab_sub = None
        self._grab_platform = None
        # Which release the screenshot pane is aimed at: None = the game
        # itself, the picture everybody's list shows for every release of it.
        self._shot_sub = None

        # Auto-sync state.  Both halves report into the one red notice at the
        # top: results this machine could not send, and a database it could
        # not refresh.
        self._pending = 0            # reports stuck on this computer
        self._share_why = ""
        self._sync_ok = True
        self._sync_why = ""
        self._auto_timer = None
        self._sharing = False
        self._after_refresh = []     # callbacks waiting on the running sync
        self._restore_id = None      # game to re-select after a background sync

        root = QVBoxLayout(self)
        # The tab is a list you scan and a list you pick from; every pixel of
        # chrome above them is a row of games you cannot see.
        root.setContentsMargins(6, 4, 6, 4)
        root.setSpacing(4)

        # Signing in is only ever needed to send something back — but finding
        # that out at the bottom of the tab, after grabbing a screenshot or
        # recording five verdicts, is finding it out too late.  So while
        # nobody is signed in the invitation is the first thing on the tab and
        # is red; once signed in it disappears and the quiet button in the
        # action row is all that is left.
        self.login_bar = QWidget()
        lrow = QHBoxLayout(self.login_bar)
        lrow.setContentsMargins(0, 0, 0, 4)
        self.login_btn = QPushButton("Log in to fpgago.com…")
        self.login_btn.setStyleSheet(
            "QPushButton { background:#e74c3c; color:white; font-weight:bold;"
            " border:none; border-radius:4px; padding:6px 16px; }"
            "QPushButton:hover { background:#ff6b5b; }")
        self.login_btn.clicked.connect(self.do_account)
        self.login_lbl = QLabel(self.SIGNED_OUT)
        self.login_lbl.setStyleSheet("color:#e74c3c; font-weight:bold;")
        self.login_lbl.setWordWrap(True)
        lrow.addWidget(self.login_btn)
        lrow.addWidget(self.login_lbl, 1)
        # Hidden until the account check comes back: a signed-in user must not
        # see a red "not signed in" bar flash on every start.
        self.login_bar.setVisible(False)
        root.addWidget(self.login_bar)

        # The one thing this tab must never hide: a result that did not get
        # out, or a database that could not be refreshed.  Both happen behind
        # the user's back now, so the only honest place for the failure is a
        # red bar at the top — and it is only ever on screen when something
        # is actually wrong, so it costs no space the rest of the time.
        self.alert_bar = QFrame()
        self.alert_bar.setStyleSheet(
            "QFrame { background:#c0392b; border-radius:4px; }"
            "QLabel { color:white; font-weight:bold; }")
        abar = QHBoxLayout(self.alert_bar)
        abar.setContentsMargins(8, 5, 8, 5)
        self.alert_lbl = QLabel("")
        self.alert_lbl.setWordWrap(True)
        abar.addWidget(self.alert_lbl, 1)
        self.alert_btn = QPushButton("Try again now")
        self.alert_btn.setToolTip(
            "Send the results again and re-read the database from "
            "fpgago.com.")
        self.alert_btn.clicked.connect(self.do_sync_now)
        abar.addWidget(self.alert_btn)
        self.alert_bar.setVisible(False)
        root.addWidget(self.alert_bar)

        # Search row.
        srow = QHBoxLayout()
        self.query = QLineEdit()
        self.query.setPlaceholderText("Search title…")
        self.query.returnPressed.connect(self.do_search)
        self.plat = QComboBox()
        for p in PLATFORMS:
            self.plat.addItem(p or "all", p)
        self.tested = QComboBox()
        for label, val in (("any", None), ("✓ works", "works"),
                           ("! has issues", "issues"), ("✗ broken", "broken"),
                           ("not tested yet", "untested"),
                           ("≠ yours differs from online", "conflict")):
            self.tested.addItem(label, val)
        self.tested.setToolTip(
            "Filter by verdict: only games known to work, only the broken "
            "ones, the ones nobody has tried — or the ones where your own "
            "result and the online database disagree.")
        self.tested.currentIndexChanged.connect(self.do_search)
        # "Has somebody put a picture on this yet?" is the question behind
        # both directions: find the games worth looking at, and find the ones
        # still missing a screenshot so you can take one.
        self.pic = QComboBox()
        for label, val in (("any", None), (f"{SHOT_MARK} has one", True),
                           ("still missing", False)):
            self.pic.addItem(label, val)
        self.pic.setToolTip(
            "Filter by screenshot: only games that already have a picture, "
            "or only the ones still waiting for somebody to take one.")
        self.pic.currentIndexChanged.connect(self.do_search)
        # EasyFlash is a c64 cartridge (retro-arch/c64/README.md), so the
        # box is only live when a platform that has a cartridge port (or
        # "all") is selected rather than quietly filtering everything away.
        self.easyflash = QCheckBox("EasyFlash")
        self.easyflash.setToolTip(
            "Only cartridge releases — the .crt images the c64 core boots "
            "straight from its cartridge port, no disc and no loader.")
        self.easyflash.stateChanged.connect(self.do_search)
        # The other Commodore-only question, and the one a tester asks most
        # often: which games did somebody find that ONLY the real drive runs?
        self.real1541 = QCheckBox("Real 1541")
        self.real1541.setToolTip(
            "Only games flagged as needing the cycle-accurate 1541 — no "
            "fastload path works for them, so the drive mode has to be the "
            "slow real one.\n"
            "The flag is set when a result is recorded (Settings… → \"Needs "
            "the real 1541\").")
        self.real1541.stateChanged.connect(self.do_search)
        # Not gated on a platform like the two above: "can two people play
        # this?" is a question every machine here can be asked.
        self.multi = QCheckBox("Multiplayer")
        self.multi.setToolTip(
            "Only games ticked as multiplayer in the shared database.\n"
            "The tick itself lives under the screenshot pane — select a "
            "game to set or clear it.")
        self.multi.stateChanged.connect(self.do_search)
        self.plat.currentIndexChanged.connect(self._sync_easyflash)
        self._sync_easyflash()
        search_btn = QPushButton("Search")
        search_btn.clicked.connect(self.do_search)
        srow.addWidget(QLabel("Query:"))
        srow.addWidget(self.query, 1)
        srow.addWidget(QLabel("Platform:"))
        srow.addWidget(self.plat)
        srow.addWidget(QLabel("Tested:"))
        srow.addWidget(self.tested)
        srow.addWidget(QLabel("Picture:"))
        srow.addWidget(self.pic)
        srow.addWidget(self.easyflash)
        srow.addWidget(self.real1541)
        srow.addWidget(self.multi)
        srow.addWidget(search_btn)
        root.addLayout(srow)

        # Games | Variants split.
        split = QSplitter(Qt.Vertical)
        # The ID is on the row because the search can now match it: type
        # "1942" and one of the answers is whatever game #1942 turned out to
        # be, which without its ID on screen looks like the list went wrong.
        self.games_tbl = self._make_table(
            ["", SHOT_MARK, "ID", "title", "platforms", "tested on",
             "variants", "year"])
        self.games_tbl.setToolTip(
            "ID is this game's canonical number — what a test result quotes "
            "and what the file on the board is named after. Typing one in "
            "the search box finds that game.")
        self.games_tbl.itemSelectionChanged.connect(self._on_game_selected)
        # One picture beside the list rather than a thumbnail per row: at four
        # thousand games a per-row image is thousands of files loaded to show
        # twenty, and the question it answers ("is this the game I mean?") is
        # only ever asked about the row you are on.
        self.shot = QLabel("no screenshot")
        self.shot.setAlignment(Qt.AlignCenter)
        self.shot.setMinimumWidth(240)
        self.shot.setStyleSheet(
            "color:#888; font-size:11px; border:1px solid #333;")
        self.shot_btn = QPushButton("Add screenshot…")
        self.shot_btn.setToolTip(self._SHOT_TIP)
        self.shot_btn.clicked.connect(self.do_upload_shot)
        # The same upload, from the board instead of a file: grab what the
        # machine is showing right now, crop the panel down to the machine's
        # own screen, and offer that as the game's picture.
        self.grab_btn = QPushButton("Grab from board")
        self.grab_btn.setToolTip(self._GRAB_TIP)
        self.grab_btn.clicked.connect(self.do_grab_shot)
        # One pane, one picture — going down a list of four thousand games,
        # two images side by side is one image too many.  So the pane has a
        # target instead: the game, or the crack intro of the release
        # selected below, and both buttons follow it.
        self.intro_chk = QCheckBox("crack intro of the selected release")
        self.intro_chk.setToolTip(self._INTRO_TIP)
        self.intro_chk.stateChanged.connect(self._on_intro_toggled)
        shot_box = QWidget()
        shot_lay = QVBoxLayout(shot_box)
        shot_lay.setContentsMargins(0, 0, 0, 0)
        shot_lay.addWidget(self.shot, 1)
        shot_lay.addWidget(self.intro_chk)
        shot_btns = QHBoxLayout()
        shot_btns.setContentsMargins(0, 0, 0, 0)
        shot_btns.addWidget(self.shot_btn)
        shot_btns.addWidget(self.grab_btn)
        shot_lay.addLayout(shot_btns)
        # A fact about the game, kept in the shared database exactly like
        # its screenshot: tick it here and everybody's next Refresh gets it.
        # `clicked` and not stateChanged, because the box is also SET by code
        # when a row is selected — only the user's own click may talk to the
        # server.
        self.mp_chk = QCheckBox("multiplayer game (2+ players)")
        self.mp_chk.setToolTip(self._MP_TIP)
        self.mp_chk.setEnabled(False)
        self.mp_chk.clicked.connect(self.do_set_multiplayer)
        shot_lay.addWidget(self.mp_chk)

        gsplit = QSplitter(Qt.Horizontal)
        # The box title carries what used to be two whole rows of chrome
        # above the tab (the database path and a "games N variants N" line
        # with a Refresh-stats button beside it).  It is the same sentence,
        # said where there was already room for it.
        self.games_box = self._wrap("Games", self.games_tbl)
        self.games_box.setToolTip(f"database: {lib.db_info()['db']}")
        gsplit.addWidget(self.games_box)
        gsplit.addWidget(self._wrap("Screenshot", shot_box))
        gsplit.setStretchFactor(0, 3)
        gsplit.setStretchFactor(1, 1)
        split.addWidget(gsplit)

        # The ID column is what makes a test result reportable: it is the
        # name the compat database and the CLI use for this exact release.
        self.var_tbl = self._make_table(
            ["", SHOT_MARK, "ID", "release", "platform", "group", "source",
             "fmt", "files", "settings", "url"])
        self.var_tbl.setToolTip(
            "ID is the canonical game ID of this release (#1234-K/2) — quote "
            "it when you record a test result, and look for its digits in "
            "the file name on the board (…-1234.2.d64).\n"
            "release is who made this dump (cr Bandit, h Angels) — the one "
            f"thing that tells a dozen cracks of the same game apart.\n"
            f"{SHOT_MARK} marks the releases whose crack intro somebody has "
            f"already uploaded.")
        self.var_tbl.itemSelectionChanged.connect(self._on_variant_selected)

        # Every button and the log live in a second column beside the
        # variants list, the same shape the Games row already has with its
        # screenshot pane.  Full width for a list is worth more than full
        # width for a row of buttons, and the two rows of buttons plus a
        # fixed 140px log that used to sit under the splitter were 200-odd
        # pixels taken off both lists at once.
        self.download_btn = QPushButton("Download")
        self.download_btn.clicked.connect(self.do_download)
        self.settings_btn = QPushButton("Settings…")
        self.settings_btn.setToolTip(
            "Per-game settings for this game (drive mode, CPU speed, "
            "buttons, start-up keys) — stored in the game library and "
            "pushed to the board with the game.\n"
            "Your verdict goes to fpgago.com by itself as soon as you save "
            "it.")
        self.settings_btn.clicked.connect(self.do_settings)
        self.send_btn = QPushButton("Send to board")
        self.send_btn.setToolTip(
            "Download it if needed, upload it to the board flash, and write "
            "its settings — in one click.")
        self.send_btn.clicked.connect(lambda: self.do_send(run=False))
        self.play_btn = QPushButton("Send && play ▶")
        self.play_btn.setToolTip("Same, then mount and start the game.")
        self.play_btn.clicked.connect(lambda: self.do_send(run=True))
        # Kept, but no longer the way results get out: the database syncs
        # itself.  This is the manual nudge for someone watching it happen.
        self.refresh_btn = QPushButton("Sync now")
        self.refresh_btn.setToolTip(
            "Send anything still queued and re-read the game database from "
            "fpgago.com.\n"
            "This happens by itself — every "
            f"{AUTO_SYNC_MS // 60000} minutes and after anything you "
            "change — so it is here for impatience, not for housekeeping.")
        self.refresh_btn.clicked.connect(self.do_sync_now)
        # The escape hatch for a machine with no account: GitHub, the
        # clipboard, a file.  The web route runs by itself.
        self.share_btn = QPushButton("Share my results…")
        self.share_btn.setToolTip(
            "Another way out for the results still queued — a GitHub issue, "
            "the clipboard or a file.\n"
            "With an account they go to fpgago.com on their own.")
        self.share_btn.clicked.connect(self.do_share)
        # Who you are, and the way out.  Hidden while logged out, when the
        # red bar at the top is the one asking.
        self.account_btn = QPushButton("Log in…")
        self.account_btn.clicked.connect(self.do_account)
        self.account_btn.setVisible(False)

        side = QWidget()
        slay = QVBoxLayout(side)
        slay.setContentsMargins(0, 0, 0, 0)
        slay.setSpacing(4)
        acts = QGridLayout()
        acts.setContentsMargins(0, 0, 0, 0)
        acts.setSpacing(4)
        lib_btns = []
        for text, cb in [("Import files…", self.do_import),
                         ("Index folder…", self.do_index),
                         ("Sources", self.do_sources)]:
            b = QPushButton(text)
            b.clicked.connect(cb)
            lib_btns.append(b)
        rows = [(self.settings_btn, self.download_btn),
                (self.send_btn, self.play_btn),
                (lib_btns[0], lib_btns[1]),
                (lib_btns[2], self.refresh_btn),
                (self.share_btn, self.account_btn)]
        for r, (a, b) in enumerate(rows):
            acts.addWidget(a, r, 0)
            if b is not None:
                acts.addWidget(b, r, 1)
        slay.addLayout(acts)
        # What the app is doing, under the buttons that ask for it — and
        # free to grow now that it is not stealing height from two lists.
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(1000)
        self.log.setMinimumHeight(80)
        self.log.setStyleSheet("font-family:monospace; font-size:12px;")
        slay.addWidget(self.log, 1)

        vsplit = QSplitter(Qt.Horizontal)
        vsplit.addWidget(self._wrap("Variants", self.var_tbl))
        vsplit.addWidget(self._wrap("Actions", side))
        vsplit.setStretchFactor(0, 3)
        vsplit.setStretchFactor(1, 1)
        self.var_tbl.itemDoubleClicked.connect(lambda _i: self.do_settings())
        split.addWidget(vsplit)
        # Half the height each, rather than whatever the two lists' size
        # hints happen to add up to — both are lists you scroll, and neither
        # deserves to open three rows tall.
        split.setStretchFactor(0, 1)
        split.setStretchFactor(1, 1)
        split.setSizes([500, 500])
        root.addWidget(split, 1)

        self._grab.updated.connect(self._on_grab_line)
        self._grab.finished.connect(self._on_grab_done)
        self._grab.failed.connect(self._on_grab_failed)

        self._show_shot(None)      # nothing selected yet: no screenshot target
        self.refresh_stats()
        self._refresh_share()
        self._refresh_account()

    # -- keeping in step with fpgago.com, without being asked ----------------
    # Two different things travel, and the user is told about neither unless
    # it fails:
    #   * OUT — the verdicts and settings this machine recorded.  They are
    #     worth nothing in `compat-local.jsonl`; a local pile of them is the
    #     failure mode, not the feature.
    #   * IN  — the catalog, everyone else's verdicts, the screenshots.
    # Anything the user changes (a verdict, a screenshot, a multiplayer tick)
    # syncs straight away, because that is the moment their copy and the
    # server's disagree; the timer is for everything somebody *else* changed.

    def start_auto_sync(self):
        """Begin syncing by itself.  Called by the window, not by __init__,
        so a test that builds a panel does not start hitting the network."""
        if self._auto_timer is not None:
            return
        self._auto_timer = QTimer(self)
        self._auto_timer.setInterval(AUTO_SYNC_MS)
        self._auto_timer.timeout.connect(self._auto_tick)
        self._auto_timer.start()
        QTimer.singleShot(FIRST_SYNC_MS, self._auto_tick)

    def _auto_tick(self):
        self._auto_share()
        self.do_refresh(auto=True)

    def do_sync_now(self):
        """The manual nudge — the same work the timer does, said out loud."""
        self._msg("syncing with fpgago.com…")
        self._auto_share(loud=True)
        self.do_refresh()

    def _auto_share(self, loud: bool = False):
        """Push the queued test results.  Never blocks and never pops up:
        the answer lands in the red notice (or, when there is nothing wrong,
        nowhere at all)."""
        if getattr(self, "_sharing", False):
            return
        self._sharing = True
        self._run(lib.auto_share,
                  on_done=lambda res: self._auto_shared(res, loud),
                  on_error=self._auto_share_failed)

    def _auto_shared(self, res, loud=False):
        self._sharing = False
        self._pending = res.get("pending", 0)
        self._share_why = res.get("why", "")
        if res.get("sent"):
            self._msg(f"sent {res['sent']} test result(s) to fpgago.com")
            # Our own report is part of the database now; bring the merged
            # answer back so the ticks say "online" like everybody else's.
            self.do_refresh(auto=True)
        elif loud and not self._pending:
            self._msg("nothing queued — everything you recorded is already "
                      "on fpgago.com")
        self._refresh_share()

    def _auto_share_failed(self, tb):
        """lib.auto_share swallows its own failures, so reaching here means
        the call itself broke — still not a dialog, still the red bar."""
        self._sharing = False
        self._share_why = tb.strip().splitlines()[-1].split(": ", 1)[-1]
        self._pending = self._pending or 1
        self._update_alert()

    def _update_alert(self):
        """One red bar, everything that did not get through."""
        lines = []
        if self._pending:
            what = ("test result" if self._pending == 1 else "test results")
            lines.append(
                f"⚠ {self._pending} {what} still on this computer — NOT sent "
                f"to fpgago.com"
                + (f": {self._share_why}" if self._share_why else "."))
        if not self._sync_ok:
            lines.append("⚠ could not read the game database from "
                         f"{lib.webdb.base_url()}"
                         + (f": {self._sync_why}" if self._sync_why else "")
                         + " — you are looking at your last copy.")
        self.alert_lbl.setText("\n".join(lines))
        self.alert_bar.setVisible(bool(lines))

    # -- helpers ------------------------------------------------------------
    def _make_table(self, headers):
        return ResponsiveTable(headers)

    def _wrap(self, title, w):
        box = QGroupBox(title)
        lay = QVBoxLayout(box)
        lay.setContentsMargins(6, 6, 6, 6)
        lay.addWidget(w)
        return box

    def _msg(self, text):
        self.log.appendPlainText(text)

    def _run(self, fn, *args, on_done=None, on_error=None,
             wants_progress=False, **kwargs):
        # on_error is named here, not left to **kwargs: without it a caller
        # that wanted its own failure handler passed one to `fn` instead, and
        # the call died as "login() got an unexpected keyword argument
        # 'on_error'" — a TypeError blamed on the library function.
        task = Task(fn, *args, wants_progress=wants_progress, **kwargs)
        start_task(
            self.pool, task,
            on_done=on_done or (lambda r: self._msg(str(r))),
            on_error=on_error or (lambda tb: self._msg(
                "ERROR:\n" + tb.strip().splitlines()[-1])),
            on_progress=self._msg)

    def _fill(self, table, rows, cols):
        table.setRowCount(0)
        for r in rows:
            i = table.rowCount()
            table.insertRow(i)
            for c, key in enumerate(cols):
                val = key(r) if callable(key) else r.get(key)
                table.setItem(i, c, QTableWidgetItem("" if val is None else str(val)))

    # -- stats --------------------------------------------------------------
    def refresh_stats(self):
        self._run(lib.stats, on_done=self._show_stats)

    def _show_stats(self, s):
        by = "  ".join(f"{p}:{n}" for p, n in sorted(s["by_platform"].items()))
        self.games_box.setTitle(
            f"Games — {s['games']} games, {s['variants']} releases, "
            f"{s['files']} file(s) here")
        self.games_box.setToolTip(
            f"{by}\ndatabase: {lib.db_info()['db']}")

    # -- search -------------------------------------------------------------
    def do_search(self):
        """Search the local copy of the database, which is the whole of it.

        There used to be a second pass over the network here, because the
        catalog was only ever as complete as what this machine had happened
        to search for.  Refresh brings down everything now, so searching is
        instant and works on a train."""
        self._run(lib.search, self.query.text().strip(),
                  self.plat.currentData() or None, self.tested.currentData(),
                  self.pic.currentData(),
                  self.easyflash.isEnabled() and self.easyflash.isChecked(),
                  self.real1541.isEnabled() and self.real1541.isChecked(),
                  self.multi.isChecked(),
                  on_done=self._show_games)

    # Column layout of the games table, by name — two mark columns in front
    # of the text ones, and every writer says which it means.
    C_VERDICT, C_SHOT, C_ID, C_TITLE, C_PLAT, C_TESTED = 0, 1, 2, 3, 4, 5

    def _show_games(self, rows):
        self._games = rows
        t = self.games_tbl
        t.setRowCount(0)
        for r in rows:
            i = t.rowCount()
            t.insertRow(i)
            for c, val in enumerate([
                    r.get("title"), r.get("platforms"), "",
                    r.get("n_variants"), r.get("year")], start=self.C_TITLE):
                t.setItem(i, c, QTableWidgetItem(
                    "" if val is None else str(val)))
            t.setItem(i, self.C_SHOT, _shot_item(bool(r.get("has_shot"))))
            idc = QTableWidgetItem(lib.canon_label(r.get("canon_id")))
            if r.get("by_id"):
                # It is in the list because its NUMBER matched, not its
                # title.  Unexplained, that row reads as a broken search.
                f = idc.font()
                f.setBold(True)
                idc.setFont(f)
                idc.setForeground(QColor("#8e44ad"))
                idc.setToolTip("matched by this ID, not by its title")
            t.setItem(i, self.C_ID, idc)
            self._paint_verdict(i, r.get("verdicts") or {},
                                bool(r.get("real1541")))
        self.var_tbl.setRowCount(0)
        self._msg(f"{len(rows)} game(s)")
        for r in rows:
            if r.get("by_id"):
                self._msg(f"  {lib.canon_label(r.get('canon_id'))} "
                          f"\"{r.get('title')}\" — the game with that ID, "
                          "listed first")
        # A background sync re-ran this search under the user's cursor; put
        # the cursor back on the game it was on.
        keep = getattr(self, "_restore_id", None)
        self._restore_id = None
        if keep is not None:
            for i, r in enumerate(rows):
                if r.get("id") == keep:
                    t.selectRow(i)
                    return
        by_id = self.query.text().strip().startswith("#")
        # Searching by ID means "show me this one" — so land on it, and on the
        # release the "/n" named, rather than making the user click the single
        # row they just asked for by name.
        self._want_sub = rows[0].get("want_sub") if len(rows) == 1 else None
        if by_id and len(rows) == 1:
            t.selectRow(0)                     # fires _on_game_selected
            return
        if by_id and not rows:
            self._msg(f"no game with ID {self.query.text().strip()} in the "
                      "local database — press \"Sync now\" to fetch it "
                      "straight away, or check the number")
        self._show_shot(None)                  # nothing selected: no target

    def _paint_verdict(self, row: int, verdicts: dict, real1541: bool = False):
        """The tick column plus the 'tested on' column for one game row."""
        self.games_tbl.setItem(
            row, self.C_VERDICT, _verdict_item(_best_verdict(verdicts),
                                               verdicts))
        text = _tested_on_text(verdicts)
        if real1541:
            # Where somebody scanning the list will actually see it: this is
            # the column that already says what the game does on a machine,
            # and "only on the real drive" is part of that answer.
            text = (text + "   " if text else "") + REAL1541_MARK
        cell = QTableWidgetItem(text)
        tips = [_verdict_tip(verdicts)] if lib.any_disagreement(verdicts) else []
        if lib.any_disagreement(verdicts):
            cell.setForeground(QColor("#8e44ad"))
        if real1541:
            tips.append("no fastload path works — this game needs the "
                        "cycle-accurate 1541")
        if tips:
            cell.setToolTip("\n".join(tips))
        self.games_tbl.setItem(row, self.C_TESTED, cell)

    def _sync_easyflash(self):
        """The cartridge and drive filters only mean something on a machine
        that has a cartridge port and a serial drive."""
        plat = self.plat.currentData() or ""
        on = plat in ("", "c64", "c16", "plus4", "264")
        for box in (self.easyflash, self.real1541):
            box.setEnabled(on)
            if not on and box.isChecked():
                box.setChecked(False)          # fires do_search once

    def _on_game_selected(self):
        r = self.games_tbl.currentRow()
        if r < 0 or r >= len(self._games):
            self._variants = []            # nothing to aim an intro at either
            self._show_shot(None)          # no game = nothing to add one to
            return
        gid = self._games[r]["id"]
        self._show_shot(self._games[r].get("canon_id"))
        self._run(lib.variants, gid, on_done=self._show_variants)

    def _on_variant_selected(self):
        """The pane can be aimed at the selected release's crack intro, so
        moving the cursor in the variants table changes what it shows."""
        self._show_shot(getattr(self, "_shot_canon", None))

    def _on_intro_toggled(self, _state):
        self._show_shot(getattr(self, "_shot_canon", None))

    def _show_shot(self, canon_id):
        """Show the cached picture the pane is aimed at, if the sync brought
        one down: the game's own picture, or — with the box ticked — the crack
        intro of the release selected below.

        Straight off the disk: these are a few kilobytes each and already
        local, so a worker thread would cost more than it saves."""
        self._shot_canon = canon_id
        # Both buttons need a game the shared database knows — so a button
        # you can press and a button that then refuses is one button too
        # many.  Greyed out with the reason in the tooltip instead: with no
        # row selected there is nothing to add a picture TO, and "this game
        # is not in the shared database yet" was being said about no game at
        # all, which reads as a bug in the game you did not select.
        selected = 0 <= self.games_tbl.currentRow() < len(self._games)
        why = ("" if canon_id is not None else
               "pick a game in the list first" if not selected else
               "this game is not in the shared database yet — it arrives with "
               "the next sync")
        self.shot_btn.setEnabled(canon_id is not None)
        self.grab_btn.setEnabled(canon_id is not None
                                 and not self._grab.running)
        if why:
            self.shot_btn.setToolTip(why)
            self.grab_btn.setToolTip(why)
        else:
            self.shot_btn.setToolTip(self._SHOT_TIP)
            self.grab_btn.setToolTip(self._GRAB_TIP)
        # The multiplayer tick follows the same target for the same reason:
        # the flag is filed under the game's canonical ID.
        row = self.games_tbl.currentRow()
        self.mp_chk.setChecked(bool(       # `clicked` does not fire for this
            selected and 0 <= row < len(self._games)
            and self._games[row].get("multiplayer")))
        self.mp_chk.setEnabled(canon_id is not None)
        self.mp_chk.setToolTip(why or self._MP_TIP)
        sub = self._intro_target(canon_id)
        self._shot_sub = sub
        path = lib.screenshot_for(canon_id, sub)
        if not path:
            self.shot.setPixmap(QPixmap())
            self.shot.setText(
                "no crack intro for this release\n\nadd one and everybody\n"
                "syncing gets it" if sub is not None else
                "no screenshot\n\nadd one and everybody\nsyncing gets it"
                if selected else "no game selected")
            return
        pix = QPixmap(path)
        if pix.isNull():
            self.shot.setText("(unreadable image)")
            return
        self.shot.setPixmap(pix.scaled(
            self.shot.width() or 240, 260,
            Qt.KeepAspectRatio, Qt.SmoothTransformation))
        self.shot.setText("")

    def do_set_multiplayer(self, on: bool):
        """The user clicked the multiplayer tick — record it for everyone.

        The server is asked first and the checkbox only keeps its new state
        if the server took it: a tick that silently meant "only on this
        machine" would be a different feature wearing the same checkbox."""
        canon_id = getattr(self, "_shot_canon", None)
        row = self.games_tbl.currentRow()
        if canon_id is None or not (0 <= row < len(self._games)):
            return                          # box is disabled in this state
        if not getattr(self, "_account", None):
            self.mp_chk.setChecked(not on)  # nothing was changed anywhere
            self._msg("sign in first (Log in…) — the multiplayer flag goes "
                      "to everybody, so it needs an account")
            return
        game = self._games[row]
        game["multiplayer"] = on            # optimistic; put back on failure

        def failed(tb):
            game["multiplayer"] = not on
            self.mp_chk.setChecked(not on)
            self._msg("ERROR:\n" + tb.strip().splitlines()[-1])

        def done(res):
            self._msg(res.get("done", "saved"))
            # We just changed the shared database — read it back, so this
            # copy is the one everybody else will get rather than our guess.
            self.do_refresh(auto=True)

        self._run(lib.set_multiplayer, canon_id, on,
                  on_done=done, on_error=failed)

    def _intro_target(self, canon_id):
        """Which release the pane is aimed at, or None for the game itself.

        A crack intro belongs to one release, so it needs a release with an
        ID of its own — a row still showing 'var#12' is not in the shared
        database and cannot be given one."""
        _g, v = self._selected()
        sub = (v or {}).get("canon_sub")
        can = canon_id is not None and sub is not None
        if not can and self.intro_chk.isChecked():
            # Do not re-enter _show_shot through stateChanged: we are in it.
            self.intro_chk.blockSignals(True)
            self.intro_chk.setChecked(False)
            self.intro_chk.blockSignals(False)
        self.intro_chk.setEnabled(can)
        self.intro_chk.setToolTip(
            self._INTRO_TIP if can else
            "pick a release below that has an ID of its own (#1234-K/2) — a "
            "crack intro belongs to one release, not to the game")
        return sub if (can and self.intro_chk.isChecked()) else None

    @staticmethod
    def _shot_label(canon_id, sub) -> str:
        """What a picture is going to be a picture of, said the way the rest
        of the app names it."""
        return (lib.canon_label(canon_id) if sub is None
                else f"the crack intro of "
                     f"{lib.variant_id_str(canon_id, sub, None)}")

    def _shot_target(self):
        """(canon_id, sub) for where a picture would go, or None (with the
        reason said in the log).  `sub` is None for the game's own picture and
        a release number for that release's crack intro.  Both ways in — a
        file and a board grab — need the same two things: a game the shared
        database knows, and an account."""
        canon_id = getattr(self, "_shot_canon", None)
        if canon_id is None:
            self._msg("this game is not in the shared database yet — it "
                      "arrives with the next sync (\"Sync now\" fetches it "
                      "immediately)")
            return None
        if not getattr(self, "_account", None):
            self._msg("sign in first (Log in…) — a screenshot goes to "
                      "everybody, so it needs an account")
            return None
        return canon_id, getattr(self, "_shot_sub", None)

    def do_upload_shot(self):
        target = self._shot_target()
        if target is None:
            return
        canon_id, sub = target
        path, _f = QFileDialog.getOpenFileName(
            self, "Pick a crack intro" if sub is not None
            else "Pick a screenshot", "",
            "Images (*.png *.jpg *.jpeg *.gif *.webp);;All files (*)")
        if not path:
            return
        self._msg(f"uploading {os.path.basename(path)} for "
                  f"{self._shot_label(canon_id, sub)}…")
        self._run(lib.upload_screenshot, canon_id, path, sub,
                  on_done=self._shot_uploaded)

    def _shot_uploaded(self, res):
        self._msg(res.get("done", "uploaded"))
        # Bring our own copy down so the pane shows what everyone else will
        # get, rather than the local file we happened to pick.
        self.do_refresh(auto=True, then=self._after_shot_sync)

    def _after_shot_sync(self):
        canon_id = getattr(self, "_shot_canon", None)
        self._show_shot(canon_id)
        self._mark_intros()
        # The list has to agree with the pane beside it: this game has a
        # picture now, so its column says so without a re-search.  Asked of
        # the disk rather than assumed — an intro upload does NOT give the
        # game a picture, and the column is about the game.
        r = self.games_tbl.currentRow()
        has = lib.screenshot_for(canon_id) is not None
        if 0 <= r < len(self._games) \
                and self._games[r].get("canon_id") == canon_id:
            self._games[r]["has_shot"] = has
            self.games_tbl.setItem(r, self.C_SHOT, _shot_item(has))

    # -- screenshot straight off the board ----------------------------------
    def do_grab_shot(self):
        """Grab the board's screen and offer it as this game's picture.

        The panel is 800×480 but the machine's screen is not: the Commodore
        cores double a 400×240 window of their own raster onto it, of which
        the outer ring is border.  So the grab comes down as the logical
        400×240 frame and is cropped to the display window before it becomes
        a PNG — see shotgrab.crop_active()."""
        target = self._shot_target()
        if target is None:
            return
        canon_id, sub = target
        if self._grab.running:
            self._msg("a grab is already running")
            return
        if not self.mgr.is_open:
            self._msg("connect the board first (Connection tab)")
            return
        g, v = self._selected()
        # All three pinned now: a grab takes a couple of seconds and the
        # selection can move while it runs — the picture must still go to the
        # game (or the release) it was taken for, cropped for the machine it
        # was taken on.
        self._grab_canon = canon_id
        self._grab_sub = sub
        self._grab_platform = ((v or {}).get("platform")
                               or (g or {}).get("platforms"))
        self.grab_btn.setEnabled(False)
        self._msg(f"grabbing the board screen for "
                  f"{self._shot_label(canon_id, sub)}…")
        self.shot.setPixmap(QPixmap())
        self.shot.setText("grabbing…")
        self._grab.start(dense=False)

    def _on_grab_line(self, img, lines, h):
        """Show the frame as it arrives — it takes a couple of seconds, and
        watching it fill in is the only sign the board is answering."""
        self.shot.setText("")
        self.shot.setPixmap(QPixmap.fromImage(img).scaled(
            self.shot.width() or 240, 260,
            Qt.KeepAspectRatio, Qt.FastTransformation))

    def _on_grab_failed(self, why):
        self._msg(f"grab failed: {why}")
        self.grab_btn.setEnabled(True)
        self._show_shot(getattr(self, "_shot_canon", None))

    def _on_grab_done(self, img):
        canon_id = self._grab_canon
        sub = getattr(self, "_grab_sub", None)
        self.grab_btn.setEnabled(True)
        if canon_id is None:
            return
        shot = crop_active(img, self._grab_platform)
        self._msg(f"grabbed {img.width()}×{img.height()} panel → "
                  f"{shot.width()}×{shot.height()} "
                  f"{screen_name(self._grab_platform)}")
        stem = canon_id if sub is None else f"{canon_id}.{sub}"
        path = os.path.join(tempfile.gettempdir(), f"fpgago-grab-{stem}.png")
        if not shot.save(path, "PNG"):
            self._msg(f"could not write {path}")
            return
        dlg = GrabPreviewDialog(shot, self._shot_label(canon_id, sub), self)
        if dlg.exec() != QDialog.Accepted:
            self._msg("grab discarded")
            self._show_shot(getattr(self, "_shot_canon", None))
            return
        self._msg(f"uploading {os.path.basename(path)} "
                  f"({os.path.getsize(path)} bytes)…")
        self._run(lib.upload_screenshot, canon_id, path, sub,
                  on_done=self._shot_uploaded)

    # Column layout of the variants table, mirroring the games list above it:
    # verdict, picture mark, then the identity.
    V_VERDICT, V_INTRO, V_ID, V_RELEASE = 0, 1, 2, 3

    def _mark_intros(self):
        """Say which releases have a crack intro on file.

        One directory listing for the whole table (webdb.intro_subs), not one
        stat per row — the same reason the games list asks once for all four
        thousand of its pictures."""
        have = lib.intro_subs(getattr(self, "_shot_canon", None))
        for i, v in enumerate(self._variants or []):
            if i >= self.var_tbl.rowCount():
                break
            got = v.get("canon_sub") in have
            it = QTableWidgetItem(SHOT_MARK if got else "")
            it.setTextAlignment(Qt.AlignCenter)
            it.setToolTip("somebody has uploaded this release's crack intro"
                          if got else
                          "no crack intro for this release yet — select it, "
                          "tick \"crack intro\" beside the picture above, and "
                          "add one")
            self.var_tbl.setItem(i, self.V_INTRO, it)

    def _show_variants(self, rows):
        self._variants = rows
        t = self.var_tbl
        t.setRowCount(0)
        for v in rows:
            i = t.rowCount()
            t.insertRow(i)
            ver = v.get("verdict")
            t.setItem(i, 0, _verdict_item(
                ver.status if ver is not None else None,
                {v.get("platform"): ver} if ver is not None else {}))
            prof = v.get("profile")
            for c, val in enumerate([
                    v.get("canon"), v.get("release"),
                    v.get("platform"), v.get("group_name"), v.get("source"),
                    v.get("fmt"), v.get("n_files"),
                    gprofile.describe(prof) if prof else "",
                    v.get("source_url")], start=self.V_ID):
                t.setItem(i, c, QTableWidgetItem(
                    "" if val is None else str(val)))
            # A committed correction has something to say about this release
            # — that the source mislabeled it, or that the disk holds two
            # games.  It is worth more than the columns it sits beside, so it
            # marks the row rather than hiding in a note nobody opens.
            note = v.get("note")
            if note:
                for c in range(t.columnCount()):
                    cell = t.item(i, c)
                    if cell is not None:
                        cell.setToolTip(note)
                mark = t.item(i, self.V_RELEASE)
                if mark is not None:
                    mark.setText((mark.text() + "  ⚠").strip())
        self._mark_intros()
        # "#4193-U/5" names a release, not just a game — a compat report
        # quotes it that way, so pasting one into the search must land on it.
        want, self._want_sub = getattr(self, "_want_sub", None), None
        if want is None:
            return
        row = next((i for i, v in enumerate(rows)
                    if v.get("canon_sub") == want), None)
        if row is None:
            self._msg(f"the game has no release /{want} — showing all "
                      f"{len(rows)} of them")
            return
        t.selectRow(row)
        t.scrollToItem(t.item(row, self.V_ID))

    def do_download(self):
        r = self.var_tbl.currentRow()
        if r < 0 or r >= len(self._variants):
            self._msg("select a variant first")
            return
        vid = self._variants[r]["id"]
        self._msg(f"downloading variant #{vid}…")
        self._run(lib.download_variant, vid, wants_progress=True,
                  on_done=self._show_download)

    def _show_download(self, res):
        if "error" in res:
            self._msg(f"  ERROR {res['error']}")
            return
        for got in res.get("downloaded", []):
            self._msg(f"  {got['dest']}  ({got['bytes']} bytes, "
                      f"{got['platform']})")
        # The game's settings came down with it (from the compat database) and
        # will be written to the board by "Send to board".
        if res.get("profile"):
            self._msg(f"  settings: {gprofile.describe(res['profile'])}")
        self.refresh_stats()

    # -- per-game settings ---------------------------------------------------
    def _selected(self):
        """(game row, variant row or None) for whatever is selected."""
        g = v = None
        r = self.games_tbl.currentRow()
        if 0 <= r < len(self._games):
            g = self._games[r]
        r = self.var_tbl.currentRow()
        if 0 <= r < len(self._variants):
            v = self._variants[r]
        return g, v

    def do_settings(self):
        """Edit the settings the library keeps for this game — the ones a
        download brings along and an upload writes to the board."""
        g, v = self._selected()
        if not g:
            self._msg("select a game first")
            return
        if g.get("canon_id") is None:
            self._msg(f"\"{g['title']}\" has no canon ID yet — settings are "
                      "filed under one. Download a release of it (or send one "
                      "to the board) and it gets its ID, then try again.")
            return
        machines = lib.machines_for(
            [v["platform"]] if v else (g.get("platforms") or ""))
        if not machines:
            self._msg("no machine here can carry settings yet — the "
                      "compat database has to learn this platform first "
                      "(library/compat.py MACHINES)")
            return
        canon_id = g["canon_id"]
        sub = v.get("canon_sub") if v else None
        self._settings_row = self.games_tbl.currentRow()

        def look(machine):
            return lib.game_profile(canon_id, machine, sub)

        cur = look(machines[0])
        who = lib.reporter_identity()
        dlg = GameSettingsDialog(
            self, g["title"], cur.get("profile") or "",
            db={"machines": machines, "status": cur.get("status"),
                "notes": cur.get("notes"), "real1541": cur.get("real1541"),
                "by": who.get("by"), "email": who.get("email"),
                "lookup": look})
        if dlg.exec() != QDialog.Accepted:
            return
        blob = dlg.blob()
        self._run(lib.save_game_profile, canon_id, sub, dlg.machine(), blob,
                  dlg.verdict(), dlg.notes() or None, dlg.real1541(),
                  dlg.reviewer() or None, dlg.email(),
                  on_done=self._show_saved)

    def _show_saved(self, res):
        rep = res["report"]
        for w in res.get("warnings", []):
            self._msg(f"  warning: {w}")
        flag = ("  REAL-1541" if rep.get("real1541") else
                "  (real-1541 flag cleared)" if "real1541" in rep else "")
        self._msg(f"saved {rep['id']} {rep['machine']} [{rep['status']}]{flag}: "
                  f"{gprofile.describe(rep.get('profile', ''))}"
                  + (f"\n  notes: {rep['notes']}" if rep.get("notes") else "")
                  + (f"\n  by: {rep['by']} <{rep['email']}>"
                     if rep.get("email") else ""))
        self._refresh_share()
        # The verdict was recorded for everyone, not for this laptop: it
        # leaves now, without being asked to.  If it cannot, the red bar at
        # the top says so — which is the whole of the user's job here.
        self._auto_share()
        # A new verdict changes the ticks — repaint that one row rather than
        # re-running the search, which with an empty query means every game
        # in the catalog.
        r = self._settings_row
        if r is not None and 0 <= r < len(self._games):
            g = self._games[r]
            v = g.setdefault("verdicts", {}).get(rep["machine"])
            if v is None:
                v = lib.Verdict()
                g["verdicts"][rep["machine"]] = v
            v.yours = rep["status"]
            if "real1541" in rep:
                g["real1541"] = bool(rep["real1541"])
            self._paint_verdict(r, g["verdicts"], bool(g.get("real1541")))
        self._on_game_selected()          # and the variant's own tick

    def _refresh_share(self):
        n = len(lib.unshared_reports())
        self._pending = n
        self.share_btn.setText(
            f"Share my results… ({n})" if n else "Share my results…")
        self.share_btn.setEnabled(bool(n))
        self._update_alert()

    # -- sharing -------------------------------------------------------------
    def do_share(self):
        info = lib.share_preview()
        if not info["n"]:
            self._msg("nothing new to share — record a verdict with "
                      "Settings… first")
            return
        dlg = ShareDialog(self, info)
        if dlg.exec() != QDialog.Accepted or not dlg.chosen:
            return
        target = None
        if dlg.chosen == "file":
            target, _f = QFileDialog.getSaveFileName(
                self, "Save test results", "fpgago-test-results.jsonl",
                "Report lines (*.jsonl);;All files (*)")
            if not target:
                self._msg("share cancelled")
                return
        self._run(lib.share_via, dlg.chosen, target, on_done=self._shared)

    def _shared(self, res):
        if res.get("text"):
            QApplication.clipboard().setText(res["text"])
        self._msg(res["done"])
        if res.get("url"):
            self._msg(f"  {res['url']}")
        self._refresh_share()

    # -- the fpgago.com account ---------------------------------------------
    def _refresh_account(self):
        """Ask the server who we are, in the background — the button must not
        make the tab wait for the network to finish drawing."""
        self._run(lib.account, on_done=self._show_account,
                  on_error=self._account_unknown)

    def _account_unknown(self, tb):
        """The server did not answer.  Show the way in anyway: a tab with
        neither "log in" nor "signed in as" is a tab nobody can sign in
        from, and an unreachable server is exactly when that would happen."""
        self._msg("could not check the account: "
                  + tb.strip().splitlines()[-1].split(": ", 1)[-1])
        self._show_account({"user": None})
        self.login_lbl.setText(
            f"Could not reach {lib.webdb.base_url()} — signing in is what "
            "sending screenshots and test results needs.")

    def _show_account(self, info):
        self._account = info.get("user")
        self.account_btn.setText(
            f"Signed in: {self._account}" if self._account else "Log in…")
        self.account_btn.setToolTip(
            "Sign out of fpgago.com" if self._account else
            "Sign in with your fpgago.com account to send your test results, "
            "settings and screenshots back to the project.")
        # Exactly one of the two is up: the red invitation at the top, or the
        # quiet "who am I / sign out" button at the bottom.
        self.account_btn.setVisible(bool(self._account))
        self.login_bar.setVisible(not self._account)
        self.login_lbl.setText(self.SIGNED_OUT)
        self.login_btn.setToolTip(
            f"Sign in to {info.get('server', 'fpgago.com')} — the same "
            "account as on the website.")

    def do_account(self):
        if getattr(self, "_account", None):
            self._run(lib.logout, on_done=lambda _r: (
                self._msg("signed out"), self._refresh_account()))
            return
        dlg = LoginDialog(self)
        if dlg.exec() != QDialog.Accepted:
            return
        self._msg(f"signing in to {lib.webdb.base_url()}…")
        self._run(lib.login, dlg.username(), dlg.password(),
                  on_done=self._logged_in, on_error=self._login_failed)

    def _logged_in(self, res):
        self._msg(f"signed in as {res['user']}")
        self._refresh_account()
        self._refresh_share()
        # Signing in is usually somebody answering the red bar: whatever was
        # queued has a way out now, so take it rather than making them find
        # a second button.
        self._auto_share()
        self.do_refresh(auto=True)

    def _login_failed(self, tb):
        last = tb.strip().splitlines()[-1]
        self._msg("could not sign in: " + last.split(": ", 1)[-1])

    # -- straight to the board ----------------------------------------------
    def do_send(self, run=False):
        r = self.var_tbl.currentRow()
        if r < 0 or r >= len(self._variants):
            self._msg("select a variant first")
            return
        if not self.mgr.is_open:
            self._msg("not connected — connect the board on the Connection tab first")
            return
        vid = self._variants[r]["id"]
        for b in (self.send_btn, self.play_btn):
            b.setEnabled(False)
        self._msg("sending to the board…")
        task = Task(lib.send_variant, self.ops, vid, run, wants_progress=True)
        start_task(self.pool, task, on_done=self._show_sent,
                   on_error=self._send_error, on_progress=self._msg)

    def _show_sent(self, res):
        for b in (self.send_btn, self.play_btn):
            b.setEnabled(True)
        if "error" in res:
            self._msg(f"  ERROR {res['error']}")
            return
        self._msg(f"on board: {res['file']}"
                  + ("  — running" if res.get("ran") else ""))
        if not res.get("profile"):
            self._msg("  (no per-game settings recorded — Settings… adds "
                      "them)")
        # The new file exists on the board now, so the Board tab's listing is
        # stale — re-read it rather than making the user hit Refresh.
        if self.board_panel is not None:
            self.board_panel.refresh()

    def _send_error(self, tb):
        for b in (self.send_btn, self.play_btn):
            b.setEnabled(True)
        self._msg("ERROR:\n" + tb.strip().splitlines()[-1])

    # -- import / index / sync / sources -----------------------------------
    def do_import(self):
        paths, _ = QFileDialog.getOpenFileNames(
            self, "Import game files", "",
            "Games (*.prg *.d64 *.t64 *.tap *.crt *.zip *.bin);;All files (*)")
        if not paths:
            return
        self._msg(f"importing {len(paths)} file(s)…")
        self._run(lib.import_files, paths, on_done=self._show_import)

    def _show_import(self, results):
        for r in results:
            if "error" in r:
                self._msg(f"  {r['path']}: ERROR {r['error']}")
            else:
                dup = " (dup)" if r.get("duplicate") else ""
                self._msg(f"  {r['path']} -> {r['platform']} "
                          f"crc={r['crc32']} game#{r['game_id']}{dup}")
        self.refresh_stats()

    def do_index(self):
        path = QFileDialog.getExistingDirectory(self, "Index collection folder")
        if not path:
            return
        self._msg(f"indexing {path}…  (may take a while)")
        self._run(lib.index_tree, path, wants_progress=True,
                  on_done=self._show_index)

    def _show_index(self, st):
        by = "  ".join(f"{p}:{n}" for p, n in sorted(st["by_platform"].items()))
        self._msg(f"indexed={st['indexed']} scanned={st['scanned']} "
                  f"tosec={st['tosec_hits']} dupes={st['dupes']}   {by}")
        self.refresh_stats()

    def do_refresh(self, auto: bool = False, then=None):
        """Get the latest database from fpgago.com.

        `auto` is the timer's version of the same work: it says nothing in
        the log unless something actually changed, and leaves the list where
        the user had it.  A sync that narrates itself every quarter of an
        hour is a sync people turn off.

        `then` runs when the sync lands.  Only one sync is ever in flight —
        two of them write the same sqlite catalog — so a caller that needs
        the result has to be carried by whichever sync is running.
        """
        if then is not None:
            self._after_refresh.append(then)
        if getattr(self, "_refreshing", False):
            if not auto:
                self._msg("a refresh is already running…")
            return
        self._refreshing = True
        self.refresh_btn.setEnabled(False)
        task = Task(lib.sync_web, wants_progress=True)
        start_task(self.pool, task,
                   on_done=lambda res: self._refresh_done(res, auto),
                   on_error=lambda tb: self._refresh_error(tb, auto),
                   on_progress=(lambda _m: None) if auto else self._msg)

    def _run_after_refresh(self):
        waiting, self._after_refresh = self._after_refresh, []
        for cb in waiting:
            cb()

    def _refresh_done(self, res, auto: bool = False):
        self._refreshing = False
        self.refresh_btn.setEnabled(True)
        self._run_after_refresh()
        self._sync_ok = not res.get("errors")
        self._sync_why = "; ".join(res.get("errors") or [])
        self._update_alert()
        for err in res.get("errors", []):
            self._msg(f"  {err}")
        self.refresh_stats()
        if auto and not res.get("changed"):
            return                       # nothing new: do not disturb the list
        if auto:
            self._msg(f"database updated: {res.get('games', 0)} game(s), "
                      f"{res.get('new', 0)} new release(s), "
                      f"{res.get('reports', 0)} verdict(s)")
            # Keep the user where they were — an auto-refresh that jumps the
            # cursor off the game they are reading is worse than a stale row.
            r = self.games_tbl.currentRow()
            if 0 <= r < len(self._games):
                self._restore_id = self._games[r].get("id")
        # Re-run whatever is on screen so the new rows appear straight away.
        self.do_search()

    def _refresh_error(self, tb, auto: bool = False):
        self._refreshing = False
        self.refresh_btn.setEnabled(True)
        # Whoever was waiting for the sync still has to be let go — a failed
        # refresh must not leave the screenshot pane waiting forever.
        self._run_after_refresh()
        # Being offline is a normal state for this app, not a crash — but it
        # is also not a state to be quiet about, because everything the user
        # records while it lasts is going nowhere.
        self._sync_ok = False
        self._sync_why = tb.strip().splitlines()[-1].split(": ", 1)[-1]
        self._update_alert()
        if not auto:
            self._msg("could not reach the game database — showing what you "
                      "already have")
            self._msg("  " + tb.strip().splitlines()[-1])

    def do_sources(self):
        self._run(lib.list_sources, on_done=lambda ss: self._msg(
            "sources: " + ", ".join(
                f"{s['name']}({','.join(s['platforms']) or 'any'})" for s in ss)
            or "(none)"))


# ── shared bits for the board-facing panels ────────────────────────────────
class _OpsPanel(QWidget):
    """Base for panels that run blocking BoardOps calls off the GUI thread."""

    def __init__(self, mgr, pool: QThreadPool):
        super().__init__()
        self.mgr = mgr
        self.pool = pool
        self.ops = board.BoardOps(mgr)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(1000)
        self.log.setFixedHeight(110)
        self.log.setStyleSheet("font-family:monospace; font-size:12px;")

    def _msg(self, text):
        self.log.appendPlainText(str(text))

    def _run(self, fn, *args, on_done=None, on_error=None,
             wants_progress=False, **kwargs):
        if not self.mgr.is_open:
            self._msg("not connected — connect the board on the Connection tab first")
            return
        task = Task(fn, *args, wants_progress=wants_progress, **kwargs)
        start_task(
            self.pool, task, on_done=on_done,
            on_error=on_error or (lambda tb: self._msg(
                "ERROR: " + tb.strip().splitlines()[-1])),
            on_progress=self._msg)

    @staticmethod
    def _table(headers):
        return ResponsiveTable(headers)

    @staticmethod
    def _selected_name(table: QTableWidget, col: int = 1):
        r = table.currentRow()
        if r < 0:
            return None
        item = table.item(r, col)
        return item.text() if item else None


# ── Connection tab: the link, and everything you press on the machine ───────
class ConnectionPanel(_OpsPanel):
    """Finding the board, staying connected to it, and driving it live.

    Connecting is automatic and never blocks the GUI.  Two rules make that
    work, and both are load-bearing:

      * **Only fpgago boards are listed or opened.**  A Mac reports its
        Bluetooth serial ports as ordinary ttys; opening one sits for many
        seconds before failing, which is exactly the freeze this app used to
        have.  serial_manager.list_ports() filters by USB vendor id.
      * **The open runs on a worker thread** (open_port_async), so even a
        board that is wedged mid-enumeration costs no frames.

    One board = no decision to make: it connects itself.  The picker only
    appears when there really is more than one.
    """

    def __init__(self, mgr: SerialManager, pool: QThreadPool, on_status):
        super().__init__(mgr, pool)
        self.on_status = on_status
        self._ports = []
        self._auto_tried = set()          # devices we already auto-connected
        self._user_disconnected = False   # Disconnect was pressed on purpose
        self._seen_devs = set()           # port set as of the last poll
        self._ctl_loaded = False          # controls show the board's state

        root = QVBoxLayout(self)

        # ── the link ────────────────────────────────────────────────────
        box = QGroupBox("Board")
        g = QVBoxLayout(box)
        srow = QHBoxLayout()
        self.dot = QLabel("●")
        self.dot.setStyleSheet("color:#7f8c8d; font-size:20px;")
        self.status_lbl = QLabel("Looking for a board…")
        self.status_lbl.setStyleSheet("font-size:14px;")
        self.connect_btn = QPushButton("Connect")
        self.connect_btn.clicked.connect(self._toggle_connect)
        srow.addWidget(self.dot)
        srow.addWidget(self.status_lbl, 1)
        srow.addWidget(self.connect_btn)
        g.addLayout(srow)

        # Only shown when there is genuinely a choice to make.
        self.pick_row = QWidget()
        prow = QHBoxLayout(self.pick_row)
        prow.setContentsMargins(0, 0, 0, 0)
        self.port_combo = QComboBox()
        self.port_combo.setMinimumWidth(360)
        self.port_combo.currentIndexChanged.connect(self._picked)
        prow.addWidget(QLabel("Board:"))
        prow.addWidget(self.port_combo, 1)
        g.addWidget(self.pick_row)
        self.pick_row.setVisible(False)

        self.hint_lbl = QLabel("")
        self.hint_lbl.setStyleSheet("color:#888; font-size:11px;")
        self.hint_lbl.setWordWrap(True)
        g.addWidget(self.hint_lbl)
        root.addWidget(box)

        # ── machine controls (moved here from the Board tab) ────────────
        self.ctl_box = QGroupBox("Machine controls")
        c = QGridLayout(self.ctl_box)

        c.addWidget(QLabel("Volume:"), 0, 0)
        self.vol_slider = QSlider(Qt.Horizontal)
        self.vol_slider.setRange(0, 10)
        self.vol_slider.setTickPosition(QSlider.TicksBelow)
        self.vol_slider.setTickInterval(1)
        self.vol_lbl = QLabel("?")
        self.persist_cb = QCheckBox("remember")
        self.persist_cb.setChecked(True)
        self.persist_cb.setToolTip(
            "Also store audio.volume in the MCU KV store so the level "
            "survives reboot (the board powers up muted).")
        self.mute_btn = QPushButton("Mute")
        self.mute_btn.clicked.connect(lambda: self.vol_slider.setValue(0))
        c.addWidget(self.vol_slider, 0, 1)
        c.addWidget(self.vol_lbl, 0, 2)
        c.addWidget(self.mute_btn, 0, 3)
        c.addWidget(self.persist_cb, 0, 4)
        self._vol_timer = QTimer(self)
        self._vol_timer.setSingleShot(True)
        self._vol_timer.setInterval(300)
        self._vol_timer.timeout.connect(self._apply_volume)
        self.vol_slider.valueChanged.connect(self._on_vol_changed)

        c.addWidget(QLabel("Drive mode:"), 1, 0)
        self.dmode_lbl = QLabel("?")
        self.dmode_btn = QPushButton("Cycle drive mode")
        self.dmode_btn.clicked.connect(
            lambda: self._run(self.ops.drive_mode_toggle, on_done=self._on_dmode))
        c.addWidget(self.dmode_lbl, 1, 1)
        c.addWidget(self.dmode_btn, 1, 2, 1, 2)

        krow = QHBoxLayout()
        for text, which in [("Reset", "reset"), ("RUN/STOP", "runstop"),
                            ("RS+RESTORE", "restore")]:
            b = QPushButton(text)
            b.clicked.connect(lambda _c=False, w=which: self._run(
                self.ops.machine_ctrl, w,
                on_done=lambda _r, w=w: self._msg(f"{w} sent")))
            krow.addWidget(b)
        bios_btn = QPushButton("BIOS overlay")
        bios_btn.clicked.connect(
            lambda: self._run(self.ops.bios_toggle,
                              on_done=lambda _r: self._msg("BIOS toggled")))
        krow.addWidget(bios_btn)
        krow.addStretch(1)
        reboot_btn = QPushButton("Reboot MCU")
        reboot_btn.clicked.connect(self._reboot)
        bootsel_btn = QPushButton("BOOTSEL")
        bootsel_btn.setToolTip("Reboot the MCU into the UF2 bootloader")
        bootsel_btn.clicked.connect(lambda: self._reboot(bootsel=True))
        krow.addWidget(reboot_btn)
        krow.addWidget(bootsel_btn)
        c.addLayout(krow, 2, 0, 1, 5)

        trow = QHBoxLayout()
        self.type_edit = QLineEdit()
        self.type_edit.setPlaceholderText(
            'type on the machine (Enter sends with Return) — e.g. list')
        self.type_edit.setStyleSheet("font-family:monospace;")
        type_btn = QPushButton("Type")
        self.type_edit.returnPressed.connect(self._type)
        type_btn.clicked.connect(self._type)
        trow.addWidget(QLabel("Keyboard:"))
        trow.addWidget(self.type_edit, 1)
        trow.addWidget(type_btn)
        # F-key row: one click = one press on the machine (type_text
        # {f1}..{f8} escapes; on the c64 F2/F4/F6/F8 are SHIFT+F1/F3/F5/F7,
        # handled by the FPGA kbd map)
        for i in range(1, 9):
            fb = QPushButton(f"F{i}")
            fb.setFixedWidth(34)
            fb.setToolTip(f"press F{i} on the machine "
                          f"(same as typing {{f{i}}} in the keyboard box)")
            fb.clicked.connect(lambda _c, n=i: self._fkey(n))
            trow.addWidget(fb)
        # C= has no PC glyph, and games poll it straight off the matrix
        # (Save New York's demo exits only on C=, row 7 column 5)
        cb = QPushButton("C=")
        cb.setFixedWidth(34)
        cb.setToolTip("press the Commodore key on the machine "
                      "(same as typing {cbm} in the keyboard box)")
        cb.clicked.connect(lambda _c: self._key("{cbm}", "C="))
        trow.addWidget(cb)
        c.addLayout(trow, 3, 0, 1, 5)
        root.addWidget(self.ctl_box)

        # ── console ─────────────────────────────────────────────────────
        self.console = QPlainTextEdit()
        self.console.setReadOnly(True)
        self.console.setMaximumBlockCount(2000)
        self.console.setStyleSheet("font-family:monospace; font-size:12px;")
        self.log = self.console            # _OpsPanel._msg writes here
        root.addWidget(QLabel("MCU console:"))
        root.addWidget(self.console, 1)

        irow = QHBoxLayout()
        self.input_edit = QLineEdit()
        self.input_edit.setPlaceholderText(
            "console input — chars are sent raw; Enter appends CR "
            "(try H for help)")
        self.input_edit.setStyleSheet("font-family:monospace;")
        self.send_btn = QPushButton("Send")
        self.ping_btn = QPushButton("Ping")
        self.ping_btn.setToolTip("text identity probe ('H' → banner)")
        self.link_btn = QPushButton("Link ping")
        self.link_btn.setToolTip("binary hostlink PING (proto/fw/caps)")
        irow.addWidget(self.input_edit, 1)
        irow.addWidget(self.send_btn)
        irow.addWidget(self.ping_btn)
        irow.addWidget(self.link_btn)
        root.addLayout(irow)

        self.send_btn.clicked.connect(self._send_console)
        self.input_edit.returnPressed.connect(self._send_console)
        self.ping_btn.clicked.connect(self.mgr.ping)
        self.link_btn.clicked.connect(self._link_ping)
        self.mgr.link_result.connect(self._on_link_result)
        self.mgr.link_event.connect(self._on_link_event)
        self.mgr.ports_changed.connect(self._on_ports)
        self.mgr.status_changed.connect(self._on_status)
        self.mgr.data_received.connect(self._on_data)

        self._set_controls_enabled(False)

        # Retry: a board that was busy, or that came back under a new tty
        # name, is picked up without the user doing anything.  2 s + the
        # 1 s port poll = a lost link is back inside ~3 s.
        self._retry_timer = QTimer(self)
        self._retry_timer.setInterval(2000)
        self._retry_timer.timeout.connect(self._retry_tick)
        self._retry_timer.start()

        # auto-reconnect poll after an MCU reboot / FPGA reprogram
        self._reconnect_timer = QTimer(self)
        self._reconnect_timer.setInterval(1500)
        self._reconnect_timer.timeout.connect(self._try_reconnect)
        self._reconnect_dev = None
        self._reconnect_deadline = 0.0

    # ── discovery + auto-connect ────────────────────────────────────────
    def _on_ports(self, ports):
        self._ports = ports
        cur = self.port_combo.currentData()
        self.port_combo.blockSignals(True)
        self.port_combo.clear()
        for p in ports:
            self.port_combo.addItem(p.label(), p.device)
        i = self.port_combo.findData(cur) if cur else -1
        self.port_combo.setCurrentIndex(max(0, i))
        self.port_combo.blockSignals(False)
        # A picker for one board is a decision nobody needs to make.
        self.pick_row.setVisible(len(ports) > 1)

        # The set of boards changed — a replug, or macOS handing the same
        # board a new tty name.  Either way the "already tried that one"
        # memory is stale, and this is the moment to try again.
        devs = {p.device for p in ports}
        if devs != self._seen_devs:
            self._seen_devs = devs
            self._auto_tried.clear()

        from .serial_manager import other_port_count
        hidden = other_port_count()
        note = (f"  ({hidden} other serial port{'s' if hidden != 1 else ''} "
                "hidden — not an fpgago board)") if hidden else ""
        if not ports:
            self.hint_lbl.setText(
                "No fpgago board found. Plug one in over USB — it appears "
                "here by itself." + note)
        else:
            self.hint_lbl.setText(
                f"{len(ports)} board{'s' if len(ports) > 1 else ''} found."
                + note)
        self._maybe_auto_connect()

    def _maybe_auto_connect(self):
        """Connect by itself when there is exactly one board and nothing is
        already connected.  Tried once per device, then again on the slow
        retry tick — so a board held open by another program is not hammered
        every port poll, but does connect on its own once it is free."""
        if self.mgr.is_open or self.mgr.is_opening or self._user_disconnected:
            return
        if len(self._ports) != 1:
            return
        dev = self._ports[0].device
        if dev in self._auto_tried:
            return
        self._auto_tried.add(dev)
        self._msg(f"[auto-connect] {dev}")
        self.mgr.open_port_async(dev)

    def _retry_tick(self):
        if self.mgr.is_open or self._user_disconnected:
            return
        self._auto_tried.clear()
        self._maybe_auto_connect()

    def _picked(self):
        """Choosing a different board in the picker switches to it."""
        dev = self.port_combo.currentData()
        if dev and self.mgr.is_open and self.mgr.device != dev:
            self._connect(dev)

    def _toggle_connect(self):
        if self.mgr.is_open:
            # An explicit disconnect stays disconnected — otherwise the
            # auto-connect would undo the button the moment it was pressed.
            self._user_disconnected = True
            self.mgr.close_port()
        else:
            dev = self.port_combo.currentData() or (
                self._ports[0].device if self._ports else None)
            if dev:
                self._connect(dev)
            else:
                self._msg("no fpgago board to connect to")

    def _connect(self, dev):
        self._user_disconnected = False
        self._auto_tried.discard(dev)
        self.mgr.open_port_async(dev)

    # ── status ──────────────────────────────────────────────────────────
    @staticmethod
    def _friendly(detail: str) -> str:
        """Turn pyserial's errno prose into something a user can act on.
        The raw text is still logged to the console — this is the one-liner
        next to the status dot."""
        low = (detail or "").lower()
        if "resource busy" in low or "errno 16" in low:
            return ("the board is busy — another program has the port open "
                    "(a serial terminal, or a second copy of this app)")
        if "permission" in low or "errno 13" in low:
            return ("no permission to open the port — on Linux add yourself "
                    "to the 'dialout' group and log back in")
        if "no such file" in low or "errno 2" in low:
            return "the board went away (unplugged?)"
        if detail.startswith("open failed: "):
            return detail[len("open failed: "):]
        return detail

    def _on_status(self, state, detail):
        self.dot.setStyleSheet(
            f"color:{_status_color(state).name()}; font-size:20px;")
        label = {ST_ONLINE: "Connected", ST_OFFLINE: "Not responding",
                 ST_CONNECTING: "Connecting…",
                 ST_DISCONNECTED: "Not connected"}.get(state, state)
        dev = self.mgr.device
        line = label
        if state != ST_DISCONNECTED and dev:
            line += f"  —  {dev}"
        if detail and detail != dev:
            line += f"  —  {self._friendly(detail)}"
        self.status_lbl.setText(line)
        if detail and ("failed" in detail or "stalled" in detail):
            self._msg(f"[connect] {detail}")     # the raw errno, for the log
        connected = state != ST_DISCONNECTED
        self.connect_btn.setText("Disconnect" if connected else "Connect")
        online = state == ST_ONLINE
        self._set_controls_enabled(online)
        if online and not self._ctl_loaded:
            self._refresh_controls()
        self.on_status(state, self._friendly(detail))

    def _set_controls_enabled(self, on: bool):
        self.ctl_box.setEnabled(on)
        if not on:
            self._ctl_loaded = False

    def _refresh_controls(self):
        """Read volume + drive mode once the link is up, so the widgets show
        the board's state rather than their defaults."""
        self._ctl_loaded = True

        def worker():
            out = {}
            for key, fn in (("volume", self.ops.get_volume),
                            ("dmode", self.ops.get_drive_mode)):
                try:
                    out[key] = fn()
                except Exception:                    # noqa: BLE001
                    out[key] = None
            return out
        self._run(worker, on_done=self._show_controls)

    def _show_controls(self, st):
        vol = st.get("volume")
        if vol is not None:
            self.vol_slider.blockSignals(True)
            self.vol_slider.setValue(vol)
            self.vol_slider.blockSignals(False)
            self.vol_lbl.setText(str(vol))
        else:
            self.vol_lbl.setText("? (default 0 = mute)")
        self.dmode_lbl.setText(DRIVE_MODE_NAMES.get(
            st.get("dmode"), "(not set)"))

    # ── controls ────────────────────────────────────────────────────────
    def _on_vol_changed(self, v):
        self.vol_lbl.setText(str(v))
        self._vol_timer.start()                      # debounce slider drags

    def _apply_volume(self):
        v = self.vol_slider.value()
        persist = self.persist_cb.isChecked()
        self._run(self.ops.set_volume, v, persist,
                  on_done=lambda _r: self._msg(
                      f"volume {v}" + (" (remembered)" if persist else "")))

    def _on_dmode(self, text):
        if text:
            self._msg(text)
        low = (text or "").lower()
        if "1541" in low and "fastload" not in low.split("->")[-1]:
            self.dmode_lbl.setText("REAL 1541 (IEC)")
        elif "fastload" in low:
            self.dmode_lbl.setText("FASTLOAD (QSPI)")

    def _type(self):
        text = self.type_edit.text()
        if not text:
            return
        self._run(self.ops.type_text, text + "\r",
                  on_done=lambda _r: self._msg(f"typed: {text}"))
        self.type_edit.clear()

    def _key(self, escape: str, label: str):
        # bare key press: no trailing Return
        self._run(self.ops.type_text, escape,
                  on_done=lambda _r: self._msg(f"pressed {label}"))

    def _fkey(self, n: int):
        self._key("{f%d}" % n, f"F{n}")

    # ── reboot + reconnect ──────────────────────────────────────────────
    def _reboot(self, bootsel: bool = False):
        what = "BOOTSEL bootloader" if bootsel else "MCU"
        if QMessageBox.question(self, "Reboot", f"Reboot into {what}?") \
                != QMessageBox.Yes:
            return
        dev = self.mgr.device
        self._run(self.ops.reboot, bootsel,
                  on_done=lambda _r: None if bootsel
                  else self.reconnect_after(dev, "(reboot)"))

    def reconnect_after(self, dev, what=""):
        """Poll the port back up after something that resets the MCU.  Also
        called by the Board tab when it programs the FPGA."""
        if what:
            self._msg(f"{what}: waiting for the board to come back…")
        self._reconnect_dev = dev
        self._auto_tried.discard(dev)
        self._reconnect_deadline = time.monotonic() + 25.0
        self._reconnect_timer.start()

    def _try_reconnect(self):
        if self.mgr.is_open and self.mgr._state == ST_ONLINE:   # noqa: SLF001
            self._reconnect_timer.stop()
            self._msg("reconnected")
            return
        if time.monotonic() > self._reconnect_deadline:
            self._reconnect_timer.stop()
            self._msg("auto-reconnect gave up — press Connect")
            return
        if self.mgr.is_open or self.mgr.is_opening:
            return
        # After a reboot the board may well come back under a different tty
        # name (macOS renumbers), so aim at whichever board is there rather
        # than at the name we left from.
        dev = self._reconnect_dev
        here = [p.device for p in self._ports]
        if dev not in here:
            dev = here[0] if len(here) == 1 else None
        if dev:
            self._auto_tried.discard(dev)
            self.mgr.open_port_async(dev)

    # ── console ─────────────────────────────────────────────────────────
    def _link_ping(self):
        self._msg("[hostlink] PING…")
        self.mgr.link_ping_async()

    def _on_link_result(self, result):
        if isinstance(result, Exception):
            self._msg(f"[hostlink] PING failed: {result}")
            return
        v = result
        hi, lo = v["proto_ver"] >> 8, v["proto_ver"] & 0xFF
        self._msg(f"[hostlink] ONLINE  proto v{hi}.{lo}  fw={v['fw_hash']}  "
                  f"board={v['board']}  caps=0x{v['caps']:08x}")

    def _on_link_event(self, fr):
        self._msg(f"[hostlink event] type=0x{fr.type:02x} "
                  f"len={len(fr.payload)} {fr.payload[:48]!r}")

    def _on_data(self, text):
        self.console.moveCursor(QTextCursor.End)
        self.console.insertPlainText(text)

    def _send_console(self):
        text = self.input_edit.text()
        if not text or not self.mgr.is_open:
            return
        try:
            self.mgr.write_bytes(text.encode("latin1", "replace") + b"\r")
        except Exception as e:                       # noqa: BLE001
            self._msg(f"[send failed: {e}]")
        self.input_edit.clear()


# ── picking a machine bitstream that this checkout has built ───────────────
class BitstreamPicker(QDialog):
    """Choose a machine to put on the board, from the builds that exist.

    A file dialog is the wrong tool here: the answer is never "some .bit
    somewhere", it is "the c64 I built twenty minutes ago", and those live
    in `/tmp` under names encoding RAM/HW/CPU.  So list them — newest first,
    duplicate copies folded together — and keep Browse… for the odd file
    from elsewhere.
    """

    def __init__(self, parent, bits):
        super().__init__(parent)
        self.setWindowTitle("Add a machine")
        self.setMinimumWidth(720)
        self._bits = bits
        self.chosen = None
        self.browse = False

        root = QVBoxLayout(self)
        head = QLabel(
            f"<b>{len(bits)} bitstream{'s' if len(bits) != 1 else ''}</b> "
            "found in this checkout. Newest first — the top one is usually "
            "the build you just made.")
        head.setWordWrap(True)
        root.addWidget(head)

        self.tbl = ResponsiveTable(["machine", "file", "size", "built",
                                    "where"])
        self.tbl.setMinimumHeight(260)
        for b in bits:
            r = self.tbl.rowCount()
            self.tbl.insertRow(r)
            origin = b.origin + (f"  (+{len(b.dupes)} identical)"
                                 if b.dupes else "")
            for c, v in enumerate([b.arch, b.name, f"{b.size // 1024} KB",
                                   b.age, origin]):
                it = QTableWidgetItem(v)
                it.setToolTip(b.path)
                self.tbl.setItem(r, c, it)
        self.tbl.itemDoubleClicked.connect(lambda _i: self._accept())
        self.tbl.itemSelectionChanged.connect(self._sync)
        root.addWidget(self.tbl)

        nrow = QHBoxLayout()
        self.ed_name = QLineEdit()
        self.ed_name.setToolTip(
            "The name on the board. The BIOS boots <machine>.bit, so keeping "
            "the machine name replaces the copy already there.")
        nrow.addWidget(QLabel("Upload as:"))
        nrow.addWidget(self.ed_name, 1)
        root.addLayout(nrow)

        bb = QDialogButtonBox()
        self.btn_ok = bb.addButton("Add to board", QDialogButtonBox.AcceptRole)
        btn_browse = bb.addButton("Browse…", QDialogButtonBox.ActionRole)
        bb.addButton("Cancel", QDialogButtonBox.RejectRole)
        bb.accepted.connect(self._accept)
        bb.rejected.connect(self.reject)
        btn_browse.clicked.connect(self._browse)
        root.addWidget(bb)

        if bits:
            self.tbl.selectRow(0)
        self._sync()

    def _sync(self):
        b = self.selected()
        self.btn_ok.setEnabled(b is not None)
        if b is not None:
            self.ed_name.setText(b.suggested_name)

    def selected(self):
        r = self.tbl.currentRow()
        return self._bits[r] if 0 <= r < len(self._bits) else None

    def name(self) -> str:
        return self.ed_name.text().strip()

    def _accept(self):
        b = self.selected()
        if b is None or not self.name():
            return
        self.chosen = b
        self.accept()

    def _browse(self):
        self.browse = True
        self.accept()


# ── Board tab: everything that lives in the board's flash ──────────────────
class BoardPanel(_OpsPanel):
    """The board's storage, in the two shapes it actually has: machines
    (bitstreams) and games.

    This used to be two tabs — "Board" listed what was there and "Files"
    uploaded to it — which meant every answer to "how do I get a game on the
    board" started with "wrong tab".  Same list, same file, so: one tab, and
    each box carries the actions for its own kind.  Live machine controls
    (keyboard, volume, reset) are not storage and live on Connection.
    """

    # Upload category choices (the FS stores a mandatory type+platform tag
    # per file; the BIOS game list filters on it).
    _UPLOAD_CHOICES = [
        ("machine bitstream (.bit)", board.FT_BIT, None),
        ("c64 game", board.FT_GAME, "c64"),
        ("c16 game", board.FT_GAME, "c16"),
        ("plus4 game", board.FT_GAME, "plus4"),
        ("c16+plus4 game (264)", board.FT_GAME, "264"),
        ("machine ROM set (.roms)", board.FT_ROM, None),
        ("custom platform game…", board.FT_GAME, None),
    ]

    def __init__(self, mgr, pool: QThreadPool, connection=None):
        super().__init__(mgr, pool)
        self._entries: list[board.FsEntry] = []
        self._boot: str | None = None
        self._games: list[board.FsEntry] = []
        self._machines: list[board.FsEntry] = []
        self._active: dict[str, str] = {}  # arch -> the game it would start
        self._baked: dict = {}             # arch -> bit carries its own ROMs
        self._loaded = False              # the lists describe a live board
        self._keep_cursor = None          # (table, row) to restore after a refresh
        self.connection = connection      # for reconnect after FPGA_PROG

        root = QVBoxLayout(self)

        # Status row.
        srow = QHBoxLayout()
        self.info_lbl = QLabel("—")
        self.refresh_btn = QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self.refresh)
        srow.addWidget(self.info_lbl, 1)
        srow.addWidget(self.refresh_btn)
        root.addLayout(srow)

        root.addWidget(self._build_rom_banner())

        split = QSplitter(Qt.Horizontal)

        # ── Machines (bitstreams) ───────────────────────────────────────
        mwrap = QWidget()
        mlay = QVBoxLayout(mwrap)
        mlay.setContentsMargins(6, 6, 6, 6)
        # "file", not "bitstream": the box also lists each machine's ROM set.
        self.mach_tbl = self._table(["arch", "file", "size", ""])
        self.mach_tbl.setSelectionMode(QTableWidget.ExtendedSelection)
        mlay.addWidget(self.mach_tbl, 1)
        mrow = QHBoxLayout()
        self.boot_btn = QPushButton("Boot this machine")
        self.setboot_btn = QPushButton("Set as boot")
        self.boot_btn.clicked.connect(self._boot_machine)
        self.setboot_btn.clicked.connect(self._set_boot)
        mrow.addWidget(self.boot_btn)
        mrow.addWidget(self.setboot_btn)
        mrow.addStretch(1)
        mlay.addLayout(mrow)
        mrow2 = QHBoxLayout()
        for text, cb in (("Add…", lambda: self._upload(board.FT_BIT)),
                         ("Save as…", lambda: self._download(self.mach_tbl)),
                         ("Delete", lambda: self._delete(self.mach_tbl))):
            b = QPushButton(text)
            b.clicked.connect(cb)
            mrow2.addWidget(b)
        mrow2.addStretch(1)
        mlay.addLayout(mrow2)
        mbox = QGroupBox("Machines")
        QVBoxLayout(mbox).addWidget(mwrap)
        split.addWidget(mbox)

        # ── Games (everything that is not a bitstream) ──────────────────
        gwrap = QWidget()
        glay = QVBoxLayout(gwrap)
        glay.setContentsMargins(6, 6, 6, 6)
        self.game_tbl = self._table(["arch", "game", "size", "kind", ""])
        # shift+arrows / ctrl+click select a run of games; Delete takes them
        # all, which is what clearing out a machine's worth of tests needs.
        self.game_tbl.setSelectionMode(QTableWidget.ExtendedSelection)
        self.game_tbl.itemDoubleClicked.connect(lambda _i: self._settings())
        glay.addWidget(self.game_tbl, 1)
        grow = QHBoxLayout()
        self.run_btn = QPushButton("Run")
        self.mount_btn = QPushButton("Mount")
        self.unmount_btn = QPushButton("Unmount")
        self.dir_btn = QPushButton("Disk dir")
        self.run_delay = QDoubleSpinBox()
        self.run_delay.setRange(0.0, 30.0)
        self.run_delay.setValue(4.0)
        self.run_delay.setSuffix(" s RUN delay")
        self.run_delay.setToolTip(
            "Seconds between typed LOAD and RUN. 0 = type RUN right behind "
            "LOAD (KERNAL type-ahead; fine on the real-1541 IEC path).")
        self.run_btn.clicked.connect(self._run_game)
        self.mount_btn.clicked.connect(self._mount)
        self.unmount_btn.clicked.connect(
            lambda: self._run(self.ops.unmount,
                              on_done=lambda _r: self._msg("unmounted")))
        self.dir_btn.clicked.connect(
            lambda: self._run(self.ops.disk_dir, on_done=self._msg))
        grow.addWidget(self.run_btn)
        grow.addWidget(self.run_delay)
        grow.addWidget(self.mount_btn)
        grow.addWidget(self.unmount_btn)
        grow.addWidget(self.dir_btn)
        grow.addStretch(1)
        glay.addLayout(grow)
        grow2 = QHBoxLayout()
        self.set_btn = QPushButton("Settings…")
        self.set_btn.setToolTip(
            "Per-game settings this board applies when the game starts "
            "(drive mode, buttons, start-up keys)")
        self.set_btn.clicked.connect(self._settings)
        for text, cb in (("Add…", lambda: self._upload(board.FT_GAME)),
                         ("Save as…", lambda: self._download(self.game_tbl)),
                         ("Delete", lambda: self._delete(self.game_tbl)),
                         ("Verify", self._stat)):
            b = QPushButton(text)
            b.clicked.connect(cb)
            grow2.addWidget(b)
        grow2.addWidget(self.set_btn)
        grow2.addStretch(1)
        glay.addLayout(grow2)
        gbox = QGroupBox("Games")
        QVBoxLayout(gbox).addWidget(gwrap)
        split.addWidget(gbox)
        root.addWidget(split, 1)

        self.progress = QProgressBar()
        self.progress.setRange(0, 100)
        self.progress.setValue(0)
        root.addWidget(self.progress)

        # ── advanced: raw KV + format ───────────────────────────────────
        kbox = QGroupBox("Advanced")
        kl = QGridLayout(kbox)
        self.kv_tbl = self._table(["key", "value (hex)"])
        self.kv_tbl.setMaximumHeight(130)
        kl.addWidget(self.kv_tbl, 0, 0, 1, 5)
        self.kv_key = QLineEdit()
        self.kv_key.setPlaceholderText("key (e.g. audio.volume)")
        self.kv_val = QLineEdit()
        self.kv_val.setPlaceholderText("value hex bytes (e.g. 05)")
        kv_set_btn = QPushButton("Set")
        kv_ref_btn = QPushButton("Refresh KV")
        fmt_btn = QPushButton("Format FS…")
        kv_set_btn.clicked.connect(self._kv_set)
        kv_ref_btn.clicked.connect(self._kv_refresh)
        fmt_btn.clicked.connect(self._format)
        kl.addWidget(self.kv_key, 1, 0)
        kl.addWidget(self.kv_val, 1, 1)
        kl.addWidget(kv_set_btn, 1, 2)
        kl.addWidget(kv_ref_btn, 1, 3)
        kl.addWidget(fmt_btn, 1, 4)
        # Collapsed by default: raw KV and Format are for debugging, and a
        # tab that opens showing them reads as "this is complicated".
        kbox.setCheckable(True)
        kbox.setChecked(False)
        for w in (self.kv_tbl, self.kv_key, self.kv_val, kv_set_btn,
                  kv_ref_btn, fmt_btn):
            kbox.toggled.connect(w.setVisible)
            w.setVisible(False)
        kbox.toggled.connect(
            lambda on: kbox.setMaximumHeight(16777215 if on else 26))
        kbox.setMaximumHeight(26)          # hidden children still reserve space
        root.addWidget(kbox)

        root.addWidget(self.log)

        # Selecting a machine moves the Games cursor to that machine's first
        # game — the two lists are one thought, not two.
        self.mach_tbl.itemSelectionChanged.connect(self._machine_picked)
        # The lists describe a board that is present.  When it goes away they
        # are a lie, so they are emptied; when it comes back they reload
        # themselves rather than waiting for someone to press Refresh.
        self.mgr.status_changed.connect(self._on_link_status)

    # -- link state ---------------------------------------------------------
    def _on_link_status(self, state, _detail):
        if state == ST_ONLINE:
            if not self._loaded:
                self.refresh()
        elif self._loaded:
            self.clear()

    def clear(self):
        self._loaded = False
        self._entries, self._machines, self._games = [], [], []
        self.mach_tbl.setRowCount(0)
        self.game_tbl.setRowCount(0)
        self.kv_tbl.setRowCount(0)
        self.progress.setValue(0)
        self.info_lbl.setText("no board connected")

    # -- refresh ------------------------------------------------------------
    # ── "your Commodore machines can't run" banner ──────────────────────
    # The ROM flow was reachable only from the Install tab, three checkboxes
    # down, which a new user has no reason to open — and when it went wrong
    # there was nothing on the Board tab saying so.  This is the sign that
    # tells them, on the tab they are already looking at, and the one button
    # that fixes it.  Hidden whenever the board is fine, so it can never
    # become furniture.
    def _build_rom_banner(self):
        self.rom_banner = QWidget()
        self.rom_banner.setStyleSheet(
            "QWidget#rombox { background:#7d1a1a; border:2px solid #e74c3c; "
            "border-radius:6px; }"
            "QLabel { color:#fff; }")
        self.rom_banner.setObjectName("rombox")
        lay = QVBoxLayout(self.rom_banner)
        lay.setContentsMargins(12, 10, 12, 10)

        self.rom_title = QLabel("<b>Commodore machines unavailable</b>")
        self.rom_title.setStyleSheet("color:#fff; font-size:15px;")
        lay.addWidget(self.rom_title)

        self.rom_body = QLabel()
        self.rom_body.setWordWrap(True)
        self.rom_body.setStyleSheet("color:#ffdede; font-size:12px;")
        lay.addWidget(self.rom_body)

        self.rom_consent = QCheckBox()
        self.rom_consent.setWordWrap(True) if hasattr(
            self.rom_consent, "setWordWrap") else None
        self.rom_consent.setStyleSheet("color:#fff; font-size:11px;")
        self.rom_consent.toggled.connect(
            lambda on: self.rom_go.setEnabled(on))
        lay.addWidget(self.rom_consent)

        brow = QHBoxLayout()
        self.rom_go = QPushButton("Download ROMs and install to board")
        self.rom_go.setEnabled(False)
        self.rom_go.clicked.connect(self._rom_install)
        brow.addWidget(self.rom_go)
        # The answer to a question this app cannot answer for itself: the
        # bitstream on the board may well have its ROMs baked in, and only
        # the person watching the machine start knows.
        self.rom_baked_btn = QPushButton("It has its own ROMs — stop warning")
        self.rom_baked_btn.setToolTip(
            "Records that the bitstream now on the board carries its own "
            "ROMs, so this warning stops for it. Tied to that exact "
            "bitstream — replacing it asks again.")
        self.rom_baked_btn.clicked.connect(self._rom_mark_baked)
        self.rom_baked_btn.hide()
        brow.addWidget(self.rom_baked_btn)
        b = QPushButton("What is this?")
        b.clicked.connect(self._rom_explain)
        brow.addWidget(b)
        brow.addStretch(1)
        lay.addLayout(brow)

        # The install is a download, a pack and three uploads — tens of
        # seconds with nothing else on this tab moving.  The bar covers the
        # whole run (one segment per step) and fills smoothly inside an
        # upload, so it is never ambiguous whether anything is happening.
        self.rom_prog = QProgressBar()
        self.rom_prog.setRange(0, 100)
        self.rom_prog.setTextVisible(True)
        self.rom_prog.hide()
        lay.addWidget(self.rom_prog)

        self.rom_banner.hide()
        return self.rom_banner

    def _rom_prog_begin(self, steps: int):
        self._rom_steps = max(1, steps)
        self._rom_step = 0
        self.rom_prog.setFormat("%p%  starting…")
        self.rom_prog.setValue(0)
        self.rom_prog.show()

    def _rom_prog_line(self, msg: str):
        """Drive the bar off the progress text the workers already emit —
        no second reporting channel to keep in step with the first."""
        msg = str(msg)
        frac = None
        if msg.startswith("upload ") and "/" in msg:
            try:
                done, total = msg.split()[1].split("/")
                frac = int(done) / max(1, int(total))
            except (ValueError, IndexError):
                frac = None
        elif msg.startswith("── ["):                # Runner step header
            try:
                self._rom_step = int(msg.split("[")[1].split("/")[0]) - 1
            except (ValueError, IndexError):
                pass
            frac = 0.0
        elif msg.startswith("uploading "):
            self._rom_step += 1
            frac = 0.0
        if frac is None:
            return
        span = 100.0 / self._rom_steps
        self.rom_prog.setValue(
            int(min(100, self._rom_step * span + frac * span)))
        self.rom_prog.setFormat(f"%p%  {msg[:60]}")

    def _update_rom_banner(self, entries):
        from . import install_backend as inst
        self.rom_consent.setText(inst.ROM_CONSENT)
        self._rom_unsure = []
        try:
            bad = inst.board_needs_roms(entries, baked=self._baked)
        except Exception:                                # noqa: BLE001
            self.rom_banner.hide()
            return
        if not bad:
            self.rom_banner.hide()
            return
        rows = {b.machine: b for b in
                inst.board_machines(entries, baked=self._baked)}
        # A machine whose bitstream we could not identify is a SUSPICION, not
        # a fault: `make build ARCH=c64` bakes the ROMs in, and telling
        # somebody running such a build that their machine is broken is how
        # this banner earned its "stop lying to me".  So it only shouts about
        # what it knows, and offers the one-click answer for the rest.
        self._rom_unsure = [m for m in bad
                            if rows[m].state == "no-roms"
                            and self._baked.get(m) is None]
        sure = [m for m in bad if m not in self._rom_unsure]
        why = ("not installed on the board"
               if all(rows[m].state == "no-bit" for m in bad)
               else "ROMs missing on the board")
        if sure:
            self.rom_title.setText(
                f"<b>{', '.join(bad)} unavailable — {why}</b>")
        else:
            self.rom_title.setText(
                f"<b>{', '.join(bad)}: no ROMs on the board — "
                "does the bitstream carry its own?</b>")
        self.rom_body.setText(
            "These machines need Commodore's KERNAL/BASIC ROMs, which are "
            "copyrighted and cannot ship with the hardware. The bitstreams "
            "shipped here are <b>ROM-free</b>: the board loads your own ROMs "
            "into them at power-up, from a <i>&lt;machine&gt;.roms</i> file "
            "in its flash. A bitstream you built yourself normally has them "
            "<b>baked in</b> and needs no such file. Right now: "
            + "; ".join(f"<b>{m}</b> — {rows[m].detail}" for m in bad)
            + (".<br>This app cannot read a bitstream back off the board, so "
               "for " + ", ".join(self._rom_unsure) + " it cannot tell which "
               "kind is up there. If the machine starts, say so with the "
               "second button and the warning stops."
               if self._rom_unsure else "")
            + "<br>To install ROMs: tick the box below, then press the "
              "button — it downloads them from the VICE project, packs them "
              "and uploads them to the board.")
        self.rom_baked_btn.setVisible(bool(self._rom_unsure))
        self.rom_baked_btn.setText(
            "It has its own ROMs — stop warning"
            if len(self._rom_unsure) < 2 else
            "They have their own ROMs — stop warning")
        self.rom_banner.show()

    def _rom_mark_baked(self):
        """Take the user's word for the thing the link cannot tell us.

        Recorded against the bitstream's own checksum, not its name, so
        replacing that machine's bit asks the question again instead of
        inheriting an answer given about a different file."""
        from . import install_backend as inst
        rows = {b.machine: b for b in
                inst.board_machines(self._entries, baked=self._baked)}
        names = [rows[m].bit for m in getattr(self, "_rom_unsure", [])
                 if rows.get(m) and rows[m].bit]
        if not names:
            return

        def worker():
            for name in names:
                got = self.ops.fs_stat(name).get("sum32")
                if got is None:
                    raise board.BoardError(
                        f"this firmware cannot checksum {name}, so the answer "
                        "cannot be tied to a particular bitstream")
                self.ops.kv_set(inst.KV_BIT_PREFIX + name,
                                inst._kv_bit_pack(False, got))
            return names
        self._run(worker, on_done=lambda ns: (
            self._msg(f"noted: {', '.join(ns)} carry their own ROMs"),
            self.refresh()))

    def _rom_explain(self):
        QMessageBox.information(
            self, "Why ROMs are not included",
            "A Commodore 64 (or 16, or Plus/4) is not just a chip layout — it "
            "boots from Commodore's KERNAL and BASIC ROM images, which are "
            "still under copyright. This project ships no ROM bytes: not in "
            "the repository, not in the bitstreams, not in the firmware.\n\n"
            "What it ships instead are ROM-FREE bitstreams. Their ROM arrays "
            "are empty and the board holds the machine in reset until the "
            "ROMs are pushed in over the link at power-up — so a machine "
            "without them stays dark rather than running on garbage.\n\n"
            "The button fetches the images from the VICE emulator project "
            "for your own use, packs them into one <machine>.roms file and "
            "uploads it. If you already own dumps, you can put them in "
            "retro-arch/<machine>/roms/ instead and use the Install tab.")

    def _rom_install(self):
        from . import install_backend as inst
        if not self.rom_consent.isChecked():
            self._msg("the consent box has to be ticked first")
            return
        steps = inst.rom_install_plan()
        self.rom_go.setEnabled(False)
        self._msg(f"ROM install: {len(steps)} local step(s), then upload")
        # local steps + one upload per machine that still needs something
        self._rom_prog_begin(len(steps) + 2 * len(inst.MACHINES))

        runner = inst.Runner()

        have = {b.machine: b for b in inst.board_machines(self._entries)}

        def worker(progress=None):
            runner.run(steps, progress)          # download + build containers
            sent = []
            for m in inst.MACHINES:
                path = inst.roms_container_path(m)
                if not os.path.isfile(path):
                    progress(f"{m}: no container was built — skipping")
                    continue
                # ROMs first, then the bitstream if the board has none: the
                # fabric holds the machine until its banks arrive, so an
                # interrupted run should leave ROMs waiting for a bit rather
                # than a bit waiting for ROMs.
                with open(path, "rb") as fh:
                    data = fh.read()
                name = f"{m}.roms"
                progress(f"uploading {name} ({len(data)} bytes)")
                self.ops.fs_upload(name, data, progress=progress,
                                   ftype=board.FT_ROM, platform=m)
                sent.append(name)

                if have.get(m) and have[m].state != "no-bit":
                    continue
                bit = inst.shipped_bitstream(m)
                if not bit:
                    progress(f"{m}: no bitstream on the board and none "
                             f"shipped — synthesize one on the Install tab")
                    continue
                with open(bit, "rb") as fh:
                    data = fh.read()
                progress(f"uploading {m}.bit ({len(data)} bytes) from "
                         f"{os.path.basename(bit)}")
                self.ops.fs_upload(f"{m}.bit", data, progress=progress,
                                   ftype=board.FT_BIT, platform=m)
                sent.append(f"{m}.bit")
            return sent

        if not self.mgr.is_open:
            self._msg("not connected — connect the board on the Connection "
                      "tab first")
            self.rom_go.setEnabled(True)
            self.rom_prog.hide()
            return
        task = Task(worker, wants_progress=True)
        start_task(
            self.pool, task, on_done=self._rom_install_done,
            on_error=lambda tb: self._rom_install_failed(tb),
            on_progress=lambda m: (self._msg(m), self._rom_prog_line(m)))

    def _rom_install_failed(self, tb):
        self.rom_go.setEnabled(True)
        self.rom_prog.setFormat("failed")
        self._msg("ERROR: " + tb.strip().splitlines()[-1])

    def _rom_install_done(self, sent):
        self.rom_go.setEnabled(True)
        self.rom_prog.setValue(100)
        self.rom_prog.setFormat("done")
        if sent:
            self._msg("uploaded: " + ", ".join(sent)
                      + " — power-cycle or re-select the machine in the BIOS")
        else:
            self._msg("nothing was uploaded — see the messages above")
        self.refresh()

    def refresh(self):
        self._run(self._gather_status, on_done=self._show_status)

    def _gather_status(self):
        out = {"files": self.ops.fs_list()}
        try:
            out["info"] = self.ops.boot_info()
        except Exception as e:                       # noqa: BLE001
            out["info"] = {"boot": None, "error": str(e)}
        try:
            out["version"] = self.ops.version()
        except Exception as e:                       # noqa: BLE001
            out["version"] = {"fw": "?", "bit": "?", "error": str(e)}
        try:
            out["active"] = self.ops.active_games(out["files"])
        except Exception:                            # noqa: BLE001
            # Cosmetic: a board that will not answer the KV read still has a
            # file list worth showing.
            out["active"] = {}
        from . import install_backend as inst
        try:
            out["baked"] = inst.board_bit_roms(self.ops, out["files"])
        except Exception:                            # noqa: BLE001
            # Only decides whether a warning is shown; never worth the list.
            out["baked"] = {}
        return out

    def _show_status(self, st):
        entries = st["files"]
        self._entries = entries
        info = st.get("info", {})
        ver = st.get("version", {})
        self._boot = info.get("boot")
        self._active = {k.lower(): v
                        for k, v in (st.get("active") or {}).items()}
        self._baked = st.get("baked") or {}
        self.info_lbl.setText(
            f"fw {ver.get('fw', '?')}   bit {ver.get('bit', '?')}   "
            f"boot {self._boot or '(none)'}   "
            f"free {info.get('free_kb', '?')} KB "
            f"(gap {info.get('gap_kb', '?')} KB)")
        self._update_rom_banner(entries)

        # Both lists are grouped by machine and alphabetical inside it, so a
        # game is where you would look for it and the two tables line up.
        # Files with no platform tag (older uploads) go last: they belong to
        # no machine, so they must not sit above the ones that do.
        def order(e):
            arch = (e.arch or "").lower()
            return (arch in ("", "?"), arch, (e.name or "").lower())

        # A ROM set belongs with the machine it feeds, not among the games: it
        # is not something you launch, and a c64 that will not start is
        # answered by looking at the machine box.  Sorting by (arch, kind)
        # puts each <machine>.roms directly under its bitstream.
        def morder(e):
            arch = (e.arch or "").lower()
            return (arch in ("", "?"), arch, e.kind != "bitstream",
                    (e.name or "").lower())

        machines = sorted((e for e in entries
                           if e.kind in ("bitstream", "roms")), key=morder)
        # Everything else, not a whitelist of kinds: a file kind a newer
        # firmware invents must still be visible and deletable.
        games = sorted((e for e in entries
                        if e.kind not in ("bitstream", "roms")), key=order)
        self._machines, self._games = machines, games

        self.mach_tbl.setRowCount(0)
        for e in machines:
            i = self.mach_tbl.rowCount()
            self.mach_tbl.insertRow(i)
            live = e.kind != "roms" and e.name == self._boot
            mark = "ROMs" if e.kind == "roms" else (ACTIVE_MARK if live else "")
            for c_, v in enumerate([e.arch, e.name, str(e.size), mark]):
                self.mach_tbl.setItem(i, c_, QTableWidgetItem(v))
            if live:
                _paint_active(self.mach_tbl, i,
                              "the machine this board is running — it is the "
                              "boot bitstream, and only its games can start")
        self.game_tbl.setRowCount(0)
        for e in games:
            i = self.game_tbl.rowCount()
            self.game_tbl.insertRow(i)
            live = self._is_active(e)
            for c_, v in enumerate([e.arch, e.name, str(e.size), e.kind,
                                    ACTIVE_MARK if live else ""]):
                self.game_tbl.setItem(i, c_, QTableWidgetItem(v))
            if live:
                _paint_active(self.game_tbl, i,
                              f"the game {e.arch or 'this machine'} would "
                              "start — the last one launched on it")
        self._loaded = True
        if not self._restore_cursor():
            self._select_default_machine()
        self._msg(f"{len(machines)} machine(s), {len(games)} game(s)")

    def _restore_cursor(self) -> bool:
        """Put the cursor back where the user was working after a refresh.
        Deleting a file used to clear the selection, so removing five games
        meant five extra clicks."""
        keep, self._keep_cursor = self._keep_cursor, None
        if not keep:
            return False
        table, row = keep
        n = table.rowCount()
        if not n:
            return True                    # nothing left to point at
        table.selectRow(min(row, n - 1))   # the row that slid up into place
        return True

    def _is_active(self, e) -> bool:
        """Is this the game its machine would start?  One per machine, not one
        per board: the BIOS remembers a game for the c64 and another for the
        c16, and both are "active" — on the machine they belong to."""
        return self._active.get((e.arch or "").lower()) == e.name

    # -- the two lists move together ----------------------------------------
    def _select_default_machine(self):
        """Land on the machine the board would boot into — that is the one
        the user is about to play — falling back to the first alphabetically
        when no boot bitstream is set."""
        if not self._machines:
            return
        row = next((i for i, e in enumerate(self._machines)
                    if e.name == self._boot),
                   next((i for i, e in enumerate(self._machines)
                         if e.kind == "bitstream"), 0))
        self.mach_tbl.selectRow(row)          # fires _machine_picked

    def _machine_picked(self):
        r = self.mach_tbl.currentRow()
        if not (0 <= r < len(self._machines)):
            return
        self._show_games_of(self._machines[r].arch)

    def _show_games_of(self, arch):
        """Put the Games cursor on `arch`'s game: the active one if the BIOS
        remembers one, else the first.  Games of other machines stay listed —
        hiding them would make 'where did it go?' the next question — but the
        cursor tells you where you are."""
        same = [i for i, e in enumerate(self._games)
                if (e.arch or "").lower() == (arch or "").lower()]
        row = next((i for i in same if self._is_active(self._games[i])),
                   same[0] if same else None)
        if row is None:
            self.game_tbl.clearSelection()
            self.game_tbl.setCurrentCell(-1, -1)
            return
        self.game_tbl.selectRow(row)
        self.game_tbl.scrollToItem(self.game_tbl.item(row, 1))

    # -- machines -----------------------------------------------------------
    def _selected_bitstream(self):
        """The selected machine row, refusing a ROM set.  The box lists both
        (a .roms sits under the machine it feeds) and neither booting nor
        setting boot means anything for one."""
        name = self._selected_name(self.mach_tbl)
        if not name:
            self._msg("select a bitstream first")
            return None
        r = self.mach_tbl.currentRow()
        if 0 <= r < len(self._machines) and self._machines[r].kind == "roms":
            self._msg(f"\"{name}\" is a ROM set, not a machine — it is "
                      "loaded automatically by the bitstream above it")
            return None
        return name

    def _set_boot(self):
        name = self._selected_bitstream()
        if not name:
            return
        self._run(self.ops.set_boot, name,
                  on_done=lambda _r: (self._msg(f"boot = {name}"),
                                      self.refresh()))

    def _boot_machine(self):
        name = self._selected_bitstream()
        if not name:
            return
        # No confirmation: booting a machine is what this button is for, it is
        # undone by booting another one, and the dialog stood between the user
        # and every single machine change.  What it used to explain is said in
        # the log instead, where it does not have to be clicked away.
        self._msg(f"programming the FPGA with \"{name}\"… (a firmware without "
                  "live FPGA_PROG sets it as boot and reboots the MCU — the "
                  "app reconnects by itself)")
        dev = self.mgr.device
        def worker():
            self.ops.fpga_prog(name)
            return name
        self._run(worker, on_done=lambda n: self._after_boot(n, dev))

    def _after_boot(self, name, dev):
        self._msg(f"boot requested: {name}")
        if self.connection is not None:
            self.connection.reconnect_after(dev, name)

    # -- games --------------------------------------------------------------
    def _mount(self):
        name = self._selected_name(self.game_tbl)
        if not name:
            self._msg("select a game first")
            return
        self._run(self.ops.mount, name,
                  on_done=lambda _r: self._msg(f"mounted {name}"))

    def _run_game(self):
        name = self._selected_name(self.game_tbl)
        if not name:
            self._msg("select a game first")
            return
        if name.lower().endswith(".crt"):
            # A cartridge is inserted by the BIOS (it streams the image into
            # the running bitstream's cart port and resets); there is no disk
            # to mount and nothing to type — EasyFlash carts boot themselves.
            self._run(self.ops.bios_launch, name,
                      on_done=lambda _r: self._msg(f"cartridge {name} inserted"))
            return
        delay = self.run_delay.value()
        self._run(self.ops.run_game, name, run_delay=delay,
                  wants_progress=True,
                  on_done=lambda _r: self._msg(f"{name}: LOAD/RUN typed"))

    # -- files --------------------------------------------------------------
    def _ask_tag(self, name, want=None):
        """Mandatory platform/type dialog for an upload.  Returns
        (ftype, platform) or None when cancelled."""
        from PySide6.QtWidgets import QInputDialog
        ftype_guess, plat_guess = board.infer_tag(name)
        choices = [c for c in self._UPLOAD_CHOICES
                   if want is None or c[1] == want or c[2] is None]
        labels = [c[0] for c in choices]
        default = 0
        if ftype_guess == board.FT_GAME:
            default = next((i for i, c in enumerate(choices)
                            if c[2] == plat_guess), len(labels) - 1)
        label, ok = QInputDialog.getItem(
            self, "File platform",
            f"What is {name}?\n(the BIOS lists games under their platform)",
            labels, default, False)
        if not ok:
            return None
        _, ftype, plat = choices[labels.index(label)]
        if plat is None:                     # bitstream or custom platform
            what = ("platform this bitstream implements"
                    if ftype == board.FT_BIT else "platform the game runs on")
            plat, ok = QInputDialog.getText(
                self, "Platform", f"{what} (e.g. c64, mycore):",
                text=plat_guess or "")
            if not ok or not plat.strip():
                return None
        try:
            return ftype, board.norm_platform(plat)
        except board.BoardError as e:
            self._msg(str(e))
            return None

    def _pick_bitstream(self):
        """(path, flash name, platform) for a machine — from the list of
        builds, not a file dialog.  Returns None when cancelled."""
        from . import bitfiles
        bits = bitfiles.discover()
        if bits:
            dlg = BitstreamPicker(self, bits)
            if dlg.exec() != QDialog.Accepted:
                return None
            if not dlg.browse:
                b = dlg.chosen
                return b.path, dlg.name(), (b.arch if b.arch != "?" else None)
        else:
            self._msg("no built bitstreams found — pick a file instead")
        path, _f = QFileDialog.getOpenFileName(
            self, "Machine bitstream", "",
            "Machine bitstreams (*.bit);;All files (*)")
        if not path:
            return None
        import os
        return path, os.path.basename(path), None

    def _upload(self, want=None):
        import os
        name = platform = None
        if want == board.FT_BIT:
            picked = self._pick_bitstream()
            if picked is None:
                return
            path, name, platform = picked
        else:
            path, _f = QFileDialog.getOpenFileName(
                self, "Add a file to the board", "",
                "Board files (*.d64 *.prg *.crt *.fat "
                "*.roms);;All files (*)")
            if not path:
                return
            name = os.path.basename(path)
        ftype = want
        if platform is None:
            tag = self._ask_tag(name, want)
            if tag is None:
                self._msg("upload cancelled (a platform is required)")
                return
            ftype, platform = tag
        else:
            try:
                platform = board.norm_platform(platform)
            except board.BoardError as e:
                self._msg(str(e))
                return
        with open(path, "rb") as fh:
            data = fh.read()
        self._msg(f"uploading {name} ({len(data)} bytes, "
                  f"{'bitstream' if ftype == board.FT_BIT else 'game'} "
                  f"for {platform})…")
        self.progress.setValue(0)
        total = max(1, len(data))

        def progress_hook(msg):
            m = None
            if msg.startswith("upload "):
                try:
                    m = int(msg.split()[1].split("/")[0])
                except (ValueError, IndexError):
                    m = None
            if m is not None:
                self.progress.setValue(int(100 * m / total))
            return msg

        if not self.mgr.is_open:
            self._msg("not connected")
            return
        def worker(progress=None):
            self.ops.fs_upload(name, data, progress=progress, ftype=ftype,
                               platform=platform)
            if ftype == board.FT_BIT:
                # The one moment the flash name and the local file are known
                # to be the same thing: record whether it carries its own
                # ROMs, so the banner never has to guess about this one.
                from . import install_backend as inst
                inst.remember_bit_roms(self.ops, name, path)

        task = Task(worker, wants_progress=True)
        start_task(
            self.pool, task,
            on_done=lambda _r: (self.progress.setValue(100),
                                self._msg(f"uploaded {name}"),
                                self.refresh()),
            on_error=lambda tb: self._msg(
                "ERROR: " + tb.strip().splitlines()[-1]),
            on_progress=lambda m: (progress_hook(m), self._msg(m))
            if "bytes" not in m else progress_hook(m))

    def _download(self, table):
        name = self._selected_name(table)
        if not name:
            self._msg("select a file first")
            return
        path, _f = QFileDialog.getSaveFileName(self, "Save file", name)
        if not path:
            return

        def worker(progress=None):
            data = self.ops.fs_download(name, progress=progress)
            with open(path, "wb") as fh:
                fh.write(data)
            return f"saved {len(data)} bytes to {path}"
        self._run(worker, wants_progress=True, on_done=self._msg)

    @staticmethod
    def _selected_names(table, col: int = 1) -> list:
        """Every selected row's name, in table order — shift+arrows and
        ctrl+click both land here."""
        rows = sorted({i.row() for i in table.selectedIndexes()})
        return [table.item(r, col).text() for r in rows
                if table.item(r, col)]

    def _delete(self, table):
        names = self._selected_names(table)
        if not names:
            self._msg("select a file first")
            return
        what = names[0] if len(names) == 1 else f"{len(names)} files"
        detail = "" if len(names) == 1 else "\n\n" + "\n".join(names[:12]) + (
            f"\n… and {len(names) - 12} more" if len(names) > 12 else "")
        if QMessageBox.question(self, "Delete",
                                f"Delete \"{what}\"?{detail}") \
                != QMessageBox.Yes:
            return
        # Where the cursor should end up: deleting five games in a row must
        # not mean five trips back to the list to click again.
        row = min(i.row() for i in table.selectedIndexes())

        def worker(progress=None):
            done = []
            for n in names:
                self.ops.fs_delete(n)
                done.append(n)
                if progress:
                    progress(f"deleted {n}")
            return done
        self._run(worker, wants_progress=True,
                  on_done=lambda done: self._after_delete(table, done, row))

    def _after_delete(self, table, done, row):
        self._msg(f"deleted {len(done)} file(s)")
        self._keep_cursor = (table, row)
        self.refresh()

    def _stat(self):
        name = self._selected_name(self.game_tbl)
        if not name:
            self._msg("select a file first")
            return
        self._run(self.ops.fs_stat, name,
                  on_done=lambda st: self._msg(
                      f"{name}: {st['size']} bytes, crc32 {st['crc32']:08x}"))

    def _format(self):
        if QMessageBox.warning(
                self, "Format flash FS",
                "Delete ALL files on the board flash?\nThis cannot be "
                "undone.", QMessageBox.Yes | QMessageBox.No,
                QMessageBox.No) != QMessageBox.Yes:
            return
        self._run(self.ops.fs_format,
                  on_done=lambda _r: (self._msg("formatted"), self.refresh()))

    # -- per-game settings --------------------------------------------------
    def _settings(self):
        """Per-game settings: read the profile off the board, edit it, write
        it back.  The key is `g.<flash-name>` — see library/profile.py and
        the board firmware."""
        name = self._selected_name(self.game_tbl)
        if not name:
            self._msg("select a game first")
            return
        key = gprofile.kv_key(name)
        self._run(self.ops.kv_get, key,
                  on_done=lambda blob: self._settings_edit(name, blob))

    def _settings_edit(self, name: str, blob):
        text = ""
        if blob:
            text = bytes(blob).decode("utf-8", "replace")
        dlg = GameSettingsDialog(self, name, text)
        if dlg.exec() != QDialog.Accepted:
            return
        new = dlg.blob()
        if new == text:
            self._msg("settings unchanged")
            return
        # There is no KV delete over the link, and none is needed: the BIOS
        # treats an empty profile as no profile (gpActive() is false), and
        # gpSave() drops the entry the next time it writes one.
        self._run(self.ops.kv_set, gprofile.kv_key(name),
                  new.encode("utf-8"),
                  on_done=lambda _r: (
                      self._msg(f"settings for {name}: "
                                f"{gprofile.describe(new)}"),
                      self._kv_refresh()))

    # -- KV -----------------------------------------------------------------
    def _kv_refresh(self):
        self._run(self.ops.kv_list, on_done=self._kv_show)

    def _kv_show(self, items):
        self.kv_tbl.setRowCount(0)
        for key, val in items:
            i = self.kv_tbl.rowCount()
            self.kv_tbl.insertRow(i)
            self.kv_tbl.setItem(i, 0, QTableWidgetItem(key))
            self.kv_tbl.setItem(i, 1, QTableWidgetItem(val.hex(" ")))
        self._msg(f"{len(items)} KV entr{'y' if len(items) == 1 else 'ies'}")

    def _kv_set(self):
        key = self.kv_key.text().strip()
        hexval = self.kv_val.text().strip().replace(" ", "")
        if not key or not hexval:
            self._msg("key and hex value required")
            return
        try:
            val = bytes.fromhex(hexval)
        except ValueError:
            self._msg("invalid hex value")
            return
        self._run(self.ops.kv_set, key, val,
                  on_done=lambda _r: (self._msg(f"{key} = {val.hex()}"),
                                      self._kv_refresh()))


# ── the start-up key sequence, as a list of steps ──────────────────────────
class MacroEditor(QWidget):
    """Edit a game's start-up key sequence as one action per row.

    "Three seconds after the LOAD, press C=; four seconds later fire; two
    seconds later K" is a sentence anyone can write down, and
    `@3000;{c=};@4000;#a;@2000;k` is not — but the second one is what fits in
    255 bytes of flash.  This is the first form; library/profile.py converts.

    The grammar lives in profile.py (parse_macro/build_macro/step_label), so
    this class only owns widgets: one Action combo per row, plus a Detail
    editor whose type follows the action.
    """

    changed = Signal()

    _ACTIONS = [
        ("Wait for the machine to start", gprofile.WAIT_BOOT),
        ("Wait for the game to load", gprofile.WAIT_LOAD),
        ("Wait…", gprofile.WAIT_MS),
        ("Type text", gprofile.TEXT),
        ("Press a key", gprofile.KEY),
        ("Joystick / button", gprofile.BUTTON),
    ]

    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)

        self.tbl = QTableWidget(0, 2)
        self.tbl.setHorizontalHeaderLabels(["Action", "Detail"])
        self.tbl.verticalHeader().setVisible(False)
        self.tbl.setSelectionBehavior(QTableWidget.SelectRows)
        self.tbl.setSelectionMode(QTableWidget.SingleSelection)
        self.tbl.setEditTriggers(QTableWidget.NoEditTriggers)
        hdr = self.tbl.horizontalHeader()
        hdr.setSectionResizeMode(0, QHeaderView.Fixed)
        hdr.setSectionResizeMode(1, QHeaderView.Stretch)
        self.tbl.setColumnWidth(0, 220)
        self.tbl.setMinimumHeight(150)
        lay.addWidget(self.tbl)

        row = QHBoxLayout()
        self.add_btn = QPushButton("Add step")
        self.add_btn.clicked.connect(lambda: self._append_default())
        self.del_btn = QPushButton("Remove")
        self.del_btn.clicked.connect(self._remove)
        self.up_btn = QPushButton("↑")
        self.dn_btn = QPushButton("↓")
        self.up_btn.clicked.connect(lambda: self._move(-1))
        self.dn_btn.clicked.connect(lambda: self._move(+1))
        for b in (self.add_btn, self.del_btn, self.up_btn, self.dn_btn):
            row.addWidget(b)
        row.addStretch(1)
        lay.addLayout(row)

    # -- model ---------------------------------------------------------------
    def steps(self) -> list:
        out = []
        for r in range(self.tbl.rowCount()):
            kind = self.tbl.cellWidget(r, 0).currentData()
            out.append(gprofile.Step(kind, self._value(r, kind)))
        return out

    def set_steps(self, steps):
        self.tbl.setRowCount(0)
        for s in steps:
            self._append(s)

    def macro(self) -> str:
        return gprofile.build_macro(self.steps())

    def set_macro(self, macro: str):
        self.set_steps(gprofile.parse_macro(macro))

    # -- rows ----------------------------------------------------------------
    def _append_default(self):
        """A new row defaults to a short wait — the step people actually add
        between two things that already work."""
        self._append(gprofile.Step(gprofile.WAIT_MS, "2000"))
        self.tbl.selectRow(self.tbl.rowCount() - 1)
        self.changed.emit()

    def _append(self, step):
        r = self.tbl.rowCount()
        self.tbl.insertRow(r)
        cb = QComboBox()
        for label, kind in self._ACTIONS:
            cb.addItem(label, kind)
        i = cb.findData(step.kind)
        cb.setCurrentIndex(i if i >= 0 else 0)
        cb.currentIndexChanged.connect(
            lambda _i, c=cb: self._action_changed(c))
        self.tbl.setCellWidget(r, 0, cb)
        self.tbl.setCellWidget(r, 1, self._detail_widget(step))
        self.tbl.setRowHeight(r, 30)

    def _row_of(self, combo) -> int:
        for r in range(self.tbl.rowCount()):
            if self.tbl.cellWidget(r, 0) is combo:
                return r
        return -1

    def _action_changed(self, combo):
        r = self._row_of(combo)
        if r < 0:
            return
        kind = combo.currentData()
        default = {gprofile.WAIT_MS: "2000", gprofile.KEY: "ret",
                   gprofile.BUTTON: "a", gprofile.TEXT: ""}.get(kind, "")
        self.tbl.setCellWidget(r, 1,
                               self._detail_widget(gprofile.Step(kind, default)))
        self.changed.emit()

    def _detail_widget(self, step):
        kind = step.kind
        if kind == gprofile.WAIT_MS:
            w = QDoubleSpinBox()
            w.setRange(0.0, 65.0)
            w.setSingleStep(0.5)
            w.setDecimals(1)
            w.setSuffix(" seconds")
            try:
                w.setValue(int(step.value) / 1000.0)
            except (TypeError, ValueError):
                w.setValue(2.0)
            w.valueChanged.connect(lambda _v: self.changed.emit())
            return w
        if kind in (gprofile.KEY, gprofile.BUTTON):
            w = QComboBox()
            labels = (gprofile.KEY_LABELS if kind == gprofile.KEY
                      else gprofile.BUTTON_LABELS)
            for name, label in labels:
                w.addItem(label, name)
            i = w.findData(step.value)
            if i < 0 and step.value:        # a name from a newer firmware
                w.addItem(step.value, step.value)
                i = w.count() - 1
            w.setCurrentIndex(max(0, i))
            if kind == gprofile.BUTTON:
                w.setToolTip(
                    "Joystick and fire-button steps are stored and shipped, "
                    "but this firmware does not press them yet — it needs "
                    "the virtual-joystick RTL (profiles plan, phase 5).")
            w.currentIndexChanged.connect(lambda _i: self.changed.emit())
            return w
        if kind == gprofile.TEXT:
            w = QWidget()
            h = QHBoxLayout(w)
            h.setContentsMargins(0, 0, 0, 0)
            ed = QLineEdit(gprofile.text_body(step.value))
            ed.setPlaceholderText('what to type, e.g. load"*",8,1')
            ed.setStyleSheet("font-family:monospace;")
            cbx = QCheckBox("then Return")
            cbx.setChecked(gprofile.text_has_enter(step.value))
            h.addWidget(ed, 1)
            h.addWidget(cbx)
            w.ed, w.cbx = ed, cbx
            ed.textChanged.connect(lambda _t: self.changed.emit())
            cbx.toggled.connect(lambda _b: self.changed.emit())
            return w
        lab = QLabel({
            gprofile.WAIT_BOOT: "…after a reset, before typing anything",
            gprofile.WAIT_LOAD: "…until the drive stops loading",
        }.get(kind, ""))
        lab.setStyleSheet("color:#888;")
        return lab

    def _value(self, row: int, kind: str) -> str:
        w = self.tbl.cellWidget(row, 1)
        if kind == gprofile.WAIT_MS:
            return str(int(round(w.value() * 1000)))
        if kind in (gprofile.KEY, gprofile.BUTTON):
            return w.currentData() or ""
        if kind == gprofile.TEXT:
            return gprofile.text_step(w.ed.text(), w.cbx.isChecked())
        return ""

    def _remove(self):
        r = self.tbl.currentRow()
        if r < 0:
            return
        self.tbl.removeRow(r)
        self.changed.emit()

    def _move(self, delta: int):
        r = self.tbl.currentRow()
        n = self.tbl.rowCount()
        if r < 0 or not (0 <= r + delta < n):
            return
        steps = self.steps()
        steps[r], steps[r + delta] = steps[r + delta], steps[r]
        self.set_steps(steps)
        self.tbl.selectRow(r + delta)
        self.changed.emit()


# ── the per-game settings dialog (used by the Board and Library tabs) ──────
class GameSettingsDialog(QDialog):
    """View / edit one game's per-game settings — the profile the board keeps
    in KV under `g.<flash-name>` and applies when that game launches
    (the board firmware's per-game profile store).

    Pure UI over a text blob: the panel does the board I/O.  Every row's first
    entry is "Use global", which is how an override is created and removed —
    a profile key exists exactly when a row is off it, the same rule the BIOS
    screen uses.  Keys this app does not understand are preserved verbatim
    (gprofile.update), so editing here can never silently drop settings a
    newer firmware wrote.
    """

    # token -> label.  The tokens are wire format (they live in flash); the
    # labels are ours to change.
    _DRIVE = [("fastload", "Fastload (QSPI)"), ("1541", "Real 1541 (IEC)"),
              ("auto", "Auto — decided by the disk"), ("dos", "DOS 1541 (link)"),
              ("fpga", "FPGA 1541 (in the fabric)")]
    _SPEED = [("std", "Standard"), ("t15", "Turbo 1.5x"), ("t2", "Turbo 2x")]
    _BTN = [("text", "Text keys"), ("joy1", "Joystick port 1"),
            ("joy2", "Joystick port 2"), ("joyboth", "Joystick both ports")]

    _AS_DEFAULT, _AS_OFF, _AS_CUSTOM = 0, 1, 2

    _STATUS = [("works", "works"), ("issues", "has issues"),
               ("broken", "broken")]

    def __init__(self, parent, name: str, blob: str, db: dict = None):
        """`db` switches the dialog from the board copy of the settings to
        the library's: {"machines": [...], "status": <current verdict>}.
        The settings are the same text either way — only where they are
        stored, and therefore the wording of the accept button, differ."""
        super().__init__(parent)
        self.setWindowTitle(f"Game settings — {name}")
        self.setMinimumWidth(560)
        self._name = name
        self._blob = blob or ""
        self._db = db

        root = QVBoxLayout(self)
        head = QLabel(
            f"<b>{name}</b> — applied by the BIOS when this game starts. "
            "Rows left on <i>Use global</i> follow the main-menu settings.")
        head.setWordWrap(True)          # or it clips at the dialog width
        root.addWidget(head)

        grid = QGridLayout()
        self.cb_drive = self._combo(self._DRIVE)
        self.cb_speed = self._combo(self._SPEED)
        self.cb_btn = self._combo(self._BTN)
        for r, (lab, cb, hint) in enumerate((
                ("Drive mode", self.cb_drive, "Commodore cores"),
                ("CPU speed", self.cb_speed, "cores that support it"),
                ("Buttons", self.cb_btn, "all cores"))):
            grid.addWidget(QLabel(lab + ":"), r, 0)
            grid.addWidget(cb, r, 1)
            grid.addWidget(QLabel(f"<i>{hint}</i>"), r, 2)
        root.addLayout(grid)

        abox = QGroupBox("When the game starts")
        al = QVBoxLayout(abox)
        self.cb_start = QComboBox()
        self.cb_start.addItems([
            "Default — LOAD\"*\",8,1 then RUN on a disc",
            "Off — type nothing",
            "Custom key sequence…",
        ])
        al.addWidget(self.cb_start)
        self.macro_ed = MacroEditor()
        self.macro_ed.changed.connect(self._sync)
        al.addWidget(self.macro_ed)
        self.macro_lbl = QLabel("")
        self.macro_lbl.setWordWrap(True)
        self.macro_lbl.setStyleSheet("color:#666; font-size:11px;")
        al.addWidget(self.macro_lbl)
        root.addWidget(abox)

        # Library copy: the settings are filed per machine, alongside a
        # verdict, because that is what a compat.jsonl line is.
        self.cb_machine = self.cb_status = None
        self.chk_1541 = self.notes_ed = self.by_ed = self.email_ed = None
        self._was_1541 = None
        if db is not None:
            dbox = QGroupBox("Review — recorded in the game library")
            dl = QGridLayout(dbox)
            self.cb_machine = QComboBox()
            for m in db.get("machines") or []:
                self.cb_machine.addItem(m, m)
            self.cb_status = QComboBox()
            for tok, lab in self._STATUS:
                self.cb_status.addItem(lab, tok)
            self._select(self.cb_status, db.get("status") or "works")
            dl.addWidget(QLabel("Machine:"), 0, 0)
            dl.addWidget(self.cb_machine, 0, 1)
            dl.addWidget(QLabel("On it, the game:"), 0, 2)
            dl.addWidget(self.cb_status, 0, 3)
            dl.setColumnStretch(4, 1)       # keep each label beside its combo

            # The drive verdict, which is a fact about the GAME rather than
            # about this test run: some titles talk to the drive in ways no
            # fastload path can serve, and the only thing that runs them is
            # the slow, cycle-accurate 1541.  Worth its own flag because it
            # is the difference between "broken" and "works, just slowly".
            self.chk_1541 = QCheckBox(
                "Needs the real 1541 — no fastload works")
            self.chk_1541.setToolTip(
                "Tick this when the game only runs on the cycle-accurate "
                "1541 emulation: fastload (and AUTO falling back to it) "
                "fails, so the drive has to be the slow real thing.\n"
                "Games with this flag can be found again from the Library's "
                "\"Real 1541\" search box.")
            self.chk_1541.setChecked(bool(db.get("real1541")))
            self._was_1541 = db.get("real1541")
            self.chk_1541.stateChanged.connect(self._real1541_toggled)
            dl.addWidget(self.chk_1541, 1, 0, 1, 5)

            # What the next person needs to know and the database cannot
            # infer: which loader it used, where it hangs, what fixed it.
            self.notes_ed = QPlainTextEdit(db.get("notes") or "")
            self.notes_ed.setMaximumHeight(70)
            self.notes_ed.setPlaceholderText(
                "What happened — how far it got, what was needed, what "
                "still fails.  Long analysis goes in "
                "retro-arch/COMPATIBILITY.md.")
            nlab = QLabel("Notes:")
            nlab.setAlignment(Qt.AlignTop | Qt.AlignLeft)
            dl.addWidget(nlab, 2, 0)
            dl.addWidget(self.notes_ed, 2, 1, 1, 4)

            # Who tested it.  Stored with the report so a maintainer with
            # half a dozen testers can read their results back per person —
            # and has somebody to ask about a surprising one.  Typed once:
            # it is remembered for every later verdict from this machine.
            self.by_ed = QLineEdit(db.get("by") or "")
            self.by_ed.setPlaceholderText("your name")
            self.email_ed = QLineEdit(db.get("email") or "")
            self.email_ed.setPlaceholderText("you@example.com")
            self.email_ed.setToolTip(
                "Recorded with every result you send, so results can be "
                "reviewed per tester.  Typed once — the app remembers it.")
            self.email_ed.textChanged.connect(self._sync)
            dl.addWidget(QLabel("Tested by:"), 3, 0)
            dl.addWidget(self.by_ed, 3, 1)
            dl.addWidget(QLabel("Email:"), 3, 2)
            dl.addWidget(self.email_ed, 3, 3, 1, 2)

            note = QLabel(
                "<i>saved to desktop/library/data/compat.jsonl as one more "
                "report (append-only), and pushed to the board with the game "
                "on the next upload</i>")
            note.setWordWrap(True)
            dl.addWidget(note, 4, 0, 1, 5)
            if not (db.get("machines") or []):
                dbox.setEnabled(False)
            root.addWidget(dbox)
            self.cb_machine.currentIndexChanged.connect(self._machine_changed)

        self.preview = QPlainTextEdit()
        self.preview.setReadOnly(True)
        self.preview.setMaximumHeight(90)
        root.addWidget(QLabel("Stored as:"))
        root.addWidget(self.preview)
        self.status = QLabel("")
        self.status.setWordWrap(True)
        root.addWidget(self.status)

        bb = QDialogButtonBox()
        self.btn_write = bb.addButton(
            "Save settings" if db is not None else "Write to board",
            QDialogButtonBox.AcceptRole)
        self.btn_clear = bb.addButton("Clear", QDialogButtonBox.DestructiveRole)
        bb.addButton("Cancel", QDialogButtonBox.RejectRole)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        self.btn_clear.clicked.connect(self._clear)
        root.addWidget(bb)

        for w in (self.cb_drive, self.cb_speed, self.cb_btn, self.cb_start):
            w.currentIndexChanged.connect(self._sync)

        self._load(self._blob)

    @staticmethod
    def _combo(pairs):
        cb = QComboBox()
        cb.addItem("Use global", None)
        for tok, lab in pairs:
            cb.addItem(lab, tok)
        return cb

    @staticmethod
    def _select(cb, token):
        i = cb.findData(token)
        cb.setCurrentIndex(i if i >= 0 else 0)

    def _load(self, blob: str):
        s = gprofile.parse(blob)
        self._select(self.cb_drive, s.get("drive"))
        self._select(self.cb_speed, s.get("speed"))
        self._select(self.cb_btn, s.get("btn"))
        if "type" not in s:
            self.cb_start.setCurrentIndex(self._AS_DEFAULT)
            self.macro_ed.set_macro(GP_DEFAULT_MACRO)   # a starting point
        elif s["type"] == "":
            self.cb_start.setCurrentIndex(self._AS_OFF)
            self.macro_ed.set_macro("")
        else:
            self.cb_start.setCurrentIndex(self._AS_CUSTOM)
            self.macro_ed.set_macro(s["type"])
        self._sync()

    def _clear(self):
        self._blob = ""
        self._load("")

    # -- library-copy extras (only when constructed with `db`) --------------
    def machine(self):
        return self.cb_machine.currentData() if self.cb_machine else None

    def verdict(self):
        return self.cb_status.currentData() if self.cb_status else None

    def real1541(self):
        """True to flag the game, False to clear a flag somebody had set,
        None to say nothing about the drive.

        An unticked box on a game nobody has assessed is *not* a claim that
        fastload works — the tester may never have tried it — so it writes
        nothing.  It only becomes an explicit False when it is un-ticking a
        flag that was there, which is the one case where silence would leave
        the wrong answer standing (compat.current_real1541)."""
        if self.chk_1541 is None:
            return None
        on = self.chk_1541.isChecked()
        return True if on else (False if self._was_1541 else None)

    def notes(self):
        return (self.notes_ed.toPlainText().strip() if self.notes_ed else "")

    def reviewer(self):
        return self.by_ed.text().strip() if self.by_ed else ""

    def email(self):
        return self.email_ed.text().strip() if self.email_ed else ""

    def _real1541_toggled(self, _state):
        """Ticking the flag pins the drive to the only mode that will run the
        game.  Left on "Use global" or on fastload, the settings the board
        gets would contradict the verdict just recorded."""
        if self.chk_1541.isChecked() and \
                self.cb_drive.currentData() in (None, "fastload"):
            self._select(self.cb_drive, "1541")
        self._sync()

    def _machine_changed(self):
        """Settings are per machine, so switching machines shows that
        machine's settings — not the previous one's, half-edited."""
        look = (self._db or {}).get("lookup")
        if not look:
            return
        cur = look(self.machine()) or {}
        self._blob = cur.get("profile") or ""
        # an untested machine goes back to the default verdict rather than
        # inheriting the previous machine's
        self._select(self.cb_status, cur.get("status") or "works")
        # …and the same for the notes and the drive flag, which are equally
        # per-machine: a c16 report must not inherit the c64's write-up.
        self._was_1541 = cur.get("real1541")
        self.chk_1541.blockSignals(True)      # not a user edit: no auto-pin
        self.chk_1541.setChecked(bool(cur.get("real1541")))
        self.chk_1541.blockSignals(False)
        self.notes_ed.setPlainText(cur.get("notes") or "")
        self._load(self._blob)

    def blob(self) -> str:
        """The profile text this dialog currently describes."""
        mode = self.cb_start.currentIndex()
        macro = (None if mode == self._AS_DEFAULT else
                 "" if mode == self._AS_OFF else self.macro_ed.macro())
        return gprofile.update(self._blob, {
            "drive": self.cb_drive.currentData(),
            "speed": self.cb_speed.currentData(),
            "btn": self.cb_btn.currentData(),
            "type": macro,
        })

    def _sync(self):
        custom = self.cb_start.currentIndex() == self._AS_CUSTOM
        self.macro_ed.setEnabled(custom)
        self.macro_lbl.setText(
            gprofile.describe_macro(self.macro_ed.macro()) if custom else
            "The board types LOAD\"*\",8,1 and RUN by itself on a disc image."
            if self.cb_start.currentIndex() == self._AS_DEFAULT else
            "The board types nothing — start the game yourself.")
        blob = self.blob()
        self.preview.setPlainText(blob or "(nothing set — the game follows "
                                          "the global settings)")
        errs, warns = gprofile.check(blob)
        # A mistyped address is a report nobody can follow up, so it stops the
        # save the same way a malformed profile does.  Empty is fine — the
        # email is a courtesy, not a requirement.
        if self.email() and not gcompat.valid_email(self.email()):
            errs = errs + [f"{self.email()} is not an email address"]
        n = len(blob.encode("utf-8"))
        bits = [f"{n}/{gprofile.MAX} bytes"]
        bits += [f"<span style='color:#c00'>{e}</span>" for e in errs]
        bits += [f"<span style='color:#a60'>{w}</span>" for w in warns]
        self.status.setText("  ·  ".join(bits))
        self.btn_write.setEnabled(not errs)


# ── main window ─────────────────────────────────────────────────────────────
# ── Install tab: first-run setup + reinstall (permanent) ────────────────────
class InstallPanel(_OpsPanel):
    """Bring a fresh checkout + fresh board to a running Commodore machine:
    toolchain → (consented) ROM download → bitstream synthesis → board flash.
    Every action shells out to the same setup.sh / make targets as the
    console flow (install_backend.py),
    and the tab stays available for later modification or reinstall."""

    def __init__(self, mgr, pool: QThreadPool):
        super().__init__(mgr, pool)
        from . import install_backend as inst
        self.inst = inst
        self.runner = None
        self._pretick_done = False

        root = QVBoxLayout(self)

        intro = QLabel(
            "<b>Welcome!</b> Out of the box the console can't run the "
            "Commodore machines: the KERNAL/BASIC ROMs are copyrighted, so "
            "they can't ship with the hardware. Two ways to get there. "
            "<b>With the toolchain:</b> ROMs (your consent) → synthesize "
            "(the ROMs are baked in) → flash. <b>Without it:</b> tick the "
            "ROM-free option — the repo ships those bitstreams prebuilt, and "
            "the board loads your ROMs into them at run time from a "
            "<i>&lt;machine&gt;.roms</i> file this tab builds and uploads. "
            "It stays here for later changes or reinstalls.")
        intro.setWordWrap(True)
        intro.setStyleSheet("color:#888; font-size:12px;")
        root.addWidget(intro)

        # environment status
        g = QGroupBox("Environment")
        gl = QVBoxLayout(g)
        self.tbl = self._table(["component", "status", "detail"])
        self.tbl.setMinimumHeight(180)
        gl.addWidget(self.tbl)
        row = QHBoxLayout()
        b = QPushButton("Refresh")
        b.clicked.connect(self.refresh)
        row.addWidget(b)
        row.addStretch(1)
        gl.addLayout(row)
        root.addWidget(g)

        # options
        g = QGroupBox("Install options")
        gl = QVBoxLayout(g)
        mrow = QHBoxLayout()
        mrow.addWidget(QLabel("Machines:"))
        self.machine_cbs = {}
        for m in inst.MACHINES:
            cb = QCheckBox(m)
            cb.setChecked(True)
            self.machine_cbs[m] = cb
            mrow.addWidget(cb)
        mrow.addStretch(1)
        gl.addLayout(mrow)

        self.cb_tools = QCheckBox(
            "Base tools + FPGA toolchain (oss-cad-suite — needed to "
            "synthesize)")
        self.cb_roms = QCheckBox("Commodore ROMs for the checked machines")
        self.cb_roms.setEnabled(False)
        self.cb_consent = QCheckBox(inst.ROM_CONSENT)
        self.cb_consent.setStyleSheet("font-size:11px;")
        self.cb_consent.toggled.connect(self._consent_toggled)
        self.cb_bits = QCheckBox(
            "Synthesize bitstreams for the checked machines (ROMs are baked "
            "in at synthesis)")
        self.cb_container = QCheckBox(
            "Build <machine>.roms from the downloaded ROMs (needed by the "
            "shipped ROM-free bitstreams)")
        self.cb_romfree = QCheckBox(
            "Flash the shipped ROM-free bitstreams instead of synthesizing "
            "(no toolchain needed — the board loads the ROMs at run time)")
        self.cb_romfree.toggled.connect(self._romfree_toggled)
        for cb in (self.cb_tools, self.cb_roms, self.cb_consent,
                   self.cb_bits, self.cb_romfree, self.cb_container):
            gl.addWidget(cb)
        root.addWidget(g)

        # actions
        row = QHBoxLayout()
        self.btn_install = QPushButton("Run install")
        self.btn_install.clicked.connect(self._install)
        self.btn_flash = QPushButton("Flash bitstreams to board")
        self.btn_flash.clicked.connect(self._flash)
        self.btn_abort = QPushButton("Abort")
        self.btn_abort.setEnabled(False)
        self.btn_abort.clicked.connect(self._abort)
        row.addWidget(self.btn_install)
        row.addWidget(self.btn_flash)
        row.addWidget(self.btn_abort)
        row.addStretch(1)
        root.addLayout(row)

        self.log.setFixedHeight(220)
        root.addWidget(self.log)
        self.refresh()

    # -- environment ---------------------------------------------------------
    def _machines(self):
        return tuple(m for m, cb in self.machine_cbs.items()
                     if cb.isChecked())

    def refresh(self):
        rows = self.inst.all_statuses()
        self.tbl.setRowCount(len(rows))
        color = {"ok": QColor("#2ecc71"), "partial": QColor("#f39c12"),
                 "missing": QColor("#e74c3c")}
        for r, (name, st) in enumerate(rows):
            self.tbl.setItem(r, 0, QTableWidgetItem(name))
            item = QTableWidgetItem(st.state)
            item.setForeground(color.get(st.state, QColor("#7f8c8d")))
            self.tbl.setItem(r, 1, item)
            self.tbl.setItem(r, 2, QTableWidgetItem(st.detail))
        # Every row above is about THIS COMPUTER.  Saying "ok" and meaning
        # "downloaded here" is how a user whose board has no ROMs ends up
        # with nothing to click — so the board's own answer goes on the end,
        # and it is the one the Board tab's red banner reads too.
        self._refresh_board_rows()
        # Pre-tick what's missing (ROMs stay behind the consent gate) — but
        # ONLY on the first look.  Re-ticking on every refresh silently undid
        # the user's own choices, so anything already present could not be
        # re-run: tick "Commodore ROMs", press Refresh, and it un-ticked
        # itself because the files were there (board, 2026-08-05).  A step you
        # cannot repeat is a step you cannot debug.
        if self._pretick_done:
            return
        self._pretick_done = True
        self.cb_tools.setChecked(self.inst.check_tools().state != "ok")
        need_roms = any(self.inst.check_roms(m).state != "ok"
                        for m in self.inst.MACHINES)
        if self.cb_consent.isChecked():
            self.cb_roms.setChecked(need_roms)
        # No toolchain: synthesis cannot work, so offer the shipped ROM-free
        # bits instead — that is the whole point of shipping them.
        have_tools = self.inst.check_tools().state == "ok"
        have_shipped = all(self.inst.shipped_bitstream(m)
                           for m in self.inst.MACHINES)
        if not have_tools and have_shipped:
            self.cb_romfree.setChecked(True)
        self.cb_bits.setChecked(not self.cb_romfree.isChecked())
        self.cb_container.setChecked(
            any(self.inst.check_roms_container(m).state != "ok"
                for m in self.inst.MACHINES))

    def _refresh_board_rows(self):
        """Append one row per machine for what the BOARD holds.  Silent when
        no board is connected — this tab has to work offline."""
        if not self.mgr.is_open:
            return

        def worker():
            return self.ops.fs_list()

        def done(entries):
            rows = self.inst.board_machines(entries)
            base = self.tbl.rowCount()
            self.tbl.setRowCount(base + len(rows))
            color = {"ok": QColor("#2ecc71")}
            for i, bm in enumerate(rows):
                r = base + i
                self.tbl.setItem(r, 0, QTableWidgetItem(
                    f"{bm.machine} ON THE BOARD"))
                item = QTableWidgetItem(
                    "ok" if bm.state == "ok" else "missing")
                item.setForeground(color.get(bm.state, QColor("#e74c3c")))
                self.tbl.setItem(r, 1, item)
                self.tbl.setItem(r, 2, QTableWidgetItem(bm.detail))

        start_task(self.pool, Task(worker), on_done=done,
                   on_error=lambda _tb: None)

    def _consent_toggled(self, on):
        self.cb_roms.setEnabled(on)
        if not on:
            self.cb_roms.setChecked(False)

    def _romfree_toggled(self, on):
        # The two are alternatives, not a combination: synthesizing bakes the
        # ROMs in, which is exactly what the ROM-free path avoids.
        if on:
            self.cb_bits.setChecked(False)
            self.cb_container.setChecked(True)

    # -- install run ---------------------------------------------------------
    def _install(self):
        machines = self._machines()
        steps = self.inst.plan(
            tools=self.cb_tools.isChecked(),
            roms=machines if (self.cb_roms.isChecked()
                              and self.cb_consent.isChecked()) else (),
            bits=machines if self.cb_bits.isChecked() else (),
            containers=machines if self.cb_container.isChecked() else ())
        if not steps:
            self._msg("nothing selected")
            return
        if any(consent for _t, _a, consent in steps) \
                and not self.cb_consent.isChecked():
            self._msg("ROM download needs the consent checkbox")
            return
        self._msg(f"install: {len(steps)} step(s)")
        self.runner = self.inst.Runner()
        self.btn_install.setEnabled(False)
        self.btn_abort.setEnabled(True)
        task = Task(self.runner.run, steps, wants_progress=True)
        start_task(self.pool, task,
                   on_done=lambda _r: self._install_done(None),
                   on_error=lambda tb: self._install_done(
                       tb.strip().splitlines()[-1]),
                   on_progress=self._msg)

    def _install_done(self, err):
        self.btn_install.setEnabled(True)
        self.btn_abort.setEnabled(False)
        self.runner = None
        self._msg(f"install FAILED: {err}" if err else "install finished")
        self.refresh()

    def _abort(self):
        if self.runner is not None:
            self._msg("aborting…")
            self.runner.abort()

    # -- board flash ---------------------------------------------------------
    def _flash(self):
        romfree = self.cb_romfree.isChecked()
        items = self.inst.flash_plan(self._machines(), romfree=romfree)
        for why in self.inst.flash_skipped(self._machines(), romfree=romfree):
            self._msg(f"skipped {why}")
        if not items:
            self._msg("nothing to flash — synthesize a bitstream, or tick "
                      "the ROM-free option and build the .roms containers")
            return

        def worker(progress=None):
            first_bit = None
            for name, path in items:
                with open(path, "rb") as fh:
                    data = fh.read()
                # A .roms container is its own file type; the MCU takes its
                # platform from the name, so a mis-tag cannot feed a c64 the
                # Plus/4 kernal.
                is_bit = name.endswith(".bit")
                progress(f"uploading {name} ({len(data)} bytes) from {path}")
                self.ops.fs_upload(name, data, progress=progress,
                                   ftype=board.FT_BIT if is_bit
                                   else board.FT_ROM,
                                   platform=name.rsplit(".", 1)[0])
                if is_bit and first_bit is None:
                    first_bit = name
            info = self.ops.boot_info()
            if first_bit and not info.get("boot"):
                self.ops.set_boot(first_bit)
                progress(f"boot file set to {first_bit}")
            return [n for n, _p in items]

        self._run(worker, wants_progress=True,
                  on_done=lambda names: self._msg(
                      f"flashed: {', '.join(names)} — select the machine in "
                      "the BIOS (U21) or on the Board tab"))


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("fpgago — companion")
        self.resize(920, 720)
        self.pool = QThreadPool.globalInstance()

        self.mgr = SerialManager()
        tabs = QTabWidget()
        self.conn_panel = ConnectionPanel(self.mgr, self.pool,
                                          self._status_to_bar)
        self.board_panel = BoardPanel(self.mgr, self.pool,
                                      connection=self.conn_panel)
        self.library_panel = LibraryPanel(self.mgr, self.pool,
                                          board_panel=self.board_panel)
        self.install_panel = InstallPanel(self.mgr, self.pool)
        tabs.addTab(self.conn_panel, "Connection")
        tabs.addTab(self.board_panel, "Board")
        tabs.addTab(self.library_panel, "Library")
        tabs.addTab(self.install_panel, "Install")
        self.setCentralWidget(tabs)

        self.statusBar().showMessage("Disconnected")
        self.mgr.start()
        # From here the game database keeps itself up to date and the user's
        # test results leave this machine on their own; the Library tab only
        # speaks up when one of the two could not happen.
        self.library_panel.start_auto_sync()

        # `make start` (FPGAGO_INSTALL_TAB=1) always lands on the Install
        # tab — that command IS the install flow.  A plain `make desktop`
        # goes there only on a fresh setup (no toolchain / no ROMs), so
        # the user is greeted where the answers are, not on an empty
        # Connection tab.
        import os
        from .install_backend import needs_install
        if os.environ.get("FPGAGO_INSTALL_TAB") or needs_install():
            tabs.setCurrentWidget(self.install_panel)

    def _status_to_bar(self, state, detail):
        self.statusBar().showMessage(
            f"MCU: {state}" + (f" — {detail}" if detail else ""))

    def closeEvent(self, e):
        self.mgr.shutdown()
        super().closeEvent(e)


def main():
    app = QApplication(sys.argv)
    w = MainWindow()
    w.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
