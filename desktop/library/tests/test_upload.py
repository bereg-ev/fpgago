"""Tests for pushing a file to the board: XMODEM throughput, and what
"verified" is allowed to mean.

Run:  cd desktop && python3 -m pytest library/tests -q   (skips without pyserial)

Both halves come from one measurement session against the real board:

  * the reader asked pyserial for 256 bytes with a 0.2 s timeout, so a
    one-byte ACK could take 200 ms to arrive — and XMODEM is stop-and-wait,
    so uploads crawled at a few KB/s;
  * the console XMODEM path has no length field, so the last block is padded
    to 1 KB and the MCU stores whole blocks — meaning the size check called
    every .d64 upload corrupt.
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

from library import board as libboard  # noqa: E402


# ── what the board is allowed to be holding ────────────────────────────────

DATA = bytes((i * 7 + 3) & 0xFF for i in range(174848))      # a .d64


def stat_of(payload: bytes) -> dict:
    import zlib
    return {"size": len(payload), "crc32": zlib.crc32(payload) & 0xFFFFFFFF}


def test_an_exact_copy_verifies():
    assert libboard.verify_upload(stat_of(DATA), DATA, "x.d64") is True


def test_the_xmodem_padded_copy_verifies_too():
    """174848 bytes is not a multiple of 1024, so it lands as 175104 — which
    used to be reported as 'flash verify FAILED' for every single .d64."""
    padded = libboard.xmodem_padded(DATA)
    assert len(padded) == 175104
    assert libboard.verify_upload(stat_of(padded), DATA, "x.d64") is False


def test_padding_is_reported_not_hidden():
    said = []
    libboard.verify_upload(stat_of(libboard.xmodem_padded(DATA)), DATA,
                           "x.d64", progress=said.append)
    assert any("padding" in m for m in said)


def test_the_pad_byte_is_the_one_the_sender_actually_sends():
    """0x1A (CP/M EOF) — xmodem1k_send pads with it, so the board's copy
    contains it and the CRC must be computed over the same thing."""
    from app.console_script import XMODEM_BLOCK
    padded = libboard.xmodem_padded(b"abc")
    assert len(padded) == XMODEM_BLOCK
    assert padded == b"abc" + b"\x1a" * (XMODEM_BLOCK - 3)


def test_a_file_that_is_already_a_whole_number_of_blocks_is_untouched():
    data = b"\xaa" * 4096
    assert libboard.xmodem_padded(data) == data
    assert libboard.verify_upload(stat_of(data), data, "x.bit") is True


def test_real_corruption_still_fails():
    bad = stat_of(DATA)
    bad["crc32"] ^= 1
    with pytest.raises(IOError, match="verify FAILED"):
        libboard.verify_upload(bad, DATA, "x.d64")


def test_a_truncated_upload_still_fails():
    with pytest.raises(IOError, match="verify FAILED"):
        libboard.verify_upload(stat_of(DATA[:-4096]), DATA, "x.d64")


# ── throughput: the reader must not sit on an ACK ──────────────────────────

class ModelSerial:
    """pyserial's read() semantics, modelled: it returns as soon as `size`
    bytes are available, and otherwise waits out the timeout.  That single
    rule is the whole bug — asking for 256 bytes when the MCU is about to
    send one ACK means waiting the full timeout for it."""

    def __init__(self, timeout=0.2):
        self.timeout = timeout
        self._buf = bytearray()
        self._lock = threading.Lock()
        self.waited = 0.0

    def feed(self, data: bytes):
        with self._lock:
            self._buf += data

    @property
    def in_waiting(self):
        with self._lock:
            return len(self._buf)

    def read(self, size=1):
        end = time.monotonic() + self.timeout
        while True:
            with self._lock:
                if len(self._buf) >= size or time.monotonic() >= end:
                    out = bytes(self._buf[:size])
                    del self._buf[:len(out)]
                    return out
            time.sleep(0.002)
            self.waited += 0.002


def reader_call(ser):
    """Exactly what serial_manager._read_loop asks for."""
    return ser.read(max(1, min(ser.in_waiting, 4096)))


def test_a_single_ack_is_delivered_at_once():
    ser = ModelSerial(timeout=0.2)
    ser.feed(b"\x06")                       # one ACK is waiting
    t0 = time.monotonic()
    got = reader_call(ser)
    assert got == b"\x06"
    assert time.monotonic() - t0 < 0.05, "the reader sat on the ACK"


def test_the_old_call_would_have_waited_for_the_whole_timeout():
    # the regression this replaced: read(256) with one byte available
    ser = ModelSerial(timeout=0.2)
    ser.feed(b"\x06")
    t0 = time.monotonic()
    ser.read(256)
    assert time.monotonic() - t0 >= 0.15


def test_a_burst_is_read_in_one_go():
    ser = ModelSerial()
    ser.feed(b"x" * 3000)
    assert len(reader_call(ser)) == 3000     # not 256 bytes at a time


def test_an_idle_port_still_blocks_rather_than_spinning():
    ser = ModelSerial(timeout=0.05)
    t0 = time.monotonic()
    assert reader_call(ser) == b""
    assert time.monotonic() - t0 >= 0.04     # waited, did not busy-loop


def test_stop_and_wait_upload_speed_scales_with_that_delay():
    """40 blocks of XMODEM, one ACK each: the only thing between a few KB/s
    and a fast upload is how quickly that ACK comes back."""
    def run(read_call):
        ser = ModelSerial(timeout=0.2)
        t0 = time.monotonic()
        for _ in range(40):
            ser.feed(b"\x06")               # the MCU ACKs immediately
            while not read_call(ser):
                pass
        return time.monotonic() - t0
    new = run(reader_call)
    old = run(lambda s: s.read(256))
    assert new < old / 5, f"new={new:.2f}s old={old:.2f}s"
