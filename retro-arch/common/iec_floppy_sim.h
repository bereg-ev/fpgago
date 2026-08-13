/*
 * iec_floppy_sim.h — shared 1541 floppy + IEC-bus glue for the Commodore
 * retro SDL sims (c16, plus4, c64, ...).
 *
 * Every Commodore 8-bit uses the SAME serial IEC bus and the SAME 1541 drive,
 * so a single drive emulator (floppy1541.c, shared with the RP2350 firmware in
 * the board firmware) works for all of them.  This header is the sim-side glue:
 * loading .d64 / 1541-ROM images, driving the IEC bus each cycle, a headless
 * screenshot mode, and a hands-free auto-typer.
 *
 * Include this ONCE from a sim_top.cpp (after "Vsoc.h").  The Verilated top
 * ("Vsoc") must expose these signals (release semantics: 1 = HIGH/released,
 * 0 = LOW/pulled):
 *     output iec_atn_out, iec_clk_out, iec_data_out
 *     input  iec_clk_in,  iec_data_in
 * and the sim's UART/keyboard driver must feed keystrokes from g_uart_queue.
 *
 * Bus wire = AND of every device's "release" state (open collector).
 * floppy.out_clk / out_data are INVERTED drivers: 1 = pulling LOW, 0 = released.
 */
#ifndef IEC_FLOPPY_SIM_H
#define IEC_FLOPPY_SIM_H

#include <vector>
#include <queue>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>

extern "C" {
#include "floppy1541.h"
}

/* ── Drive + host state ─────────────────────────────────────────────────── */
static floppy1541_t         g_floppy;
static bool                 g_floppy_enabled  = false;
/* DOS-over-link owns the drive: the wire state machine must NOT also run.
 *
 * Both transports drive the SAME floppy1541_t.  protocol_update() keeps a
 * show-ahead byte (prepare_tx_byte) as a real drive does, so if it advances
 * while the link is serving a channel it pops one byte the link then never
 * delivers — the file arrives short by its FIRST byte, which for a PRG means
 * the load address is read from the wrong bytes and the whole transfer lands
 * one byte low (Axe of Rage: AORM loaded to $0B08 instead of $0801).
 *
 * The board never does this: iec1541DosLinkConfig() calls iec1541Suspend(),
 * so core 1's wire engine is parked for the whole of DOS mode.  This flag is
 * that suspend, and without it the sim is not modelling the board. */
static bool                 g_floppy_wire_park = false;
static std::vector<uint8_t> g_d64_data;
static std::vector<uint8_t> g_floppy_rom;

/* Host keystroke queue: the auto-typer fills it, the sim's UART driver drains
 * it into the emulated keyboard. */
static std::queue<uint8_t>  g_uart_queue;

/* Headless / screenshot options (set by iec_floppy_parse_args). */
static bool                 g_headless        = false;
static const char*          g_screenshot_path = nullptr;
static uint32_t             g_exit_us         = 0;
static uint32_t             g_shot_every_us   = 0;   /* --screenshot-every */
static uint32_t             g_shot_next_us    = 0;

/* Fast-loader (opt-in via --fastload).  Config filled in by each sim; see the
 * fast-loader section below for the mechanism. */
struct fl_cfg {
    uint16_t load_vec, stub, fnadr, fnlen, sa, reloc_ptr, status, ram_mask;
    bool     valid;
    /* KERNAL's default LOAD-vector target (e.g. $F4A5 on the C64).  When set,
     * a vector that reads as this value is recognised as a KERNAL re-init (we
     * re-patch); on disarm the vector is restored to it.  0 = unknown. */
    uint16_t kernal_load_default;
};
static fl_cfg g_flcfg    = { 0, 0, 0, 0, 0, 0, 0, 0, false, 0 };
static bool   g_fastload = false;
static bool   g_fl_disarmed = false;
static int    g_fl_load_count = 0;   /* successful stub-mediated loads */

/* ── Disk / ROM image loading ───────────────────────────────────────────── */
static inline void floppy_load_d64(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "floppy: cannot open D64 '%s'\n", path); return; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    g_d64_data.resize((size_t)sz);
    if (fread(g_d64_data.data(), 1, (size_t)sz, f) != (size_t)sz) {
        fprintf(stderr, "floppy: short read on D64 '%s'\n", path);
        fclose(f); g_d64_data.clear(); return;
    }
    fclose(f);
    floppy1541_insert_d64(&g_floppy, g_d64_data.data(),
                          (uint32_t)g_d64_data.size(), 1);
    fprintf(stderr, "floppy: loaded %ld bytes from %s\n", sz, path);
}

static inline bool floppy_load_rom(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "floppy: cannot open 1541 ROM '%s'\n", path); return false; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz != F1541_ROM_SIZE) {
        fprintf(stderr, "floppy: 1541 ROM must be %d bytes (got %ld)\n",
                F1541_ROM_SIZE, sz);
        fclose(f); return false;
    }
    g_floppy_rom.resize((size_t)sz);
    if (fread(g_floppy_rom.data(), 1, (size_t)sz, f) != (size_t)sz) {
        fprintf(stderr, "floppy: short read on 1541 ROM\n");
        fclose(f); g_floppy_rom.clear(); return false;
    }
    fclose(f);
    floppy1541_load_rom(&g_floppy, g_floppy_rom.data());
    fprintf(stderr, "floppy: loaded 16KB 1541 ROM (full 6502 emulation mode)\n");
    return true;
}

static inline void floppy_make_empty_d64()
{
    g_d64_data.assign(683 * 256, 0);            /* 35-track standard D64 */
    int bam_off = (17 * 21 + 0) * 256;          /* track 18 = index 17   */
    uint8_t* bam = &g_d64_data[bam_off];
    bam[0] = 18; bam[1] = 1; bam[2] = 'A';
    memset(&bam[0x90], 0xA0, 0x1B);
    memcpy(&bam[0x90], "EMPTY DISK", 10);
    bam[0xA2] = '0'; bam[0xA3] = '0';
    bam[0xA5] = 0xA0; bam[0xA6] = 0x32; bam[0xA7] = 0x41;
    int dir_off = (17 * 21 + 1) * 256;
    g_d64_data[dir_off + 0] = 0;
    g_d64_data[dir_off + 1] = 0xFF;
    floppy1541_insert_d64(&g_floppy, g_d64_data.data(),
                          (uint32_t)g_d64_data.size(), 1);
    fprintf(stderr, "floppy: synthesized empty 35-track D64 (683 sectors)\n");
}

/* ── Auto-typer: feed a byte stream to the keyboard after boot ──────────────
 * Sentinel 0x01 in the stream = "wait ~6s for a slow command (LOAD) to finish"
 * so a script can chain LOAD then RUN.  Timing is driven by sim_us. */
static std::vector<uint8_t> g_autotype;
static size_t   g_autotype_pos   = 0;
static uint32_t g_autotype_next  = 0;
static uint32_t g_autotype_start = 0;

static inline void autotype_load(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "autotype: cannot open %s\n", path); return; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    g_autotype.resize((size_t)sz);
    if (fread(g_autotype.data(), 1, (size_t)sz, f) != (size_t)sz) g_autotype.clear();
    fclose(f);
    g_autotype_pos = 0;
    fprintf(stderr, "autotype: loaded %ld bytes from %s\n", sz, path);
}

/* Call once per video frame with the current sim_us. */
static inline void autotype_tick(uint32_t sim_us)
{
    if (g_autotype.empty() || g_autotype_pos >= g_autotype.size()) return;
    if (g_autotype_start == 0 && sim_us > 0) g_autotype_start = sim_us;
    /* Settle time after boot before typing (µs); tunable for slow-booting
     * arches (C64 KERNAL) via AUTOTYPE_BOOT_MS. */
    static uint32_t boot_us = 0;
    if (boot_us == 0) {
        const char* b = getenv("AUTOTYPE_BOOT_MS");
        boot_us = (b ? (uint32_t)atoi(b) : 1000) * 1000; if (!boot_us) boot_us = 1000000;
    }
    if (sim_us < g_autotype_start + boot_us) return;
    if (sim_us < g_autotype_next) return;

    uint8_t ch = g_autotype[g_autotype_pos++];
    if (ch == 0x01) { g_autotype_next = sim_us + 6000000; return; }  /* long wait */
    g_uart_queue.push(ch);
    /* Per-character / post-RETURN delays (µs).  Tunable via env for arches
     * with a slower keyboard bridge (e.g. C64): AUTOTYPE_MS / AUTOTYPE_RET_MS. */
    static uint32_t char_us = 0, ret_us = 0;
    if (char_us == 0) {
        const char* m = getenv("AUTOTYPE_MS");
        const char* r = getenv("AUTOTYPE_RET_MS");
        char_us = (m ? (uint32_t)atoi(m) : 100) * 1000; if (!char_us) char_us = 100000;
        ret_us  = (r ? (uint32_t)atoi(r) : 500) * 1000; if (!ret_us)  ret_us  = 500000;
    }
    g_autotype_next = sim_us + (ch == 0x0Du ? ret_us : char_us);
}

/* ── Framebuffer → PPM dump (headless verification) ─────────────────────── */
static inline void dump_ppm(const char* path, const uint32_t* fb, int w, int h)
{
    FILE* f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "screenshot: cannot open %s\n", path); return; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; i++) {
        uint32_t px = fb[i];   /* ARGB8888 */
        uint8_t rgb[3] = { (uint8_t)(px >> 16), (uint8_t)(px >> 8), (uint8_t)px };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    fprintf(stderr, "screenshot: wrote %s (%dx%d)\n", path, w, h);
}

/* Periodic screenshots (--screenshot-every <us>): call once per frame with
 * the current sim_us; writes <base>_t<seconds*10>.ppm alongside the final
 * --screenshot path (or shot.ppm if none was given). */
static inline void screenshot_tick(uint32_t sim_us, const uint32_t* fb, int w, int h)
{
    if (!g_shot_every_us || sim_us < g_shot_next_us) return;
    g_shot_next_us = sim_us + g_shot_every_us;
    const char* base = g_screenshot_path ? g_screenshot_path : "shot.ppm";
    char path[512];
    size_t blen = strlen(base);
    if (blen > 4 && !strcmp(base + blen - 4, ".ppm")) blen -= 4;
    snprintf(path, sizeof(path), "%.*s_t%04u.ppm", (int)blen, base, sim_us / 100000);
    dump_ppm(path, fb, w, h);
}

/* ── CLI: --autotype/--d64/--rom/--no-floppy/--headless/--screenshot/--exit-us
 * Initialises the drive as `device` (usually 8). */
static inline void iec_floppy_parse_args(int argc, char** argv, uint8_t device)
{
    floppy1541_init(&g_floppy, device);
    g_floppy.prev_atn = 1;
    g_floppy.prev_clk = 1;
    g_floppy_enabled  = true;
    const char* d64 = nullptr;
    const char* rom = nullptr;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--autotype")   && i+1 < argc) autotype_load(argv[++i]);
        else if (!strcmp(argv[i], "--d64")        && i+1 < argc) d64 = argv[++i];
        else if (!strcmp(argv[i], "--rom")        && i+1 < argc) rom = argv[++i];
        else if (!strcmp(argv[i], "--no-floppy"))                g_floppy_enabled = false;
        else if (!strcmp(argv[i], "--headless"))                 g_headless = true;
        else if (!strcmp(argv[i], "--screenshot") && i+1 < argc) g_screenshot_path = argv[++i];
        else if (!strcmp(argv[i], "--exit-us")    && i+1 < argc) g_exit_us = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--screenshot-every") && i+1 < argc) g_shot_every_us = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--fastload"))                 g_fastload = true;
    }
    if (g_fastload) fprintf(stderr, "floppy: FAST LOAD enabled (direct RAM injection, bypasses the real drive)\n");
    if (g_screenshot_path && g_exit_us == 0) g_exit_us = 5000000;
    if (g_floppy_enabled) {
        if (d64) floppy_load_d64(d64); else floppy_make_empty_d64();
        if (rom) { if (!floppy_load_rom(rom)) fprintf(stderr, "floppy: falling back to protocol-level mode\n"); }
        else fprintf(stderr, "floppy: protocol-level mode (pass --rom <1541.bin> for full emulation)\n");
    }
}

/* ── Fast loader (opt-in, --fastload) ──────────────────────────────────────
 * Instead of the authentic (slow) serial transfer, trap the KERNAL LOAD and
 * copy the file straight into the computer's RAM.  Mechanism: patch the RAM
 * LOAD vector to a tiny stub we drop in a free RAM area; when the CPU reaches
 * the stub we read the filename from zero-page, pull the file from the mounted
 * .d64, write it into RAM, and the stub returns the end address to BASIC.
 *
 * Bypasses the real drive, so custom loaders / copy protection won't work
 * through it — that's why it's opt-in and the real 1541 stays the default.
 *
 * Requires the top's `ram` array to be `/* verilator public_flat_rw *​/` (all
 * three socs are); accessed as top->rootp->soc__DOT__ram[addr].  Config fields
 * (fl_cfg / g_flcfg / g_fastload) are declared with the globals above.
 */
template <class TOP> static inline uint8_t fl_rd(TOP* top, uint16_t a)
{ return top->rootp->soc__DOT__ram[a & g_flcfg.ram_mask]; }
template <class TOP> static inline void fl_wr(TOP* top, uint16_t a, uint8_t v)
{ top->rootp->soc__DOT__ram[a & g_flcfg.ram_mask] = v; }

/* Write the return-stub + keep the LOAD vector pointed at it (call each frame
 * so it survives a KERNAL re-init).  Stub:  LDX $S+8 ; LDY $S+9 ; CLC ; RTS.
 *
 * NON-DESTRUCTIVE: the stub sits in the cassette buffer, which multi-load
 * games (crack loaders especially) reuse for their own drive code.  The
 * moment the program overwrites the stub, or points the LOAD vector anywhere
 * that is neither our stub nor the KERNAL default, fastload disarms for good
 * and the real emulated drive takes over.  An all-zero stub area is the
 * KERNAL boot RAM-clear, not a claim — we just re-patch. */
template <class TOP> static inline void fastload_maintain(TOP* top)
{
    if (!g_fastload || !g_flcfg.valid || !g_floppy_enabled || g_fl_disarmed) return;
    uint16_t S = g_flcfg.stub;
    const uint8_t stub_code[8] = { 0xAE, (uint8_t)(S+8), (uint8_t)((S+8)>>8),
                                   0xAC, (uint8_t)(S+9), (uint8_t)((S+9)>>8),
                                   0x18, 0x60 };
    /* Takeover detection only engages once a load has actually gone through
     * the stub — during boot the KERNAL RAM-clear/RESTOR sequence briefly
     * leaves both the buffer and the vector in transient states (zeros,
     * $0000) that must not read as a program claim. */
    if (g_fl_load_count > 0) {
        bool ours = true, zeros = true;
        for (int i = 0; i < 8; i++) {
            uint8_t b = fl_rd(top, (uint16_t)(S+i));
            if (b != stub_code[i]) ours  = false;
            if (b != 0x00)         zeros = false;
        }
        uint16_t vec = (uint16_t)(fl_rd(top, g_flcfg.load_vec) |
                                  (fl_rd(top, g_flcfg.load_vec+1) << 8));
        bool vec_ours    = (vec == S) || (vec == 0x0000);
        bool vec_kernal  = g_flcfg.kernal_load_default &&
                           (vec == g_flcfg.kernal_load_default);
        if (!ours && !zeros) {
            /* Program claimed the cassette buffer: back off. */
            g_fl_disarmed = true;
            if (vec_ours && g_flcfg.kernal_load_default) {
                fl_wr(top, g_flcfg.load_vec+0, (uint8_t)g_flcfg.kernal_load_default);
                fl_wr(top, g_flcfg.load_vec+1, (uint8_t)(g_flcfg.kernal_load_default>>8));
            }
            fprintf(stderr, "fastload: program claimed $%04X — disarmed, real drive takes over\n", S);
            return;
        }
        if (!vec_ours && !vec_kernal) {
            /* Program installed its own LOAD vector: respect it. */
            g_fl_disarmed = true;
            fprintf(stderr, "fastload: program revectored LOAD to $%04X — disarmed\n", vec);
            return;
        }
    }
    for (int i = 0; i < 8; i++) fl_wr(top, (uint16_t)(S+i), stub_code[i]);
    fl_wr(top, g_flcfg.load_vec+0, (uint8_t)S);
    fl_wr(top, g_flcfg.load_vec+1, (uint8_t)(S>>8));
}

/* Called every cycle with the current CPU PC.  When it reaches the stub, do
 * the load and stash the end address for the stub to return in X/Y. */
template <class TOP> static inline void fastload_trap(TOP* top, uint16_t pc)
{
    if (!g_fastload || !g_flcfg.valid || !g_floppy_enabled || g_fl_disarmed) return;
    /* dbg_cpu_addr is the whole address bus (data accesses too, not just
     * opcode fetches), so fire only on the EDGE into the stub, and require a
     * plausible filename length — this rejects the boot-time RAM clear's stray
     * accesses to the stub area. */
    static uint16_t prev_pc = 0xFFFF;
    bool entered = (pc == g_flcfg.stub && prev_pc != g_flcfg.stub);
    prev_pc = pc;
    if (!entered) return;

    const fl_cfg& c = g_flcfg;
    /* The address bus also shows DATA accesses: a program write to $stub
     * (e.g. a decruncher sweeping through the cassette buffer) looks like an
     * entry edge, and re-injecting on stale ZP state would corrupt the very
     * program we just loaded.  A genuine entry executes our stub — so if the
     * stub code is no longer intact, this was a data access: disarm. */
    {
        uint16_t S = c.stub;
        const uint8_t stub_code[8] = { 0xAE, (uint8_t)(S+8), (uint8_t)((S+8)>>8),
                                       0xAC, (uint8_t)(S+9), (uint8_t)((S+9)>>8),
                                       0x18, 0x60 };
        for (int i = 0; i < 8; i++)
            if (fl_rd(top, (uint16_t)(S+i)) != stub_code[i]) {
                g_fl_disarmed = true;
                /* The LOAD vector may still point at the (now overwritten)
                 * stub — a later KERNAL LOAD would jump into the program's
                 * data.  Put the KERNAL default back, exactly like the
                 * maintain() disarm paths do (Pirates! decrunches over the
                 * cassette buffer, preserves $0330 across a RESTOR, and
                 * LOADs every later game part through it). */
                uint16_t vec = (uint16_t)(fl_rd(top, c.load_vec) |
                                          (fl_rd(top, c.load_vec+1) << 8));
                if (vec == S && c.kernal_load_default) {
                    fl_wr(top, c.load_vec+0, (uint8_t)c.kernal_load_default);
                    fl_wr(top, c.load_vec+1, (uint8_t)(c.kernal_load_default>>8));
                }
                fprintf(stderr, "fastload: data access hit the stub (program claiming $%04X) — disarmed\n", S);
                return;
            }
    }
    uint8_t  len = fl_rd(top, c.fnlen);
    if (len == 0 || len > 16) return;          /* not a real LOAD */
    g_fl_load_count++;                         /* arms the takeover checks */
    uint16_t adr = (uint16_t)(fl_rd(top, c.fnadr) | (fl_rd(top, c.fnadr+1) << 8));
    char name[20]; int nl = len < 19 ? len : 19;
    for (int i = 0; i < nl; i++) name[i] = (char)fl_rd(top, (uint16_t)(adr+i));
    name[nl] = 0;

    static uint8_t buf[66000];
    int n;
    if (nl >= 1 && name[0] == '$')
        n = floppy1541_read_dir(&g_floppy, buf, (int)sizeof(buf));
    else
        n = floppy1541_read_prg(&g_floppy, name, nl, buf, (int)sizeof(buf));
    if (n < 2) {
        fprintf(stderr, "fastload: \"%s\" (len=%d, hex", name, len);
        for (int i = 0; i < nl; i++) fprintf(stderr, " %02X", (uint8_t)name[i]);
        fprintf(stderr, ") not in directory");
        if (c.kernal_load_default) {
            /* Unresolvable name — often a custom loader's trigger for drive
             * code it uploaded via the command channel (which never passes
             * through the LOAD vector).  The CPU is parked at stub+0 right
             * now, so rewrite the stub to JMP <KERNAL LOAD> and disarm: this
             * very load re-runs on the real drive, transparently. */
            fl_wr(top, c.stub+0, 0x4C);
            fl_wr(top, c.stub+1, (uint8_t)c.kernal_load_default);
            fl_wr(top, c.stub+2, (uint8_t)(c.kernal_load_default>>8));
            fl_wr(top, c.load_vec+0, (uint8_t)c.kernal_load_default);
            fl_wr(top, c.load_vec+1, (uint8_t)(c.kernal_load_default>>8));
            g_fl_disarmed = true;
            fprintf(stderr, " — handing this LOAD to the real drive, fastload disarmed\n");
            return;
        }
        /* No known KERNAL entry → stub returns start==end with a
         * FILE-NOT-FOUND-ish status bit so BASIC doesn't hang. */
        fl_wr(top, c.status, 0x40);
        fl_wr(top, c.stub+8, fl_rd(top, c.reloc_ptr));
        fl_wr(top, c.stub+9, fl_rd(top, c.reloc_ptr+1));
        fprintf(stderr, "\n");
        return;
    }

    /* KERNAL LOAD semantics: SA == 0 → relocate to the caller's X/Y
     * address; ANY nonzero SA → the file's own header address.  (Was
     * `sa & 1`, which sent even nonzero SAs down the relocate path —
     * Terra Nova's loader uses SETLFS(1,8,4) and its 49KB level file
     * landed +$1A18 off, crashing into the LOAD vector with garbage.) */
    uint8_t  sa   = fl_rd(top, c.sa);
    uint16_t load = (sa != 0) ? (uint16_t)(buf[0] | (buf[1] << 8))
                              : (uint16_t)(fl_rd(top, c.reloc_ptr) | (fl_rd(top, c.reloc_ptr+1) << 8));
    for (int i = 2; i < n; i++) fl_wr(top, (uint16_t)(load + (i-2)), buf[i]);
    uint16_t end = (uint16_t)(load + (n-2));
    fl_wr(top, c.stub+8, (uint8_t)end);
    fl_wr(top, c.stub+9, (uint8_t)(end>>8));
    fl_wr(top, c.status, 0);
    fprintf(stderr, "fastload: \"%s\" -> $%04X..$%04X (%d bytes)\n", name, load, end, n-2);
}

/* ── IEC bus step ───────────────────────────────────────────────────────── */

/* Every Verilator cycle: keep the computer's IEC inputs current (drive output
 * changes at most once per µs, but this minimises round-trip latency). */
template <class TOP>
static inline void iec_floppy_feedback(TOP* top)
{
    if (!g_floppy_enabled) return;
    int fc = top->iec_clk_out  & (g_floppy.out_clk  ? 0 : 1);
    int fd = top->iec_data_out & (g_floppy.out_data ? 0 : 1);
    top->iec_clk_in  = fc;
    top->iec_data_in = fd;
}

/* Once per simulated µs: advance the drive and exchange the open-collector
 * bus.  IMPORTANT: the drive must run at exactly 1 MHz (sim_us must advance
 * 1 per real microsecond) or it will out-run the host CPU and lose IEC sync. */
template <class TOP>
static inline void iec_floppy_step(TOP* top, uint32_t sim_us)
{
    /* Parked (either no drive, or DOS-over-link owns it): release both lines,
     * exactly like the suspended core-1 engine leaves the pads Hi-Z. */
    if (!g_floppy_enabled || g_floppy_wire_park) {
        top->iec_clk_in = 1; top->iec_data_in = 1; return;
    }
    int a = (int)top->iec_atn_out;
    int c = (int)top->iec_clk_out;
    int d = (int)top->iec_data_out;
    int fc = g_floppy.out_clk  ? 0 : 1;
    int fd = g_floppy.out_data ? 0 : 1;
    floppy1541_update(&g_floppy, sim_us, a, c & fc, d & fd);
    fc = g_floppy.out_clk  ? 0 : 1;
    fd = g_floppy.out_data ? 0 : 1;
    top->iec_clk_in  = c & fc;
    top->iec_data_in = d & fd;
}

#endif /* IEC_FLOPPY_SIM_H */
