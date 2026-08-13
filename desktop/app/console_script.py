"""console_script.py — scripted dialogs over the MCU's text console.

The MCU console is interactive (single-char commands, readLine prompts,
XMODEM transfers).  Several features have no hostlink command yet — upload
(XMODEM-1K), format, KV get/set, drive-mode toggle — so the desktop drives
the console the way a human would: send a command char, wait for the prompt,
answer it, collect the result.

ConsoleSession is a context manager over any transport exposing
    add_text_tap(q) / remove_text_tap(q)   — subscribe to raw console bytes
    write_bytes(data)                      — raw write to the device
    hold_pings() / release_pings()         — suppress auto-ping frames
(SerialManager implements these).  While a session is open, NO hostlink
frames may be sent: the MCU's readLine/xReceive consume raw stdin chars, so
a frame sent mid-dialog would be eaten as line input.

xmodem1k_send() implements the sender side of the MCU's xreceive.c
(XMODEM-CRC handshake 'C', STX 1K blocks, CRC16-CCITT init 0).
"""

from __future__ import annotations

import queue
import time
from typing import Callable, Optional

SOH = 0x01
STX = 0x02
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18
CRC_PROMPT = ord("C")

XMODEM_BLOCK = 1024


class ConsoleError(Exception):
    """A console dialog went off-script (missing prompt, NAK storm, ...)."""


def crc16_ccitt(data: bytes, crc: int = 0) -> int:
    """CRC16-CCITT poly 0x1021 init 0 — matches xreceive.c crc_ccitt_update."""
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 \
                else (crc << 1) & 0xFFFF
    return crc


class ConsoleSession:
    """Exclusive scripted access to the MCU console text stream."""

    def __init__(self, transport):
        self.t = transport
        self.q: queue.Queue = queue.Queue()
        self.buf = bytearray()          # text accumulated since last expect

    def __enter__(self):
        self.t.hold_pings()
        self.t.add_text_tap(self.q)
        return self

    def __exit__(self, *exc):
        self.t.remove_text_tap(self.q)
        self.t.release_pings()
        return False

    # ── low level ────────────────────────────────────────────────────────
    def send(self, data) -> None:
        if isinstance(data, str):
            data = data.encode("latin1")
        self.t.write_bytes(data)

    def _pump(self, timeout: float) -> bool:
        """Move one queued chunk into buf; False on timeout."""
        try:
            self.buf += self.q.get(timeout=timeout)
            return True
        except queue.Empty:
            return False

    def drain(self, settle: float = 0.05) -> bytes:
        """Collect whatever is pending until the stream goes quiet."""
        while self._pump(settle):
            pass
        out = bytes(self.buf)
        self.buf.clear()
        return out

    def expect(self, pattern, timeout: float = 3.0) -> str:
        """Wait until `pattern` (str/bytes substring) appears in the incoming
        text.  Returns the text up to and including the match and consumes it
        from the buffer; raises ConsoleError on timeout."""
        if isinstance(pattern, str):
            pattern = pattern.encode("latin1")
        deadline = time.monotonic() + timeout
        while True:
            idx = self.buf.find(pattern)
            if idx >= 0:
                end = idx + len(pattern)
                out = self.buf[:end].decode("latin1", "replace")
                del self.buf[:end]
                return out
            left = deadline - time.monotonic()
            if left <= 0 or not self._pump(min(left, 0.25)):
                if time.monotonic() >= deadline:
                    got = self.buf.decode("latin1", "replace")
                    raise ConsoleError(
                        f"timeout waiting for {pattern!r} (got {got[-120:]!r})")

    def expect_line_with(self, pattern, timeout: float = 3.0) -> str:
        """expect() the pattern, then finish reading its line."""
        self.expect(pattern, timeout)
        try:
            tail = self.expect(b"\n", timeout=1.0)
        except ConsoleError:
            tail = self.drain().decode("latin1", "replace")
        if isinstance(pattern, bytes):
            pattern = pattern.decode("latin1")
        return pattern + tail.rstrip("\r\n")

    # ── byte-level reads (XMODEM handshake) ──────────────────────────────
    def read_byte(self, timeout: float) -> Optional[int]:
        deadline = time.monotonic() + timeout
        while not self.buf:
            left = deadline - time.monotonic()
            if left <= 0 or not self._pump(min(left, 0.25)):
                if time.monotonic() >= deadline:
                    return None
        b = self.buf[0]
        del self.buf[:1]
        return b


def xmodem_abort(sess: ConsoleSession) -> None:
    """Tell a receiver that is still waiting to give up.

    xreceive.c takes two CANs in a row (`case CAN: if (waitbyte() == CAN)`),
    with the second read separately — so they are sent with a gap, and a few
    times, because the first pair may land inside a packet the receiver was
    already collecting."""
    try:
        for _ in range(3):
            sess.send(bytes([CAN]))
            time.sleep(0.05)
            sess.send(bytes([CAN]))
            time.sleep(0.15)
        sess.send(b"\r")
        sess.drain(0.2)
    except Exception:                                # noqa: BLE001
        pass


def xmodem1k_send(sess: ConsoleSession, data: bytes,
                  progress: Optional[Callable[[str], None]] = None,
                  handshake_timeout: float = 15.0) -> None:
    """Send `data` as XMODEM-1K to the MCU already sitting in xReceive().

    The receiver polls 'C' (CRC mode) until the first block arrives; each
    block is STX blk ~blk data[1024] crc_hi crc_lo, short blocks padded with
    0x1A (CP/M EOF); EOT is ACKed to finish."""
    # wait for the CRC prompt (drop any leftover console echo before it)
    deadline = time.monotonic() + handshake_timeout
    while True:
        b = sess.read_byte(timeout=max(0.05, deadline - time.monotonic()))
        if b == CRC_PROMPT:
            break
        if b == CAN:
            raise ConsoleError("receiver cancelled before transfer")
        if b is None and time.monotonic() >= deadline:
            raise ConsoleError("no XMODEM 'C' handshake from the MCU")

    total = len(data)
    nblocks = (total + XMODEM_BLOCK - 1) // XMODEM_BLOCK or 1
    for blk in range(nblocks):
        chunk = data[blk * XMODEM_BLOCK:(blk + 1) * XMODEM_BLOCK]
        chunk = chunk.ljust(XMODEM_BLOCK, b"\x1a")
        blkno = (blk + 1) & 0xFF
        crc = crc16_ccitt(chunk)
        pkt = bytes([STX, blkno, blkno ^ 0xFF]) + chunk + \
            bytes([(crc >> 8) & 0xFF, crc & 0xFF])
        for attempt in range(10):
            sess.send(pkt)
            while True:
                r = sess.read_byte(timeout=10.0)
                if r in (CRC_PROMPT,):          # late extra prompt — ignore
                    continue
                break
            if r == ACK:
                break
            if r == CAN:
                raise ConsoleError(
                    f"receiver aborted at block {blk + 1}/{nblocks} "
                    "(file larger than the largest free gap?)")
            if r is None:
                raise ConsoleError(f"no ACK for block {blk + 1}/{nblocks}")
            # NAK (or garbage): retransmit
        else:
            raise ConsoleError(f"block {blk + 1} rejected 10 times")
        if progress:
            progress(f"upload {min((blk + 1) * XMODEM_BLOCK, total)}"
                     f"/{total} bytes")
    for _ in range(10):
        sess.send(bytes([EOT]))
        r = sess.read_byte(timeout=5.0)
        if r == ACK:
            return
        if r is None:
            break
    raise ConsoleError("EOT not acknowledged")
