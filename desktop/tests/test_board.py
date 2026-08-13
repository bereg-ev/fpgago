"""Tests for board_backend + console_script against a scripted fake MCU.

The fake implements the transport surface BoardOps needs (command(),
write_bytes(), text taps, ping holds) and emulates the firmware behaviours
the desktop relies on: implemented hostlink commands, NOT_IMPL for the ones
the MCU hasn't wired, and the console dialogs ('U' XMODEM upload, 'P' KV
set, 'K' KV list, 'C' version, 'N' dir header, 'M' drive toggle).
"""

import queue
import threading
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app import hostlink                                     # noqa: E402
from app.board_backend import (                              # noqa: E402
    FT_BIT, FT_GAME, FT_ROM, FT_UNKNOWN, BoardError, BoardOps, arch_of_name,
    infer_tag, kind_of_name, norm_platform, parse_fs_list, parse_fs_list2,
)
from app.console_script import (                             # noqa: E402
    ACK, CAN, ConsoleError, ConsoleSession, EOT, STX, crc16_ccitt,
    xmodem1k_send,
)

P = hostlink.load_proto()


# ── fake MCU ────────────────────────────────────────────────────────────────

class FakeMcu:
    """Emulates the firmware side: hostlink handlers + console dialogs."""

    def __init__(self):
        self.P = P
        self.files = {"c64-iec.bit": b"\xff" * 100,
                      "wizard.d64": b"\x01" * 50,
                      "boulder.prg": b"\x02" * 30,
                      "prince.crt": b"\x03" * 20}
        # FS v2 tag per file: name -> (ftype, platform)
        self.tags = {"c64-iec.bit": (1, "c64"), "prince.crt": (2, "c64")}
        self.boot = "c64-iec.bit"
        self.kv = {"drive.mode": b"\x00"}
        self.volume = None
        self.mounted = None
        self.typed = b""
        self.machine_ctl = []
        self.not_impl = {P.HL_CMD_UP_BEGIN, P.HL_CMD_UP_DATA, P.HL_CMD_UP_END,
                         P.HL_CMD_KV_GET, P.HL_CMD_KV_SET, P.HL_CMD_FS_FORMAT,
                         P.HL_CMD_FS_READ, P.HL_CMD_DISK_DIR,
                         P.HL_CMD_FPGA_PROG, P.HL_CMD_R2_LAUNCH}
        self.rebooted = []

        self._taps = []
        self._tap_lock = threading.Lock()
        self._console = _ConsoleEmu(self)
        self.ping_hold = 0

    # -- transport surface (what SerialManager provides) --------------------
    is_open = True
    device = "/dev/fake"

    def add_text_tap(self, q):
        with self._tap_lock:
            self._taps.append(q)

    def remove_text_tap(self, q):
        with self._tap_lock:
            if q in self._taps:
                self._taps.remove(q)

    def hold_pings(self):
        self.ping_hold += 1

    def release_pings(self):
        self.ping_hold -= 1

    def emit_text(self, data: bytes):
        with self._tap_lock:
            for q in self._taps:
                q.put(data)

    def write_bytes(self, data: bytes):
        # hostlink frames (0x00-delimited) → REBOOT bookkeeping; everything
        # else goes to the console emulator.
        if data[:1] == b"\x00":
            fr = hostlink.decode_frame(data[1:-1])
            if fr and fr.type == P.HL_CMD_REBOOT:
                self.rebooted.append(fr.payload[0] if fr.payload else 0)
            return
        self._console.feed(data)

    def command(self, cmd, payload=b"", timeout=2.0):
        assert self.ping_hold == 0, \
            "hostlink command sent while a console dialog owns the stream"
        if cmd in self.not_impl:
            return P.HL_ERR_NOT_IMPL, b""
        if cmd == P.HL_CMD_FS_LIST:
            out = bytearray([len(self.files)])
            for name, data in self.files.items():
                nb = name.encode()
                out += bytes([len(nb)]) + nb + len(data).to_bytes(4, "little")
            return P.HL_OK, bytes(out)
        if cmd == P.get("HL_CMD_FS_LIST2", 0x1A):
            out = bytearray([len(self.files)])
            for name, data in self.files.items():
                nb = name.encode()
                ft, pl = self.tags.get(name, (0, ""))
                plb = pl.encode()
                out += bytes([len(nb)]) + nb + len(data).to_bytes(4, "little")
                out += bytes([ft, len(plb)]) + plb
            return P.HL_OK, bytes(out)
        if cmd == P.get("HL_CMD_FS_TAG", 0x1B):
            ft, pl = payload[0], payload[1]
            plat = payload[2:2 + pl].decode()
            name = payload[2 + pl:].split(b"\x00")[0].decode()
            if name not in self.files:
                return P.HL_ERR_NOT_FOUND, b""
            self.tags[name] = (ft, plat)
            return P.HL_OK, b""
        if cmd == P.HL_CMD_FS_STAT:
            name = payload.split(b"\x00")[0].decode()
            if name not in self.files:
                return P.HL_ERR_NOT_FOUND, b""
            data = self.files[name]
            import zlib
            # 16-byte reply, as the firmware answers since 2026-08-05:
            # usize, sum-over-STORED-bytes, stored size, sum-over-LOGICAL.
            # The fake stores raw, so stored == logical here; the point is
            # that the desktop must use the LAST field and not the second,
            # which for a compressed file is a number it cannot compute.
            lsum = sum(data) & 0xFFFFFFFF
            return P.HL_OK, (len(data).to_bytes(4, "little")
                             + (zlib.crc32(data) & 0xFFFFFFFF)
                             .to_bytes(4, "little")
                             + len(data).to_bytes(4, "little")
                             + lsum.to_bytes(4, "little"))
        if cmd == P.HL_CMD_FS_DELETE:
            name = payload.split(b"\x00")[0].decode()
            if self.files.pop(name, None) is None:
                return P.HL_ERR_NOT_FOUND, b""
            return P.HL_OK, b""
        if cmd == P.HL_CMD_SET_BOOT:
            self.boot = payload.split(b"\x00")[0].decode()
            return P.HL_OK, b""
        if cmd == P.HL_CMD_MOUNT:
            name = payload.split(b"\x00")[0].decode()
            if name not in self.files:
                return P.HL_ERR_NOT_FOUND, b""
            self.mounted = name
            return P.HL_OK, b""
        if cmd == P.HL_CMD_UNMOUNT:
            self.mounted = None
            return P.HL_OK, b""
        if cmd == P.HL_CMD_VOLUME:
            self.volume = payload[0]
            return P.HL_OK, b""
        if cmd == P.HL_CMD_MACHINE:
            self.machine_ctl.append(payload[0])
            return P.HL_OK, b""
        if cmd == P.HL_CMD_BIOS:
            return P.HL_OK, b""
        if cmd == P.HL_CMD_UART_TX:
            self.typed += payload
            return P.HL_OK, b""
        if cmd == P.HL_CMD_KV_GET:
            # Only reached when a test takes KV_GET out of not_impl: the
            # firmware on the bench does not implement it, and the desktop's
            # console fallback is the path that actually runs.
            val = self.kv.get(payload.split(b"\x00")[0].decode())
            if val is None:
                return P.HL_ERR_NOT_FOUND, b""
            return P.HL_OK, val
        raise AssertionError(f"unexpected hostlink cmd 0x{cmd:02x}")


class _ConsoleEmu:
    """Just enough of appInChar()/readLine()/xReceive() for the tests."""

    def __init__(self, mcu: FakeMcu):
        self.m = mcu
        self.state = "idle"
        self.line = b""
        self.xm = None

    def feed(self, data: bytes):
        for i in range(len(data)):
            self._byte(data[i:i + 1])

    def _byte(self, b: bytes):
        m = self.m
        if self.state == "xmodem":
            self._xmodem_byte(b[0])
            return
        if self.state in ("u-name", "u-plat", "u-bitplat", "t-name",
                          "p-key", "p-val"):
            if b in (b"\r", b"\n"):
                line, self.line = self.line.decode(), b""
                m.emit_text(b"\n")
                self._line_done(line)
            else:
                self.line += b
                m.emit_text(b)               # readLine echoes
            return
        # idle: single-char commands
        c = b.decode("latin1")
        if c == "U":
            m.emit_text(b"filename (e.g. fpga.bit, game.d64, game.prg): ")
            self.state = "u-name"
        elif c == "3":
            m.emit_text(b"re-tag file (name or 'N' index): ")
            self.state = "t-name"
        elif c == "P":
            m.emit_text(b"key: ")
            self.state = "p-key"
        elif c == "K":
            # Byte-for-byte what kvstore.c kvDump() prints: eight bytes of
            # the value at most, and then how long it really is.  A listing
            # that quietly showed whole values would hide the exact problem
            # the desktop has to cope with.
            out = b""
            for i, (k, v) in enumerate(m.kv.items()):
                out += (f'  [{i}] "{k}" = '.encode()
                        + " ".join(f"{x:02x}" for x in v[:8]).encode() + b" ")
                if len(v) > 8:
                    out += f"... ({len(v)} bytes)".encode()
                out += b"\n"
            m.emit_text(out)
        elif c == "C":
            m.emit_text(b"fpgago-mcu  fw=2607190001.1  bit=2607181514.0\n")
        elif c == "N":
            m.emit_text(
                f"flash_fs: {len(m.files)} files, free 1234 KB "
                f"(largest gap 900 KB)\n  boot: \"{m.boot}\"\n".encode())
            for name, data in m.files.items():
                m.emit_text(f"  {name}  {len(data)}\n".encode())
        elif c == "M":
            cur = m.kv.get("drive.mode", b"\x00")[0]
            new = 0 if cur else 1
            m.kv["drive.mode"] = bytes([new])
            m.emit_text(b"drive mode: REAL 1541\n" if new
                        else b"drive mode: FASTLOAD\n")
        elif c == "F":
            m.emit_text(b"format: delete ALL files! type YES to confirm: ")
            self.state = "p-fmt" if False else "u-name"  # reuse line reader
            self._fmt = True
            return
        # everything else: ignore

    def _line_done(self, line: str):
        m = self.m
        if getattr(self, "_fmt", False):
            self._fmt = False
            self.state = "idle"
            if line == "YES":
                m.files.clear()
            else:
                m.emit_text(b"cancelled\n")
            return
        if self.state in ("u-name", "t-name"):
            self.upload_name = line
            self._tag_next = "u" if self.state == "u-name" else "t"
            m.emit_text(b"platform: 1=bit (machine bitstream)  2=c64  3=c16"
                        b"  4=plus4\n          5=264 (c16+plus4)  "
                        b"or a custom name: ")
            self.state = "u-plat"
        elif self.state == "u-plat":
            if line in ("1", "bit"):
                m.emit_text(b"bitstream platform [c64]: ")
                self.state = "u-bitplat"
                return
            plat = {"2": "c64", "3": "c16", "4": "plus4",
                    "5": "264"}.get(line, line)
            self._tag_done(FT_GAME, plat)
        elif self.state == "u-bitplat":
            self._tag_done(FT_BIT, line or "c64")
        elif self.state == "p-key":
            self.kv_key = line
            m.emit_text(b"value (hex bytes, e.g. deadbeef): ")
            self.state = "p-val"
        elif self.state == "p-val":
            val = bytes.fromhex(line)
            m.kv[self.kv_key] = val
            m.emit_text(f'stored "{self.kv_key}" = {len(val)} byte(s)\n'
                        .encode())
            self.state = "idle"

    def _tag_done(self, ftype: int, plat: str):
        """Platform prompt answered — start XMODEM ('U') or re-tag ('3')."""
        m = self.m
        m.emit_text(f'tag: {"machine bitstream" if ftype == FT_BIT else "game"}'
                    f', platform "{plat}"\n'.encode())
        if self._tag_next == "u":
            self._pending_tag = (ftype, plat)
            self.state = "xmodem"
            self.xm = {"data": b"", "blk": 1, "buf": b"", "started": False}
            m.emit_text(b"C")            # CRC handshake prompt
        else:
            if self.upload_name in m.files:
                m.tags[self.upload_name] = (ftype, plat)
                m.emit_text(f'tagged "{self.upload_name}": game, platform '
                            f'"{plat}"\n'.encode())
            else:
                m.emit_text(b"not found\n")
            self.state = "idle"

    def _xmodem_byte(self, b: int):
        m = self.m
        x = self.xm
        if not x["buf"]:
            if b == EOT:
                m.emit_text(bytes([ACK]))
                m.files[self.upload_name] = x["data"].rstrip(b"\x1a")
                m.tags[self.upload_name] = getattr(self, "_pending_tag",
                                                   (0, ""))
                m.emit_text(b"done in 10 ms, %d packet(s)\n"
                            % max(1, len(x["data"]) // 1024))
                self.state = "idle"
                return
            if b != STX:
                return                       # noise
        x["buf"] += bytes([b])
        if len(x["buf"]) < 3 + 1024 + 2:
            return
        pkt, x["buf"] = x["buf"], b""
        blkno, inv = pkt[1], pkt[2]
        data = pkt[3:3 + 1024]
        crc = (pkt[-2] << 8) | pkt[-1]
        if blkno != (x["blk"] & 0xFF) or (blkno ^ inv) != 0xFF or \
                crc16_ccitt(data) != crc:
            from app.console_script import NAK
            m.emit_text(bytes([NAK]))
            return
        x["data"] += data
        x["blk"] += 1
        m.emit_text(bytes([ACK]))


def make_ops():
    mcu = FakeMcu()
    return mcu, BoardOps(mcu)


# ── pure helpers ────────────────────────────────────────────────────────────

def test_arch_of_name():
    assert arch_of_name("c64-iec.bit") == "c64"
    assert arch_of_name("c64.bit") == "c64"
    assert arch_of_name("plus4-v2.bit") == "plus4"
    assert arch_of_name("p4-game.prg") == "plus4"
    assert arch_of_name("264-game.prg") == "264"
    assert arch_of_name("c16-terranova.prg") == "c16"
    assert arch_of_name("wizard.d64") == "?"


def test_kind_of_name():
    assert kind_of_name("a.bit") == "bitstream"
    assert kind_of_name("a.d64") == "disk"
    assert kind_of_name("a.PRG") == "program"
    assert kind_of_name("a.crt") == "cartridge"


def test_infer_tag():
    assert infer_tag("c64.bit") == (FT_BIT, "c64")
    assert infer_tag("mycore.bit") == (FT_BIT, "mycore")
    assert infer_tag("c64-wizard.d64") == (FT_GAME, "c64")
    assert infer_tag("wizard.d64") == (FT_GAME, "")
    assert infer_tag("notes.txt") == (FT_UNKNOWN, "")


def test_crt_uploads_as_a_c64_cartridge():
    """An EasyFlash .crt goes to the board as-is — the MCU unpacks it into the
    cart port (mcu cart_push.c) — so it must tag as a c64 game even when the
    filename says nothing, and read as a cartridge in the file list."""
    assert kind_of_name("pop.crt") == "cartridge"
    assert infer_tag("pop.crt") == (FT_GAME, "c64")
    assert infer_tag("c64-prince_of_persia-4711.1.crt") == (FT_GAME, "c64")


def test_norm_platform():
    assert norm_platform("C64") == "c64"
    assert norm_platform("c16+plus4") == "264"
    assert norm_platform("mycore") == "mycore"
    for bad in ("", "?", "waytoolongname", "sp ace"):
        try:
            norm_platform(bad)
            assert False, f"expected BoardError for {bad!r}"
        except BoardError:
            pass


def test_parse_fs_list_roundtrip():
    mcu, ops = make_ops()
    entries = ops.fs_list()                      # LIST2 with v2 tags
    assert [e.name for e in entries] == list(mcu.files)
    assert entries[0].size == 100
    assert entries[0].kind == "bitstream"
    assert entries[0].platform == "c64"
    by_name = {e.name: e for e in entries}
    assert by_name["prince.crt"].kind == "game"
    assert by_name["wizard.d64"].platform == ""  # untagged legacy file
    assert by_name["wizard.d64"].arch == "?"


def test_parse_fs_list_v1_fallback():
    mcu, ops = make_ops()
    mcu.not_impl.add(P.get("HL_CMD_FS_LIST2", 0x1A))
    entries = ops.fs_list()                      # old FS_LIST path
    assert [e.name for e in entries] == list(mcu.files)
    assert entries[0].platform == ""             # no tags on pre-v2 firmware
    assert entries[0].kind == "bitstream"        # extension fallback


def test_fs_set_tag_hostlink():
    mcu, ops = make_ops()
    ops.fs_set_tag("wizard.d64", FT_GAME, "C16+Plus4")
    assert mcu.tags["wizard.d64"] == (FT_GAME, "264")
    try:
        ops.fs_set_tag("missing.d64", FT_GAME, "c64")
        assert False, "expected BoardError"
    except BoardError:
        pass


# ── hostlink-backed ops ─────────────────────────────────────────────────────

def test_stat_delete_mount_volume():
    mcu, ops = make_ops()
    st = ops.fs_stat("wizard.d64")
    assert st["size"] == 50
    ops.mount("wizard.d64")
    assert mcu.mounted == "wizard.d64"
    ops.unmount()
    assert mcu.mounted is None
    ops.fs_delete("boulder.prg")
    assert "boulder.prg" not in mcu.files
    try:
        ops.fs_delete("boulder.prg")
        assert False, "expected BoardError"
    except BoardError:
        pass


def test_set_volume_persists_via_console_fallback():
    mcu, ops = make_ops()
    ops.set_volume(5, persist=True)
    assert mcu.volume == 5
    assert mcu.kv["audio.volume"] == b"\x05"     # via console 'P' fallback
    assert ops.get_volume() == 5                 # read back via console 'K'


def test_machine_ctrl_and_typing():
    mcu, ops = make_ops()
    ops.machine_ctrl("reset")
    ops.machine_ctrl("runstop")
    assert mcu.machine_ctl == [1, 2]
    ops.type_text('load"*",8,1\nrun\n')
    assert mcu.typed == b'load"*",8,1\rrun\r'


def test_boot_flow_falls_back_to_setboot_reboot():
    mcu, ops = make_ops()
    ops.fpga_prog("c64-iec.bit")
    assert mcu.boot == "c64-iec.bit"
    assert mcu.rebooted == [0]


# ── console-backed ops ──────────────────────────────────────────────────────

def test_version_and_boot_info():
    mcu, ops = make_ops()
    v = ops.version()
    assert v["fw"] == "2607190001.1"
    assert v["bit"] == "2607181514.0"
    info = ops.boot_info()
    assert info["boot"] == "c64-iec.bit"
    assert info["free_kb"] == 1234
    assert info["gap_kb"] == 900
    assert info["files"] == 4


def test_kv_list_and_drive_mode_toggle():
    mcu, ops = make_ops()
    kv = dict(ops.kv_list())
    assert kv["drive.mode"] == b"\x00"
    out = ops.drive_mode_toggle()
    assert "1541" in out
    assert mcu.kv["drive.mode"] == b"\x01"
    assert ops.get_drive_mode() == 1


def test_upload_via_console_xmodem():
    mcu, ops = make_ops()
    data = bytes(range(256)) * 9 + b"tail"       # 2308 bytes, 3 blocks
    msgs = []
    ops.fs_upload("newgame.prg", data, progress=msgs.append,
                  ftype=FT_GAME, platform="c64")
    assert mcu.files["newgame.prg"] == data
    assert mcu.tags["newgame.prg"] == (FT_GAME, "c64")
    assert any("done in" in m for m in msgs)
    # ping hold must be released afterwards
    assert mcu.ping_hold == 0


def test_upload_infers_tag_from_name():
    mcu, ops = make_ops()
    ops.fs_upload("plus4-terra.d64", b"\x05" * 700, progress=None)
    assert mcu.tags["plus4-terra.d64"] == (FT_GAME, "plus4")


def test_upload_custom_platform():
    mcu, ops = make_ops()
    ops.fs_upload("doom.bin", b"\x06" * 100, progress=None,
                  ftype=FT_GAME, platform="mycore")
    assert mcu.tags["doom.bin"] == (FT_GAME, "mycore")


def test_upload_bitstream_tag_flow():
    mcu, ops = make_ops()
    ops.fs_upload("mycore.bit", b"\x07" * 100, progress=None)   # inferred
    assert mcu.tags["mycore.bit"] == (FT_BIT, "mycore")


def test_upload_without_platform_fails():
    mcu, ops = make_ops()
    try:
        ops.fs_upload("mystery.dat", b"\x00" * 10, progress=None)
        assert False, "expected BoardError (platform required)"
    except BoardError as e:
        assert "platform" in str(e)
    assert "mystery.dat" not in mcu.files


def test_upload_large_binary_with_zeros():
    mcu, ops = make_ops()
    data = b"\x00" * 3000                        # 0x00-heavy (bitstream-like)
    ops.fs_upload("zeros.bin", data + b"\x01", progress=None,
                  ftype=FT_GAME, platform="c64")
    assert mcu.files["zeros.bin"] == data + b"\x01"


def test_format_via_console():
    mcu, ops = make_ops()
    ops.fs_format()
    assert mcu.files == {}


def test_download_not_impl_reports_cleanly():
    mcu, ops = make_ops()
    try:
        ops.fs_download("wizard.d64")
        assert False, "expected BoardError"
    except BoardError as e:
        assert "FS_READ" in str(e)


def test_run_game_types_load_and_run():
    mcu, ops = make_ops()
    ops.run_game("wizard.d64", boot_wait=0.0, run_delay=0.0)
    assert mcu.mounted == "wizard.d64"
    assert mcu.machine_ctl == [1]                # reset
    assert mcu.typed == b'load"*",8,1\rrun\r'


def test_bios_launch_console_fallback():
    mcu, ops = make_ops()
    # console 'J' isn't in the fake console emulator: expect a clean error
    try:
        ops.bios_launch("prince.crt")
        assert False, "expected error"
    except (BoardError, ConsoleError):
        pass
    assert mcu.ping_hold == 0                    # session cleaned up


# ── xmodem sender unit ──────────────────────────────────────────────────────

class _PipeTransport:
    """Minimal transport whose write_bytes feeds a user hook."""

    def __init__(self):
        self.q = queue.Queue()
        self.on_write = None

    def add_text_tap(self, q):
        self._q = q

    def remove_text_tap(self, q):
        pass

    def hold_pings(self):
        pass

    def release_pings(self):
        pass

    def write_bytes(self, data):
        if self.on_write:
            self.on_write(data)

    def emit(self, data: bytes):
        self._q.put(data)


def test_xmodem_crc():
    # CRC16-CCITT init 0 of "123456789" is 0x31C3
    assert crc16_ccitt(b"123456789") == 0x31C3


def test_xmodem_sender_retransmits_on_nak():
    t = _PipeTransport()
    seen = {"n": 0, "pkts": []}

    def on_write(data):
        if data == bytes([EOT]):
            t.emit(bytes([ACK]))
            return
        seen["pkts"].append(data)
        seen["n"] += 1
        from app.console_script import NAK
        t.emit(bytes([NAK if seen["n"] == 1 else ACK]))

    t.on_write = on_write
    with ConsoleSession(t) as s:
        t.emit(b"C")
        xmodem1k_send(s, b"hello world")
    assert seen["n"] == 2                        # first NAKed, then ACKed
    assert seen["pkts"][0] == seen["pkts"][1]    # identical retransmit


def test_xmodem_sender_cancel_raises():
    t = _PipeTransport()
    t.on_write = lambda data: t.emit(bytes([CAN]))
    with ConsoleSession(t) as s:
        t.emit(b"C")
        try:
            xmodem1k_send(s, b"data")
            assert False, "expected ConsoleError"
        except ConsoleError as e:
            assert "abort" in str(e).lower()


def test_upload_roms_container_keeps_its_type():
    """The reported board bug: a c64.roms upload landed tagged as a c64 GAME.

    The console tag prompt answers with a platform name, and firmware that
    forced FS_TYPE_GAME on any explicit answer (which is what FakeMcu models)
    silently downgraded the type — the file was on the board and nothing that
    looks for a ROM set could see it.  The upload now sets the tag explicitly
    afterwards, so the result no longer depends on the firmware's guess."""
    mcu, ops = make_ops()
    ops.fs_upload("c64.roms", b"GCRM" + b"\x00" * 200, progress=None,
                  ftype=FT_ROM, platform="c64")
    assert mcu.files["c64.roms"].startswith(b"GCRM")
    assert mcu.tags["c64.roms"] == (FT_ROM, "c64")


def test_upload_roms_container_infers_its_own_platform():
    """A .roms container takes its platform from its own name, so a mis-typed
    answer cannot feed a c64 the Plus/4 kernal."""
    assert infer_tag("plus4.roms") == (FT_ROM, "plus4")
    mcu, ops = make_ops()
    ops.fs_upload("plus4.roms", b"GCRM" + b"\x00" * 40, progress=None)
    assert mcu.tags["plus4.roms"] == (FT_ROM, "plus4")


def test_fs_stat_reads_the_new_logical_checksum():
    """Firmware from 2026-08-05 answers FS_STAT with 16 bytes: the extra two
    fields are the stored size and a sum over the LOGICAL bytes, which is the
    only one an uploader can compare against."""
    mcu, ops = make_ops()
    data = mcu.files["wizard.d64"]
    st = ops.fs_stat("wizard.d64")
    assert st["size"] == len(data)
    assert st["stored"] == len(data)
    assert st["sum32"] == sum(data) & 0xFFFFFFFF


def test_upload_is_verified_against_the_logical_sum():
    """End to end: the console upload path lands the bytes and the verify
    accepts them.  The old code compared zlib.crc32 of the file against a
    field that is a byte SUM over the STORED form and failed here."""
    from library.board import verify_upload
    mcu, ops = make_ops()
    data = b"\x00" * 3000 + b"\x01"        # compressible, odd length
    ops.fs_upload("c64-game-42.d64", data, progress=None,
                  ftype=FT_GAME, platform="c64")
    msgs = []
    verify_upload(ops.fs_stat("c64-game-42.d64"), data, "c64-game-42.d64",
                  msgs.append)
    assert any("verified on board" in m for m in msgs)


# ── which game each machine would start ─────────────────────────────────────
# The BIOS writes KV "game.<arch>" on every launch.
# Reading it back is the awkward part: the firmware on the bench does NOT
# implement HL_CMD_KV_GET (board-checked 2026-08-06), so the only way in is
# the console listing — which prints eight bytes of a value and a length.

class Ent:
    def __init__(self, arch, name):
        self.arch, self.name = arch, name


BOARD_FILES = [Ent("c64", "prince-of-persia.crt"),
               Ent("c64", "prince-of-persia-two.crt"),
               Ent("c64", "wizard.d64"),
               Ent("c16", "terranova.prg"),
               Ent("?", "stray.d64")]


def test_the_active_game_survives_the_eight_byte_console_print():
    """"prince-o" plus "20 bytes" is enough to name the file, and it must be:
    a firmware without KV_GET is the one on the bench."""
    mcu, ops = make_ops()
    mcu.kv["game.c64"] = b"prince-of-persia.crt"
    mcu.kv["game.c16"] = b"terranova.prg"
    assert ops.active_games(BOARD_FILES) == {"c64": "prince-of-persia.crt",
                                             "c16": "terranova.prg"}


def test_two_files_that_could_both_be_it_are_not_guessed_between():
    """Same first eight characters AND the same length — nothing is marked
    rather than the wrong game."""
    mcu, ops = make_ops()
    mcu.kv["game.c64"] = b"prince-of-persia.crt"
    files = BOARD_FILES + [Ent("c64", "prince-of-persia.zzz")]
    assert "c64" not in ops.active_games(files)


def test_a_remembered_game_that_is_no_longer_on_the_board():
    mcu, ops = make_ops()
    mcu.kv["game.c64"] = b"deleted-long-ago.d64"
    assert ops.active_games(BOARD_FILES) == {}


def test_a_machine_that_has_never_run_anything_is_simply_absent():
    _mcu, ops = make_ops()
    assert ops.active_games(BOARD_FILES) == {}


def test_a_short_name_is_read_straight_off_the_listing():
    """Eight bytes or fewer are printed whole, so there is nothing to
    resolve — and nothing on the board to resolve it against either."""
    mcu, ops = make_ops()
    mcu.kv["game.c16"] = b"a.prg"
    assert ops.active_games([Ent("c16", "a.prg")]) == {"c16": "a.prg"}


def test_untagged_files_ask_no_question():
    """A file with no platform belongs to no machine, so there is no
    "game.?" to look up."""
    mcu, ops = make_ops()
    mcu.kv["game.c64"] = b"prince-of-persia.crt"
    assert ops.active_games([Ent("?", "stray.d64")]) == {}


def test_a_firmware_that_does_answer_kv_get_is_believed():
    mcu, ops = make_ops()
    mcu.not_impl.discard(P.HL_CMD_KV_GET)
    mcu.kv["game.c64"] = b"prince-of-persia.crt"
    assert ops.active_games(BOARD_FILES)["c64"] == "prince-of-persia.crt"


def test_the_kv_listing_still_reads_as_before():
    """kv_list() is what the Advanced box shows; adding the length to
    kv_items() must not have changed it."""
    mcu, ops = make_ops()
    mcu.kv["game.c64"] = b"prince-of-persia.crt"
    kv = dict(ops.kv_list())
    assert kv["drive.mode"] == b"\x00"
    assert kv["game.c64"] == b"prince-o"          # what the MCU printed
    assert dict((k, n) for k, _v, n in ops.kv_items())["game.c64"] == 20
