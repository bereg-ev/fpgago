#!/usr/bin/env python3
"""
opcode_test.py — conformance test for retro-arch's 6502 core (common/cpu/6502/cpu_6502.v).

Generates a 6502 program that, for every (opcode, addressing mode, operand
vector) case, sets A/X/Y/P/memory, executes exactly ONE instruction, and parks
A, X, Y, P and the touched memory byte in a result table.  The program runs in
tb_cpu6502.v; the dumped table is diffed against the reference semantics
encoded below.

Coverage is the undocumented ("illegal") NMOS opcode set that C64 crunchers
use — SLO RLA SRE RRA SAX LAX DCP ISC ANC ALR ARR XAA SBX and SBC #$EB — plus
a documented-opcode regression set, because the illegals share the core's
decode tables with them and a bad casex pattern would break both.

    python3 opcode_test.py            # build, run, check
    python3 opcode_test.py -v         # ... and list every case

Exit status is 0 only if every case matches.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CPUDIR = HERE

# ── flags ──────────────────────────────────────────────────────────────────
C, Z_, I_, D_, B_, U_, V_, N_ = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80


def nz(p, v):
    """N and Z from an 8-bit result."""
    p &= ~(N_ | Z_) & 0xFF
    if v & 0x80:
        p |= N_
    if (v & 0xFF) == 0:
        p |= Z_
    return p


def setb(p, bit, on):
    return (p | bit) if on else (p & ~bit & 0xFF)


# ── reference semantics ────────────────────────────────────────────────────
# each: fn(a, x, y, p, m) -> (a, x, y, p, m)   ("m" is the memory operand /
# immediate; for immediate modes the returned m is ignored)

def _adc(a, m, p):
    ci = p & C
    s = a + m + ci
    r = s & 0xFF
    p = setb(p, C, s > 0xFF)
    p = setb(p, V_, bool((~(a ^ m) & (a ^ r)) & 0x80))
    return r, nz(p, r)


def _sbc(a, m, p):
    ci = p & C
    s = a - m - (1 - ci)
    r = s & 0xFF
    p = setb(p, C, s >= 0)
    p = setb(p, V_, bool(((a ^ m) & (a ^ r)) & 0x80))
    return r, nz(p, r)


def _cmp(reg, m, p):
    r = (reg - m) & 0xFF
    p = setb(p, C, reg >= m)
    return nz(p, r)


REF = {
    # ── undocumented: read-modify-write + accumulator ──────────────────────
    "SLO": lambda a, x, y, p, m: (
        (lambda m2: (a | m2, x, y, nz(setb(p, C, bool(m & 0x80)), a | m2), m2))
        ((m << 1) & 0xFF)),
    "RLA": lambda a, x, y, p, m: (
        (lambda m2: (a & m2, x, y, nz(setb(p, C, bool(m & 0x80)), a & m2), m2))
        (((m << 1) | (p & C)) & 0xFF)),
    "SRE": lambda a, x, y, p, m: (
        (lambda m2: (a ^ m2, x, y, nz(setb(p, C, bool(m & 1)), a ^ m2), m2))
        (m >> 1)),
    "RRA": lambda a, x, y, p, m: _rra(a, x, y, p, m),
    "SAX": lambda a, x, y, p, m: (a, x, y, p, a & x),
    "LAX": lambda a, x, y, p, m: (m, m, y, nz(p, m), m),
    "DCP": lambda a, x, y, p, m: (
        (lambda m2: (a, x, y, _cmp(a, m2, p), m2))((m - 1) & 0xFF)),
    "ISC": lambda a, x, y, p, m: _isc(a, x, y, p, m),
    # ── undocumented: immediate ────────────────────────────────────────────
    "ANC": lambda a, x, y, p, m: (
        (lambda r: (r, x, y, setb(nz(p, r), C, bool(r & 0x80)), m))(a & m)),
    "ALR": lambda a, x, y, p, m: (
        (lambda t: (t >> 1, x, y, nz(setb(p, C, bool(t & 1)), t >> 1), m))
        (a & m)),
    "ARR": lambda a, x, y, p, m: _arr(a, x, y, p, m),
    "XAA": lambda a, x, y, p, m: (
        (lambda r: (r, x, y, nz(p, r), m))(a & x & m)),
    "LXA": lambda a, x, y, p, m: (m, m, y, nz(p, m), m),   # LAX #imm
    "SBX": lambda a, x, y, p, m: (
        (lambda t: (a, t & 0xFF, y, nz(setb(p, C, (a & x) >= m), t & 0xFF), m))
        ((a & x) - m)),
    "SBCI": lambda a, x, y, p, m: (
        (lambda r: (r[0], x, y, r[1], m))(_sbc(a, m, p))),
    # ── documented regression set ──────────────────────────────────────────
    "ADC": lambda a, x, y, p, m: (
        (lambda r: (r[0], x, y, r[1], m))(_adc(a, m, p))),
    "SBC": lambda a, x, y, p, m: (
        (lambda r: (r[0], x, y, r[1], m))(_sbc(a, m, p))),
    "AND": lambda a, x, y, p, m: (a & m, x, y, nz(p, a & m), m),
    "ORA": lambda a, x, y, p, m: (a | m, x, y, nz(p, a | m), m),
    "EOR": lambda a, x, y, p, m: (a ^ m, x, y, nz(p, a ^ m), m),
    "CMP": lambda a, x, y, p, m: (a, x, y, _cmp(a, m, p), m),
    "CPX": lambda a, x, y, p, m: (a, x, y, _cmp(x, m, p), m),
    "CPY": lambda a, x, y, p, m: (a, x, y, _cmp(y, m, p), m),
    "LDA": lambda a, x, y, p, m: (m, x, y, nz(p, m), m),
    "LDX": lambda a, x, y, p, m: (a, m, y, nz(p, m), m),
    "LDY": lambda a, x, y, p, m: (a, x, m, nz(p, m), m),
    "STA": lambda a, x, y, p, m: (a, x, y, p, a),
    "ASL": lambda a, x, y, p, m: (
        (lambda r: (a, x, y, nz(setb(p, C, bool(m & 0x80)), r), r))
        ((m << 1) & 0xFF)),
    "LSR": lambda a, x, y, p, m: (
        (lambda r: (a, x, y, nz(setb(p, C, bool(m & 1)), r), r))(m >> 1)),
    "ROL": lambda a, x, y, p, m: (
        (lambda r: (a, x, y, nz(setb(p, C, bool(m & 0x80)), r), r))
        (((m << 1) | (p & C)) & 0xFF)),
    "ROR": lambda a, x, y, p, m: (
        (lambda r: (a, x, y, nz(setb(p, C, bool(m & 1)), r), r))
        ((m >> 1) | ((p & C) << 7))),
    "INC": lambda a, x, y, p, m: (
        (lambda r: (a, x, y, nz(p, r), r))((m + 1) & 0xFF)),
    "DEC": lambda a, x, y, p, m: (
        (lambda r: (a, x, y, nz(p, r), r))((m - 1) & 0xFF)),
    "BIT": lambda a, x, y, p, m: (
        a, x, y,
        setb(setb(setb(p, Z_, (a & m) == 0), N_, bool(m & 0x80)),
             V_, bool(m & 0x40)),
        m),
}


def _rra(a, x, y, p, m):
    m2 = (m >> 1) | ((p & C) << 7)
    p = setb(p, C, bool(m & 1))
    r, p = _adc(a, m2, p)
    return r, x, y, p, m2


def _isc(a, x, y, p, m):
    m2 = (m + 1) & 0xFF
    r, p = _sbc(a, m2, p)
    return r, x, y, p, m2


def _arr(a, x, y, p, m):
    t = a & m
    r = (t >> 1) | ((p & C) << 7)
    p = nz(p, r)
    p = setb(p, C, bool(r & 0x40))
    p = setb(p, V_, bool(((r >> 6) ^ (r >> 5)) & 1))
    return r, x, y, p, m


# ── the opcode table ───────────────────────────────────────────────────────
# (mnemonic, opcode, mode).  Modes: zp zpx zpy abs abx aby izx izy imm
ILLEGAL = [
    ("SLO", 0x07, "zp"),  ("SLO", 0x17, "zpx"), ("SLO", 0x0F, "abs"),
    ("SLO", 0x1F, "abx"), ("SLO", 0x1B, "aby"), ("SLO", 0x03, "izx"),
    ("SLO", 0x13, "izy"),
    ("RLA", 0x27, "zp"),  ("RLA", 0x37, "zpx"), ("RLA", 0x2F, "abs"),
    ("RLA", 0x3F, "abx"), ("RLA", 0x3B, "aby"), ("RLA", 0x23, "izx"),
    ("RLA", 0x33, "izy"),
    ("SRE", 0x47, "zp"),  ("SRE", 0x57, "zpx"), ("SRE", 0x4F, "abs"),
    ("SRE", 0x5F, "abx"), ("SRE", 0x5B, "aby"), ("SRE", 0x43, "izx"),
    ("SRE", 0x53, "izy"),
    ("RRA", 0x67, "zp"),  ("RRA", 0x77, "zpx"), ("RRA", 0x6F, "abs"),
    ("RRA", 0x7F, "abx"), ("RRA", 0x7B, "aby"), ("RRA", 0x63, "izx"),
    ("RRA", 0x73, "izy"),
    ("SAX", 0x87, "zp"),  ("SAX", 0x97, "zpy"), ("SAX", 0x8F, "abs"),
    ("SAX", 0x83, "izx"),
    ("LAX", 0xA7, "zp"),  ("LAX", 0xB7, "zpy"), ("LAX", 0xAF, "abs"),
    ("LAX", 0xBF, "aby"), ("LAX", 0xA3, "izx"), ("LAX", 0xB3, "izy"),
    ("DCP", 0xC7, "zp"),  ("DCP", 0xD7, "zpx"), ("DCP", 0xCF, "abs"),
    ("DCP", 0xDF, "abx"), ("DCP", 0xDB, "aby"), ("DCP", 0xC3, "izx"),
    ("DCP", 0xD3, "izy"),
    ("ISC", 0xE7, "zp"),  ("ISC", 0xF7, "zpx"), ("ISC", 0xEF, "abs"),
    ("ISC", 0xFF, "abx"), ("ISC", 0xFB, "aby"), ("ISC", 0xE3, "izx"),
    ("ISC", 0xF3, "izy"),
    ("ANC", 0x0B, "imm"), ("ANC", 0x2B, "imm"),
    ("ALR", 0x4B, "imm"), ("ARR", 0x6B, "imm"),
    ("XAA", 0x8B, "imm"), ("LXA", 0xAB, "imm"),
    ("SBX", 0xCB, "imm"), ("SBCI", 0xEB, "imm"),
]

DOCUMENTED = [
    ("ADC", 0x65, "zp"), ("ADC", 0x69, "imm"), ("ADC", 0x71, "izy"),
    ("SBC", 0xE5, "zp"), ("SBC", 0xE9, "imm"), ("SBC", 0xE1, "izx"),
    ("AND", 0x25, "zp"), ("ORA", 0x05, "zp"),  ("EOR", 0x45, "zp"),
    ("AND", 0x3D, "abx"), ("ORA", 0x19, "aby"),
    ("CMP", 0xC5, "zp"), ("CPX", 0xE4, "zp"),  ("CPY", 0xC4, "zp"),
    ("LDA", 0xA5, "zp"), ("LDX", 0xA6, "zp"),  ("LDY", 0xA4, "zp"),
    ("LDA", 0xB5, "zpx"), ("LDX", 0xB6, "zpy"),
    ("STA", 0x85, "zp"), ("STA", 0x9D, "abx"),
    ("ASL", 0x06, "zp"), ("LSR", 0x46, "zp"),  ("ROL", 0x26, "zp"),
    ("ROR", 0x66, "zp"), ("INC", 0xE6, "zp"),  ("DEC", 0xC6, "zp"),
    ("ASL", 0x1E, "abx"), ("INC", 0xFE, "abx"),
    ("BIT", 0x24, "zp"),
]

# (a, x, y, p, m) — p always has D=0 (decimal illegals are out of scope) and
# the unused/break bits set, as the core's P wire always reads them back as 1
VECTORS = [
    (0x00, 0x00, 0x00, 0x30, 0x00),
    (0xFF, 0xFF, 0xFF, 0x31, 0xFF),
    (0x5A, 0x33, 0x77, 0x30, 0xA5),
    (0x80, 0x01, 0x02, 0x31, 0x80),
    (0x01, 0x80, 0x40, 0x30, 0x01),
    (0x7F, 0x7F, 0x10, 0x31, 0x01),
    (0xC3, 0x0F, 0xF0, 0xF0, 0x3C),
    (0x42, 0xA5, 0x5A, 0x30, 0x99),
]

TARGET_ZP = 0x10          # zero-page operand
TARGET_ABS = 0x0440       # absolute operand
PTR_ZP = 0x20             # indirect pointer lives here
RESULT = 0x2000           # 8 bytes per case: A X Y P M - - -
RESULT_END = 0x4000       # must match tb_cpu6502.v's $writememh window
CODE = 0x4000
CYC_START = 0xBFFE        # bracket marker writes — tb latches the cycle
CYC_END = 0xBFFD          # counter on each, dumps the write-to-write deltas

# ── NMOS cycle counts ──────────────────────────────────────────────────────
# The bracket-STA overhead is constant, so a leading NOP case (2 cycles)
# calibrates it away and every case's cycle count is checked exactly —
# including the conditional +1 for a page-crossing indexed read.  This gate
# exists because the RMW dummy-write fix (2026-07-20) silently made every
# RMW instruction one cycle long, which no functional check can see (found
# 2026-08-08 via Street Fighter #3634's cycle-counted fastloader).
RMW_MNEMS = {"SLO", "RLA", "SRE", "RRA", "DCP", "ISC",
             "ASL", "LSR", "ROL", "ROR", "INC", "DEC"}
STORE_MNEMS = {"STA", "SAX"}
CYC_RMW = {"zp": 5, "zpx": 6, "zpy": 6, "abs": 6, "abx": 7, "aby": 7,
           "izx": 8, "izy": 8}
CYC_STORE = {"zp": 3, "zpx": 4, "zpy": 4, "abs": 4, "abx": 5, "aby": 5,
             "izx": 6, "izy": 6}
CYC_READ = {"zp": 3, "zpx": 4, "zpy": 4, "abs": 4, "abx": 4, "aby": 4,
            "izx": 6, "izy": 5}


def expect_cycles(mnem, mode, vx, vy):
    if mnem in ("ALR", "ARR"):
        return 3       # KNOWN DEVIATION: real silicon does 2, the core needs
                       # the ILL2 second ALU pass (see cpu_6502.v header)
    if mode == "imm":
        return 2
    if mnem in RMW_MNEMS:
        return CYC_RMW[mode]
    if mnem in STORE_MNEMS:
        return CYC_STORE[mode]
    n = CYC_READ[mode]
    if mode in ("abx", "aby", "izy"):           # +1 when the index crosses
        idx = vx if mode == "abx" else vy
        base = (TARGET_ABS - idx) & 0xFFFF
        if ((base & 0xFF) + idx) > 0xFF:
            n += 1
    return n


class Asm:
    def __init__(self, org):
        self.org = org
        self.b = []

    def emit(self, *bs):
        self.b.extend(bs)

    def lda_i(self, v): self.emit(0xA9, v & 0xFF)
    def ldx_i(self, v): self.emit(0xA2, v & 0xFF)
    def ldy_i(self, v): self.emit(0xA0, v & 0xFF)
    def sta_zp(self, a): self.emit(0x85, a & 0xFF)
    def sta_ab(self, a): self.emit(0x8D, a & 0xFF, (a >> 8) & 0xFF)
    def stx_ab(self, a): self.emit(0x8E, a & 0xFF, (a >> 8) & 0xFF)
    def sty_ab(self, a): self.emit(0x8C, a & 0xFF, (a >> 8) & 0xFF)
    def lda_ab(self, a): self.emit(0xAD, a & 0xFF, (a >> 8) & 0xFF)
    def lda_zp(self, a): self.emit(0xA5, a & 0xFF)
    def pha(self): self.emit(0x48)
    def pla(self): self.emit(0x68)
    def php(self): self.emit(0x08)
    def plp(self): self.emit(0x28)


def build():
    """Return (image bytes, list of case descriptors)."""
    a = Asm(CODE)
    cases = []

    a.ldx_i(0xFF)
    a.emit(0x9A)                       # TXS — stack at $01FF

    # cycle-probe calibration: a bracketed NOP (2 cycles) — cyc[0]
    a.lda_i(0x00)
    a.sta_ab(CYC_START)
    a.emit(0xEA)                       # NOP
    a.sta_ab(CYC_END)

    for mnem, opc, mode in ILLEGAL + DOCUMENTED:
        for (va, vx, vy, vp, vm) in VECTORS:
            idx = len(cases)
            res = RESULT + idx * 8
            if res + 8 > RESULT_END:
                raise SystemExit("result table overflow — trim the vectors")

            # where the operand lives, and how the instruction reaches it
            if mode in ("zp", "zpx", "zpy"):
                target = TARGET_ZP
            elif mode == "imm":
                target = None
            else:
                target = TARGET_ABS

            # seed the operand
            if target is not None:
                a.lda_i(vm)
                if target < 0x100:
                    a.sta_zp(target)
                else:
                    a.sta_ab(target)

            # seed the indirect pointer for izx/izy
            if mode == "izx":
                ptr = PTR_ZP
                a.lda_i(TARGET_ABS & 0xFF)
                a.sta_zp(ptr)
                a.lda_i(TARGET_ABS >> 8)
                a.sta_zp(ptr + 1)
            elif mode == "izy":
                ptr = PTR_ZP
                base = (TARGET_ABS - vy) & 0xFFFF
                a.lda_i(base & 0xFF)
                a.sta_zp(ptr)
                a.lda_i(base >> 8)
                a.sta_zp(ptr + 1)

            # registers, then flags (PLP last — LDA/LDX/LDY set N and Z)
            a.ldx_i(vx)
            a.ldy_i(vy)
            a.lda_i(vp)
            a.pha()
            a.lda_i(va)
            a.plp()

            # ── the instruction under test, cycle-bracketed (STA touches
            # neither flags nor registers, so the PHP capture still sees the
            # instruction's own results) ──
            a.sta_ab(CYC_START)
            if mode == "imm":
                a.emit(opc, vm)
            elif mode == "zp":
                a.emit(opc, target)
            elif mode == "zpx":
                a.emit(opc, (target - vx) & 0xFF)
            elif mode == "zpy":
                a.emit(opc, (target - vy) & 0xFF)
            elif mode == "abs":
                a.emit(opc, target & 0xFF, target >> 8)
            elif mode == "abx":
                b = (target - vx) & 0xFFFF
                a.emit(opc, b & 0xFF, b >> 8)
            elif mode == "aby":
                b = (target - vy) & 0xFFFF
                a.emit(opc, b & 0xFF, b >> 8)
            elif mode == "izx":
                a.emit(opc, (PTR_ZP - vx) & 0xFF)
            elif mode == "izy":
                a.emit(opc, PTR_ZP)

            # ── capture (none of these touch the flags before PHP reads them)
            a.sta_ab(CYC_END)
            a.php()
            a.sta_ab(res + 0)
            a.stx_ab(res + 1)
            a.sty_ab(res + 2)
            a.pla()
            a.sta_ab(res + 3)
            if target is not None:
                if target < 0x100:
                    a.lda_zp(target)
                else:
                    a.lda_ab(target)
            else:
                a.lda_i(0)
            a.sta_ab(res + 4)

            cases.append((mnem, opc, mode, va, vx, vy, vp, vm, res))

    a.lda_i(0x5A)
    a.emit(0x8D, 0xFF, 0xFF)           # STA $FFFF — the tb's stop sentinel
    a.emit(0x4C, 0x00, 0x00)           # JMP $0000 (never reached)

    img = bytearray(0x10000)
    img[CODE:CODE + len(a.b)] = bytes(a.b)
    if CODE + len(a.b) >= 0xFF00:
        raise SystemExit("program too large")
    img[0xFFFC] = CODE & 0xFF
    img[0xFFFD] = CODE >> 8
    return img, cases


def expect(mnem, mode, va, vx, vy, vp, vm):
    """Reference A, X, Y, P, memory-after for one case."""
    ea, ex, ey, ep, em = REF[mnem](va, vx, vy, vp, vm)
    ep = (ep | B_ | U_) & 0xFF          # the core's P wire reads 4,5 as 1
    if mode == "imm":
        em = None
    return ea & 0xFF, ex & 0xFF, ey & 0xFF, ep, em


def main():
    verbose = "-v" in sys.argv
    img, cases = build()

    build_dir = os.path.join(HERE, "build")
    os.makedirs(build_dir, exist_ok=True)
    image = os.path.join(build_dir, "image.hex")
    dump = os.path.join(build_dir, "dump.hex")
    cycdump = os.path.join(build_dir, "cycles.hex")
    vvp = os.path.join(build_dir, "tb_cpu6502.vvp")

    with open(image, "w") as f:
        for i in range(0, len(img), 16):
            f.write(" ".join("%02x" % b for b in img[i:i + 16]) + "\n")

    src = [os.path.join(HERE, "tb_cpu6502.v"),
           os.path.join(CPUDIR, "cpu_6502.v"),
           os.path.join(CPUDIR, "ALU.v")]
    subprocess.run(["iverilog", "-g2005", "-o", vvp, "-s", "tb"] + src,
                   check=True)
    r = subprocess.run(["vvp", vvp, "+image=" + image, "+dump=" + dump,
                        "+cycdump=" + cycdump, "+maxcycles=4000000"],
                       capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0 or "TIMEOUT" in r.stdout:
        sys.stderr.write(r.stderr)
        print("FAIL: simulation did not complete")
        return 1

    got = bytearray(RESULT_END - RESULT)
    with open(dump) as f:
        i = 0
        for line in f:
            line = line.split("//")[0]          # iverilog stamps addresses
            for tok in line.split():
                if tok.startswith("@"):
                    i = int(tok[1:], 16)
                    continue
                got[i] = 0 if "x" in tok.lower() else int(tok, 16)
                i += 1

    # cycle deltas, in program order: cyc[0] = the calibration NOP
    cyc = []
    with open(cycdump) as f:
        for line in f:
            line = line.split("//")[0]
            for tok in line.split():
                if tok.startswith("@"):
                    continue
                cyc.append(0 if "x" in tok.lower() else int(tok, 16))
    if len(cyc) < len(cases) + 1:
        print("FAIL: cycle probe returned %d deltas for %d cases"
              % (len(cyc), len(cases) + 1))
        return 1
    overhead = cyc[0] - 2               # bracketed NOP = 2 cycles

    bad = 0
    cyc_bad = 0
    per_op = {}
    for i, (mnem, opc, mode, va, vx, vy, vp, vm, res) in enumerate(cases):
        o = res - RESULT
        ga, gx, gy, gp, gm = got[o], got[o + 1], got[o + 2], got[o + 3], got[o + 4]
        ea, ex, ey, ep, em = expect(mnem, mode, va, vx, vy, vp, vm)
        gc = cyc[i + 1] - overhead
        ec = expect_cycles(mnem, mode, vx, vy)
        ok = (ga, gx, gy, gp) == (ea, ex, ey, ep) and (em is None or gm == em)
        cok = gc == ec
        key = "%s $%02X %s" % (mnem, opc, mode)
        per_op.setdefault(key, [0, 0, set()])
        per_op[key][0 if ok else 1] += 1
        if not ok:
            bad += 1
        if not cok:
            cyc_bad += 1
            per_op[key][2].add("%d cyc (want %d)" % (gc, ec))
        if verbose or not ok:
            print("%-16s a=%02X x=%02X y=%02X p=%02X m=%02X  ->  "
                  "got A=%02X X=%02X Y=%02X P=%02X M=%02X %dcyc  "
                  "want A=%02X X=%02X Y=%02X P=%02X M=%s %dcyc  %s"
                  % (key, va, vx, vy, vp, vm, ga, gx, gy, gp, gm, gc,
                     ea, ex, ey, ep, "--" if em is None else "%02X" % em, ec,
                     "ok" if ok and cok else "MISMATCH"))

    print()
    for key in sorted(per_op):
        good, fail, cfail = per_op[key]
        if fail:
            print("  FAIL %-16s %d/%d" % (key, good, good + fail))
        if cfail:
            print("  CYC  %-16s %s" % (key, "; ".join(sorted(cfail))))
    print("6502 opcode conformance: %d cases, %d failed, %d cycle mismatches"
          % (len(cases), bad, cyc_bad))
    return 1 if bad or cyc_bad else 0


if __name__ == "__main__":
    sys.exit(main())
