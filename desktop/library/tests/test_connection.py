"""Tests for finding and connecting to the board (app/serial_manager.py and
the Connection tab's auto-connect).

Run:  cd desktop && python3 -m pytest library/tests -q

Two things are being defended, both from real damage:

  * A Mac lists Bluetooth serial ports as ordinary ttys, and *opening* one
    blocks for many seconds.  So they are never listed and never opened.
  * The open runs off the GUI thread, so even a port that hangs costs no
    frames.

Needs the desktop venv (pyserial + PySide6 — serial_manager imports Qt for
its signals), so the whole module skips elsewhere.
"""
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

pytest.importorskip("serial", reason="desktop venv only")
pytest.importorskip("PySide6", reason="desktop venv only")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from app import serial_manager as sm  # noqa: E402


class FakePort:
    def __init__(self, device, vid=None, pid=None, desc="x", sn=None):
        self.device, self.vid, self.pid = device, vid, pid
        self.description, self.serial_number = desc, sn


# What a Mac with a board and the usual Bluetooth clutter reports.
MAC_PORTS = [
    FakePort("/dev/cu.Bluetooth-Incoming-Port"),
    FakePort("/dev/cu.usbmodem1201", vid=sm.RPI_VID, pid=0x000A,
             desc="fpgago", sn="E661"),
    FakePort("/dev/cu.SomePhone-WirelessiAP"),
    FakePort("/dev/cu.usbserial-A5069RR4", vid=0x0403, pid=0x6001,
             desc="FT232R"),
]


@pytest.fixture
def ports(monkeypatch):
    def use(lst):
        monkeypatch.setattr(sm.serial.tools.list_ports, "comports",
                            lambda: lst)
    use(MAC_PORTS)
    return use


# ── only fpgago boards are ever offered ────────────────────────────────────

def test_only_the_board_is_listed(ports):
    assert [p.device for p in sm.list_ports()] == ["/dev/cu.usbmodem1201"]


def test_bluetooth_ports_are_not_listed(ports):
    # the whole point: these are what freeze the app when opened
    assert not any("Bluetooth" in p.device for p in sm.list_ports())


def test_another_usb_serial_adapter_is_not_ours(ports):
    # an FTDI cable is a serial port, but it cannot be an fpgago board
    assert not any("usbserial" in p.device for p in sm.list_ports())


def test_the_hidden_ones_are_counted_for_the_status_line(ports):
    assert sm.other_port_count() == 3


def test_all_ports_still_sees_everything(ports):
    assert len(sm.all_ports()) == 4


def test_autodetect_picks_the_board(ports):
    assert sm.autodetect() == "/dev/cu.usbmodem1201"


def test_autodetect_finds_nothing_when_only_clutter_is_present(ports):
    ports([p for p in MAC_PORTS if p.vid != sm.RPI_VID])
    assert sm.autodetect() is None
    assert sm.list_ports() == []


def test_two_boards_are_both_listed_and_sorted(ports):
    ports(MAC_PORTS + [FakePort("/dev/cu.usbmodem1101", vid=sm.RPI_VID)])
    assert [p.device for p in sm.list_ports()] == \
        ["/dev/cu.usbmodem1101", "/dev/cu.usbmodem1201"]


def test_the_label_shows_what_a_user_needs_to_tell_boards_apart(ports):
    label = sm.list_ports()[0].label()
    assert "/dev/cu.usbmodem1201" in label and "fpgago" in label
    assert "#E661" in label                      # the serial number


# ── opening never blocks the caller ────────────────────────────────────────

def test_open_port_async_returns_before_the_port_opens(ports, monkeypatch, managers):
    started, release = threading.Event(), threading.Event()

    class SlowSerial:
        def __init__(self, *a, **k):
            started.set()
            release.wait(5)                      # a port that hangs
            raise IOError("no")
    monkeypatch.setattr(sm.serial, "Serial", SlowSerial)

    mgr = managers()
    t0 = time.monotonic()
    assert mgr.open_port_async("/dev/cu.usbmodem1201")
    elapsed = time.monotonic() - t0
    assert started.wait(2)                       # it really did start
    assert elapsed < 0.5, "open_port_async blocked the caller"
    assert mgr.is_opening
    release.set()


def test_a_second_open_is_dropped_while_one_is_in_flight(ports, monkeypatch, managers):
    release = threading.Event()

    class SlowSerial:
        def __init__(self, *a, **k):
            release.wait(5)
            raise IOError("no")
    monkeypatch.setattr(sm.serial, "Serial", SlowSerial)

    mgr = managers()
    assert mgr.open_port_async("/dev/a")
    assert not mgr.open_port_async("/dev/b")     # not queued behind it
    release.set()


def test_a_failed_open_clears_the_in_flight_flag(ports, monkeypatch, managers):
    monkeypatch.setattr(sm.serial, "Serial",
                        lambda *a, **k: (_ for _ in ()).throw(IOError("busy")))
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    for _ in range(200):
        if not mgr.is_opening:
            break
        time.sleep(0.01)
    assert not mgr.is_opening                    # or nothing could reconnect
    assert not mgr.is_open


# ── staying connected, and coming back ─────────────────────────────────────

class FakeSerial:
    """A port that opens instantly and never says anything."""

    def __init__(self, *a, **k):
        self.is_open = True
        self.written = b""
        self.in_waiting = 0             # pyserial always has this

    def read(self, _n):
        time.sleep(0.01)
        return b""

    def write(self, data):
        self.written += data
        return len(data)

    def close(self):
        self.is_open = False


@pytest.fixture
def managers():
    """Own every SerialManager a test makes, and close it afterwards.

    A manager that goes out of scope while its reader thread is still
    running gets its C++ half deleted underneath that thread, and the next
    signal it emits takes the process down — an intermittent segfault, not a
    failure.  The app keeps its manager for the whole session; tests have to
    be explicit about it.
    """
    made = []

    def make(*a, **k):
        m = sm.SerialManager(*a, **k)
        made.append(m)
        return m
    yield make
    for m in made:
        m.close_port()
        m._reader_stop.set()
    for m in made:                       # let the readers actually finish
        r = m._reader
        if r is not None and r.is_alive():
            r.join(timeout=2.0)


def wait_until(pred, timeout=3.0, app=None):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if app is not None:
            app.processEvents()
        if pred():
            return True
        time.sleep(0.01)
    return bool(pred())


def test_the_ping_timer_really_starts_after_an_async_open(qapp, ports,
                                                          monkeypatch, managers):
    """The regression that made a live board 'stop responding': open_port
    runs on a worker thread in the async path, and Qt will not start a timer
    from a thread that does not own it — so auto-ping never ran, nothing
    refreshed the liveness clock, and the link was declared dead while it
    was working perfectly."""
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)
    assert wait_until(lambda: mgr._ping_timer.isActive(), app=qapp), \
        "auto-ping never started — the link will go 'offline' on its own"
    mgr.close_port()


def test_closing_stops_the_ping_timer(qapp, ports, monkeypatch, managers):
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr._ping_timer.isActive(), app=qapp)
    mgr.close_port()
    assert wait_until(lambda: not mgr._ping_timer.isActive(), app=qapp)


def test_an_unplug_actually_closes_the_port(qapp, ports, monkeypatch, managers):
    """Marking it 'offline' while keeping it open is what made an unplug
    permanent: everything that would reconnect asks is_open first."""
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)
    ports([p for p in MAC_PORTS if p.vid != sm.RPI_VID])     # yanked
    mgr._on_watch_tick()
    assert wait_until(lambda: not mgr.is_open, app=qapp)
    assert mgr._state == sm.ST_DISCONNECTED


def test_a_read_failure_tears_the_link_down(qapp, ports, monkeypatch, managers):
    class Dying(FakeSerial):
        def read(self, _n):
            raise IOError("device not configured")
    monkeypatch.setattr(sm.serial, "Serial", Dying)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: not mgr.is_open and mgr._device, app=qapp)


def test_a_spurious_read_error_does_not_kill_a_working_link(qapp, ports,
                                                            monkeypatch, managers):
    """MEASURED on the board: pyserial raises

        device reports readiness to read but returned no data
        (device disconnected or multiple access on port?)

    several times a minute on a perfectly healthy macOS CDC port — pings
    keep answering right through it.  Treating the first one as a
    disconnect is what made a live board drop every couple of seconds."""
    calls = {"n": 0}

    class Flaky(FakeSerial):
        def read(self, _n):
            calls["n"] += 1
            if calls["n"] % 3:
                raise sm.serial.SerialException(
                    "device reports readiness to read but returned no data "
                    "(device disconnected or multiple access on port?)")
            time.sleep(0.01)
            return b""
    monkeypatch.setattr(sm.serial, "Serial", Flaky)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: calls["n"] > 10, app=qapp)
    assert mgr.is_open, "a healthy link was torn down by a spurious error"
    mgr.close_port()


def test_a_port_that_only_errors_is_eventually_given_up_on(qapp, ports,
                                                           monkeypatch, managers):
    class Dead(FakeSerial):
        def read(self, _n):
            raise sm.serial.SerialException("nope")
    monkeypatch.setattr(sm.serial, "Serial", Dead)
    monkeypatch.setattr(sm, "READ_FAIL_MAX", 5)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: not mgr.is_open, timeout=5, app=qapp)


def test_read_errors_stop_at_once_when_the_port_is_gone(qapp, ports,
                                                        monkeypatch, managers):
    class Dead(FakeSerial):
        def read(self, _n):
            raise sm.serial.SerialException("nope")
    monkeypatch.setattr(sm.serial, "Serial", Dead)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)
    ports([p for p in MAC_PORTS if p.vid != sm.RPI_VID])     # really unplugged
    # gives up on the third failure, not after the full retry budget
    assert wait_until(lambda: not mgr.is_open, timeout=2, app=qapp)


def test_any_frame_brings_an_offline_link_back(qapp, ports, monkeypatch, managers):
    """The board answered a command, so it is plainly alive — but the app
    kept saying 'not responding' because only PING replies and unsolicited
    events counted."""
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)
    mgr._set_status(sm.ST_OFFLINE, "no response to ping")

    class Frame:                       # a command response, not a ping
        type = mgr.P.HL_RESP_FLAG | mgr.P.HL_CMD_FS_LIST
        seq = 7
        payload = b"\x00"
    mgr._on_frame(Frame())
    assert mgr._state == sm.ST_ONLINE
    mgr.close_port()


def test_liveness_is_not_judged_while_pings_are_held(qapp, ports,
                                                     monkeypatch, managers):
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)
    mgr._set_status(sm.ST_ONLINE, "")
    mgr._last_identity = 0.0                 # ages ago
    mgr.hold_pings()                         # a console dialog owns the link
    mgr._on_watch_tick()
    assert mgr._state == sm.ST_ONLINE        # not our turn to judge
    mgr.release_pings()
    mgr._on_watch_tick()
    assert mgr._state == sm.ST_OFFLINE
    mgr.close_port()


def test_the_board_is_watched_often_enough_to_notice_a_rename(qapp):
    # macOS renames the tty across replugs; a slow poll means a long stare
    # at a dead window
    assert sm.SerialManager()._watch_timer.interval() <= 1000


# ── the Connection tab's rules ─────────────────────────────────────────────

from PySide6.QtCore import QObject, Signal  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402


class FakeMgr(QObject):
    ports_changed = Signal(list)
    status_changed = Signal(str, str)
    data_received = Signal(str)
    link_event = Signal(object)
    link_result = Signal(object)

    def __init__(self):
        super().__init__()
        self.opened = []
        self.is_open = False
        self.is_opening = False
        self.device = None
        self.P = {}
        self._state = sm.ST_DISCONNECTED

    def open_port_async(self, dev, auto_ping=True):
        self.opened.append(dev)
        return True

    def close_port(self):
        self.is_open = False

    def ping(self):
        pass

    def link_ping_async(self):
        pass


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def panel(qapp):
    from PySide6.QtCore import QThreadPool
    from app.main import ConnectionPanel
    mgr = FakeMgr()
    p = ConnectionPanel(mgr, QThreadPool.globalInstance(), lambda *_a: None)
    return p, mgr


def test_one_board_connects_itself(qapp, ports):
    p, mgr = panel(qapp)
    p._on_ports(sm.list_ports())
    assert mgr.opened == ["/dev/cu.usbmodem1201"]
    assert not p.pick_row.isVisible()             # no choice to present


def test_two_boards_ask_instead_of_guessing(qapp, ports):
    p, mgr = panel(qapp)
    ports(MAC_PORTS + [FakePort("/dev/cu.usbmodem1101", vid=sm.RPI_VID)])
    p._on_ports(sm.list_ports())
    assert mgr.opened == []
    assert p.port_combo.count() == 2


def test_no_board_says_so_and_counts_the_hidden_ports(qapp, ports):
    p, mgr = panel(qapp)
    ports([q for q in MAC_PORTS if q.vid != sm.RPI_VID])
    p._on_ports(sm.list_ports())
    assert mgr.opened == []
    assert "No fpgago board" in p.hint_lbl.text()
    assert "3 other serial ports hidden" in p.hint_lbl.text()


def test_a_board_that_will_not_open_is_not_hammered(qapp, ports):
    p, mgr = panel(qapp)
    for _ in range(5):
        p._on_ports(sm.list_ports())              # five port polls
    assert mgr.opened == ["/dev/cu.usbmodem1201"]


def test_but_it_is_retried_on_the_slow_tick(qapp, ports):
    p, mgr = panel(qapp)
    p._on_ports(sm.list_ports())
    p._retry_tick()                               # ~8 s later
    assert mgr.opened == ["/dev/cu.usbmodem1201"] * 2


def test_pressing_disconnect_stays_disconnected(qapp, ports):
    p, mgr = panel(qapp)
    p._on_ports(sm.list_ports())
    mgr.is_open = True
    p._toggle_connect()                           # the user meant it
    mgr.opened.clear()
    p._on_ports(sm.list_ports())
    p._retry_tick()
    assert mgr.opened == []
    p._toggle_connect()                           # ...until they say otherwise
    assert mgr.opened == ["/dev/cu.usbmodem1201"]


def test_disconnect_holds_even_when_a_different_board_turns_up(qapp, ports):
    # "stay off" means stay off: swapping the board must not undo the
    # button, and the per-device retry set alone would not catch this one
    p, mgr = panel(qapp)
    p._on_ports(sm.list_ports())
    mgr.is_open = True
    p._toggle_connect()
    mgr.opened.clear()
    ports([q for q in MAC_PORTS if q.vid != sm.RPI_VID]
          + [FakePort("/dev/cu.usbmodem9999", vid=sm.RPI_VID)])
    p._on_ports(sm.list_ports())
    assert mgr.opened == []


def test_a_replugged_board_reconnects_by_itself(qapp, ports):
    """Unplug an online board, plug it back in: it must come back without
    anyone pressing anything."""
    p, mgr = panel(qapp)
    p._on_ports(sm.list_ports())
    mgr.is_open = True                            # ...connected
    mgr.opened.clear()

    ports([q for q in MAC_PORTS if q.vid != sm.RPI_VID])   # unplugged
    mgr.is_open = False                           # the manager closes it
    p._on_ports(sm.list_ports())
    assert mgr.opened == []                       # nothing to connect to

    ports(MAC_PORTS)                              # plugged back in
    p._on_ports(sm.list_ports())
    assert mgr.opened == ["/dev/cu.usbmodem1201"]


def test_it_follows_the_board_to_a_new_tty_name(qapp, ports):
    """macOS hands the same board a different name across replugs; aiming
    at the remembered name would wait forever."""
    p, mgr = panel(qapp)
    p._on_ports(sm.list_ports())
    mgr.is_open = True
    mgr.opened.clear()

    ports([q for q in MAC_PORTS if q.vid != sm.RPI_VID]
          + [FakePort("/dev/cu.usbmodem1101", vid=sm.RPI_VID)])
    mgr.is_open = False
    p._on_ports(sm.list_ports())
    assert mgr.opened == ["/dev/cu.usbmodem1101"]


def test_a_lost_link_is_retried_within_three_seconds(qapp):
    # the promise: one port poll + one retry tick
    p, _mgr = panel(qapp)
    assert p._retry_timer.interval() + sm.SerialManager()._watch_timer.interval() \
        <= 3000


def test_reconnect_after_a_reboot_accepts_a_renamed_port(qapp, ports):
    p, mgr = panel(qapp)
    p._on_ports(sm.list_ports())
    mgr.opened.clear()
    p.reconnect_after("/dev/cu.usbmodem1201")     # the name we rebooted from
    ports([q for q in MAC_PORTS if q.vid != sm.RPI_VID]
          + [FakePort("/dev/cu.usbmodem1101", vid=sm.RPI_VID)])
    p._on_ports(sm.list_ports())
    mgr.opened.clear()
    p._try_reconnect()
    assert mgr.opened == ["/dev/cu.usbmodem1101"]


def test_controls_are_dead_until_the_board_answers(qapp, ports):
    p, _mgr = panel(qapp)
    assert not p.ctl_box.isEnabled()
    p._on_status(sm.ST_CONNECTING, "")
    assert not p.ctl_box.isEnabled()
    p._on_status(sm.ST_ONLINE, "hostlink")
    assert p.ctl_box.isEnabled()
    p._on_status(sm.ST_OFFLINE, "no response to ping")
    assert not p.ctl_box.isEnabled()


def test_a_busy_port_is_explained_not_dumped(qapp, ports):
    p, _mgr = panel(qapp)
    p._on_status(sm.ST_DISCONNECTED, "open failed: [Errno 16] could not open "
                                     "port /dev/cu.usbmodem1201: [Errno 16] "
                                     "Resource busy: '/dev/cu.usbmodem1201'")
    said = p.status_lbl.text()
    assert "another program" in said and "Errno" not in said
    assert "Errno 16" in p.console.toPlainText()   # the raw text is logged


def test_the_reader_hands_over_an_ack_without_waiting(qapp, ports,
                                                      monkeypatch, managers):
    """End to end through _read_loop: XMODEM is stop-and-wait, so an ACK
    that takes the serial timeout to surface caps uploads at a few KB/s.
    This is the wiring the throughput fix lives in (test_upload.py measures
    the call itself)."""
    class Modelled(FakeSerial):
        """pyserial semantics: return once `size` bytes are there."""

        def __init__(self, *a, **k):
            super().__init__()
            self._pending = bytearray()

        @property
        def in_waiting(self):
            return len(self._pending)

        @in_waiting.setter
        def in_waiting(self, _v):
            pass

        def write(self, data):
            self._pending += b"\x06"          # the MCU ACKs at once
            return len(data)

        def read(self, size=1):
            end = time.time() + 0.2
            while len(self._pending) < size and time.time() < end:
                time.sleep(0.002)
            out = bytes(self._pending[:size])
            del self._pending[:len(out)]
            return out

    monkeypatch.setattr(sm.serial, "Serial", Modelled)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)

    import queue
    q = queue.Queue()
    mgr.add_text_tap(q)
    t0 = time.time()
    for _ in range(10):                        # ten XMODEM blocks
        mgr.write_bytes(b"\x02" + bytes(1028))
        q.get(timeout=2.0)                     # its ACK
    dt = time.time() - t0
    mgr.remove_text_tap(q)
    assert dt < 0.5, f"{dt:.2f}s for 10 ACKs — the reader is sitting on them"
    mgr.close_port()


# ── a stalled link recovers by itself ──────────────────────────────────────
# The user's fix was Disconnect + Connect, and it worked "in a split second".
# That is the app's job, not theirs: the port was open the whole time, so
# nothing was ever going to change on its own.

def test_a_stalled_link_is_probed_and_then_reopened(qapp, ports, monkeypatch,
                                                    managers):
    opens = []

    class Counting(FakeSerial):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            opens.append(a[0] if a else None)
    monkeypatch.setattr(sm.serial, "Serial", Counting)
    monkeypatch.setattr(sm, "RECOVER_AFTER_S", 0.05)
    mgr = managers()
    mgr._recover_delay = 0.05
    mgr.open_port_async("/dev/cu.usbmodem1201")
    # `is_open` alone is not enough: it goes true a moment before the opening
    # worker retires, and the recovery path stands aside while one is in
    # flight (it must not reopen a port that is still being opened).
    assert wait_until(lambda: mgr.is_open and not mgr.is_opening, app=qapp)
    assert len(opens) == 1

    # the board answers, then goes quiet: the liveness clock runs out
    mgr._set_status(sm.ST_ONLINE, "hostlink")
    mgr._last_identity = 0.0
    mgr._on_watch_tick()
    assert mgr._state == sm.ST_OFFLINE

    # first the cheap probe, and then the reopen the user was doing by hand
    before = len(mgr._ser.written)
    mgr._on_watch_tick()
    assert len(mgr._ser.written) > before, "offline link is not being probed"
    time.sleep(0.06)
    mgr._on_watch_tick()
    assert wait_until(lambda: len(opens) == 2, app=qapp), \
        "a stalled link was never reopened — the user has to do it"
    mgr.close_port()


def test_recovery_backs_off_so_a_dead_board_is_not_hammered(qapp, ports,
                                                            monkeypatch,
                                                            managers):
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    monkeypatch.setattr(sm, "RECOVER_MAX_S", 1.0)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)
    mgr._recover_delay = 0.01
    delays = []
    for _ in range(4):
        mgr._set_status(sm.ST_OFFLINE, "quiet")
        mgr._offline_since = 0.0
        mgr._recover()
        assert wait_until(lambda: not mgr._opening, app=qapp)
        delays.append(mgr._recover_delay)
    assert delays == sorted(delays) and delays[-1] > delays[0], delays
    assert delays[-1] <= 1.0                     # capped
    mgr.close_port()


def test_coming_back_online_resets_the_backoff(qapp, ports, monkeypatch,
                                               managers):
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr._recover_delay = 47.0
    mgr._set_status(sm.ST_ONLINE, "hostlink")
    assert mgr._recover_delay == sm.RECOVER_AFTER_S


def test_going_offline_clears_the_framing_state(qapp, ports, monkeypatch,
                                                managers):
    """Belt and braces for the demux desync that caused this: whatever half
    a frame was left over, it does not survive into the recovery attempt."""
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open, app=qapp)
    mgr._demux.feed(b"\x00partial")              # stuck mid-"frame"
    assert mgr._demux._in_frame
    mgr._set_status(sm.ST_OFFLINE, "quiet")
    assert not mgr._demux._in_frame and not mgr._demux._acc
    mgr.close_port()


def test_a_held_console_dialog_is_never_reconnected_underneath(qapp, ports,
                                                               monkeypatch,
                                                               managers):
    """An XMODEM upload or a BIOS dialog owns the input stream and answers no
    pings by design.  Reopening the port under it would abort the transfer."""
    opens = []

    class Counting(FakeSerial):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            opens.append(1)
    monkeypatch.setattr(sm.serial, "Serial", Counting)
    monkeypatch.setattr(sm, "RECOVER_AFTER_S", 0.01)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open and not mgr.is_opening, app=qapp)
    mgr._recover_delay = 0.01
    mgr.hold_pings()
    mgr._set_status(sm.ST_OFFLINE, "quiet")
    mgr._offline_since = 0.0
    for _ in range(3):
        mgr._on_watch_tick()
    assert len(opens) == 1, "a console dialog was reconnected out from under"
    mgr.release_pings()
    mgr.close_port()


def test_an_open_that_never_answers_is_also_recovered(qapp, ports, monkeypatch,
                                                      managers):
    """The port opens fine and the board says nothing at all.  That used to
    park on 'connecting' for ever, where the recovery path never looked."""
    monkeypatch.setattr(sm.serial, "Serial", FakeSerial)
    mgr = managers()
    mgr.open_port_async("/dev/cu.usbmodem1201")
    assert wait_until(lambda: mgr.is_open and not mgr.is_opening, app=qapp)
    assert mgr._state == sm.ST_CONNECTING
    mgr._last_identity = 0.0
    mgr._on_watch_tick()
    assert mgr._state == sm.ST_OFFLINE, "a silent board stayed 'connecting'"
    mgr.close_port()
