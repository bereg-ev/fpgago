"""serial_manager.py — USB serial port discovery + liveness for the fpgago MCU.

The MCU (RP2350) exposes a single USB CDC text console (pico-sdk default). We
identify and health-check it over that console:

  * discovery   — enumerate ports; ports on the Raspberry Pi USB vendor id
                  (0x2E8A) are flagged as fpgago candidates and auto-selected.
  * liveness    — a "ping" writes 'H' (the console's harmless help command) and
                  watches the reply for the `fpgago_mcu` identity banner. Seeing
                  it within the timeout ⇒ online; a missing reply or an
                  unplugged port ⇒ offline.

All blocking serial I/O runs on a dedicated reader thread; the class talks to
the GUI purely through Qt signals (queued, thread-safe). No project code outside
this module imports pyserial.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Optional

import serial
import serial.tools.list_ports
from PySide6.QtCore import QObject, QTimer, Signal

from . import hostlink

RPI_VID = 0x2E8A                 # Raspberry Pi (RP2040/RP2350) USB vendor id
IDENTITY = b"fpgago_mcu"         # banner printed by the console 'H' command
BAUD = 115200                    # ignored by USB-CDC, but pyserial wants a value
# Consecutive failed reads (50 ms apart) before the link is called dead.  A
# healthy port throws the odd spurious SerialException on macOS; two solid
# seconds of nothing but errors is a different animal.
READ_FAIL_MAX = 40

# How long the link may stay silent before we do, automatically, the thing the
# user would otherwise do by hand: close the port and open it again.  It was
# measured to fix a stalled link "in a split second" (board, 2026-08-05), so
# making the human perform it was the bug.  Backs off to RECOVER_MAX_S so a
# board that is genuinely dead is not reopened every few seconds forever.
RECOVER_AFTER_S = 6.0
RECOVER_MAX_S = 60.0


@dataclass
class PortInfo:
    device: str
    description: str
    vid: Optional[int]
    pid: Optional[int]
    serial_number: Optional[str]

    @property
    def is_candidate(self) -> bool:
        return self.vid == RPI_VID

    def label(self) -> str:
        ids = ""
        if self.vid is not None and self.pid is not None:
            ids = f"  [{self.vid:04x}:{self.pid:04x}]"
        sn = f"  #{self.serial_number}" if self.serial_number else ""
        return f"{self.device}  —  {self.description}{ids}{sn}"


def all_ports() -> list[PortInfo]:
    """Every serial port the OS reports — diagnostics only."""
    return [PortInfo(p.device, p.description or "?", p.vid, p.pid,
                     p.serial_number)
            for p in serial.tools.list_ports.comports()]


def list_ports() -> list[PortInfo]:
    """Only the fpgago boards.

    Everything else on the bus is deliberately NOT returned.  A Mac lists
    its Bluetooth serial ports (`/dev/cu.Bluetooth-Incoming-Port`, paired
    headsets, a phone) as ordinary ttys, and *opening* one blocks for many
    seconds before it fails — so an app that offers them will sooner or
    later freeze on one.  Identify by USB vendor id instead: nothing that
    is not an RP2350 can be an fpgago board.
    """
    return sorted((p for p in all_ports() if p.is_candidate),
                  key=lambda pi: pi.device)


def other_port_count() -> int:
    """How many non-fpgago serial ports were hidden (for the status line)."""
    return sum(1 for p in all_ports() if not p.is_candidate)


def autodetect() -> Optional[str]:
    """Device path of the most likely fpgago MCU, or None."""
    ports = list_ports()
    return ports[0].device if ports else None


# Status strings emitted via status_changed(state, detail).
ST_DISCONNECTED = "disconnected"
ST_CONNECTING = "connecting"
ST_ONLINE = "online"
ST_OFFLINE = "offline"


class SerialManager(QObject):
    ports_changed = Signal(list)        # list[PortInfo]
    status_changed = Signal(str, str)   # (state, human detail)
    data_received = Signal(str)         # decoded console text (for a terminal)
    link_event = Signal(object)         # hostlink.Frame (unsolicited MCU event)
    link_drop = Signal(object)          # (nbytes, reason) for a big frame that
                                        # arrived but did not decode
    link_result = Signal(object)        # dict (PING info) or Exception
    # Internal: the only safe way to start/stop the ping timer, because
    # open/close can run on a worker thread and QTimer belongs to this
    # object's own thread.  Auto-connection = direct when already there,
    # queued when not.
    _want_ping_timer = Signal(bool)

    def __init__(self, ping_interval_ms: int = 3000, ping_timeout_s: float = 1.5,
                 parent=None):
        super().__init__(parent)
        self._ser: Optional[serial.Serial] = None
        self._reader: Optional[threading.Thread] = None
        self._reader_stop = threading.Event()
        self._device: Optional[str] = None
        self._opening = False                # an async open is in flight
        self._shutdown = False               # the GUI is going away
        self._last_identity = 0.0            # monotonic time of last banner/frame
        self._ping_timeout = ping_timeout_s
        self._state = ST_DISCONNECTED

        # hostlink (mixed text/binary) framing state.
        self.P = hostlink.load_proto()
        self._demux: Optional[hostlink.Demux] = None
        self._hl_lock = threading.Lock()
        self._hl_pending: dict = {}          # seq -> [Event, Frame|None]
        self._hl_seq = 0

        # Console-script support: taps receive every raw text chunk from the
        # demux (thread-safe queues, see console_script.ConsoleSession), and
        # _ping_hold suppresses auto-ping frames while an interactive console
        # dialog (readLine/XMODEM on the MCU) owns the input stream — a frame
        # sent mid-dialog would be swallowed as line characters.
        self._tap_lock = threading.Lock()
        self._text_taps: list = []           # list[queue.Queue[bytes]]
        self._ping_hold = 0

        # Raw wire capture: every chunk the reader pulls off the port, before
        # any demuxing, in a rolling ~128 KB window.  Ground truth for "did
        # those bytes ever reach the host" when a frame goes missing — the
        # demux can only report what it saw, this records what arrived.
        self._raw_lock = threading.Lock()
        self._raw_log: list = []             # [(monotonic, bytes), ...]
        self._raw_total = 0

        # Auto-ping timer (lives on the GUI thread).
        self._ping_timer = QTimer(self)
        self._ping_timer.setInterval(ping_interval_ms)
        self._ping_timer.timeout.connect(self._on_ping_tick)
        self._want_ping_timer.connect(self._set_ping_timer)

        # Port-hotplug + offline-detection poll.  One second, because macOS
        # renames the tty across replugs (usbmodem1201 -> usbmodem1101) and
        # the app must notice the new name, not wait for the old one.
        self._watch_timer = QTimer(self)
        self._watch_timer.setInterval(1000)
        self._watch_timer.timeout.connect(self._on_watch_tick)
        self._known_ports: list[str] = []

        # Automatic recovery from a stalled-but-open link.
        self._offline_since = 0.0
        self._recover_delay = RECOVER_AFTER_S

    # ── discovery ────────────────────────────────────────────────────────
    def start(self):
        """Begin watching for ports; emits an initial ports_changed."""
        self.refresh_ports()
        self._watch_timer.start()

    def refresh_ports(self) -> list[PortInfo]:
        ports = list_ports()
        self._known_ports = [p.device for p in ports]
        self.ports_changed.emit(ports)
        return ports

    def _on_watch_tick(self):
        ports = list_ports()
        devs = [p.device for p in ports]
        if devs != self._known_ports:
            self._known_ports = devs
            self.ports_changed.emit(ports)
        # Our port vanished: CLOSE it, do not merely say "offline".  A half-
        # open port keeps is_open True, and everything that would reconnect
        # asks is_open first — so an unplug used to end the session for good.
        if self._ser is not None and self._device not in devs:
            self.close_port_async(f"{self._device} unplugged")
            return
        # Passive liveness: no frame and no banner within two ping windows.
        # Skipped while pings are deliberately held (a console dialog owns
        # the input stream), or we would call a working board dead.
        if self._ping_hold:
            return
        now = time.monotonic()
        stale = now - self._last_identity > self._dead_after()
        if self._state == ST_ONLINE and self.is_open:
            if stale:
                self._set_status(ST_OFFLINE, "no response to ping")
        elif self._state == ST_CONNECTING and self.is_open \
                and not self._opening and stale:
            # An open that succeeds against a board which then never says a
            # word used to sit on "connecting" for ever, where the recovery
            # path below never looked — so the FIRST reopen was also the
            # last.  `_opening` keeps this off an open still in flight.
            self._set_status(ST_OFFLINE, "no response to ping")
        elif self._state == ST_OFFLINE and self.is_open and not self._opening:
            # Do not just sit here.  Keep probing (the answer to any one of
            # these puts us straight back online), and if the link stays
            # silent, reopen the port — the same Disconnect/Connect that
            # fixes it by hand, without making the user notice first.
            self._send_ping_frame()
            if now - self._offline_since > self._recover_delay:
                self._recover()

    def _recover(self):
        """Close and reopen the port because the link has gone quiet."""
        device = self._device
        if device is None or self._opening or self._shutdown:
            return
        self._recover_delay = min(self._recover_delay * 2, RECOVER_MAX_S)
        self._offline_since = time.monotonic()
        self._opening = True
        self._set_status(ST_CONNECTING, f"{device} — link stalled, reopening")

        def worker():
            try:
                self.open_port(device)           # closes the old port first
            except Exception as e:               # noqa: BLE001
                self._set_status(ST_DISCONNECTED, f"reopen failed: {e}")
            finally:
                self._opening = False
        threading.Thread(target=worker, daemon=True).start()

    def _dead_after(self) -> float:
        return (self._ping_timer.interval() / 1000.0) + self._ping_timeout + 1.0

    # ── connection ───────────────────────────────────────────────────────
    def open_port(self, device: str, auto_ping: bool = True):
        """Open `device` and start the reader.  BLOCKS — `serial.Serial()`
        can sit for many seconds on a port that is not really there, so the
        GUI calls open_port_async() instead and only headless code calls
        this directly."""
        self.close_port()
        self._device = device
        self._set_status(ST_CONNECTING, device)
        try:
            self._ser = serial.Serial(device, BAUD, timeout=0.2)
        except Exception as e:                       # noqa: BLE001
            self._ser = None
            self._set_status(ST_DISCONNECTED, f"open failed: {e}")
            return False
        self._demux = hostlink.Demux()
        self._reader_stop.clear()
        self._last_identity = time.monotonic()   # grace until the first ping
        reader = threading.Thread(target=self._read_loop, daemon=True)
        reader.start()
        self._reader = reader                    # published only once running
        # Kick an immediate binary probe, then start auto-ping.  The timer is
        # started through a signal, NEVER by touching it here: open_port runs
        # on a worker thread in the async path, and Qt silently refuses to
        # start a timer from a thread that does not own it — which is exactly
        # how a connected board used to go quiet and be declared dead.
        self._send_ping_frame()
        if auto_ping:
            self._want_ping_timer.emit(True)
        return True

    def open_port_async(self, device: str, auto_ping: bool = True):
        """Open `device` on a worker thread.  Returns immediately; watch
        status_changed for the outcome.  Two calls cannot overlap — the
        second is dropped rather than queued, so a hotplug storm can't
        stack up half-open ports."""
        if self._opening:
            return False
        self._opening = True
        self._set_status(ST_CONNECTING, device)

        def worker():
            try:
                self.open_port(device, auto_ping=auto_ping)
            except Exception as e:                   # noqa: BLE001
                self._set_status(ST_DISCONNECTED, f"open failed: {e}")
            finally:
                self._opening = False
        threading.Thread(target=worker, daemon=True).start()
        return True

    @property
    def is_opening(self) -> bool:
        return self._opening

    def close_port(self, detail: str = ""):
        self._want_ping_timer.emit(False)
        self._reader_stop.set()
        reader, self._reader = self._reader, None
        # is_alive() rather than "is not None": close can land between the
        # reader being created and being started (Disconnect pressed while
        # connecting), and joining an unstarted thread raises.  A thread
        # that starts after this still exits at once — _reader_stop is set.
        if reader is not None and reader.is_alive() \
                and reader is not threading.current_thread():
            reader.join(timeout=1.0)
        ser, self._ser = self._ser, None       # clear FIRST: is_open goes
        if ser is not None:                    # False before the slow close
            try:
                ser.close()
            except Exception:                    # noqa: BLE001
                pass
        if self._state != ST_DISCONNECTED:
            self._set_status(ST_DISCONNECTED, detail)

    def close_port_async(self, detail: str = ""):
        """Close without blocking the caller.  `serial.close()` on a device
        that has been yanked can sit there, and the watch tick that notices
        an unplug runs on the GUI thread."""
        threading.Thread(target=lambda: self.close_port(detail),
                         daemon=True).start()

    def _set_ping_timer(self, on: bool):
        """Slot — always runs on the thread that owns the timer."""
        if on:
            self._ping_timer.start()
        else:
            self._ping_timer.stop()

    @property
    def is_open(self) -> bool:
        return self._ser is not None and self._ser.is_open

    @property
    def device(self) -> Optional[str]:
        return self._device

    # ── ping / liveness ──────────────────────────────────────────────────
    def set_auto_ping(self, on: bool):
        if on and self.is_open:
            self._ping_timer.start()
        else:
            self._ping_timer.stop()

    def set_interval_ms(self, ms: int):
        self._ping_timer.setInterval(max(500, ms))

    def _send_ping_frame(self):
        """Fire-and-forget binary hostlink PING. The response is matched in
        _on_frame, which updates online status + proto/fw detail. Used by the
        auto-ping timer and the connect-time probe."""
        if not self.is_open:
            return
        seq = self._next_hl_seq()
        try:
            self._ser.write(hostlink.encode_frame(self.P.HL_CMD_PING, seq))
        except Exception as e:                       # noqa: BLE001
            self._set_status(ST_OFFLINE, f"write failed: {e}")

    def ping(self):
        """Send the legacy text identity probe ('H' → help banner). Kept for the
        manual 'Ping (text)' button so un-flashed firmware can still be probed."""
        if not self.is_open:
            return
        try:
            self._ser.write(b"H")
        except Exception as e:                       # noqa: BLE001
            self._set_status(ST_OFFLINE, f"write failed: {e}")

    def _on_ping_tick(self):
        if self._ping_hold:
            return
        self._send_ping_frame()

    # ── console-script hooks (see console_script.py) ─────────────────────
    def add_text_tap(self, q):
        with self._tap_lock:
            self._text_taps.append(q)

    def remove_text_tap(self, q):
        with self._tap_lock:
            if q in self._text_taps:
                self._text_taps.remove(q)

    def hold_pings(self):
        """Suppress auto-ping frames while a console dialog is in progress."""
        self._ping_hold += 1

    def release_pings(self):
        self._ping_hold = max(0, self._ping_hold - 1)

    def write_bytes(self, data: bytes):
        """Raw write to the device (console text / XMODEM packets)."""
        if not self.is_open:
            raise IOError("port not open")
        self._ser.write(data)

    # ── reader thread (in-band text/binary demux) ────────────────────────
    def _read_loop(self):
        buf = b""
        ser = self._ser                    # close_port() clears the attribute
        fails = 0
        while not self._reader_stop.is_set() and ser is not None:
            try:
                # `read(256)` waits for 256 bytes OR the 0.2 s timeout, so a
                # single ACK byte took up to 200 ms to reach the sender —
                # XMODEM is stop-and-wait, so that capped uploads at ~5 KB/s.
                # Ask for what is already there (at least one byte) instead:
                # this returns the instant anything arrives.
                chunk = ser.read(max(1, min(ser.in_waiting, 4096)))
                fails = 0
            except Exception:                        # noqa: BLE001
                # macOS + pyserial raise
                #   "device reports readiness to read but returned no data
                #    (device disconnected or multiple access on port?)"
                # regularly on a perfectly healthy CDC port — select() says
                # readable, read() hands back nothing.  MEASURED on the
                # board: several times a minute, with pings answering
                # normally in between.  Treating it as a disconnect (or
                # letting it kill this thread, which is what used to happen)
                # is what made a working link go quiet.  So: retry, and only
                # give up if the port has actually gone or it never recovers.
                if self._reader_stop.is_set():
                    break
                fails += 1
                gone = fails >= 3 and self._device not in \
                    {p.device for p in list_ports()}
                if gone or fails >= READ_FAIL_MAX:
                    self.close_port_async(
                        "unplugged" if gone else "connection lost")
                    break
                time.sleep(0.05)
                continue
            if not chunk:
                continue
            with self._raw_lock:
                self._raw_log.append((time.monotonic(), chunk))
                self._raw_total += len(chunk)
                while self._raw_total > 131072 and self._raw_log:
                    self._raw_total -= len(self._raw_log.pop(0)[1])
            for kind, item in self._demux.feed(chunk):
                if kind == "drop":
                    self.link_drop.emit(item)
                    continue
                if kind == "text":
                    with self._tap_lock:
                        for q in self._text_taps:
                            q.put(item)
                    buf += item
                    if IDENTITY in buf:
                        self._last_identity = time.monotonic()
                        self._set_status(ST_ONLINE, self._banner_line(buf))
                        buf = buf[-256:]
                    try:
                        self.data_received.emit(item.decode("utf-8", "replace"))
                    except Exception:                # noqa: BLE001
                        pass
                    if len(buf) > 4096:
                        buf = buf[-1024:]
                else:                                # a decoded hostlink Frame
                    self._on_frame(item)

    def raw_tail(self, seconds: float = 6.0) -> bytes:
        """Everything read off the port in the last `seconds`, undemuxed."""
        cut = time.monotonic() - seconds
        with self._raw_lock:
            return b"".join(c for t, c in self._raw_log if t >= cut)

    def _on_frame(self, fr):
        # A binary frame proves the link is alive (structured heartbeat) —
        # ANY frame, including the answer to a command someone just ran.
        # Without this, a board that had been marked offline stayed offline
        # while the Board tab happily listed its files over the same link.
        self._last_identity = time.monotonic()
        if self._state == ST_OFFLINE:
            self._set_status(ST_ONLINE, "hostlink")
        # Unsolicited events FIRST.  Event ids (0xE0-0xE3) have bit 7 set
        # too, so testing HL_RESP_FLAG first reads every event as "a response
        # nobody is waiting for" and silently discards it — the emit below
        # was unreachable for every event id the protocol defines.  That ate
        # ALL 240 SHOT_LINE frames of the screen grab while the raw tap
        # showed 22 KB/s of perfectly framed bytes arriving (board,
        # 2026-08-06); it had eaten LOG/UART_RX/STATUS since day one, and an
        # event whose rolling seq happened to match a pending command's
        # could even be delivered as that command's "response".
        if 0xE0 <= fr.type <= 0xEF:
            if self._state != ST_ONLINE:
                self._set_status(ST_ONLINE, "hostlink")
            self.link_event.emit(fr)
            return
        if fr.type & self.P.HL_RESP_FLAG:
            with self._hl_lock:
                slot = self._hl_pending.get(fr.seq)
            if slot is not None:                     # deliver to a blocking waiter
                slot[1] = fr
                slot[0].set()
            # A PING response (solicited by auto-ping OR a manual link ping)
            # drives the online status line with proto/fw detail.
            if (fr.type & ~self.P.HL_RESP_FLAG) == self.P.HL_CMD_PING:
                self._note_ping_response(fr)
            return
        # Unsolicited event (LOG / UART_RX / STATUS).
        if self._state != ST_ONLINE:
            self._set_status(ST_ONLINE, "hostlink")
        self.link_event.emit(fr)

    def _note_ping_response(self, fr):
        p = fr.payload                               # [status, proto16, fw8, board, caps32]
        if not p or p[0] != self.P.HL_OK or len(p) < 16:
            return
        proto = p[1] | (p[2] << 8)
        fw = p[3:11].split(b"\x00", 1)[0].decode("latin1")
        self._set_status(ST_ONLINE, f"hostlink v{proto >> 8}.{proto & 0xFF} fw={fw}")

    # ── hostlink command/response (binary protocol) ──────────────────────
    def _next_hl_seq(self) -> int:
        with self._hl_lock:
            self._hl_seq = (self._hl_seq + 1) & 0xFF
            return self._hl_seq

    def command(self, cmd_type: int, payload: bytes = b"", timeout: float = 2.0):
        """Send a hostlink command; return (status:int, payload:bytes).
        Blocks up to `timeout` — call off the GUI thread."""
        if not self.is_open:
            raise IOError("port not open")
        seq = self._next_hl_seq()
        ev = threading.Event()
        slot = [ev, None]
        with self._hl_lock:
            self._hl_pending[seq] = slot
        try:
            self._ser.write(hostlink.encode_frame(cmd_type, seq, payload))
            if not ev.wait(timeout):
                raise TimeoutError(f"no response to cmd 0x{cmd_type:02x}")
            fr = slot[1]
            status = fr.payload[0] if fr.payload else self.P.HL_ERR_BAD_ARG
            return status, fr.payload[1:]
        finally:
            with self._hl_lock:
                self._hl_pending.pop(seq, None)

    def link_ping(self, timeout: float = 2.0) -> dict:
        status, p = self.command(self.P.HL_CMD_PING, timeout=timeout)
        if status != self.P.HL_OK or len(p) < 15:
            raise IOError(f"PING failed (status {status})")
        return {"proto_ver": p[0] | (p[1] << 8),
                "fw_hash": p[2:10].split(b"\x00", 1)[0].decode("latin1"),
                "board": p[10],
                "caps": p[11] | (p[12] << 8) | (p[13] << 16) | (p[14] << 24)}

    def link_ping_async(self):
        """Run link_ping() on a worker thread; result/exception -> link_result."""
        def worker():
            try:
                self.link_result.emit(self.link_ping())
            except Exception as e:                   # noqa: BLE001
                self.link_result.emit(e)
        threading.Thread(target=worker, daemon=True).start()

    @staticmethod
    def _banner_line(buf: bytes) -> str:
        text = buf.decode("utf-8", "replace")
        idx = text.rfind("fpgago_mcu")
        if idx < 0:
            return "fpgago MCU"
        line = text[idx:].splitlines()[0].strip()
        return line or "fpgago MCU"

    # ── shutdown ─────────────────────────────────────────────────────────
    def shutdown(self):
        """Stop talking to the GUI.  Call before the window goes away: an
        open that is still blocked in serial.Serial() will finish later and
        emit into a Qt object whose C++ half has been deleted, which is a
        crash rather than an exception."""
        self._shutdown = True
        self._reader_stop.set()
        self.close_port()

    # ── status helper ────────────────────────────────────────────────────
    def _set_status(self, state: str, detail: str):
        if state == ST_OFFLINE and self._state != ST_OFFLINE:
            # Entering offline starts the recovery clock, and any framing
            # desync dies with the old demux state.  (The demux resynchronises
            # on content by itself — this is belt and braces, not the fix.)
            self._offline_since = time.monotonic()
            if self._demux is not None:
                self._demux.reset()
        elif state == ST_ONLINE and self._state != ST_ONLINE:
            self._recover_delay = RECOVER_AFTER_S     # healthy again
        self._state = state
        if self._shutdown:
            return
        self.status_changed.emit(state, detail)
