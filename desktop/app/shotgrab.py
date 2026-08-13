"""shotgrab.py — one screen grab off the board, and the crop that turns a
panel frame into the machine's own screen.

The wire side: HL_CMD_SHOT_GRAB starts the MCU job, which
walks the panel frame line by line and relays each one as an HL_EVT_SHOT_LINE
event — header `line u16, w u16, h u16, flags u8`, then `2*w` bytes of RGB565
LE pixels.  flags bit7 marks the last line, bit6 an abort whose reason sits in
the `line` field.  A grab takes a couple of seconds.

Two panels want that: the Screen tab (raw panel frame, with its debug trace)
and the Library tab's "Grab from board", which crops the machine's screen out
of the frame and uploads it as the game's screenshot.  Both drive ShotSession
below, so there is one assembler for the format.
"""

from __future__ import annotations

import struct
import time

from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtGui import QImage

from .tasks import Task, start_task

# Abort reasons the MCU sends as a w = h = 0 SHOT_LINE (shot.h SHOT_ABORT_*).
SHOT_ABORT = {
    1: "the FPGA is not configured — flash a bitstream first",
    2: "the FPGA never captured a line — bitstream without shot_cap, "
       "or no video on the panel",
    3: "QSPI read error on the link",
    4: "the 1541 drive owned the link — stop the drive (or eject the disk) "
       "and grab again",
}

# No SHOT_LINE for this long means the MCU-side job died without saying so.
STALL_MS = 4000


class ShotSession(QObject):
    """One grab: send SHOT_GRAB, assemble the SHOT_LINE events, hand back a
    QImage.  Lives as long as its owner panel; `start()` may be called again
    for each new grab."""

    started = Signal()                  # the MCU accepted the grab
    updated = Signal(object, int, int)  # partial QImage, lines so far, height
    finished = Signal(object)           # complete QImage
    failed = Signal(str)                # human-readable reason, grab is over
    stalled = Signal(int)               # silence after N lines (before failed)
    note = Signal(str)                  # trace line for whoever shows one

    def __init__(self, mgr, pool, parent=None):
        super().__init__(parent)
        self.mgr = mgr
        self.pool = pool
        self.image: QImage | None = None
        self.lines = 0
        self._w = self._h = 0
        self._t0 = 0.0
        self._running = False

        self.mgr.link_event.connect(self._on_link_event)

        self._wd = QTimer(self)
        self._wd.setSingleShot(True)
        self._wd.setInterval(STALL_MS)
        self._wd.timeout.connect(self._on_stall)

    @property
    def running(self) -> bool:
        return self._running

    @property
    def elapsed(self) -> float:
        return time.monotonic() - self._t0

    # -- control ------------------------------------------------------------
    def start(self, dense: bool = False):
        """Ask the MCU for a frame.  dense=False is the 400x240 logical frame
        (one sample per source pixel on the machine cores); dense=True is all
        800x480 panel pixels."""
        flags = 1 if dense else 0
        self._wd.stop()
        self.image = None
        self.lines = 0
        self._w = self._h = 0
        self._t0 = time.monotonic()
        self._running = True
        self.note.emit(f"→ SHOT_GRAB flags={flags}")

        def worker():
            return self.mgr.command(self.mgr.P.HL_CMD_SHOT_GRAB,
                                    bytes([flags]), timeout=3.0)

        start_task(self.pool, Task(worker), on_done=self._on_grab_started,
                   on_error=lambda e: self._fail(
                       f"Grab failed: {e.strip().splitlines()[-1]}"))

    def stop(self, quiet: bool = False):
        """Tell the MCU to drop a running grab."""
        self._wd.stop()
        self._running = False

        def worker():
            return self.mgr.command(self.mgr.P.HL_CMD_SHOT_STOP, b"",
                                    timeout=2.0)

        start_task(self.pool, Task(worker),
                   on_done=lambda _r: None if quiet
                   else self.note.emit("stopped"))

    # -- wire ---------------------------------------------------------------
    def _on_grab_started(self, resp):
        status = resp[0] if isinstance(resp, tuple) else 0x7F
        self.note.emit(f"← SHOT_GRAB status=0x{status:02x}")
        if status == 0:
            self._wd.start()
            self.started.emit()
        else:
            self._fail(f"MCU refused the grab (status 0x{status:02x} — busy, "
                       "or bitstream without shot_cap?)")

    def _fail(self, why: str):
        self._wd.stop()
        self._running = False
        self.failed.emit(why)

    def _on_stall(self):
        self.note.emit(f"watchdog: {STALL_MS // 1000} s of silence after "
                       f"{self.lines} line(s)")
        self.stalled.emit(self.lines)
        if self.lines:
            why = (f"Grab stalled after {self.lines} line(s) — see the Board "
                   "tab console for the MCU's “shot:” message.")
        else:
            why = ("No lines arrived — the MCU accepted the grab but the FPGA "
                   "never captured a line.  Check the Board tab console for "
                   "“shot: … timed out / read error”.")
        self._fail(why)
        self.stop(quiet=True)

    def _on_link_event(self, fr):
        if fr.type != self.mgr.P.get("HL_EVT_SHOT_LINE", 0xE3):
            if self._running:
                self.note.emit(f"event type 0x{fr.type:02x}, "
                               f"{len(fr.payload)} B (not a shot line)")
            return
        if not self._running:
            return                       # a late line from a stopped grab
        p = fr.payload
        if len(p) < 7:
            self.note.emit(f"short SHOT_LINE event: {len(p)} B")
            return
        line, w, h = struct.unpack_from("<HHH", p, 0)
        flags = p[6]
        if self.lines == 0 or line % 60 == 0 or flags & 0xC0:
            self.note.emit(f"← SHOT_LINE line={line} {w}x{h} "
                           f"flags=0x{flags:02x} ({len(p)} B)")
        if flags & 0x40:            # abort: w = h = 0, reason in the line field
            self._fail("Grab aborted by the MCU: "
                       + SHOT_ABORT.get(line, f"reason {line}"))
            return
        if not w or not h:          # malformed / pre-abort-flag firmware
            self._fail("Grab ended early (empty line from the MCU — firmware "
                       "older than the abort reasons?)")
            return
        data = p[7:7 + 2 * w]
        if len(data) < 2 * w:
            return
        if self.image is None or self._w != w or self._h != h:
            self._w, self._h = w, h
            self.image = QImage(w, h, QImage.Format_RGB16)   # RGB565
            self.image.fill(0)
            self.lines = 0
        if line < h:
            # QImage RGB16 scanline is raw RGB565 LE — memcpy the payload
            mv = self.image.scanLine(line)
            mv[:2 * w] = data
            self.lines += 1
        self._wd.start()                       # progress: rearm the watchdog
        self.updated.emit(self.image, self.lines, h)
        if flags & 0x80:
            self._wd.stop()
            self._running = False
            self.finished.emit(self.image)


# ── the machine's screen inside the panel frame ────────────────────────────
# The Commodore cores fill the whole panel: the c64 bit doubles a 400x240
# window of the VIC raster to 800x480 (soc.v LCD_CAP_X0/LCD_VSTART), and the
# TED cores do the same with their own window.  So a grab of a C64 is 400x240
# of picture — of which the outer 40 columns and 20 lines are the machine's
# BORDER, and the 320x200 in the middle is the display window: the screen the
# game is actually drawn on, and what a screenshot of the game means.
# (Measured on a board grab of Prince of Persia: columns 0-39 and 360-399 are
# pure border, the picture is exactly 40..359.)
#
# The trim is content-driven and capped at those numbers rather than fixed, so
# a game that opens the border and paints into it keeps what it painted — an
# edge is only cut while it is one flat colour, which is what a border is.
ACTIVE_MARGIN = {
    "c64":   (40, 20),
    "c16":   (40, 20),
    "plus4": (40, 20),
    "264":   (40, 20),      # c16-or-plus4: same window either way
}


def margin_for(platforms) -> tuple[int, int] | None:
    """The border margin to trim for a game, or None to keep the whole frame.

    `platforms` may be one name, a comma-separated list or a sequence — a
    game filed under several machines only gets a crop when they agree on
    one (they all do, today; a future core with its own geometry would not)."""
    if platforms is None:
        return None
    if isinstance(platforms, str):
        platforms = [p.strip() for p in platforms.split(",")]
    margins = {ACTIVE_MARGIN.get(p) for p in platforms if p}
    if len(margins) != 1:
        return None
    return margins.pop()


def screen_name(platforms) -> str:
    """What the cropped picture is, for the user: 'screen' or 'panel'."""
    return "machine screen" if margin_for(platforms) else "panel"


def crop_active(img: QImage, platforms) -> QImage:
    """The machine's own screen out of a panel grab.

    Trims a flat-coloured border frame off each edge, never more than the
    machine's border is wide, so a normal Commodore frame comes back as the
    320x200 display window and an unusual one (raster bars, art in the
    border) comes back with whatever it drew still in it."""
    margin = margin_for(platforms)
    if img is None or img.isNull() or margin is None:
        return img
    if img.format() != QImage.Format_RGB16:
        img = img.convertToFormat(QImage.Format_RGB16)
    w, h = img.width(), img.height()
    # A dense grab is the same picture at 2x, so the border is 2x as wide.
    scale = max(1, round(w / 400.0))
    max_x, max_y = margin[0] * scale, margin[1] * scale
    if w <= 2 * max_x or h <= 2 * max_y:
        return img

    rows = [bytes(img.scanLine(y))[:2 * w] for y in range(h)]
    # The border colour, not simply the top-left pixel: a game may have put
    # something in one corner, and three corners still agree on the border.
    corners = [rows[0][:2], rows[0][-2:], rows[-1][:2], rows[-1][-2:]]
    bg = max(set(corners), key=corners.count)

    top = 0
    while top < max_y and rows[top] == bg * w:
        top += 1
    bottom = 0
    while bottom < max_y and rows[h - 1 - bottom] == bg * w:
        bottom += 1
    left = 0
    while left < max_x and all(r[2 * left:2 * left + 2] == bg for r in rows):
        left += 1
    right = 0
    while right < max_x and all(
            r[2 * (w - 1 - right):2 * (w - right)] == bg for r in rows):
        right += 1

    # The machine's screen sits centred in the frame, so the crop has to be:
    # each axis trims by whichever of its two edges is flat border for less.
    # An edge with art in it therefore keeps its opposite edge too, instead
    # of sliding the picture off-centre.
    x, y = min(left, right), min(top, bottom)
    if not (x or y):
        return img
    return img.copy(x, y, w - 2 * x, h - 2 * y)
