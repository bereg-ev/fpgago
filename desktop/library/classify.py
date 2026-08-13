"""
library/classify.py — content-based platform classification + hashing.

The source database (Plus4World, GB64, CSDb) is the *primary* platform signal.
This module is the content-based cross-check / fallback for loose files, and
the source of the content hashes that give each cracked variation its identity.

What it can decide from bytes alone:
  * C64 vs 264-family, from the PRG BASIC load address ($0801 vs $1001) — the
    same sniff the FPGA BIOS uses.
  * C16 vs Plus/4 *hint* from the memory footprint: a single-file program whose
    top byte climbs past the C16's 16 KB ($3FFF) can't run on a stock C16, so
    it's Plus/4.  This is reliable for single-load PRGs, unreliable for .d64
    multi-loaders (the first file is just a small loader) — hence a confidence
    field, and source metadata always wins.

Stdlib only (zlib for CRC32, hashlib, zipfile).
"""

from __future__ import annotations

import hashlib
import io
import os
import zipfile
import zlib
from dataclasses import dataclass
from typing import Optional

from .db import PLATFORM_C64, PLATFORM_C16, PLATFORM_PLUS4, PLATFORM_264

# .d64: sectors per track (1-based), same table as prg2d64.py / bios_ui.c.
_SPT = [0] + [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5
D64_SIZE = 174848

C16_RAM_TOP = 0x4000          # C16 = 16 KB ($0000-$3FFF)
LOAD_C64 = 0x0801             # C64 BASIC start
LOAD_264 = 0x1001             # C16 / Plus/4 BASIC start


def _d64_off(track: int, sector: int) -> int:
    return (sum(_SPT[1:track]) + sector) * 256


@dataclass
class Verdict:
    platform: str                  # c64 / c16 / plus4 / 264 / unknown
    confidence: str                # high / medium / low
    load_addr: Optional[int] = None
    mem_top: Optional[int] = None
    fmt: Optional[str] = None       # prg / d64 / tap / t64 / crt / unknown
    inner_name: Optional[str] = None  # file picked out of a zip
    note: str = ""


# ── filename / path hints ───────────────────────────────────────────────────
# For a local collection, the path is often the STRONGEST platform signal:
# TOSEC sets live in machine-named folders ("Commodore C16 ... TOSEC"), and
# many files carry a machine token. This is exactly how the FPGA BIOS tags
# bitstreams (bios_ui.c arch_from_name), extended with 264-family tokens.

_HINT_TOKENS = {
    PLATFORM_PLUS4: ("plus4", "plus/4", "plus_4", "plus 4", "+4", "plus-4"),
    PLATFORM_C16:   ("c116", "c16", "c-16", "commodore 16"),
    PLATFORM_264:   ("264",),
    PLATFORM_C64:   ("c64", "commodore 64", "commodore_64"),
}


def platform_from_name(path: str):
    """(platform, confidence) from the file name / parent folders, or (None,'').

    The 264 family is resolved carefully: the TOSEC set is a *combined*
    "Commodore C16, C116 & Plus/4" folder, so a path can carry both c16 and
    plus4 tokens — that's ambiguous ("264"), NOT plus4. A 264-family token
    always outranks a c64 token (a "c64 crack" note inside a Plus4 folder is
    about the crack's origin, not the platform).
    """
    low = path.lower()
    hits = {plat for plat, toks in _HINT_TOKENS.items()
            if any(t in low for t in toks)}
    fam = hits & {PLATFORM_C16, PLATFORM_PLUS4, PLATFORM_264}
    if fam == {PLATFORM_C16} or fam == {PLATFORM_PLUS4}:
        return fam.pop(), "medium"
    if fam:                                    # both, or explicit "264"
        return PLATFORM_264, "low"
    if PLATFORM_C64 in hits:
        return PLATFORM_C64, "medium"
    return None, ""


# ── hashing (variation identity) ────────────────────────────────────────────

def hashes(data: bytes):
    """(sha1_hex, crc32_hex8) — sha1 for exact dedup, crc32 for TOSEC/GB64
    cross-reference."""
    return hashlib.sha1(data).hexdigest(), f"{zlib.crc32(data) & 0xffffffff:08x}"


# ── PRG / D64 sniffers ──────────────────────────────────────────────────────

def _split_264(load_addr: int, mem_top: Optional[int], reliable: bool) -> tuple:
    """Map a 264-family load address + footprint to (platform, confidence).

    Per the retro-dev consensus (see README): the 16K/64K split has NO reliable
    pure-content heuristic — both use $1001, and the C16's 16K RAM mirrors 4×
    so a small file can still bank/decompress above $3FFF at runtime. Only one
    direction is solid: a loaded footprint > 16K CANNOT be a stock C16, so it's
    Plus/4. Otherwise stay ambiguous and let the curated tag (Plus4World
    memoryreq, or a filename hint) decide.
    """
    if mem_top is not None and mem_top > C16_RAM_TOP:
        return PLATFORM_PLUS4, ("high" if reliable else "medium")
    # Fits in 16K, or unknown footprint: genuinely ambiguous. A single-file PRG
    # is *probably* C16-capable, but that's a weak hint, not a claim.
    if reliable and mem_top is not None:
        return PLATFORM_C16, "low"
    return PLATFORM_264, "low"


def sniff_prg(data: bytes) -> Verdict:
    if len(data) < 2:
        return Verdict("unknown", "low", fmt="prg", note="too short")
    load = data[0] | (data[1] << 8)
    mem_top = load + (len(data) - 2)          # highest byte this file occupies
    if load == LOAD_C64:
        return Verdict(PLATFORM_C64, "high", load, mem_top, "prg")
    if load == LOAD_264:
        plat, conf = _split_264(load, mem_top, reliable=True)
        return Verdict(plat, conf, load, mem_top, "prg",
                       note="264 load addr; c16/plus4 from mem_top")
    # Non-BASIC load address (machine-code / cartridge-style). Ambiguous.
    return Verdict("unknown", "low", load, mem_top, "prg",
                   note=f"non-BASIC load ${load:04x}")


def sniff_d64(data: bytes) -> Verdict:
    if len(data) < D64_SIZE:
        return Verdict("unknown", "low", fmt="d64", note="short d64")
    dir_sec = _d64_off(18, 1)
    for i in range(8):
        e = dir_sec + 2 + i * 32
        ftype = data[e]
        if (ftype & 0x80) and (ftype & 7) == 2:      # closed PRG entry
            t, s = data[e + 1], data[e + 2]
            if 1 <= t <= 35 and s < _SPT[t]:
                d = _d64_off(t, s)
                load = data[d + 2] | (data[d + 3] << 8)
                if load == LOAD_C64:
                    return Verdict(PLATFORM_C64, "high", load, None, "d64")
                if load == LOAD_264:
                    # d64 first-file mem_top is unreliable (loader stub) — leave
                    # the c16/plus4 split to source metadata.
                    return Verdict(PLATFORM_264, "low", load, None, "d64",
                                   note="264 disk; c16/plus4 needs source meta")
            break
    return Verdict("unknown", "low", fmt="d64", note="no closed PRG in dir")


# ── container / dispatch ────────────────────────────────────────────────────

_KNOWN_EXT = (".prg", ".d64", ".tap", ".t64", ".crt", ".bin")

def _pick_from_zip(zf: zipfile.ZipFile) -> Optional[str]:
    """Pick the most game-like member: prefer d64 > prg > tap/t64, largest."""
    order = {".d64": 0, ".prg": 1, ".t64": 2, ".tap": 3}
    best = None
    for info in zf.infolist():
        if info.is_dir():
            continue
        ext = os.path.splitext(info.filename)[1].lower()
        if ext not in order:
            continue
        key = (order[ext], -info.file_size)
        if best is None or key < best[0]:
            best = (key, info.filename)
    return best[1] if best else None


def classify_bytes(name: str, data: bytes) -> Verdict:
    ext = os.path.splitext(name)[1].lower()
    if ext == ".prg":
        return sniff_prg(data)
    if ext == ".d64":
        return sniff_d64(data)
    if ext == ".crt":
        # C64 cartridge image: "C64 CARTRIDGE" magic + CBM80 at the ROM start.
        if data[:16].startswith(b"C64 CARTRIDGE") or b"CBM80" in data[:0x100]:
            # Hardware type (u16 BE at 0x16) decides runnability on the board:
            # type 32 = EasyFlash — the c64 core emulates it (see
            # retro-arch/c64/README.md) and the .crt is uploaded AS IT
            # STANDS: the board firmware unpacks it into the cart port
            # itself.  Every other cart type is recognized-but-unsupported
            # and the note says so.
            hwtype = int.from_bytes(data[0x16:0x18], "big") if len(data) >= 0x18 else -1
            if hwtype == 32:
                return Verdict(PLATFORM_C64, "high", fmt="crt-easyflash",
                               note="EasyFlash cartridge (supported)")
            return Verdict(PLATFORM_C64, "high", fmt="crt",
                           note=f"C64 .crt magic (cart type {hwtype}, unsupported)")
        return Verdict(PLATFORM_C64, "low", fmt="crt", note="crt (assumed c64)")
    if ext in (".tap", ".t64", ".bin"):
        # Tape images carry no BASIC load address here; platform must come from
        # the source / filename. Still hashed (identity) upstream.
        return Verdict("unknown", "low", fmt=ext[1:],
                       note="no load-addr classification for this format")
    return Verdict("unknown", "low", fmt="unknown", note=f"unknown ext {ext}")


def classify_path(path: str) -> Verdict:
    """Classify a local file, transparently reaching into a .zip."""
    with open(path, "rb") as fh:
        data = fh.read()
    if path.lower().endswith(".zip"):
        try:
            zf = zipfile.ZipFile(io.BytesIO(data))
        except zipfile.BadZipFile:
            return Verdict("unknown", "low", fmt="zip", note="bad zip")
        inner = _pick_from_zip(zf)
        if not inner:
            return Verdict("unknown", "low", fmt="zip", note="no game file in zip")
        v = classify_bytes(inner, zf.read(inner))
        v.inner_name = inner
        return v
    return classify_bytes(os.path.basename(path), data)
