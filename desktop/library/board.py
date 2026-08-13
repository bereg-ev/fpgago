"""library/board.py — push a library file straight onto the board.

Closes the loop the user otherwise walks by hand: download → hunt for the
file in the filesystem → serial terminal → 'U' → XMODEM.  Here it is one
call: name the file for the board, upload it (hostlink or XMODEM-1K
fallback via BoardOps), CRC-verify what landed in flash against the local
bytes, and optionally mount + LOAD"*",8,1 + RUN it.

pyserial (and the app package) are imported lazily so every network-free
library command keeps working without the desktop venv.
"""

from __future__ import annotations

import os
import re
import sys
import zlib
from typing import Callable, Optional

Progress = Optional[Callable[[str], None]]

BOARD_NAME_MAX = 35                     # HL_NAME_MAX(36) minus the NUL
_ARCH_PREFIXES = ("c64", "c16", "plus4", "p4", "264")


def _slug(text: str) -> str:
    """Lowercase, filesystem-safe, no leading/trailing punctuation."""
    return re.sub(r"[^a-z0-9._-]+", "_", (text or "").lower()).strip("._-")


def _title_slug(title: str) -> str:
    """A game title as a filename stem, minus the bracketed apparatus —
    "Wizard of Wor (1983)(Commodore)[cr Bandit]" is 41 characters of which 13
    are the game.  The tags in there are the `group` argument's job."""
    return _slug(re.sub(r"[\(\[\{].*?[\)\]\}]", " ", title or ""))


# The group name is the discriminator a human reads, but the canon ID already
# guarantees uniqueness — so when the 35-char budget is tight the group is
# what gets shortened first, never below this, and the title keeps the rest.
_GROUP_MIN = 6


def board_name(filename: str, platform: Optional[str] = None,
               ident=None, *, title: Optional[str] = None,
               group: Optional[str] = None) -> str:
    """Flash-file name for a game file: lowercase, filesystem-safe, arch
    prefix (c64-/c16-/plus4-) so the BIOS files it under the right machine,
    truncated to the MCU name limit with the extension preserved.

    `ident` is what tells two releases of one game apart, appended as
    "-<id>": they very often download under the SAME filename, and the flash
    FS replaces a file of the same name — so sending a second variant
    silently overwrote the first and the board showed one file where the user
    expected two (board, 2026-08-05).

    Pass the CANON id here ("4193.7", from canon.flash_ident) — then the name
    on the board, the ID column in the desktop Library and the key in the
    compat database are all the same string, and a verdict recorded against
    what ran on the board is findable afterwards.  An int is still accepted
    (the old local row id) so an un-published release can still be sent.

    `title`/`group` build the stem from the game's identity instead of from
    whatever the source called the download: "c64-wizard_of_wor-bandit-…"
    rather than "c64-wizard_of_wor_1983_co-…", where the truncation ate the
    one word that said which crack this was.

    The id is appended AFTER truncation, never truncated itself — a cut-off
    id would collide exactly as before."""
    base = os.path.basename(filename).lower()
    base = re.sub(r"[^a-z0-9._-]+", "_", base).strip("._-") or "game"
    fstem, dot, ext = base.rpartition(".")
    if not dot:
        fstem, ext = base, ""

    tail = f".{ext}" if ext else ""
    suffix = ""
    if ident is not None:
        suffix = f"-{_slug(str(ident)) if isinstance(ident, str) else int(ident)}"
    room = BOARD_NAME_MAX - len(tail) - len(suffix)

    if title:
        stem, gslug = _title_slug(title) or "game", _slug(group or "")
        prefix = f"{platform}-" if platform in ("c64", "c16", "plus4") else ""
        over = len(prefix) + len(stem) + (len(gslug) + 1 if gslug else 0) - room
        if over > 0 and gslug:                    # shorten the group first
            cut = min(over, max(0, len(gslug) - _GROUP_MIN))
            gslug, over = gslug[:len(gslug) - cut], over - cut
        if over > 0:
            stem = stem[:max(1, len(stem) - over)].rstrip("._-") or "game"
        stem = prefix + stem + (f"-{gslug}" if gslug else "")
    else:
        stem = fstem
        has_prefix = any(stem == p or stem.startswith(p + "-") or
                         stem.startswith(p + "_") for p in _ARCH_PREFIXES)
        if platform and platform in ("c64", "c16", "plus4") and not has_prefix:
            stem = f"{platform}-{stem}"

    stem = stem[:max(1, room)]
    if suffix:
        stem = stem.rstrip("._-") or "game"   # never "title_-23307"
    return stem + suffix + tail


def wrap_prg_to_d64(prg_path: str, out_dir: str) -> str:
    """Wrap a .prg into a minimal bootable .d64 (retro-arch/common/prg2d64)
    so the board's d64-mount + LOAD"*" flow can run it."""
    common = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "..", "..", "retro-arch", "common")
    sys.path.insert(0, os.path.abspath(common))
    try:
        import prg2d64
    finally:
        sys.path.pop(0)
    out = os.path.join(out_dir,
                       os.path.splitext(os.path.basename(prg_path))[0] + ".d64")
    prg2d64.build(out, [prg_path])
    return out


def push_profile(ops, flash_name: str, blob: Optional[str],
                 progress: Progress = None) -> bool:
    """Write a game's per-game settings into the board's KV store, where the
    BIOS reads them at launch.  No new protocol:
    HL_CMD_KV_SET has always been there.  Returns True if anything was sent."""
    from . import profile as profile_mod
    if not blob:
        return False
    profile_mod.validate(blob, flash_name)          # never ship a bad one
    ops.kv_set(profile_mod.kv_key(flash_name), blob.encode("utf-8"))
    if progress:
        progress(f"settings for '{flash_name}': "
                 f"{profile_mod.describe(blob)}")
    return True


XMODEM_BLOCK = 1024
XMODEM_PAD = b"\x1a"                     # CP/M EOF, what the sender pads with


def xmodem_padded(data: bytes) -> bytes:
    """`data` as the console XMODEM path actually delivers it."""
    n = ((len(data) + XMODEM_BLOCK - 1) // XMODEM_BLOCK) * XMODEM_BLOCK
    return data.ljust(n, XMODEM_PAD)


def sum32(data: bytes) -> int:
    """The firmware's fsSum32: a plain 32-bit byte sum.  This — not CRC-32 —
    is the checksum the flash FS speaks."""
    return sum(data) & 0xFFFFFFFF


def verify_upload(st: dict, data: bytes, fname: str,
                  progress: Progress = None) -> bool:
    """Check what landed in flash against what we sent.  Returns True when
    the board holds the bytes exactly, False when it holds the XMODEM-padded
    form; raises IOError when it holds neither.

    The padding is not corruption and must not be reported as a failure:
    XMODEM has no length field, so the sender rounds the last block up to
    1 KB with 0x1A and the MCU stores whole blocks (`xmodemUSize += len` in
    app.c).  A 174848-byte .d64 therefore lands as 175104 bytes — which is
    to say *every* .d64 upload used to end in "flash verify FAILED".

    The checksum went the same way.  FS_STAT's `crc32` is a byte SUM over the
    STORED bytes, and the flash FS compresses everything that is not a
    bitstream — so for a .d64 it is a number the host cannot compute, and
    comparing it to zlib.crc32 of the file reported a CRC error on every
    upload that in fact arrived perfectly (board, 2026-08-05).  Firmware from
    that date adds `sum32` (over the LOGICAL bytes) and `stored`; against an
    older board there is nothing comparable and the size is all we can check
    — which is said out loud rather than dressed up as "verified".
    """
    have_sum = "sum32" in st
    padded = xmodem_padded(data)

    for buf, kind in ((data, "exact"), (padded, "padded")):
        if st["size"] != len(buf):
            continue
        if have_sum and st["sum32"] != sum32(buf):
            raise IOError(
                f"flash verify FAILED for '{fname}': board has "
                f"{st['size']}B sum={st['sum32']:08x}, expected "
                f"sum={sum32(buf):08x} — the size is right, so the bytes "
                f"were corrupted in transfer")
        if progress:
            extra = len(buf) - len(data)
            how = (f"sum={st['sum32']:08x}" if have_sum
                   else "size only — this firmware cannot report a "
                        "comparable checksum")
            tail = (f" + {extra} bytes of XMODEM block padding" if extra
                    else "")
            progress(f"verified on board: {len(data)} bytes{tail} ({how})")
        return kind == "exact"

    raise IOError(
        f"flash verify FAILED for '{fname}': board has {st['size']}B; "
        f"expected {len(data)}B (or {len(padded)}B padded)")


def upload_file(path: str, *, platform: Optional[str] = None,
                name: Optional[str] = None, run: bool = False,
                port: Optional[str] = None, profile: Optional[str] = None,
                ident=None, title: Optional[str] = None,
                group: Optional[str] = None,
                progress: Progress = print) -> str:
    """Upload `path` to board flash (verified), optionally mount + run it.
    Opens the serial port itself — the CLI entry point.  A caller that
    already holds a link (the desktop app) uses upload_with_ops() instead."""
    desktop_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if desktop_dir not in sys.path:
        sys.path.insert(0, desktop_dir)
    try:
        from app.headless import open_board
    except ImportError as e:
        raise IOError(
            "board upload needs pyserial — run inside the desktop venv "
            "(make desktop-venv; desktop/.venv/bin/python3 -m library.cli …) "
            f"[{e}]") from e
    with open_board(port) as ops:
        return upload_with_ops(ops, path, platform=platform, name=name,
                               run=run, profile=profile, ident=ident,
                               title=title, group=group, progress=progress)


def upload_with_ops(ops, path: str, *, platform: Optional[str] = None,
                    name: Optional[str] = None, run: bool = False,
                    profile: Optional[str] = None, ident=None,
                    title: Optional[str] = None, group: Optional[str] = None,
                    progress: Progress = print) -> str:
    """Upload `path` through an already-open BoardOps, optionally mount + run.
    `profile` is the game's per-game settings blob (see profile.py), pushed
    after the file lands and BEFORE any run, so the launch already sees it.
    Returns the flash file name.  Raises IOError/BoardError on failure."""
    desktop_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if desktop_dir not in sys.path:
        sys.path.insert(0, desktop_dir)

    if run and path.lower().endswith(".prg"):
        import tempfile
        path = wrap_prg_to_d64(path, tempfile.mkdtemp(prefix="fpgago-"))
        if progress:
            progress(f"wrapped .prg into {os.path.basename(path)} "
                     "(the board runs games from mounted .d64 images)")

    with open(path, "rb") as fh:
        data = fh.read()
    fname = name or board_name(path, platform, ident, title=title,
                               group=group)

    # FS v2: every upload carries a mandatory type+platform tag.  The library
    # knows the game's machine; custom tags (e.g. "mycore") pass through.
    from app import board_backend
    if platform:
        try:
            plat = board_backend.norm_platform(platform)
        except board_backend.BoardError as e:
            raise IOError(str(e)) from e
    else:
        _ft, plat = board_backend.infer_tag(fname)
    if not plat:
        raise IOError(
            f"cannot determine the platform for '{fname}' — pass "
            "--platform (c64/c16/plus4/264 or a custom tag)")

    if progress:
        progress(f"uploading {len(data)} bytes as '{fname}' "
                 f"(game for {plat}) …")
    ops.fs_upload(fname, data, progress=progress,
                  ftype=board_backend.FT_GAME, platform=plat)
    verify_upload(ops.fs_stat(fname), data, fname, progress)
    # before run_game(): game_selected() loads the profile at launch, so
    # a profile pushed afterwards would miss its own first start
    push_profile(ops, fname, profile, progress=progress)
    if run:
        if fname.lower().endswith(".crt"):
            # Cartridges go in through the BIOS launcher: it streams the image
            # into the running bit's cart port and resets.  run_game()'s
            # mount + LOAD"*",8,1 is the disk ritual and would do nothing here.
            if progress:
                progress(f"inserting cartridge {fname} …")
            ops.bios_launch(fname)
        else:
            ops.run_game(fname, progress=progress)
    return fname
