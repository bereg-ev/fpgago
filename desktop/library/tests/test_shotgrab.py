"""Tests for the screen grab (app/shotgrab.py + the Library tab's Grab
button).

Run:  cd desktop && python3 -m pytest library/tests -q   (skips without PySide6)

Two claims: SHOT_LINE events assemble into the frame the MCU sent, and what
gets uploaded as a game's screenshot is the machine's own screen — not the
800x480 panel it is doubled onto.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

pytest.importorskip("serial", reason="desktop venv only")
pytest.importorskip("PySide6", reason="desktop venv only")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QThreadPool  # noqa: E402
from PySide6.QtGui import QImage  # noqa: E402
from PySide6.QtWidgets import QApplication, QDialog  # noqa: E402

from app import hostlink  # noqa: E402
from app.shotgrab import (SHOT_ABORT, ShotSession, crop_active,  # noqa: E402
                          margin_for, screen_name)

from test_connection import FakeMgr  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


# ── the crop ───────────────────────────────────────────────────────────────
def make_frame(w=400, h=240, border=0x0000, inner=0xF800,
               inset_x=40, inset_y=20):
    """A panel frame: flat `border` everywhere, `inner` in the middle."""
    img = QImage(w, h, QImage.Format_RGB16)
    img.fill(border)
    for y in range(inset_y, h - inset_y):
        row = img.scanLine(y)
        row[2 * inset_x:2 * (w - inset_x)] = \
            struct.pack("<H", inner) * (w - 2 * inset_x)
    return img


def pixel_at(img, x, y):
    return struct.unpack_from("<H", bytes(img.scanLine(y)), 2 * x)[0]


def test_a_commodore_frame_crops_to_the_display_window(qapp):
    """400x240 of panel, of which the outer ring is border: what is left is
    the 320x200 the game is drawn on."""
    out = crop_active(make_frame(), "c64")
    assert (out.width(), out.height()) == (320, 200)
    assert pixel_at(out, 0, 0) == 0xF800
    assert pixel_at(out, 319, 199) == 0xF800


@pytest.mark.parametrize("platform", ["c64", "c16", "plus4", "264"])
def test_every_commodore_platform_has_the_same_window(qapp, platform):
    out = crop_active(make_frame(), platform)
    assert (out.width(), out.height()) == (320, 200)


def test_a_dense_grab_crops_at_twice_the_margin(qapp):
    """A dense grab is the same picture at 2x, so its border is 2x as wide."""
    out = crop_active(make_frame(w=800, h=480, inset_x=80, inset_y=40), "c64")
    assert (out.width(), out.height()) == (640, 400)


def test_a_machine_without_a_known_window_keeps_the_whole_frame(qapp):
    for platform in ("othercore", "", None):
        out = crop_active(make_frame(), platform)
        assert (out.width(), out.height()) == (400, 240)


def test_platforms_that_disagree_are_not_cropped(qapp):
    """A game filed under several machines is only cropped when they agree
    on one window — they all do today; a future core need not."""
    assert margin_for("c64,plus4") == (40, 20)
    assert margin_for(["c64", "264"]) == (40, 20)
    assert margin_for("c64,othercore") is None
    assert screen_name("c64") == "machine screen"
    assert screen_name("othercore") == "panel"


def test_art_in_the_border_survives(qapp):
    """A game that opens the border and paints into it keeps what it painted:
    an edge is only trimmed while it is one flat colour, and its opposite
    edge goes with it so the picture stays centred."""
    img = make_frame()
    img.scanLine(0)[0:2] = struct.pack("<H", 0x07E0)   # one lit border pixel
    out = crop_active(img, "c64")
    assert (out.width(), out.height()) == (400, 240)
    # …and that one pixel did not get taken for "the border colour" either:
    # three corners still agree, so the sides are measured against real border
    img.scanLine(0)[0:2] = struct.pack("<H", 0x0000)
    assert crop_active(img, "c64").width() == 320


def test_a_wider_flat_run_is_not_over_cropped(qapp):
    """Prince of Persia draws black at the top of its own screen, so 32 rows
    of the frame are flat black — the trim stops at the border's width and
    never eats into the picture (measured on the board grab)."""
    out = crop_active(make_frame(inset_y=32), "c64")
    assert (out.width(), out.height()) == (320, 200)


# ── the assembler ──────────────────────────────────────────────────────────
class Mgr(FakeMgr):
    """FakeMgr plus the two things a grab uses: the protocol table and a
    command() that answers OK."""

    def __init__(self):
        super().__init__()
        self.P = hostlink.Proto(hostlink._EMBEDDED)
        self.sent = []
        self.is_open = True

    def command(self, cmd, payload=b"", timeout=2.0):
        self.sent.append((cmd, payload))
        return (0x00, b"")


def shot_line(line, w, h, flags, fill=0x1234):
    return hostlink.Frame(type=0xE3, seq=0,
                          payload=struct.pack("<HHHB", line, w, h, flags)
                          + struct.pack("<H", fill) * w)


def running_session():
    mgr = Mgr()
    s = ShotSession(mgr, QThreadPool.globalInstance())
    s._running = True                # as if SHOT_GRAB had been acknowledged
    return mgr, s


def feed(session, *frames):
    for fr in frames:
        session._on_link_event(fr)


def test_lines_assemble_into_the_frame(qapp):
    _mgr, s = running_session()
    done = []
    s.finished.connect(done.append)
    feed(s, *[shot_line(y, 4, 3, 0x80 if y == 2 else 0x00, fill=0x1000 + y)
              for y in range(3)])
    assert len(done) == 1
    assert (done[0].width(), done[0].height()) == (4, 3)
    assert pixel_at(done[0], 0, 0) == 0x1000
    assert pixel_at(done[0], 3, 2) == 0x1002
    assert s.lines == 3 and not s.running


def test_an_abort_reports_the_mcus_reason(qapp):
    _mgr, s = running_session()
    why = []
    s.failed.connect(why.append)
    feed(s, hostlink.Frame(type=0xE3, seq=0,
                           payload=struct.pack("<HHHB", 2, 0, 0, 0x40)))
    assert SHOT_ABORT[2] in why[0]
    assert not s.running


def test_a_line_after_the_grab_ended_is_ignored(qapp):
    """The MCU can still have a line in flight when a grab is over; it must
    not start an image nobody asked for."""
    _mgr, s = running_session()
    feed(s, shot_line(0, 4, 1, 0x80))
    s.image = None
    feed(s, shot_line(0, 4, 1, 0x00))
    assert s.image is None


def test_a_short_or_truncated_line_is_dropped(qapp):
    _mgr, s = running_session()
    feed(s, hostlink.Frame(type=0xE3, seq=0, payload=b"\x00\x01\x02"))
    assert s.image is None
    full = shot_line(0, 8, 2, 0x00)
    feed(s, hostlink.Frame(type=0xE3, seq=0, payload=full.payload[:-4]))
    assert s.lines == 0


def test_another_event_is_not_mistaken_for_a_shot_line(qapp):
    _mgr, s = running_session()
    feed(s, hostlink.Frame(type=0xE0, seq=0, payload=b"log line"))
    assert s.image is None


# ── the Library tab's Grab button ──────────────────────────────────────────
def library_panel():
    from app.main import LibraryPanel
    return LibraryPanel(Mgr(), QThreadPool.globalInstance())


def test_grab_needs_a_game_the_database_knows(qapp):
    p = library_panel()
    p._show_shot(None)
    assert not p.grab_btn.isEnabled()
    p._show_shot(4314)
    assert p.grab_btn.isEnabled()


def test_grab_needs_an_account(qapp):
    """A screenshot goes to everybody, so it is refused before the wire, not
    after the grab."""
    p = library_panel()
    p._show_shot(4314)
    p._account = None
    p.do_grab_shot()
    assert not p._grab.running
    assert "sign in" in p.log.toPlainText()


def test_the_game_and_machine_are_pinned_when_the_grab_starts(qapp):
    """A grab takes seconds and the selection can move meanwhile; the picture
    still belongs to the game it was taken for."""
    p = library_panel()
    p._account = {"user": "someone"}
    p._show_games([{"id": 1, "canon_id": 4314, "title": "Prince of Persia",
                    "platforms": "c64"}])
    p.games_tbl.selectRow(0)
    p.do_grab_shot()
    assert p._grab_canon == 4314
    assert p._grab_platform == "c64"
    p._grab.stop(quiet=True)


def test_a_finished_grab_is_cropped_and_offered_for_upload(qapp, monkeypatch):
    from app import main as appmain
    p = library_panel()
    p._show_shot(4314)
    p._grab_canon = 4314
    p._grab_platform = "c64"

    class Accepted:
        def __init__(self, *a, **kw):
            pass

        def exec(self):
            return QDialog.Accepted

    monkeypatch.setattr(appmain, "GrabPreviewDialog", Accepted)
    sent = []
    monkeypatch.setattr(p, "_run", lambda *a, **kw: sent.append(a))

    p._on_grab_done(make_frame())
    assert sent, "an accepted grab uploads"
    _fn, canon_id, path, sub = sent[0]
    assert (canon_id, sub) == (4314, None)     # the game's picture, not an intro
    assert path.endswith("fpgago-grab-4314.png")
    written = QImage(path)
    assert (written.width(), written.height()) == (320, 200)
    os.unlink(path)


def test_a_grab_aimed_at_a_release_becomes_its_crack_intro(qapp, monkeypatch):
    """The cracktro is on screen for a couple of seconds before the game is,
    so grabbing it off the board is how it gets recorded — and it must land on
    the release, not become the picture the whole game is browsed by."""
    from app import main as appmain
    p = library_panel()
    p._show_shot(4193)
    p._grab_canon, p._grab_sub = 4193, 5
    p._grab_platform = "c64"

    class Accepted:
        def __init__(self, *a, **kw):
            pass

        def exec(self):
            return QDialog.Accepted

    monkeypatch.setattr(appmain, "GrabPreviewDialog", Accepted)
    sent = []
    monkeypatch.setattr(p, "_run", lambda *a, **kw: sent.append(a))

    p._on_grab_done(make_frame())
    _fn, canon_id, path, sub = sent[0]
    assert (canon_id, sub) == (4193, 5)
    assert path.endswith("fpgago-grab-4193.5.png")
    os.unlink(path)


def test_a_discarded_grab_uploads_nothing(qapp, monkeypatch):
    from app import main as appmain
    p = library_panel()
    p._show_shot(4314)
    p._grab_canon = 4314

    class Rejected:
        def __init__(self, *a, **kw):
            pass

        def exec(self):
            return QDialog.Rejected

    monkeypatch.setattr(appmain, "GrabPreviewDialog", Rejected)
    sent = []
    monkeypatch.setattr(p, "_run", lambda *a, **kw: sent.append(a))

    p._on_grab_done(make_frame())
    assert not sent
    assert "discarded" in p.log.toPlainText()
