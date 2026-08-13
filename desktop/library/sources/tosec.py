"""library/sources/tosec.py — TOSEC .dat identity index.

TOSEC DAT files (ClrMamePro XML) are the canonical dump database: each entry
has a CRC32 / MD5 / SHA-1 and a strictly-formatted name that encodes title,
year, publisher, and crack/hack flags. Matching a local file's hash against
the DATs gives us, for free:
  * the canonical title (for cross-source game matching),
  * the platform (from the DAT's own name — the C64 set vs the combined
    "C16, C116 & Plus/4" set),
  * the cracker/hacker GROUP and variant flags ([cr GROUP], [h], [t], [a], [!]).

This is the backbone of indexing an existing local collection: it resolves
both "which platform" and "which cracked variation" without touching content.

Not a search Source — it's a local identity index. Point it at a directory of
.dat files (download the Commodore packs from tosecdev.org / archive.org).
"""

from __future__ import annotations

import glob
import os
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Optional

from ..db import PLATFORM_C64, PLATFORM_264

# Map a DAT header name to a platform family.
_C64_RE = re.compile(r"\bc(?:ommodore\s*)?64\b", re.I)
_264_RE = re.compile(r"\bc(?:ommodore\s*)?16\b|c116|plus.?4|\b264\b", re.I)

# TOSEC dump flags in the trailing [...]; cr/h carry the group name.
_FLAG_RE = re.compile(r"\[(cr|h|t|a|b|!|f|o|p|m|u)\b([^\]]*)\]")
_PAREN0 = re.compile(r"\s*\(")


@dataclass
class TosecEntry:
    name: str                    # full rom filename
    game: str                    # TOSEC game name (with flags)
    platform: str
    base_title: str              # title before the first "("
    group: Optional[str] = None  # cracker/hacker group from [cr X]/[h X]
    flags: tuple = ()            # ('cr','h','t','a','b','!'...)
    size: Optional[int] = None
    crc32: Optional[str] = None
    sha1: Optional[str] = None
    md5: Optional[str] = None


def platform_of_dat(header_name: str) -> str:
    """Family from a DAT header/name. C64 vs the combined 264 set."""
    if _C64_RE.search(header_name):
        return PLATFORM_C64
    if _264_RE.search(header_name):
        return PLATFORM_264          # C16/C116/Plus4 share one DAT → ambiguous
    return "unknown"


def parse_tosec_name(name: str):
    """(base_title, group, flags) from a TOSEC name.
        "Elite (1986)(Firebird)[cr Nostalgia]" -> ("Elite","Nostalgia",("cr",))
    """
    base = _PAREN0.split(name, 1)[0].strip() or name
    flags, group = [], None
    for m in _FLAG_RE.finditer(name):
        flag, rest = m.group(1), m.group(2).strip()
        flags.append(flag)
        if flag in ("cr", "h") and rest and group is None:
            # rest may be "Nostalgia" or "Nostalgia, Remember"
            group = rest.split(",")[0].strip() or None
    return base, group, tuple(flags)


class TosecIndex:
    """In-memory hash index built from a directory (or list) of .dat files."""

    def __init__(self):
        self.by_crc: dict[str, TosecEntry] = {}
        self.by_sha1: dict[str, TosecEntry] = {}
        self.n_dats = 0
        self.n_entries = 0

    def load_dir(self, dat_dir: str) -> "TosecIndex":
        for path in sorted(glob.glob(os.path.join(dat_dir, "**", "*.dat"),
                                     recursive=True)):
            try:
                self.load_dat(path)
            except ET.ParseError:
                continue          # skip non-XML / clrmamepro-text dats
        return self

    def load_dat(self, path: str):
        tree = ET.parse(path)
        root = tree.getroot()
        header = root.find("header")
        hname = (header.findtext("name", "") if header is not None else "") \
            or os.path.basename(path)
        platform = platform_of_dat(hname)
        self.n_dats += 1
        for game in root.iter("game"):
            gname = game.get("name", "")
            base, group, flags = parse_tosec_name(gname)
            for rom in game.findall("rom"):
                crc = (rom.get("crc") or "").lower() or None
                sha1 = (rom.get("sha1") or "").lower() or None
                size = rom.get("size")
                e = TosecEntry(
                    name=rom.get("name", ""), game=gname, platform=platform,
                    base_title=base, group=group, flags=flags,
                    size=int(size) if size else None,
                    crc32=crc, sha1=sha1, md5=(rom.get("md5") or "").lower() or None)
                if crc:
                    self.by_crc[crc] = e
                if sha1:
                    self.by_sha1[sha1] = e
                self.n_entries += 1

    def lookup(self, sha1: str = None, crc32: str = None) -> Optional[TosecEntry]:
        if sha1 and sha1.lower() in self.by_sha1:
            return self.by_sha1[sha1.lower()]
        if crc32 and crc32.lower() in self.by_crc:
            return self.by_crc[crc32.lower()]
        return None
