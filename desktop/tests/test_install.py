"""Tests for the Install-tab engine (install_backend.py). GUI-free."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402

from app import install_backend as inst  # noqa: E402


def test_plan_composition_and_consent_flag():
    steps = inst.plan(tools=True, roms=("c64", "plus4"), bits=("c64",))
    assert "setup.sh" in " ".join(steps[0][1])           # tools first
    rom_steps = [s for s in steps if s[2]]
    assert len(rom_steps) == 2                            # consent-gated
    for _t, argv, _c in rom_steps:
        assert "download-rom" in " ".join(argv)
    bit = [a for _t, a, _c in steps if "build" in a][0]
    assert "ARCH=c64" in bit and "TARGET=fpga" in bit


def test_empty_plan():
    assert inst.plan() == []


def test_needs_install_gates_on_tools_and_roms(monkeypatch):
    ok = inst.Status("ok", "")
    missing = inst.Status("missing", "")
    monkeypatch.setattr(inst, "check_tools", lambda: ok)
    monkeypatch.setattr(inst, "check_roms", lambda _m: ok)
    assert inst.needs_install() is False
    monkeypatch.setattr(inst, "check_roms",
                        lambda m: missing if m == "c16" else ok)
    assert inst.needs_install() is True
    monkeypatch.setattr(inst, "check_roms", lambda _m: ok)
    monkeypatch.setattr(inst, "check_tools", lambda: missing)
    assert inst.needs_install() is True


def test_statuses_shape():
    rows = inst.all_statuses()
    names = [n for n, _s in rows]
    assert "FPGA toolchain" in names
    for _n, st in rows:
        assert st.state in ("ok", "missing", "partial")


def test_runner_streams_and_fails_on_error():
    lines = []
    r = inst.Runner()
    r.run([("echo step", ["bash", "-c", "echo hello"], False)], lines.append)
    assert any("hello" in ln for ln in lines)
    with pytest.raises(RuntimeError):
        inst.Runner().run([("boom", ["bash", "-c", "exit 3"], False)],
                          lines.append)


def test_runner_abort():
    r = inst.Runner()
    r.abort()
    with pytest.raises(inst.Aborted):
        r.run([("never", ["bash", "-c", "sleep 60"], False)], lambda _l: None)


# ── ROM-free path: shipped bitstreams + the .roms container ────────────────
# The half that was missing until 2026-08-05: the repo ships ROM-free bits, so
# the app has to be able to build the container that makes them run and upload
# it with them.  See bitstreams/README.md.

def test_shipped_bitstreams_are_present_and_rom_free():
    """Every shipped bit must DECLARE its banks — an undeclared one would be
    a ROM-baked bitstream in git, which is the thing the fence forbids."""
    for m in inst.MACHINES:
        p = inst.shipped_bitstream(m)
        assert p, f"bitstreams/{m}-romless.bit is missing"
        assert inst.bit_rom_banks(p), f"{m}: shipped bit declares no roms="


def test_bank_order_is_the_bits_own_order():
    """Bank id = position in the bit's roms= list, so the desktop must never
    reorder them: the fabric decodes id, not name."""
    assert inst.bit_rom_banks(inst.shipped_bitstream("c64")) == \
        ("kernal", "basic", "chargen")
    assert inst.bit_rom_banks(inst.shipped_bitstream("c16")) == \
        ("kernal", "basic")


def test_bit_rom_banks_on_a_baked_bit(tmp_path):
    baked = tmp_path / "x.bit"
    baked.write_bytes(b"\x00" * 64 + b"gc: hw=v2 arch=c64 ver=1\n"
                      + b"\xff" * 64)
    assert inst.bit_rom_banks(str(baked)) == ()      # nothing to push
    assert inst.bit_rom_banks(str(tmp_path / "nope.bit")) == ()


def test_roms_argv_follows_the_bit_and_uses_patched_hex():
    """The container must be built from the .hex files, which carry the
    fastload LOAD detour common/kernal_fastload_patch.py writes — the same
    bytes the baked bitstreams are synthesised from."""
    argv = inst.roms_argv("c64")
    assert argv[1].endswith("mkroms.py")
    assert argv[2].endswith("c64.roms")
    specs = [a.split("=", 1)[0] for a in argv[3:]]
    assert specs == ["kernal", "basic", "chargen"]   # the bit's order
    for a in argv[3:]:
        assert a.endswith(".hex"), "must not be built from the raw .bin dumps"


def test_flash_plan_uploads_the_container_before_the_bit(monkeypatch):
    monkeypatch.setattr(inst, "roms_container_path",
                        lambda m: __file__)          # pretend it exists
    items = inst.flash_plan(("c64",), romfree=True)
    assert [n for n, _p in items] == [os.path.basename(__file__), "c64.bit"]


def test_flash_plan_refuses_a_rom_free_bit_with_no_container(monkeypatch):
    """Uploading it alone would give the user a machine that cannot start and
    no clue why."""
    monkeypatch.setattr(inst, "roms_container_path",
                        lambda m: "/nonexistent/x.roms")
    assert inst.flash_plan(("c64",), romfree=True) == []
    why = inst.flash_skipped(("c64",), romfree=True)
    assert why and "c64.roms" in why[0]


def test_latest_bitstream_ignores_rom_free_builds(monkeypatch, tmp_path):
    """A ROM-free build must not win the by-mtime race against the baked bit
    the user just synthesised — it carries no ROMs."""
    baked = tmp_path / "c64_v2_iec.bit"
    baked.write_bytes(b"x")
    free = tmp_path / "c64_v2_iec_romless.bit"
    free.write_bytes(b"x")
    os.utime(free, (2 << 30, 2 << 30))               # far newer
    monkeypatch.setattr(inst.glob, "glob",
                        lambda _p: [str(baked), str(free)])
    assert inst.latest_bitstream("c64") == str(baked)


# ── what the BOARD holds, not what this computer holds ─────────────────────
# The Install tab used to report only local files, so a user whose board had
# no ROMs saw "ok" everywhere and had nothing to act on (board, 2026-08-05).

class _E:
    """Minimal stand-in for board_backend.FsEntry."""
    def __init__(self, name, ftype, platform):
        self.name, self.ftype, self.platform = name, ftype, platform


def _bit(m):
    return _E(f"{m}.bit", inst.FT_BIT, m)


def _roms(m):
    return _E(f"{m}.roms", inst.FT_ROM, m)


def test_board_machines_empty_board():
    rows = {b.machine: b for b in inst.board_machines([])}
    assert all(b.state == "no-bit" for b in rows.values())
    assert inst.board_needs_roms([]) == list(inst.MACHINES)


def test_board_machines_bit_without_roms_is_not_ok():
    """The exact reported state: bitstreams uploaded, no .roms, machine dead."""
    entries = [_bit(m) for m in inst.MACHINES]
    rows = {b.machine: b for b in inst.board_machines(entries)}
    assert rows["c64"].state == "no-roms"
    assert "c64.roms" in rows["c64"].detail
    assert inst.board_needs_roms(entries) == list(inst.MACHINES)


def test_board_machines_complete_board_is_silent():
    entries = [f(m) for m in inst.MACHINES for f in (_bit, _roms)]
    assert inst.board_needs_roms(entries) == []
    assert all(b.state == "ok" for b in inst.board_machines(entries))


def test_board_machines_is_per_machine():
    entries = [_bit("c64"), _roms("c64"), _bit("c16")]
    assert inst.board_needs_roms(entries) == ["c16", "plus4"]


def test_rom_install_plan_downloads_only_what_is_missing(monkeypatch):
    ok, missing = inst.Status("ok", ""), inst.Status("missing", "")
    monkeypatch.setattr(inst, "check_roms",
                        lambda m: missing if m == "c16" else ok)
    titles = [t for t, _a, _c in inst.rom_install_plan()]
    assert sum("Download" in t for t in titles) == 1
    assert "c16" in [t for t in titles if "Download" in t][0]
    # ...but every container is rebuilt, so a stale one cannot survive
    assert sum(".roms" in t for t in titles) == len(inst.MACHINES)


def test_rom_install_plan_needs_no_toolchain():
    """This is the path for a user who cannot synthesize; a build step here
    would make the button fail on exactly the machines that need it."""
    for _t, argv, _c in inst.rom_install_plan():
        assert "TARGET=fpga" not in " ".join(argv)


# ── is the bitstream ON THE BOARD ROM-free, or does it carry its own? ───────
# The presence check above ("no .roms beside the .bit") is right for every
# bitstream this project SHIPS, and wrong for the ones a user builds — `make
# build ARCH=c64` bakes the ROMs in at synthesis.  Telling somebody running
# such a build that their machine is unavailable is a lie the banner used to
# tell on every refresh.

class _StatOps:
    """Board stub: FS_STAT sums and a KV store."""

    def __init__(self, sums=None, kv=None, stat_raises=False):
        self.sums = sums or {}
        self.kv = dict(kv or {})
        self.stat_raises = stat_raises
        self.writes = []

    def fs_stat(self, name):
        if self.stat_raises:
            raise IOError("no FS_STAT on this firmware")
        return {"size": 1, "sum32": self.sums[name]} if name in self.sums \
            else {"size": 1}

    def kv_many(self, keys):
        return {k: (self.kv[k], len(self.kv[k])) for k in keys if k in self.kv}

    def kv_set(self, key, value):
        self.kv[key] = value
        self.writes.append((key, value))


class _Bit:
    def __init__(self, path, arch):
        self.path, self.arch = path, arch


def _local(tmp_path, name, arch, body):
    p = tmp_path / name
    p.write_bytes(body)
    return _Bit(str(p), arch)


BAKED = b"\x00" * 64 + b"gc: hw=v2 arch=c64 ver=1\n" + b"\xff" * 900
ROMFREE = b"\x00" * 64 + b"gc: hw=v2 arch=c64 roms=kernal,basic\n" + b"\xff" * 900


def test_a_baked_bitstream_on_the_board_is_recognised(tmp_path):
    b = _local(tmp_path, "c64.bit", "c64", BAKED)
    ops = _StatOps(sums={"c64.bit": sum(BAKED) & 0xFFFFFFFF})
    got = inst.board_bit_roms(ops, [_bit("c64")], machines=("c64",),
                              discover_fn=lambda: [b])
    assert got["c64"] is True                    # carries its own ROMs
    entries = [_bit("c64")]
    assert inst.board_needs_roms(entries, machines=("c64",), baked=got) == []
    rows = {x.machine: x for x in
            inst.board_machines(entries, ("c64",), got)}
    assert rows["c64"].state == "baked"
    assert "its own ROMs" in rows["c64"].detail


def test_a_rom_free_bitstream_with_no_container_still_warns(tmp_path):
    b = _local(tmp_path, "c64.bit", "c64", ROMFREE)
    ops = _StatOps(sums={"c64.bit": sum(ROMFREE) & 0xFFFFFFFF})
    got = inst.board_bit_roms(ops, [_bit("c64")], machines=("c64",),
                              discover_fn=lambda: [b])
    assert got["c64"] is False
    assert inst.board_needs_roms([_bit("c64")], ("c64",), got) == ["c64"]


def test_an_xmodem_padded_upload_is_still_recognised(tmp_path):
    """A .bit sent over the console fallback is stored padded to a 1 KB
    block with 0x1A, so the board's sum is not the file's sum."""
    b = _local(tmp_path, "c64.bit", "c64", BAKED)
    pad = -len(BAKED) % 1024
    ops = _StatOps(sums={"c64.bit": (sum(BAKED) + 0x1A * pad) & 0xFFFFFFFF})
    got = inst.board_bit_roms(ops, [_bit("c64")], machines=("c64",),
                              discover_fn=lambda: [b])
    assert got["c64"] is True


def test_the_answer_is_cached_on_the_board(tmp_path):
    """So it survives /tmp being cleaned out from under the build."""
    b = _local(tmp_path, "c64.bit", "c64", BAKED)
    s = sum(BAKED) & 0xFFFFFFFF
    ops = _StatOps(sums={"c64.bit": s})
    inst.board_bit_roms(ops, [_bit("c64")], ("c64",), lambda: [b])
    assert ops.writes and ops.writes[0][0] == "bit.c64.bit"
    assert len(ops.writes[0][1]) <= 8       # the console listing shows 8 bytes

    # …and with the local build gone, the record still answers.
    got = inst.board_bit_roms(_StatOps(sums={"c64.bit": s}, kv=ops.kv),
                              [_bit("c64")], ("c64",), lambda: [])
    assert got["c64"] is True


def test_a_replaced_bitstream_is_not_answered_for_by_the_old_record(tmp_path):
    """The record is stamped with the checksum it describes: flash a
    different c64.bit and the question is asked again, not inherited."""
    s = sum(BAKED) & 0xFFFFFFFF
    kv = {"bit.c64.bit": inst._kv_bit_pack(False, s)}
    ops = _StatOps(sums={"c64.bit": s ^ 0x1234}, kv=kv)
    got = inst.board_bit_roms(ops, [_bit("c64")], ("c64",), lambda: [])
    assert got["c64"] is None                    # unknown, not "baked"


def test_a_bitstream_nobody_can_identify_stays_unknown(tmp_path):
    ops = _StatOps(sums={"c64.bit": 0xDEADBEEF})
    got = inst.board_bit_roms(ops, [_bit("c64")], ("c64",), lambda: [])
    assert got["c64"] is None
    # unknown is still warned about — it may genuinely need ROMs
    assert inst.board_needs_roms([_bit("c64")], ("c64",), got) == ["c64"]


def test_a_firmware_that_cannot_checksum_leaves_it_unknown():
    ops = _StatOps(stat_raises=True)
    got = inst.board_bit_roms(ops, [_bit("c64")], ("c64",), lambda: [])
    assert got["c64"] is None
    assert not ops.writes


def test_remembering_uses_the_boards_own_sum(tmp_path):
    """Not the file's: an XMODEM upload is padded, and a record stamped with
    the wrong sum would be ignored by every later refresh."""
    b = _local(tmp_path, "c64.bit", "c64", BAKED)
    ops = _StatOps(sums={"c64.bit": 0xABCD})
    inst.remember_bit_roms(ops, "c64.bit", b.path)
    assert ops.kv["bit.c64.bit"] == inst._kv_bit_pack(False, 0xABCD)
    got = inst.board_bit_roms(ops, [_bit("c64")], ("c64",), lambda: [])
    assert got["c64"] is True
