"""board_backend.py — high-level board operations for the desktop app.

Mirrors the MCU BIOS + console feature set over the hostlink protocol:
machine selection, game mount/run, volume, drive mode, file management, KV.

Strategy: every operation tries the binary hostlink command first; when the
firmware answers HL_ERR_NOT_IMPL (handlers the MCU hasn't wired yet) it
falls back to driving the text console the way a human would (see
console_script.py).  As firmware grows real handlers the app upgrades
itself automatically — no desktop change needed.

All methods BLOCK (serial round-trips); call them off the GUI thread (the
panels use main.Task).  A single lock serializes operations: the MCU console
is a stateful dialog and hostlink allows one command in flight.
"""

from __future__ import annotations

import re
import threading
import time
from dataclasses import dataclass
from typing import Callable, Optional

from . import hostlink
from .console_script import (ConsoleError, ConsoleSession,
                             xmodem1k_send, xmodem_abort)

Progress = Optional[Callable[[str], None]]


class BoardError(Exception):
    """An operation failed, message is user-presentable."""


# ── architecture tagging (mirror of bios_ui.c arch conventions) ─────────────

ARCHES = ("c64", "c16", "plus4", "264")

# file types (FS v2 fsDirEntry_t.ftype / HL_FTYPE_*): every upload must say
# whether it is a machine bitstream or a game, and for which platform.
FT_UNKNOWN, FT_BIT, FT_GAME, FT_ROM = 0, 1, 2, 3
# FT_ROM: "<platform>.roms", the ROM banks a ROM-free bitstream is fed
# after configuration (see bitstreams/README.md, util/mkroms.py).

PLAT_RE = re.compile(r"[a-z0-9]{1,9}")   # FS_PLAT_MAX-1 chars, lowercase


def norm_platform(platform: str) -> str:
    """Normalise a platform tag ("C16+Plus4" -> "264"); raise on invalid."""
    p = (platform or "").strip().lower()
    if p == "c16+plus4":
        p = "264"
    if not PLAT_RE.fullmatch(p):
        raise BoardError(
            f"invalid platform {platform!r} (1-9 lowercase letters/digits)")
    return p


def infer_tag(name: str) -> tuple[int, str]:
    """(ftype, platform) guessed from the filename — the upload default.
    platform '' / FT_UNKNOWN = could not classify."""
    low = name.lower()
    arch = arch_of_name(name)
    plat = "" if arch == "?" else arch
    if low.endswith(".bit"):
        stem = low.rsplit(".", 1)[0]
        if not plat:
            head = re.split(r"[-_.]", stem)[0]
            plat = head if PLAT_RE.fullmatch(head) else ""
        return FT_BIT, plat
    if low.endswith(".roms"):
        # the container's own name says which machine it serves, so a
        # mis-tagged upload cannot feed a c64 its Plus/4 kernal
        stem = low.rsplit(".", 1)[0]
        return FT_ROM, (stem if PLAT_RE.fullmatch(stem) else plat)
    if low.endswith(".crt"):
        # An EasyFlash cartridge.  The board stores the .crt as it stands and
        # unpacks it into the c64 bit's cart port itself, so nothing is
        # converted on the way in; .crt is a C64 format, so an untagged one
        # is a c64 game — the same call the board firmware makes.
        return FT_GAME, plat or "c64"
    if low.endswith((".d64", ".prg")):
        return FT_GAME, plat
    return FT_UNKNOWN, plat

_PREFIXES = [
    ("c64", "c64"), ("c16", "c16"), ("plus4", "plus4"), ("p4", "plus4"),
    ("264", "264"),
]


def arch_of_name(name: str) -> str:
    """Best-effort arch tag from the filename prefix convention
    (c64-..., c16-..., p4-/plus4-..., plain c64.bit etc.)."""
    low = name.lower()
    stem = low.rsplit(".", 1)[0]
    for pfx, tag in _PREFIXES:
        if stem == pfx or low.startswith(pfx + "-") or low.startswith(pfx + "_"):
            return tag
    return "?"


def kind_of_name(name: str) -> str:
    low = name.lower()
    for ext, kind in ((".bit", "bitstream"), (".d64", "disk"),
                      (".prg", "program"), (".crt", "cartridge"),
                      (".fat", "fat"), (".uf2", "firmware")):
        if low.endswith(ext):
            return kind
    return "other"


@dataclass
class FsEntry:
    name: str
    size: int
    ftype: int = FT_UNKNOWN          # FS v2 tag (0 on pre-v2 firmware)
    platform: str = ""               # FS v2 tag ("" = untagged)

    @property
    def arch(self) -> str:
        """Platform for display: the explicit FS tag, else the name guess."""
        return self.platform or arch_of_name(self.name)

    @property
    def kind(self) -> str:
        if self.ftype == FT_BIT:
            return "bitstream"
        if self.ftype == FT_GAME:
            return "game"
        if self.ftype == FT_ROM:
            return "roms"
        return kind_of_name(self.name)


# ── status codes → text ─────────────────────────────────────────────────────

_STATUS_STR = {
    0x00: "OK", 0x01: "bad argument", 0x02: "not found", 0x03: "flash full",
    0x04: "busy", 0x05: "FPGA link down", 0x06: "CRC error", 0x07: "range",
    0x7F: "not implemented in firmware",
}


def _statmsg(status: int) -> str:
    return _STATUS_STR.get(status, f"status 0x{status:02x}")


def _kv_text(val: bytes) -> str:
    """A KV value read as the string the firmware stored (no terminator: the
    store keeps a length, so a trailing NUL is padding if it is there)."""
    return val.decode("latin1", "replace").split("\x00")[0].strip()


def _resolve_truncated(shown: bytes, full_len: int, names) -> Optional[str]:
    """A file name the console listing only printed the first eight bytes of,
    matched back to the file it names.  Same length and same eight opening
    characters; anything less certain than one hit is not marked at all."""
    text = _kv_text(shown)
    if full_len <= len(shown):
        return text or None                  # short enough to be printed whole
    hits = [n for n in names
            if len(n) == full_len and n.startswith(text)]
    return hits[0] if len(hits) == 1 else None


class BoardOps:
    """All board operations, blocking, over a SerialManager-like transport."""

    def __init__(self, mgr):
        self.mgr = mgr
        self.P = mgr.P
        self._lock = threading.RLock()

    # ── plumbing ─────────────────────────────────────────────────────────
    def _cmd(self, cmd: int, payload: bytes = b"", timeout: float = 3.0):
        status, resp = self.mgr.command(cmd, payload, timeout=timeout)
        return status, resp

    def _cmd_ok(self, cmd: int, payload: bytes = b"", timeout: float = 3.0,
                what: str = "command") -> bytes:
        status, resp = self._cmd(cmd, payload, timeout)
        if status == self.P.HL_OK:
            return resp
        raise BoardError(f"{what}: {_statmsg(status)}")

    def _not_impl(self, status: int) -> bool:
        return status == self.P.get("HL_ERR_NOT_IMPL", 0x7F)

    def _fire_and_forget(self, cmd: int, payload: bytes = b""):
        """Send a command whose ack may never come (REBOOT)."""
        self.mgr.write_bytes(hostlink.encode_frame(cmd, 0x7E, payload))

    # ── info / status ────────────────────────────────────────────────────
    def ping(self) -> dict:
        with self._lock:
            return self.mgr.link_ping()

    def version(self) -> dict:
        """Console 'C' — {'fw': ..., 'bit': ..., 'raw': full text}."""
        with self._lock:
            with ConsoleSession(self.mgr) as s:
                s.drain(0.02)
                s.send("C")
                try:
                    s.expect("fpgago-mcu", timeout=3.0)
                    line = "fpgago-mcu" + s.expect("\n", timeout=2.0)
                except ConsoleError as e:
                    raise BoardError(f"no version reply: {e}") from e
                raw = (line + s.drain(0.15).decode("latin1", "replace")).strip()
        fw = bit = "?"
        m = re.search(r"fw=(\S+)", raw)
        if m:
            fw = m.group(1)
        m = re.search(r"bit=(\S+)", raw)
        if m:
            bit = m.group(1)
        return {"fw": fw, "bit": bit, "raw": raw}

    def boot_info(self) -> dict:
        """Console 'N' header — {'boot': name|None, 'files': n, 'free_kb': n,
        'gap_kb': n}."""
        with self._lock:
            with ConsoleSession(self.mgr) as s:
                s.drain(0.02)
                s.send("N")
                try:
                    s.expect("flash_fs:", timeout=3.0)
                    head = "flash_fs:" + s.expect("\n", timeout=2.0)
                    bootline = s.expect_line_with("boot:", timeout=2.0)
                except ConsoleError as e:
                    raise BoardError(f"directory listing failed: {e}") from e
                s.drain(0.2)                     # rest of the listing
        info = {"boot": None, "files": 0, "free_kb": 0, "gap_kb": 0}
        m = re.search(r"(\d+)\s+files?,\s+free\s+(\d+)\s+KB\s+\(largest gap"
                      r"\s+(\d+)\s+KB\)", head)
        if m:
            info["files"] = int(m.group(1))
            info["free_kb"] = int(m.group(2))
            info["gap_kb"] = int(m.group(3))
        m = re.search(r'boot:\s+"([^"]*)"', bootline)
        if m and m.group(1):
            info["boot"] = m.group(1)
        return info

    # ── flash filesystem ─────────────────────────────────────────────────
    def fs_list(self) -> list[FsEntry]:
        with self._lock:
            status, resp = self._cmd(self.P.get("HL_CMD_FS_LIST2", 0x1A))
            if status == self.P.HL_OK:
                return parse_fs_list2(resp)
            if not self._not_impl(status):
                raise BoardError(f"file list: {_statmsg(status)}")
            resp = self._cmd_ok(self.P.HL_CMD_FS_LIST, what="file list")
        return parse_fs_list(resp)

    def fs_set_tag(self, name: str, ftype: int, platform: str) -> None:
        """Set a file's FS v2 type/platform tag (hostlink FS_TAG, console
        '3' fallback).  Silently a no-op on pre-v2 firmware."""
        platform = norm_platform(platform)
        with self._lock:
            pb = platform.encode("latin1")
            status, _ = self._cmd(self.P.get("HL_CMD_FS_TAG", 0x1B),
                                  bytes([ftype, len(pb)]) + pb
                                  + name.encode("latin1"))
            if status == self.P.HL_OK:
                return
            if not self._not_impl(status):
                raise BoardError(f"tag {name}: {_statmsg(status)}")
            with ConsoleSession(self.mgr) as s:      # console '3' fallback
                s.drain(0.02)
                s.send("3")
                try:
                    s.expect("re-tag file", timeout=2.0)
                except ConsoleError:
                    return                           # pre-v2 firmware
                s.expect(": ", timeout=1.0)
                s.send(name + "\r")
                if self._answer_tag_prompts(s, ftype, platform):
                    try:
                        s.expect("tagged", timeout=3.0)
                    except ConsoleError as e:
                        raise BoardError(f"tag {name} failed: {e}") from e
                s.drain(0.1)

    @staticmethod
    def _answer_tag_prompts(s: ConsoleSession, ftype: int,
                            platform: str) -> bool:
        """Answer the firmware's mandatory platform prompt(s) (console 'U'
        and '3').  Returns False when the prompt never comes (pre-v2 fw)."""
        try:
            s.expect("platform:", timeout=2.0)
            s.expect(": ", timeout=2.0)              # end of the prompt block
        except ConsoleError:
            return False
        if ftype == FT_BIT:
            s.send("bit\r")
            s.expect("bitstream platform", timeout=3.0)
            s.expect(": ", timeout=1.0)
            s.send(platform + "\r")
        else:
            s.send(platform + "\r")
        return True

    def fs_stat(self, name: str) -> dict:
        with self._lock:
            resp = self._cmd_ok(self.P.HL_CMD_FS_STAT, name.encode("latin1"),
                                what=f"stat {name}")
        if len(resp) < 8:
            raise BoardError("short FS_STAT response")
        out = {"size": int.from_bytes(resp[0:4], "little"),
               "crc32": int.from_bytes(resp[4:8], "little")}
        # Firmware from 2026-08-05 adds the two fields an uploader actually
        # needs.  "crc32" above is neither a CRC-32 nor over the bytes we
        # sent — it is a byte sum over the STORED (possibly compressed) form
        # — so on older firmware there is nothing here to compare against and
        # `sum32` stays absent.
        if len(resp) >= 16:
            out["stored"] = int.from_bytes(resp[8:12], "little")
            out["sum32"] = int.from_bytes(resp[12:16], "little")
        return out

    def fs_delete(self, name: str) -> None:
        with self._lock:
            self._cmd_ok(self.P.HL_CMD_FS_DELETE, name.encode("latin1"),
                         what=f"delete {name}")

    def fs_format(self) -> None:
        with self._lock:
            magic = self.P.get("HL_FORMAT_MAGIC", 0x46524D54)
            status, _ = self._cmd(self.P.get("HL_CMD_FS_FORMAT", 0x13),
                                  magic.to_bytes(4, "little"), timeout=10.0)
            if status == self.P.HL_OK:
                return
            if not self._not_impl(status):
                raise BoardError(f"format: {_statmsg(status)}")
            with ConsoleSession(self.mgr) as s:      # console fallback
                s.drain(0.02)
                s.send("F")
                s.expect("confirm", timeout=3.0)
                s.send("YES\r")
                s.drain(1.0)

    def fs_upload(self, name: str, data: bytes, progress: Progress = None,
                  timeout_first: float = 20.0, *,
                  ftype: Optional[int] = None,
                  platform: Optional[str] = None) -> None:
        """Upload `data` as flash file `name` — hostlink UP_* when the
        firmware has it, else console 'U' + XMODEM-1K.

        The FS requires a type/platform tag on every upload.  Pass
        ftype=FT_BIT/FT_GAME + platform ("c64", "264", "mycore", ...);
        omitted, both are inferred from the filename and the upload FAILS if
        the name doesn't classify — callers with real knowledge (library
        machine, install machine list, the GUI dialog) must pass it."""
        if ftype is None or platform is None:
            ift, ipl = infer_tag(name)
            ftype = ift if ftype is None else ftype
            platform = ipl if platform is None else platform
        if ftype not in (FT_BIT, FT_GAME, FT_ROM) or not platform:
            raise BoardError(
                f"upload {name}: platform required (could not infer it from "
                "the name; pass ftype/platform)")
        platform = norm_platform(platform)
        with self._lock:
            status, _ = self._cmd(self.P.get("HL_CMD_UP_BEGIN", 0x15),
                                  name.encode("latin1").ljust(
                                      self.P.get("HL_NAME_MAX", 40), b"\x00")
                                  + len(data).to_bytes(4, "little"),
                                  timeout=8.0)
            if status == self.P.HL_OK:
                self._upload_hostlink(data, progress)
                self.fs_set_tag(name, ftype, platform)
                return
            if not self._not_impl(status):
                raise BoardError(f"upload begin: {_statmsg(status)}")

            # console XMODEM-1K fallback
            if progress:
                progress("uploading over console XMODEM-1K…")
            with ConsoleSession(self.mgr) as s:
                s.drain(0.02)
                s.send("U")
                try:
                    s.expect("filename", timeout=3.0)
                    s.expect(": ", timeout=1.0)
                except ConsoleError as e:
                    raise BoardError(f"upload prompt missing: {e}") from e
                s.send(name + "\r")
                try:
                    # FS v2 firmware asks for the mandatory platform tag
                    # before opening the XMODEM window (pre-v2 skips it)
                    self._answer_tag_prompts(s, ftype, platform)
                except ConsoleError as e:
                    raise BoardError(f"platform prompt failed: {e}") from e
                try:
                    xmodem1k_send(s, data, progress=progress,
                                  handshake_timeout=timeout_first)
                    done = s.expect_line_with("done in", timeout=10.0)
                except ConsoleError as e:
                    # Leave the MCU somewhere it can be talked to again.
                    # xReceive() blocks the whole main loop, so an abandoned
                    # transfer means no console AND no hostlink until it
                    # gives up; two CANs are how the receiver is told to
                    # stop (xreceive.c `case CAN: if (waitbyte() == CAN)`).
                    xmodem_abort(s)
                    raise BoardError(f"XMODEM upload failed: {e}") from e
                s.drain(0.1)
                if progress:
                    progress(done.strip())

        # The console prompt is not a reliable tagger: a firmware whose
        # promptTag() forced FS_TYPE_GAME on every explicit answer landed
        # c64.roms on the board as a c64 GAME — uploaded fine, invisible to
        # everything that looks for a ROM set (board, 2026-08-05).  The
        # hostlink path above already set the tag explicitly; do the same here
        # so the result does not depend on which firmware is running.  Outside
        # the ConsoleSession: fs_set_tag opens its own.
        try:
            self.fs_set_tag(name, ftype, platform)
        except BoardError as e:
            if progress:
                progress(f"note: could not confirm the {name} tag ({e})")

    def _upload_hostlink(self, data: bytes, progress: Progress):
        maxchunk = self.P.get("HL_MAX_PAYLOAD", 2048) - 64
        off = 0
        while off < len(data):
            chunk = data[off:off + maxchunk]
            for _ in range(50):                     # BUSY retry (fastload)
                status, _ = self._cmd(
                    self.P.get("HL_CMD_UP_DATA", 0x16),
                    off.to_bytes(4, "little") + chunk, timeout=8.0)
                if status != self.P.get("HL_ERR_BUSY", 0x04):
                    break
                time.sleep(0.1)
            if status != self.P.HL_OK:
                raise BoardError(f"upload data: {_statmsg(status)}")
            off += len(chunk)
            if progress:
                progress(f"upload {off}/{len(data)} bytes")
        crc = _crc32(data)
        self._cmd_ok(self.P.get("HL_CMD_UP_END", 0x17),
                     crc.to_bytes(4, "little"), timeout=20.0,
                     what="upload commit")

    def fs_download(self, name: str, progress: Progress = None) -> bytes:
        """Download a flash file (hostlink FS_READ; no console equivalent)."""
        with self._lock:
            st = self.fs_stat(name)
            size = st["size"]
            out = bytearray()
            chunk = 1024
            while len(out) < size:
                off = len(out)
                n = min(chunk, size - off)
                payload = (name.encode("latin1").ljust(
                    self.P.get("HL_NAME_MAX", 40), b"\x00")
                    + off.to_bytes(4, "little") + n.to_bytes(2, "little"))
                status, resp = self._cmd(self.P.get("HL_CMD_FS_READ", 0x14),
                                         payload, timeout=8.0)
                if self._not_impl(status):
                    raise BoardError(
                        "download needs firmware FS_READ (not wired yet)")
                if status != self.P.HL_OK:
                    raise BoardError(f"read {name}: {_statmsg(status)}")
                if not resp:
                    raise BoardError("empty FS_READ response")
                out += resp
                if progress:
                    progress(f"download {len(out)}/{size} bytes")
            return bytes(out[:size])

    # ── KV store ─────────────────────────────────────────────────────────
    def kv_items(self) -> list[tuple[str, bytes, int]]:
        """Console 'K' — [(key, value-bytes-as-shown, real length)].

        The MCU prints at most eight bytes of a value and then says how long
        it really is (kvstore.c kvDump), so what comes back is a prefix and a
        length, not necessarily the value.  Callers that care — anything
        reading a file name out of the KV store — must say which they got.
        """
        with self._lock:
            with ConsoleSession(self.mgr) as s:
                s.drain(0.02)
                s.send("K")
                time.sleep(0.15)
                text = s.drain(0.25).decode("latin1", "replace")
        out = []
        for m in re.finditer(r'\[\d+\]\s+"([^"]+)"\s+=\s+((?:[0-9a-fA-F]{2}'
                             r'\s+)*)(?:\.\.\.\s*\((\d+)\s+bytes\))?', text):
            key = m.group(1)
            val = bytes(int(h, 16) for h in m.group(2).split())
            out.append((key, val, int(m.group(3) or len(val))))
        return out

    def kv_list(self) -> list[tuple[str, bytes]]:
        """Console 'K' — [(key, value-bytes-as-shown)] (long values are
        truncated to 8 bytes by the MCU's print)."""
        return [(k, v) for k, v, _n in self.kv_items()]

    def kv_set(self, key: str, value: bytes) -> None:
        with self._lock:
            status, _ = self._cmd(self.P.get("HL_CMD_KV_SET", 0x19),
                                  key.encode("latin1") + b"\x00" + value)
            if status == self.P.HL_OK:
                return
            if not self._not_impl(status):
                raise BoardError(f"kv set: {_statmsg(status)}")
            with ConsoleSession(self.mgr) as s:      # console 'P' fallback
                s.drain(0.02)
                s.send("P")
                s.expect("key:", timeout=3.0)
                s.send(key + "\r")
                s.expect("value", timeout=3.0)
                s.expect(": ", timeout=1.0)
                s.send(value.hex() + "\r")
                try:
                    s.expect("stored", timeout=3.0)
                except ConsoleError as e:
                    raise BoardError(f"kv set failed: {e}") from e
                s.drain(0.1)

    def kv_get(self, key: str) -> Optional[bytes]:
        with self._lock:
            status, resp = self._cmd(self.P.get("HL_CMD_KV_GET", 0x18),
                                     key.encode("latin1"))
            if status == self.P.HL_OK:
                return bytes(resp)
            if status == self.P.get("HL_ERR_NOT_FOUND", 0x02):
                return None
            if not self._not_impl(status):
                raise BoardError(f"kv get: {_statmsg(status)}")
        for k, v in self.kv_list():
            if k == key:
                return v
        return None

    def kv_many(self, keys) -> dict:
        """{key: (value, real length)} for the keys the board has.

        Several keys, at most one console round trip.  KV_GET answers per key
        and whole; the firmware that leaves it NOT_IMPL forces the console 'K'
        sweep, and doing that once per key would cost a console session each
        (~0.4 s) for something a Board refresh does on every press.  When the
        sweep is what answered, `value` is only the first eight bytes and the
        length says so — see kv_items()."""
        keys = list(dict.fromkeys(keys))
        not_found = self.P.get("HL_ERR_NOT_FOUND", 0x02)
        out, sweep = {}, False
        for key in keys:
            with self._lock:
                status, resp = self._cmd(self.P.get("HL_CMD_KV_GET", 0x18),
                                         key.encode("latin1"))
            if status == self.P.HL_OK:
                out[key] = (bytes(resp), len(resp))
            elif status == not_found:
                continue
            elif self._not_impl(status):
                sweep = True
                break
            else:
                raise BoardError(f"kv get {key}: {_statmsg(status)}")
        if sweep:
            want = set(keys)
            out = {k: (v, n) for k, v, n in self.kv_items() if k in want}
        return out

    def active_games(self, entries) -> dict:
        """{arch: filename} — the game each machine would start.  The BIOS
        writes KV "game.<arch>" every time one is launched (bios_ui.c
        game_remember_for()), so this is "active" as the board means it: one
        game per machine, not one per board.

        Two firmwares to read it out of.  One answers HL_CMD_KV_GET and the
        name comes back whole.  The other does not implement that command at
        all (board-checked 2026-08-06) and the only way in is the console 'K'
        listing — which prints eight bytes and a length.  So the truncated
        form is resolved against the names the board actually holds rather
        than believed: a file of exactly that length whose first eight
        characters match is the one, and if two files answer to that, nothing
        is marked rather than the wrong thing.

        `entries` are the FsEntry rows of the board's own file list; a
        machine with nothing remembered is simply absent from the result.
        """
        by_arch: dict[str, list[str]] = {}
        for e in entries:
            arch = (getattr(e, "arch", "") or "").lower()
            if arch and arch != "?":
                by_arch.setdefault(arch, []).append(e.name)
        got = self.kv_many(f"game.{a}" for a in by_arch)
        out: dict[str, str] = {}
        for arch, names in by_arch.items():
            rec = got.get(f"game.{arch}")
            name = _resolve_truncated(*rec, names) if rec else None
            if name:
                out[arch] = name
        return out

    # ── disk / games ─────────────────────────────────────────────────────
    def mount(self, name: str) -> None:
        with self._lock:
            self._cmd_ok(self.P.HL_CMD_MOUNT, name.encode("latin1"),
                         timeout=6.0, what=f"mount {name}")

    def unmount(self) -> None:
        with self._lock:
            self._cmd_ok(self.P.HL_CMD_UNMOUNT, what="unmount")

    def disk_dir(self) -> str:
        """Directory of the mounted image (hostlink DISK_DIR, console 'I'
        fallback)."""
        with self._lock:
            status, resp = self._cmd(self.P.get("HL_CMD_DISK_DIR", 0x22),
                                     timeout=6.0)
            if status == self.P.HL_OK:
                return resp.decode("latin1", "replace")
            if not self._not_impl(status):
                raise BoardError(f"disk dir: {_statmsg(status)}")
            with ConsoleSession(self.mgr) as s:
                s.drain(0.02)
                s.send("I")
                time.sleep(0.3)
                return s.drain(0.3).decode("latin1", "replace")

    def set_boot(self, name: str) -> None:
        with self._lock:
            self._cmd_ok(self.P.HL_CMD_SET_BOOT, name.encode("latin1"),
                         what=f"set boot {name}")

    def fpga_prog(self, name: str) -> None:
        """Program the FPGA from flash file `name` NOW (hostlink FPGA_PROG).
        Falls back to set-boot + MCU reboot when the handler isn't wired."""
        with self._lock:
            status, _ = self._cmd(self.P.get("HL_CMD_FPGA_PROG", 0x27),
                                  name.encode("latin1"), timeout=15.0)
            if status == self.P.HL_OK:
                return
            if not self._not_impl(status):
                raise BoardError(f"FPGA program: {_statmsg(status)}")
            self.set_boot(name)
            self.reboot()

    def bios_launch(self, name: str) -> None:
        """Hand a file to the BIOS launcher — how a cartridge gets inserted.

        The BIOS streams the image into the running bitstream (for a .crt,
        the c64 core's cart port) and resets the machine, so there is no disk
        to mount and nothing to type."""
        with self._lock:
            # HL_CMD_R2_LAUNCH is the firmware's name for the launcher command.
            status, _ = self._cmd(self.P.get("HL_CMD_R2_LAUNCH", 0x29),
                                  name.encode("latin1"), timeout=15.0)
            if status == self.P.HL_OK:
                return
            if not self._not_impl(status):
                raise BoardError(f"BIOS launch: {_statmsg(status)}")
            with ConsoleSession(self.mgr) as s:      # console 'J' fallback
                s.drain(0.02)
                s.send("J")
                s.expect("app (", timeout=3.0)
                s.send(name + "\r")
                s.drain(1.0)

    # ── machine control ──────────────────────────────────────────────────
    def machine_ctrl(self, which: str) -> None:
        """which: 'reset' | 'runstop' | 'restore'."""
        arg = {"reset": 1, "runstop": 2, "restore": 3}.get(which)
        if arg is None:
            raise BoardError(f"unknown control {which}")
        with self._lock:
            self._cmd_ok(self.P.HL_CMD_MACHINE, bytes([arg]), what=which)

    def bios_toggle(self) -> None:
        with self._lock:
            self._cmd_ok(self.P.HL_CMD_BIOS, what="BIOS toggle")

    def reboot(self, bootsel: bool = False) -> None:
        """Reboot the MCU (ack never arrives — the MCU restarts first)."""
        with self._lock:
            self._fire_and_forget(self.P.HL_CMD_REBOOT,
                                  bytes([1 if bootsel else 0]))

    # Named-key escapes for type_text: {f1}..{f8} = the kbd map's PC
    # function-key codes $85-$8C (sequential — NOT the PETSCII order),
    # {ret} = Return.  Case-insensitive; unknown {names} pass through as-is.
    # {cbm}/{ctrl}/{stop}/{shiftstop} reach keys a PC keyboard has no glyph
    # for — a game may poll the raw matrix for them (Save New York's demo
    # exits only on C=, matrix row 7 column 5).  Codes: c64_kbd_map.v.
    _KEY_ESCAPES = {**{f"f{i}": chr(0x84 + i) for i in range(1, 9)},
                    "ret": "\r",
                    "cbm": "\x84", "ctrl": "\x8E",
                    "stop": "\x03", "shiftstop": "\x83"}

    @classmethod
    def _expand_keys(cls, text: str) -> str:
        import re
        return re.sub(r"\{(\w+)\}",
                      lambda m: cls._KEY_ESCAPES.get(m.group(1).lower(),
                                                     m.group(0)),
                      text)

    def type_text(self, text: str) -> None:
        """Type on the machine via the FPGA keyboard UART (kbd_typer).
        The typer takes ASCII with '\\r' for Return — same bytes the MCU's
        own autostart sends.  {f1}..{f8} press the function keys."""
        data = self._expand_keys(text).replace("\n", "\r") \
                   .encode("latin1", "replace")
        with self._lock:
            maxchunk = self.P.get("HL_MAX_PAYLOAD", 2048) - 64
            for off in range(0, len(data), maxchunk):
                self._cmd_ok(self.P.HL_CMD_UART_TX,
                             data[off:off + maxchunk], what="type")

    # ── volume / drive mode ──────────────────────────────────────────────
    def set_volume(self, vol: int, persist: bool = True) -> None:
        vol = max(0, min(10, int(vol)))
        with self._lock:
            self._cmd_ok(self.P.HL_CMD_VOLUME, bytes([vol]),
                         what=f"volume {vol}")
            if persist:
                self.kv_set("audio.volume", bytes([vol]))

    def get_volume(self) -> Optional[int]:
        v = self.kv_get("audio.volume")
        return v[0] if v else None

    def drive_mode_toggle(self) -> str:
        """Console 'M' — returns the MCU's report line(s)."""
        with self._lock:
            with ConsoleSession(self.mgr) as s:
                s.drain(0.02)
                s.send("M")
                time.sleep(0.5)
                return s.drain(0.4).decode("latin1", "replace").strip()

    def get_drive_mode(self) -> Optional[int]:
        v = self.kv_get("drive.mode")
        return v[0] if v else None

    # ── compound: run a game ─────────────────────────────────────────────
    def run_game(self, name: str, boot_wait: float = 3.2,
                 run_delay: float = 4.0, progress: Progress = None) -> None:
        """Mount `name`, reset the machine, type LOAD"*",8,1 (+RUN).

        run_delay > 0: RUN is typed that many seconds after LOAD (the
        fastload finishes async and typed-ahead keys can be lost during the
        transfer freeze).  run_delay == 0: RUN rides the KERNAL type-ahead
        right behind LOAD (fine on the real-1541 IEC path)."""
        if progress:
            progress(f"mounting {name}…")
        self.mount(name)
        if progress:
            progress("resetting the machine…")
        self.machine_ctrl("reset")
        time.sleep(boot_wait)
        if run_delay <= 0:
            if progress:
                progress("typing LOAD+RUN…")
            self.type_text('load"*",8,1\rrun\r')
            return
        if progress:
            progress("typing LOAD…")
        self.type_text('load"*",8,1\r')
        time.sleep(run_delay)
        if progress:
            progress("typing RUN…")
        self.type_text("run\r")


# ── pure parsing helpers (unit-tested headlessly) ───────────────────────────

def parse_fs_list(resp: bytes) -> list[FsEntry]:
    """FS_LIST response payload: u8 count, then per entry
    { u8 namelen, name[namelen], u32 size }."""
    out: list[FsEntry] = []
    if not resp:
        return out
    count = resp[0]
    off = 1
    for _ in range(count):
        if off >= len(resp):
            break
        nl = resp[off]
        off += 1
        name = resp[off:off + nl].decode("latin1", "replace")
        off += nl
        if off + 4 > len(resp):
            break
        size = int.from_bytes(resp[off:off + 4], "little")
        off += 4
        out.append(FsEntry(name, size))
    return out


def parse_fs_list2(resp: bytes) -> list[FsEntry]:
    """FS_LIST2 response payload: u8 count, then per entry
    { u8 namelen, name, u32 size, u8 ftype, u8 platlen, platform }."""
    out: list[FsEntry] = []
    if not resp:
        return out
    count = resp[0]
    off = 1
    for _ in range(count):
        if off >= len(resp):
            break
        nl = resp[off]
        off += 1
        name = resp[off:off + nl].decode("latin1", "replace")
        off += nl
        if off + 6 > len(resp):
            break
        size = int.from_bytes(resp[off:off + 4], "little")
        ftype = resp[off + 4]
        pl = resp[off + 5]
        off += 6
        platform = resp[off:off + pl].decode("latin1", "replace")
        off += pl
        out.append(FsEntry(name, size, ftype, platform))
    return out


def _crc32(data: bytes) -> int:
    import zlib
    return zlib.crc32(data) & 0xFFFFFFFF
