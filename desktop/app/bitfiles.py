"""bitfiles.py — find the machine bitstreams this checkout has built.

Picking a machine to put on the board should not mean remembering that
`make build ARCH=c64 TARGET=fpga` leaves its output in `/tmp` under a name
encoding RAM, HW and CPU.  The files are all in a handful of known places,
they carry their machine in the name, and half of them are duplicates of
each other (every build also writes a timestamped copy) — so: find them,
dedup them, and show a list.

No Qt here; the GUI is a table over `discover()`.
"""

from __future__ import annotations

import glob
import hashlib
import os
import time
from dataclasses import dataclass, field
from typing import Optional

from .board_backend import arch_of_name, infer_tag

# Where a build leaves a bitstream.  `/tmp` first: that is where the make
# targets write, and it is what a fresh build produces (see the project's
# naming convention, gc_<RAM>_<HW>_<CPU>_<GAME>.bit and <arch>_<hw>_<variant>).
SEARCH = (
    ("{tmp}/*.bit", "build output"),
    ("{repo}/bitstreams/*.bit", "shipped with the repo"),
    ("{repo}/retro-arch/*/out.bit", "last build"),
    ("{repo}/retro-arch/*/*.bit", "build output"),
    ("{repo}/arch/*/*.bit", "build output"),
)

# Toolchain files that happen to be .bit and are not machines.
EXCLUDE_PARTS = ("oss-cad-suite", "site-packages")

MAX_SIZE = 8 * 1024 * 1024          # a bitstream for this FPGA is ~0.1-1 MB


@dataclass
class BitFile:
    path: str
    arch: str
    size: int
    mtime: float
    origin: str
    dupes: list = field(default_factory=list)

    @property
    def name(self) -> str:
        return os.path.basename(self.path)

    @property
    def suggested_name(self) -> str:
        """What to call it on the board.  The BIOS boots `<machine>.bit`, and
        half of these are called `out.bit`, so the machine name is both the
        useful default and the one that replaces the copy already there."""
        if self.arch and self.arch != "?":
            return f"{self.arch}.bit"
        return self.name

    @property
    def age(self) -> str:
        """'12 minutes ago' — which build is the one you just made."""
        secs = max(0, time.time() - self.mtime)
        for unit, n in (("day", 86400), ("hour", 3600), ("minute", 60)):
            if secs >= n:
                v = int(secs // n)
                return f"{v} {unit}{'s' if v != 1 else ''} ago"
        return "just now"


# A name that says nothing: every `make` in a retro-arch directory writes one.
GENERIC = ("out.bit", "top.bit", "build.bit")


def _name_score(path: str) -> tuple:
    """Lower is better: a descriptive name beats a generic one, then short
    beats long."""
    base = os.path.basename(path)
    return (base.lower() in GENERIC, len(base))


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))


def _arch_of(path: str) -> str:
    """The machine a bitstream is for.  `retro-arch/<arch>/out.bit` says it
    in the directory rather than the filename, which is the one case the
    name-based guess cannot get."""
    arch = arch_of_name(os.path.basename(path))
    if arch != "?":
        return arch
    parts = os.path.abspath(path).split(os.sep)
    for anchor in ("retro-arch", "arch"):
        if anchor in parts:
            i = parts.index(anchor)
            if i + 1 < len(parts) - 1:
                return parts[i + 1]
    ftype, plat = infer_tag(os.path.basename(path))
    return plat or "?"


def _digest(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 16), b""):
            h.update(block)
    return h.hexdigest()


def discover(repo: Optional[str] = None,
             tmp: str = "/tmp") -> list[BitFile]:
    """Every bitstream worth offering, newest first, duplicates folded in.

    Every build writes both `<name>.bit` and a timestamped twin, so a raw
    listing is half noise; identical content is collapsed onto whichever
    copy has the shortest name (the stable one you would name in a script).
    """
    repo = repo or repo_root()
    found: dict = {}
    for pattern, origin in SEARCH:
        for path in glob.glob(pattern.format(repo=repo, tmp=tmp)):
            if any(part in path for part in EXCLUDE_PARTS):
                continue
            try:
                st = os.stat(path)
            except OSError:
                continue
            if not st.st_size or st.st_size > MAX_SIZE:
                continue
            found.setdefault(os.path.realpath(path),
                             (path, origin, st.st_size, st.st_mtime))

    by_content: dict = {}
    for path, origin, size, mtime in found.values():
        try:
            key = (size, _digest(path))
        except OSError:
            continue
        cur = by_content.get(key)
        if cur is None:
            by_content[key] = BitFile(path, _arch_of(path), size, mtime,
                                      origin)
            continue
        # keep the most informative name; the rest become "also known as"
        if _name_score(path) < _name_score(cur.path):
            cur.dupes.append(cur.path)
            cur.path, cur.origin = path, origin
            cur.mtime = max(cur.mtime, mtime)
        else:
            cur.dupes.append(path)
            cur.mtime = max(cur.mtime, mtime)

    out = list(by_content.values())
    out.sort(key=lambda b: (-b.mtime, b.name))
    return out
