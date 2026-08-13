"""test_hostlink.py — protocol unit tests + a live C<->Python loopback.

The loopback compiles the firmware's hostlink.c with -DHOSTLINK_HOST_TEST and
drives the real MCU codec over a pipe, so the wire protocol is validated end to
end with no hardware.  It is SKIPPED unless FPGAGO_MCU points at a checkout of
the board firmware; the pure-Python codec tests always run.
Run:  desktop/.venv/bin/python -m pytest desktop/tests -q
"""

import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import hostlink as hl                                    # noqa: E402

MCU_DIR = os.path.expanduser(os.environ.get("FPGAGO_MCU", ""))
HOSTLINK_C = os.path.join(MCU_DIR, "hostlink.c")


# ── pure-Python codec ───────────────────────────────────────────────────────

def test_crc16_known_vector():
    # CRC16/XMODEM (poly 0x1021, init 0x0000) of "123456789" is 0x31C3.
    # (init 0xFFFF would be 0x29B1 — we deliberately use init 0 on both ends.)
    assert hl.crc16_ccitt(b"123456789") == 0x31C3


@pytest.mark.parametrize("data", [
    b"", b"\x00", b"\x00\x00", b"1", b"12345", bytes(range(256)),
    b"\x00" * 300, bytes([i % 256 for i in range(600)]),
])
def test_cobs_roundtrip(data):
    enc = hl.cobs_encode(data)
    assert 0 not in enc                      # no interior zero — the whole point
    assert hl.cobs_decode(enc) == data


@pytest.mark.parametrize("payload", [b"", b"hi", bytes(range(200)), b"\x00" * 100])
def test_frame_roundtrip(payload):
    wire = hl.encode_frame(0x42, 7, payload)
    assert wire[0] == 0x00 and wire[-1] == 0x00
    fr = hl.decode_frame(wire[1:-1])
    assert fr is not None
    assert fr.type == 0x42 and fr.seq == 7 and fr.payload == payload


def test_frame_crc_rejected():
    wire = bytearray(hl.encode_frame(0x01, 1, b"abc"))
    cobs = hl.cobs_decode(bytes(wire[1:-1]))
    tampered = bytearray(cobs)
    tampered[5] ^= 0xFF                        # corrupt a payload byte
    assert hl.decode_frame(hl.cobs_encode(bytes(tampered))) is None


def test_demux_mixes_text_and_frames():
    dm = hl.Demux()
    stream = b"READY.\r\n" + hl.encode_frame(0x03, 9, b"xy") + b"OK\r\n"
    items = dm.feed(stream)
    kinds = [(k, (v if k == "text" else (v.type, v.seq, v.payload)))
             for k, v in items]
    assert kinds == [
        ("text", b"READY.\r\n"),
        ("frame", (0x03, 9, b"xy")),
        ("text", b"OK\r\n"),
    ]


def test_demux_frame_split_across_feeds():
    dm = hl.Demux()
    wire = hl.encode_frame(0x03, 1, b"abc")
    out = dm.feed(wire[:3]) + dm.feed(wire[3:])
    frames = [v for k, v in out if k == "frame"]
    assert len(frames) == 1 and frames[0].payload == b"abc"


def test_a_stray_zero_in_the_text_does_not_swallow_every_later_frame():
    """THE connection bug: one 0x00 in the console stream shifted the
    frame/text parity by one, so every frame body afterwards was delivered as
    console text and no PING response was ever seen again.  The link stayed
    up, the app called the board dead, and only Disconnect/Connect (a fresh
    Demux) fixed it (board, 2026-08-05)."""
    dm = hl.Demux()
    # a NUL lands in the middle of ordinary console output ...
    out = dm.feed(b"READY.\x00junk")
    # ... and then normal traffic resumes
    for _ in range(3):
        out += dm.feed(hl.encode_frame(0x81, 7, b"pong") + b"log line\r\n")

    frames = [v for k, v in out if k == "frame"]
    assert len(frames) == 3, "frames went missing after a stray NUL"
    assert all(f.payload == b"pong" and f.seq == 7 for f in frames)
    text = b"".join(v for k, v in out if k == "text")
    assert b"READY." in text and b"junk" in text     # nothing is lost either
    assert b"log line\r\n" in text


def test_demux_recovers_however_the_stray_zeros_fall():
    """Any number of stray NULs, in any position, must cost at most the
    segment they land in — never the rest of the session."""
    wire = hl.encode_frame(0x81, 3, b"xyz")
    for noise in (b"\x00", b"\x00\x00", b"a\x00b", b"\x00\x00\x00x"):
        dm = hl.Demux()
        dm.feed(noise)
        got = [v for k, v in dm.feed(wire + wire) if k == "frame"]
        assert len(got) == 2, f"lost frames after {noise!r}: {len(got)}"


def test_a_corrupt_frame_costs_only_itself():
    """A CRC error must not desynchronise the stream — the bad frame comes
    back as text (visible in the console, which is honest) and the next good
    frame decodes normally."""
    dm = hl.Demux()
    bad = bytearray(hl.encode_frame(0x81, 1, b"abcd"))
    bad[4] ^= 0xFF                                   # corrupt inside the COBS
    good = hl.encode_frame(0x81, 2, b"ok")
    out = dm.feed(bytes(bad) + good)
    frames = [v for k, v in out if k == "frame"]
    assert len(frames) == 1 and frames[0].seq == 2


def test_screen_grab_sized_frame_survives_the_demux():
    """A screen-grab line is 807 B of payload — the only frame on this link
    bigger than a USB packet, and the first one that ever failed to arrive.
    Byte-at-a-time feeding is how the reader thread actually sees it."""
    payload = bytes((i * 7 + (i >> 3)) & 0xFF for i in range(807))
    wire = hl.encode_frame(0xE3, 5, payload)
    dm = hl.Demux()
    got = []
    for b in wire:
        got += dm.feed(bytes([b]))
    frames = [v for k, v in got if k == "frame"]
    assert len(frames) == 1
    assert frames[0].type == 0xE3 and frames[0].payload == payload


def test_big_corrupt_frame_is_reported_not_swallowed():
    """A large segment that fails to decode is a lost frame, not console
    noise — the demux says so, which is what pinned the grab failure on the
    MCU's USB write path instead of the FPGA."""
    bad = bytearray(hl.encode_frame(0xE3, 6, bytes(400)))
    bad[100] ^= 0xFF                                 # corrupt inside the COBS
    out = hl.Demux().feed(bytes(bad))
    drops = [v for k, v in out if k == "drop"]
    assert len(drops) == 1
    nbytes, reason = drops[0]
    assert nbytes >= 400 and ("CRC" in reason or "length" in reason
                              or "COBS" in reason)


def test_small_console_noise_is_not_reported_as_a_drop():
    """Console text between stray zeros fails to decode all the time; that is
    the normal resync path and must stay quiet."""
    out = hl.Demux().feed(b"\x00READY.\x00")
    assert not [v for k, v in out if k == "drop"]


def test_event_frames_route_as_events_not_responses():
    """Event ids (0xE0-0xE3) have bit 7 set, so a resp-flag-first dispatch
    reads every unsolicited MCU event as "a response nobody is waiting for"
    and silently discards it.  That routing bug ate all 240 SHOT_LINE frames
    of the screen grab — MCU streaming 22 KB/s of valid frames, app showing
    nothing (board, 2026-08-06).  Worse: an event whose rolling seq collided
    with a pending command's seq was delivered AS that command's response.
    Events must route as events even when a command is in flight on the
    very same seq."""
    import threading
    link = hl.HostLink(read_fn=lambda n: b"", write_fn=lambda b: None)
    events = []
    link.on_event = events.append

    # a command is pending on seq 7; an EVENT arrives carrying seq 7
    ev = threading.Event()
    slot = [ev, None]
    with link._lock:
        link._pending[7] = slot
    link._on_frame(hl.Frame(0xE3, 7, b"\x00\x00\x90\x01\xf0\x00\x00"))
    assert events and events[0].type == 0xE3, "event was not surfaced"
    assert slot[1] is None and not ev.is_set(), \
        "event was mis-delivered as the pending command's response"

    # a real response on that seq still reaches the waiter
    link._on_frame(hl.Frame(0x81, 7, b"\x00"))
    assert slot[1] is not None and slot[1].type == 0x81


def test_reset_clears_a_half_read_frame():
    dm = hl.Demux()
    wire = hl.encode_frame(0x03, 1, b"abc")
    dm.feed(wire[:4])                                # mid-frame
    dm.reset()
    frames = [v for k, v in dm.feed(wire) if k == "frame"]
    assert len(frames) == 1 and frames[0].payload == b"abc"


def test_proto_header_scraped():
    P = hl.load_proto()
    assert P.HL_CMD_PING == 0x01
    assert P.HL_RESP_FLAG == 0x80
    assert P.HL_MAX_PAYLOAD >= 2048


# ── live loopback against the compiled C codec ──────────────────────────────

@pytest.fixture(scope="module")
def clink(tmp_path_factory):
    if not os.path.exists(HOSTLINK_C):
        pytest.skip(f"{HOSTLINK_C} not found")
    binary = str(tmp_path_factory.mktemp("hl") / "selftest")
    r = subprocess.run(["cc", "-DHOSTLINK_HOST_TEST", "-O2", "-o", binary,
                        HOSTLINK_C], capture_output=True, text=True)
    if r.returncode != 0:
        pytest.skip(f"compile failed:\n{r.stderr}")
    proc = subprocess.Popen([binary], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, bufsize=0)

    texts = []
    link = hl.HostLink(
        read_fn=lambda n: proc.stdout.read(n),
        write_fn=lambda b: (proc.stdin.write(b), proc.stdin.flush()),
        on_text=texts.append)
    link.start()
    link._texts = texts
    yield link
    link.stop()
    proc.stdin.close()
    proc.terminate()


def test_c_ping(clink):
    info = clink.ping()
    assert info["proto_ver"] == clink.P.HL_PROTO_VER
    assert info["fw_hash"] == "hosttest"


@pytest.mark.parametrize("payload", [b"", b"hello", bytes(range(250)), b"\x00\x01\x00"])
def test_c_echo(clink, payload):
    status, data = clink.command(clink.P.HL_CMD_ECHO, payload)
    assert status == clink.P.HL_OK
    assert data == payload


def test_c_unknown_command_not_impl(clink):
    status, _ = clink.command(0x7E, b"")       # unassigned id
    assert status == clink.P.HL_ERR_NOT_IMPL


def test_c_text_passthrough(clink):
    # Non-frame bytes are echoed by the harness (proves in-band text demux).
    clink._texts.clear()
    clink.send_text(b"READY.\r\n")
    import time
    for _ in range(50):
        if b"".join(clink._texts) == b"READY.\r\n":
            break
        time.sleep(0.02)
    assert b"".join(clink._texts) == b"READY.\r\n"
