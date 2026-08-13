"""install_backend.py — first-run / reinstall engine behind the Install tab.

The board ships without the Commodore cores runnable: the KERNAL/BASIC ROMs
are copyrighted and can't be distributed with the hardware or the repo, and
they are baked into the FPGA bitstream at synthesis.  Getting from "bought
the hardware" to "C64 BASIC prompt" is therefore a local pipeline:

    tools (oss-cad-suite …) → ROMs (user consents) → synthesize bitstreams
                                                   → upload them to the board

Everything here shells out to the SAME commands the console flow uses
(setup.sh / make download-rom / make build ARCH=x TARGET=fpga), so the two
install paths can never drift.  This module is GUI-free and unit-testable;
the Install tab in main.py renders it.
"""

from __future__ import annotations

import glob
import os
import subprocess
import threading
from dataclasses import dataclass
from typing import Callable, Optional

from .board_backend import FT_BIT, FT_ROM, norm_platform

Progress = Callable[[str], None]

MACHINES = ("c64", "c16", "plus4")

# Consent text shown next to the ROM checkbox — the GUI answers the
# Makefile's interactive [y/N] prompt only after the user ticks it.
ROM_CONSENT = ("The Commodore KERNAL/BASIC/character ROMs are copyrighted "
               "by Commodore (downloaded from the VICE project). I want "
               "them downloaded to my machine for my own use.")


def repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))    # <repo>/desktop/app
    return os.path.dirname(os.path.dirname(here))


# Per-machine .hex files the ROM download must produce (baked at synthesis).
_ROM_HEX = {
    "c64": ("basic.hex", "kernal.hex", "chargen.hex"),
    "c16": ("basic.hex", "kernal_PAL.hex"),
    "plus4": ("basic.hex", "kernal.hex"),
}


@dataclass
class Status:
    state: str          # "ok" | "missing" | "partial"
    detail: str


def check_tools() -> Status:
    root = repo_root()
    pnr = os.path.join(root, "oss-cad-suite", "bin", "nextpnr-ecp5")
    if os.access(pnr, os.X_OK):
        return Status("ok", "oss-cad-suite installed")
    return Status("missing", "FPGA toolchain not installed (setup.sh)")


def check_roms(machine: str) -> Status:
    d = os.path.join(repo_root(), "retro-arch", machine, "roms")
    need = _ROM_HEX[machine]
    have = [f for f in need if os.path.isfile(os.path.join(d, f))]
    if len(have) == len(need):
        return Status("ok", "ROMs present")
    if have:
        return Status("partial", f"{len(have)}/{len(need)} ROM files")
    return Status("missing", "no ROMs (copyright — download needs consent)")


def check_bitstream(machine: str) -> Status:
    """Freshest locally-built bitstream for the machine (run.sh copies every
    build to /tmp/<machine>_<hw>*.bit), else the ROM-free one shipped in the
    repo — which is what a user with no toolchain flashes."""
    bit = latest_bitstream(machine)
    if bit:
        return Status("ok", os.path.basename(bit))
    if shipped_bitstream(machine):
        return Status("ok", f"{machine}-romless.bit (shipped, needs "
                            f"{machine}.roms on the board)")
    return Status("missing", "not built in this boot (/tmp is volatile)")


def latest_bitstream(machine: str) -> Optional[str]:
    """The freshest ROM-BAKED build.  ROM-free builds are excluded on purpose:
    they carry no ROMs and are useless without the container, so they must not
    win a by-mtime race against the baked bit the user just synthesised."""
    hits = [h for h in glob.glob(f"/tmp/{machine}_*.bit")
            if "_romless" not in os.path.basename(h)]
    return max(hits, key=os.path.getmtime) if hits else None


def shipped_bitstream(machine: str) -> Optional[str]:
    """The committed ROM-free bitstream for this machine, if present.
    bitstreams/<machine>-romless.bit — see bitstreams/README.md."""
    p = os.path.join(repo_root(), "bitstreams", f"{machine}-romless.bit")
    return p if os.path.isfile(p) else None


# ── the ".roms" container ───────────────────────────────────────────────────
# A ROM-free bitstream ships with empty ROM arrays and declares what it needs
# in its own header (roms=kernal,basic,…).  The MCU feeds it from ONE flash
# file per platform, <machine>.roms, built here from the ROMs the user
# downloaded.  See bitstreams/README.md.
#
# The source is the .hex files, NOT the raw .bin dumps, and that is load-
# bearing: `make download-rom` converts the dumps and then runs
# common/kernal_fastload_patch.py over them, which writes the 4-byte LOAD
# detour the fastload engine is reached through.  The baked bitstreams are
# synthesised from these same patched files, so building the container from
# anything else would give the ROM-free build a KERNAL that cannot fastload.
_ROM_BANK_FILE = {
    "c64": {"kernal": "kernal.hex", "basic": "basic.hex",
            "chargen": "chargen.hex"},
    "c16": {"kernal": "kernal_PAL.hex", "basic": "basic.hex"},
    "plus4": {"kernal": "kernal.hex", "basic": "basic.hex"},
}


def bit_rom_banks(bit_path: str) -> tuple:
    """The bank names a bitstream declares, in ITS order (bank id = position).
    Empty tuple = a ROM-baked bit that needs no container.  Read from the bit
    itself so this can never drift from the gateware."""
    try:
        with open(bit_path, "rb") as fh:
            head = fh.read(4096)
    except OSError:
        return ()
    i = head.find(b"gc: ")
    if i < 0:
        return ()
    line = head[i:i + 256].split(b"\0")[0].split(b"\n")[0].decode(
        "ascii", "replace")
    for tok in line.split():
        if tok.startswith("roms="):
            return tuple(b for b in tok[5:].split(",") if b)
    return ()


def roms_container_path(machine: str) -> str:
    """Where the built container lives.  Next to the ROMs it is made of, and
    gitignored with them — it is the user's own ROM bytes in a new wrapper."""
    return os.path.join(repo_root(), "retro-arch", machine, "roms",
                        f"{machine}.roms")


def check_roms_container(machine: str) -> Status:
    bit = shipped_bitstream(machine) or latest_bitstream(machine)
    need = bit_rom_banks(bit) if bit else ()
    if not need:
        return Status("ok", "not needed (ROMs are baked into the bitstream)")
    p = roms_container_path(machine)
    if not os.path.isfile(p):
        if check_roms(machine).state != "ok":
            return Status("missing", "download the ROMs first")
        return Status("missing", f"not built ({', '.join(need)})")
    return Status("ok", f"{os.path.basename(p)} — {', '.join(need)}")


def roms_argv(machine: str) -> list:
    """The mkroms.py command line that builds <machine>.roms.

    Deliberately does NOT check that the ROM files exist: this is also called
    while PLANNING an install whose earlier step is the download that creates
    them.  mkroms.py names the missing file itself if one is still absent."""
    bit = shipped_bitstream(machine) or latest_bitstream(machine)
    if not bit:
        raise RuntimeError(f"{machine}: no bitstream to read the ROM list from")
    need = bit_rom_banks(bit)
    if not need:
        raise RuntimeError(f"{machine}: {os.path.basename(bit)} bakes its own "
                           f"ROMs — no container needed")

    romdir = os.path.join(repo_root(), "retro-arch", machine, "roms")
    files = _ROM_BANK_FILE.get(machine, {})
    specs = []
    for bank in need:
        fn = files.get(bank)
        if not fn:
            raise RuntimeError(f"{machine}: don't know which file holds the "
                               f"\"{bank}\" bank")
        specs.append(f"{bank}={os.path.join(romdir, fn)}")
    return (["python3", os.path.join(repo_root(), "util", "mkroms.py"),
             roms_container_path(machine)] + specs)


def build_roms_container(machine: str, progress: Progress = None) -> str:
    """Build <machine>.roms from the downloaded (and fastload-patched) ROM hex
    files.  Returns the path.  Raises RuntimeError with a reason."""
    argv = roms_argv(machine)
    p = subprocess.run(argv, cwd=repo_root(), stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, errors="replace")
    for line in p.stdout.splitlines():
        if progress:
            progress(line)
    if p.returncode != 0:
        raise RuntimeError(f"{machine}: mkroms.py failed — {p.stdout.strip()}")
    return roms_container_path(machine)


def needs_install(machines=MACHINES) -> bool:
    """True on a fresh setup — the app then opens on the Install tab.
    Missing bitstreams alone don't count (/tmp is volatile); what gates a
    working console is the toolchain and the ROMs."""
    if check_tools().state != "ok":
        return True
    return any(check_roms(m).state != "ok" for m in machines)


def all_statuses(machines=MACHINES) -> list[tuple[str, Status]]:
    out = [("FPGA toolchain", check_tools())]
    for m in machines:
        out.append((f"{m} ROMs", check_roms(m)))
    for m in machines:
        out.append((f"{m} bitstream", check_bitstream(m)))
    for m in machines:
        out.append((f"{m}.roms (for the board)", check_roms_container(m)))
    return out


# ── command plans ───────────────────────────────────────────────────────────
# Each step is (title, argv, needs_rom_consent).  argv runs in repo_root().

def plan(*, tools: bool = False,
         roms: tuple = (), bits: tuple = (),
         containers: tuple = ()) -> list[tuple[str, list, bool]]:
    steps = []
    if tools:
        steps.append(("Install base tools + FPGA toolchain (setup.sh)",
                      ["bash", "setup.sh"], False))
    for m in roms:
        # 'yes' answers the Makefile's interactive copyright [y/N] prompt —
        # the GUI only schedules this step after the consent checkbox.
        steps.append((f"Download {m} ROMs (VICE project)",
                      ["bash", "-c",
                       f"echo y | make download-rom ARCH={m}"], True))
    for m in containers:
        # After the download (whose .hex output is the input) and before the
        # flash step, which uploads the result.  A machine whose bitstream
        # bakes its own ROMs raises here and is simply skipped.
        try:
            argv = roms_argv(m)
        except RuntimeError:
            continue
        steps.append((f"Build {m}.roms for the board (mkroms.py)", argv,
                      False))
    for m in bits:
        steps.append((f"Synthesize {m} bitstream (make build ARCH={m} "
                      "TARGET=fpga)",
                      ["make", "build", f"ARCH={m}", "TARGET=fpga"], False))
    return steps


def rom_install_plan(machines=MACHINES) -> list[tuple[str, list, bool]]:
    """The whole "make the Commodore machines work" chain, as steps.

    Download only what is missing, then build every container.  No synthesis:
    this is the path for the shipped ROM-free bitstreams, which is the one a
    user without a toolchain can actually finish."""
    need = tuple(m for m in machines if check_roms(m).state != "ok")
    return plan(roms=need, containers=tuple(machines))


class Aborted(Exception):
    pass


class Runner:
    """Run a plan sequentially, streaming every output line to `progress`.
    abort() terminates the current subprocess and stops the plan."""

    def __init__(self):
        self._proc: Optional[subprocess.Popen] = None
        self._abort = threading.Event()

    def abort(self):
        self._abort.set()
        p = self._proc
        if p is not None:
            try:
                p.terminate()
            except Exception:                        # noqa: BLE001
                pass

    def run(self, steps, progress: Progress) -> None:
        root = repo_root()
        for i, (title, argv, _consent) in enumerate(steps, 1):
            if self._abort.is_set():
                raise Aborted("installation aborted")
            progress(f"── [{i}/{len(steps)}] {title}")
            self._proc = subprocess.Popen(
                argv, cwd=root, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, bufsize=1,
                errors="replace")
            try:
                for line in self._proc.stdout:
                    progress(line.rstrip("\n"))
            finally:
                self._proc.stdout.close()
                rc = self._proc.wait()
                self._proc = None
            if self._abort.is_set():
                raise Aborted("installation aborted")
            if rc != 0:
                raise RuntimeError(f"step failed (exit {rc}): {title}")
            progress(f"── [{i}/{len(steps)}] done")
        progress("── all steps finished")


def flash_plan(machines=MACHINES, romfree: bool = False) \
        -> list[tuple[str, str]]:
    """[(flash_name, local_path)] to upload, in order.

    The board file is named <machine>.bit so the BIOS lists it under the right
    machine.  A ROM-FREE bitstream is dead on its own — the fabric holds the
    machine in reset until its banks arrive — so its container is uploaded
    with it, and BEFORE it: an upload that dies half way should leave the
    ROMs waiting for a bit, not a bit waiting for ROMs.

    romfree=True uses the shipped bitstreams/<m>-romless.bit for every machine
    (no toolchain needed); otherwise a locally synthesised ROM-baked build is
    preferred and the shipped one is the fallback."""
    out = []
    for m in machines:
        bit = shipped_bitstream(m) if romfree else (
            latest_bitstream(m) or shipped_bitstream(m))
        if not bit:
            continue
        if bit_rom_banks(bit):
            container = roms_container_path(m)
            if not os.path.isfile(container):
                # Uploading the bit alone would give the user a machine that
                # cannot start and no clue why; skipping it with a status the
                # caller can report is the honest outcome.
                continue
            out.append((os.path.basename(container), container))
        out.append((f"{m}.bit", bit))
    return out


# ── what is actually ON THE BOARD ───────────────────────────────────────────
# Everything above answers "what is on this computer".  That is NOT the
# question a user asking "why won't my c64 start" is asking, and reporting the
# local answer as "ok" is how someone ends up unable to tell that their board
# has no ROMs — and unable to re-run the step, because the tick box had gone
# quiet (board, 2026-08-05).  These read the board's own file list.

@dataclass
class BoardMachine:
    machine: str
    bit: Optional[str]       # machine bitstream on the board, by flash name
    roms: Optional[str]      # <machine>.roms on the board
    state: str               # "ok" | "no-roms" | "no-bit"
    baked: Optional[bool] = None   # bit carries its own ROMs (None = unknown)

    @property
    def detail(self) -> str:
        if self.state == "no-bit":
            return "no machine bitstream on the board"
        if self.state == "baked":
            return f"{self.bit} carries its own ROMs"
        if self.state == "no-roms":
            return f"{self.machine}.roms is not on the board"
        return f"{self.bit} + {self.roms}"


def board_machines(entries, machines=MACHINES, baked=None) -> list:
    """Per machine, what the BOARD holds.  `entries` is ops.fs_list().

    A machine bitstream with no .roms beside it needs one — UNLESS the
    bitstream has its ROMs baked in, which is what `make build ARCH=c64`
    produces (the ROM arrays are filled from the .vh banks at synthesis) and
    what half the boards in this project run.  `baked` is {machine: bool} from
    board_bit_roms(); a machine listed True is "ok" with no container at all,
    and one we could not identify keeps the old presence check — a guess, and
    the UI has to say so.
    """
    baked = baked or {}
    out = []
    for m in machines:
        bit = roms = None
        for e in entries:
            if e.ftype == FT_BIT and norm_platform(e.platform or "") == m:
                bit = e.name
            elif e.ftype == FT_ROM and e.name.lower() == f"{m}.roms":
                roms = e.name
        if not bit:
            state = "no-bit"
        elif baked.get(m):
            state = "baked"
        elif roms:
            state = "ok"
        else:
            state = "no-roms"
        out.append(BoardMachine(m, bit, roms, state, baked.get(m)))
    return out


def board_needs_roms(entries, machines=MACHINES, baked=None) -> list[str]:
    """Machines the board cannot currently run.  Empty = nothing to warn."""
    return [b.machine for b in board_machines(entries, machines, baked)
            if b.state not in ("ok", "baked")]


# ── which bitstream is on the board, and does it carry its own ROMs? ────────
# The board cannot answer that: the firmware leaves FS_READ NOT_IMPL, so the
# bit's own "gc:" header is unreadable over the link, and no command reports
# what the MCU read out of it.  What the board CAN answer is FS_STAT — size
# and a plain byte sum — and that is enough to recognise the local file the
# bit was uploaded from, whose header we can read.  The verdict is then kept
# in the board's own KV so it survives the local build being cleaned out of
# /tmp, stamped with the sum it was derived from so a bitstream replaced
# behind our back is never answered for by the old record.

KV_BIT_PREFIX = "bit."          # + flash name; 4 + 40 <= KV_KEY_MAX (63)


def _kv_bit_pack(romfree: bool, sum32: int) -> bytes:
    """flag + the sum it describes, in five bytes.  Five and not more on
    purpose: a firmware without KV_GET is read through the console listing,
    which prints the first EIGHT bytes of a value and nothing else."""
    return bytes([1 if romfree else 0]) + (sum32 & 0xFFFFFFFF).to_bytes(
        4, "little")


def _kv_bit_unpack(val: bytes, want_sum: Optional[int]):
    """The recorded verdict, or None when there is none for THIS file."""
    if not val or len(val) < 5:
        return None
    got = int.from_bytes(val[1:5], "little")
    if want_sum is not None and got != (want_sum & 0xFFFFFFFF):
        return None                       # a different bitstream lives there
    return not val[0]                     # True = baked (carries its own)


def bit_is_baked(path: str) -> bool:
    """Does this local bitstream carry its own ROMs?  A `roms=` tag in the
    header means ROM-free; no tag means baked (or pre-tag, which was baked)."""
    return not bit_rom_banks(path)


def _local_bits_by_sum(discover_fn=None) -> dict:
    """{byte sum: path} over every local bitstream, in both the forms the
    board could be holding: the file, and the file padded out to a 1 KB
    boundary with 0x1A — a console XMODEM upload stores whole blocks, so that
    is what a .bit sent over the fallback path actually weighs there."""
    if discover_fn is None:
        from . import bitfiles
        discover_fn = bitfiles.discover
    out = {}
    for b in discover_fn():
        try:
            with open(b.path, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        out.setdefault(sum(data) & 0xFFFFFFFF, b.path)
        pad = -len(data) % 1024
        if pad:
            out.setdefault((sum(data) + 0x1A * pad) & 0xFFFFFFFF, b.path)
    return out


def board_bit_roms(ops, entries, machines=MACHINES, discover_fn=None) -> dict:
    """{machine: True/False/None} — does the bitstream ON THE BOARD carry its
    own ROMs?  None where it could not be established.

    Never raises: this decides whether to show a warning, and a board that
    will not answer must leave the file lists alone.
    """
    bits = {}
    for m in machines:
        for e in entries:
            if e.ftype == FT_BIT and norm_platform(e.platform or "") == m:
                bits[m] = e.name
    if not bits:
        return {}
    sums = {}
    for m, name in bits.items():
        try:
            sums[m] = ops.fs_stat(name).get("sum32")
        except Exception:                                # noqa: BLE001
            sums[m] = None
    try:
        recs = ops.kv_many(KV_BIT_PREFIX + n for n in bits.values())
    except Exception:                                    # noqa: BLE001
        recs = {}

    out, fresh, by_sum = {}, {}, None
    for m, name in bits.items():
        rec = recs.get(KV_BIT_PREFIX + name)
        known = _kv_bit_unpack(rec[0], sums[m]) if rec else None
        if known is not None:
            out[m] = known
            continue
        if sums[m] is None:            # firmware too old to report a sum
            out[m] = None
            continue
        if by_sum is None:             # one scan of the local builds, not one
            by_sum = _local_bits_by_sum(discover_fn)     # per machine
        path = by_sum.get(sums[m])
        if path is None:
            out[m] = None
            continue
        out[m] = bit_is_baked(path)
        fresh[name] = _kv_bit_pack(not out[m], sums[m])

    for name, val in fresh.items():    # remember, so /tmp may be cleaned
        try:
            ops.kv_set(KV_BIT_PREFIX + name, val)
        except Exception:                                # noqa: BLE001
            pass                       # a cache miss is not a failure
    return out


def remember_bit_roms(ops, flash_name: str, path: str) -> None:
    """Record what a bitstream declares, at the moment we upload it — the one
    time the local file and the flash name are known to be the same thing.

    The sum is read back off the BOARD rather than computed here: an upload
    that went over the console XMODEM fallback is stored padded to a 1 KB
    boundary, so the sum of the file on disk is not the sum the next refresh
    will see and the record would be quietly ignored."""
    banks = bit_rom_banks(path)
    try:
        got = ops.fs_stat(flash_name).get("sum32")
    except Exception:                                    # noqa: BLE001
        return
    if got is None:                    # firmware that cannot report one
        return
    try:
        ops.kv_set(KV_BIT_PREFIX + flash_name, _kv_bit_pack(bool(banks), got))
    except Exception:                                    # noqa: BLE001
        pass


def flash_skipped(machines=MACHINES, romfree: bool = False) -> list[str]:
    """Machines flash_plan() had to leave out, with the reason — so the GUI
    can say why a box the user ticked produced nothing."""
    out = []
    for m in machines:
        bit = shipped_bitstream(m) if romfree else (
            latest_bitstream(m) or shipped_bitstream(m))
        if not bit:
            out.append(f"{m}: no bitstream (synthesize it, or use the "
                       f"shipped ROM-free one)")
        elif bit_rom_banks(bit) and not os.path.isfile(
                roms_container_path(m)):
            out.append(f"{m}: {os.path.basename(bit)} is ROM-free and "
                       f"{m}.roms is not built — download the ROMs and "
                       f"tick \"Build <machine>.roms\"")
    return out
