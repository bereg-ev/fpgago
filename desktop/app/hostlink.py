"""hostlink.py — desktop end of the fpgago mixed text/binary serial protocol.

One USB-CDC carries both the human console (plain ASCII) and the binary app
protocol, demuxed in-band by a 0x00 frame boundary (see hostlink_proto.h). This
module is the mirror image of the MCU's hostlink.c:

  * load_proto()  — scrape the constants out of the shared hostlink_proto.h so
                    the two ends can never drift.
  * cobs / crc16  — the frame codec.
  * Demux         — split an incoming byte stream into ('text', bytes) and
                    ('frame', type, seq, payload) items.
  * HostLink      — a threaded transport over any byte stream (pyserial or a
                    subprocess pipe): request/response by seq + async events +
                    a console-text callback.

No pyserial or Qt import here, so it unit-tests headlessly against the C codec.
"""

from __future__ import annotations

import os
import re
import threading
from dataclasses import dataclass
from typing import Callable, Optional

# ── shared-header constants (single source of truth) ────────────────────────

# Set FPGAGO_MCU to a checkout of the board firmware to parse the real
# header; without it the embedded copy below is used, which is what a plain
# clone of this repository runs on.
_DEFAULT_HEADER = os.path.join(
    os.path.expanduser(os.environ.get("FPGAGO_MCU", "")),
    "hostlink_proto.h") if os.environ.get("FPGAGO_MCU") else ""

# Fallback when the firmware headers are not available.
_EMBEDDED = {
    "HL_PROTO_VER": 0x0001, "HL_FRAME_DELIM": 0x00, "HL_MAX_PAYLOAD": 2048,
    "HL_HDR_LEN": 4, "HL_CRC_LEN": 2, "HL_RESP_FLAG": 0x80,
    "HL_CMD_PING": 0x01, "HL_CMD_REBOOT": 0x02, "HL_CMD_ECHO": 0x03,
    "HL_CMD_FS_LIST": 0x10, "HL_CMD_FS_STAT": 0x11, "HL_CMD_FS_DELETE": 0x12,
    "HL_CMD_FS_FORMAT": 0x13, "HL_CMD_FS_READ": 0x14,
    "HL_CMD_UP_BEGIN": 0x15, "HL_CMD_UP_DATA": 0x16, "HL_CMD_UP_END": 0x17,
    "HL_CMD_KV_GET": 0x18, "HL_CMD_KV_SET": 0x19,
    "HL_CMD_FS_LIST2": 0x1A, "HL_CMD_FS_TAG": 0x1B,
    "HL_PLAT_MAX": 10, "HL_FTYPE_UNKNOWN": 0, "HL_FTYPE_BIT": 1,
    "HL_FTYPE_GAME": 2,
    "HL_CMD_MOUNT": 0x20, "HL_CMD_UNMOUNT": 0x21, "HL_CMD_DISK_DIR": 0x22,
    "HL_CMD_MACHINE": 0x23, "HL_CMD_BIOS": 0x24, "HL_CMD_VOLUME": 0x25,
    "HL_CMD_SET_BOOT": 0x26, "HL_CMD_FPGA_PROG": 0x27,
    "HL_CMD_R2_LAUNCH": 0x29, "HL_CMD_UART_TX": 0x30,
    "HL_CMD_SHOT_GRAB": 0x40, "HL_CMD_SHOT_STOP": 0x41,
    "HL_EVT_LOG": 0xE0, "HL_EVT_UART_RX": 0xE1, "HL_EVT_STATUS": 0xE2,
    "HL_EVT_SHOT_LINE": 0xE3,
    "HL_OK": 0x00, "HL_ERR_BAD_ARG": 0x01, "HL_ERR_NOT_FOUND": 0x02,
    "HL_ERR_FS_FULL": 0x03, "HL_ERR_BUSY": 0x04, "HL_ERR_FPGA_DOWN": 0x05,
    "HL_ERR_CRC": 0x06, "HL_ERR_RANGE": 0x07, "HL_ERR_NOT_IMPL": 0x7F,
    "HL_NAME_MAX": 36, "HL_FORMAT_MAGIC": 0x46524D54,
}

_DEFINE_RE = re.compile(r"^\s*#define\s+(HL_\w+)\s+(0x[0-9A-Fa-f]+|\d+)\b")


class Proto(dict):
    """Constant table with attribute access (P.HL_CMD_PING)."""

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError as e:
            raise AttributeError(name) from e


def load_proto(path: Optional[str] = None) -> Proto:
    path = path or _DEFAULT_HEADER
    table = dict(_EMBEDDED)
    try:
        with open(path, "r") as fh:
            for line in fh:
                m = _DEFINE_RE.match(line)
                if m:
                    table[m.group(1)] = int(m.group(2), 0)
    except OSError:
        pass                                     # keep embedded defaults
    return Proto(table)


# ── frame codec ─────────────────────────────────────────────────────────────

def crc16_ccitt(data: bytes) -> int:
    """CRC16-CCITT, poly 0x1021, init 0x0000 (matches hostlink.c)."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def cobs_encode(data: bytes) -> bytes:
    out = bytearray()
    code_at = len(out)
    out.append(0)                                # placeholder for the code
    code = 1
    for byte in data:
        if byte == 0:
            out[code_at] = code
            code_at = len(out)
            out.append(0)
            code = 1
        else:
            out.append(byte)
            code += 1
            if code == 0xFF:
                out[code_at] = code
                code_at = len(out)
                out.append(0)
                code = 1
    out[code_at] = code
    return bytes(out)


def cobs_decode(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        code = data[i]
        i += 1
        if code == 0:
            raise ValueError("interior zero in COBS data")
        for _ in range(code - 1):
            if i >= n:
                raise ValueError("truncated COBS block")
            out.append(data[i])
            i += 1
        if code < 0xFF and i < n:
            out.append(0)
    return bytes(out)


def encode_frame(ftype: int, seq: int, payload: bytes = b"") -> bytes:
    """Full on-the-wire frame: DELIM + COBS(header,payload,crc) + DELIM."""
    body = bytearray()
    body.append(ftype & 0xFF)
    body.append(seq & 0xFF)
    body.append(len(payload) & 0xFF)
    body.append((len(payload) >> 8) & 0xFF)
    body += payload
    crc = crc16_ccitt(bytes(body))
    body.append(crc & 0xFF)
    body.append((crc >> 8) & 0xFF)
    return b"\x00" + cobs_encode(bytes(body)) + b"\x00"


@dataclass
class Frame:
    type: int
    seq: int
    payload: bytes


def decode_frame_ex(cobs_bytes: bytes):
    """(Frame, None) on success, (None, reason) on a malformed segment.

    The reason matters when a frame goes missing: text and small frames can
    cross the link perfectly while a big one (a screen-grab line is 807 B)
    fails, and "which check failed" says whether the bytes were corrupted,
    truncated, or never a frame at all."""
    try:
        body = cobs_decode(cobs_bytes)
    except ValueError as exc:
        return None, f"COBS: {exc}"
    if len(body) < 4 + 2:
        return None, f"too short ({len(body)} B decoded)"
    ftype, seq = body[0], body[1]
    length = body[2] | (body[3] << 8)
    if len(body) != 4 + length + 2:
        return None, (f"length field {length} vs {len(body) - 6} B decoded "
                      f"(type 0x{ftype:02x})")
    crc_rx = body[4 + length] | (body[4 + length + 1] << 8)
    crc_calc = crc16_ccitt(body[:4 + length])
    if crc_calc != crc_rx:
        return None, (f"CRC {crc_calc:04x} != {crc_rx:04x} on a {length} B "
                      f"type 0x{ftype:02x} frame")
    return Frame(ftype, seq, bytes(body[4:4 + length])), None


def decode_frame(cobs_bytes: bytes) -> Optional[Frame]:
    """Decode the COBS bytes between two delimiters. None if malformed."""
    return decode_frame_ex(cobs_bytes)[0]


# ── in-band demultiplexer (mirror of hostlink.c's state machine) ────────────

class Demux:
    """Feed raw bytes; get back ('text', bytes) and ('frame', Frame) items.

    A frame is `00 <cobs> 00`, so the delimiter both closes one frame and can
    open the next — which makes a naive open/close toggle position-dependent
    and therefore fragile.  ONE stray 0x00 in the console text stream shifts
    the parity by one, and from then on every frame body is delivered as text
    and every run of text is eaten as a frame body.  Nothing ever puts it
    back: the link keeps working, the app stops seeing PING responses, calls
    the board dead, and sits there — until the user hits Disconnect/Connect,
    which builds a fresh Demux and fixes it instantly (board, 2026-08-05; the
    MCU console filled with COBS bytes rendered as text).

    So the close decision is made on CONTENT, not on position: a segment that
    decodes as a valid frame (COBS + length + CRC) was a frame and the
    delimiter closed it; a segment that does not was text, and the delimiter
    is an OPENER, not a closer.  The parity cannot be inverted for longer
    than one segment, and a corrupt frame costs one garbage line in the
    console rather than the rest of the session.
    """

    def __init__(self):
        self._in_frame = False
        self._acc = bytearray()

    def reset(self):
        """Drop any half-read segment.  Belt and braces for the reconnect
        path — the content check above already resynchronises on its own."""
        self._in_frame = False
        self._acc = bytearray()

    def feed(self, data: bytes):
        out = []
        text = bytearray()
        for b in data:
            if not self._in_frame:
                if b == 0x00:
                    if text:
                        out.append(("text", bytes(text)))
                        text = bytearray()
                    self._in_frame = True
                    self._acc = bytearray()
                else:
                    text.append(b)
            else:
                if b == 0x00:
                    fr, why = (decode_frame_ex(bytes(self._acc)) if self._acc
                               else (None, "empty"))
                    if fr is not None:
                        out.append(("frame", fr))
                        self._in_frame = False   # this delimiter closed it
                    else:
                        # Console text between delimiters is short and fails
                        # here all the time — that is the normal resync below.
                        # A LARGE failed segment is different: something that
                        # looked like a frame did not survive the wire, and
                        # that is worth reporting instead of silently
                        # becoming console noise.
                        if len(self._acc) >= 64:
                            out.append(("drop", (len(self._acc), why)))
                        # Not a frame after all: it was text that happened to
                        # follow a stray 0x00.  Hand it back as text and read
                        # this delimiter as the opener it almost certainly is.
                        if self._acc:
                            out.append(("text", bytes(self._acc)))
                        self._acc = bytearray()
                        self._in_frame = True
                else:
                    self._acc.append(b)
        if text:
            out.append(("text", bytes(text)))
        return out


# ── threaded transport ──────────────────────────────────────────────────────

class HostLink:
    """Request/response + events over a byte stream.

    read_fn(maxbytes) -> bytes   (blocking or short-timeout; b'' on idle)
    write_fn(bytes)              (writes raw bytes to the device)
    """

    def __init__(self, read_fn: Callable[[int], bytes],
                 write_fn: Callable[[bytes], None],
                 proto: Optional[Proto] = None,
                 on_text: Optional[Callable[[bytes], None]] = None,
                 on_event: Optional[Callable[[Frame], None]] = None):
        self.P = proto or load_proto()
        self._read = read_fn
        self._write = write_fn
        self.on_text = on_text
        self.on_event = on_event
        self._demux = Demux()
        self._seq = 0
        self._lock = threading.Lock()
        self._pending: dict[int, list] = {}      # seq -> [Event, Frame|None]
        self._stop = threading.Event()
        self._reader = threading.Thread(target=self._loop, daemon=True)

    def start(self):
        self._reader.start()

    def stop(self):
        self._stop.set()

    def _loop(self):
        while not self._stop.is_set():
            try:
                data = self._read(256)
            except Exception:                    # noqa: BLE001 — stream closed
                break
            if not data:
                continue
            for kind, item in self._demux.feed(data):
                if kind == "text":
                    if self.on_text:
                        self.on_text(item)
                elif kind == "frame":
                    self._on_frame(item)
                # "drop" (a big segment that failed to decode) has no
                # consumer here; the GUI's SerialManager reports those.

    def _on_frame(self, fr: Frame):
        # Event ids (0xE0-0xEF) have bit 7 set too — route them BEFORE the
        # response test, or an event whose rolling seq collides with a
        # pending command's seq is delivered as that command's "response"
        # (and the command returns an event payload as its result).
        if 0xE0 <= fr.type <= 0xEF:
            if self.on_event:
                self.on_event(fr)
            return
        if fr.type & self.P.HL_RESP_FLAG:
            with self._lock:
                slot = self._pending.get(fr.seq)
                if slot is not None:
                    slot[1] = fr
                    slot[0].set()
                    return
            # Unmatched response — surface as an event so nothing is lost.
        if self.on_event:
            self.on_event(fr)

    def _next_seq(self) -> int:
        with self._lock:
            self._seq = (self._seq + 1) & 0xFF
            return self._seq

    def command(self, cmd_type: int, payload: bytes = b"",
                timeout: float = 2.0):
        """Send a command; return (status:int, payload:bytes).

        Raises TimeoutError if no response arrives within `timeout`."""
        seq = self._next_seq()
        ev = threading.Event()
        slot = [ev, None]
        with self._lock:
            self._pending[seq] = slot
        try:
            self._write(encode_frame(cmd_type, seq, payload))
            if not ev.wait(timeout):
                raise TimeoutError(f"no response to cmd 0x{cmd_type:02x}")
            fr: Frame = slot[1]
            status = fr.payload[0] if fr.payload else self.P.HL_ERR_BAD_ARG
            return status, fr.payload[1:]
        finally:
            with self._lock:
                self._pending.pop(seq, None)

    # -- convenience --------------------------------------------------------
    def send_text(self, data: bytes):
        """Send plain console text (no framing) — e.g. a keystroke."""
        self._write(data)

    def ping(self, timeout: float = 2.0) -> dict:
        status, p = self.command(self.P.HL_CMD_PING, timeout=timeout)
        if status != self.P.HL_OK or len(p) < 2 + 8 + 1 + 4:
            raise IOError(f"PING failed (status {status})")
        proto_ver = p[0] | (p[1] << 8)
        fw_hash = p[2:10].split(b"\x00", 1)[0].decode("latin1")
        board = p[10]
        caps = p[11] | (p[12] << 8) | (p[13] << 16) | (p[14] << 24)
        return {"proto_ver": proto_ver, "fw_hash": fw_hash,
                "board": board, "caps": caps}
