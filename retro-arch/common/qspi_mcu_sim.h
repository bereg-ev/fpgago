/* ── qspi_mcu_sim.h — C++ model of the RP2350 side of the QSPI link ────────
 *
 * Drives the soc's SPI pins (spi_sck/ss/mosi, samples spi_miso/spi_req)
 * exactly like the MCU firmware does, and serves fastload requests from the
 * same mounted .d64 as the IEC drive model (g_floppy from iec_floppy_sim.h —
 * include that first). This exercises the ENTIRE FPGA-side stack (SPI slave,
 * FIFO, register window, patched-KERNAL routine) at pin level: the only
 * thing hardware adds is the real firmware, whose logic mirrors this file.
 *
 * Enable with --qspi on the sim command line (needs --d64 as well). Without
 * it the pins idle deselected and the KERNAL routine's watchdog fallback
 * sends LOAD down the real IEC path.
 *
 * Protocol (see qspi_slave.v): frames [CMD]... ; REQ_FETCH 0x10 → name,
 * DATA_PUSH 0x11 in ≤32-byte chunks gated by REQ, XFER_END 0x12 flags.
 */
#pragma once
#include <vector>
#include <string>
#include <string.h>
#include <stdio.h>

static bool g_qspi_mcu_enabled = false;

/* --biostest <t0:t1> (µs): at t0 send MODE_SET(1) + paint a test screen
 * (fill, boxes, logo glyphs, BTN_READ); at t1 send MODE_SET(0) so the
 * frozen machine resumes.  Implies --qspi. */
static uint32_t g_bios_t0 = 0, g_bios_t1 = 0;

/* --btnmode <m:t_us> (repeatable): at t_us send SET_BTNMODE(m) — m: 0=TEXT
 * keys, 1=joystick port 1, 2=joystick port 2.  Implies --qspi. */
static std::vector<std::pair<uint32_t, uint8_t>> g_btnmode_sched;

/* --drivemode <m:t_us> (repeatable): at t_us send DRIVE_MODE(m) — m: 0 =
 * QSPI fastload, 1 = real-1541 IEC (the KERNAL detour window serves the
 * transparent fallback stub, so LOAD goes down the stock IEC path), 2 =
 * DOS over the link (the KERNAL's serial primitives are detoured too, so
 * channel I/O — OPEN/PRINT#/GET#, U1/B-P — is served here instead of on
 * the wire).  Implies --qspi. */
static std::vector<std::pair<uint32_t, uint8_t>> g_drivemode_sched;

/* --fdstat <period_ms>: poll FD_STATUS (0x0D) that often and print the
 * fabric-1541 status byte + load-done counter whenever either changes.  This
 * is the sim's view of exactly what the BIOS autostart watches on hardware
 * (bios_ui.c AS_W_LOAD in fabric mode).  Implies --qspi. */
static uint32_t g_fdstat_ms = 0;

/* --lanes <1|2|4>: negotiate the LINK_CFG multi-lane upshift at ~200 ms and
 * run every later frame half-duplex on that many data lanes — exercises the
 * whole multi-lane slave path (turnaround, per-lane oe, echo-offset shift).
 * Implies --qspi. */
static int g_qm_lanes_want = 1;

/* --vol <0..10>: the volume the MCU model applies at ~100 ms, mirroring
 * biosApplyVolume() after FPGA configuration (hardware fabrics power up
 * muted; SIMULATION fabrics power up at unity so plain no-model sims keep
 * audio).  Default 10 = unity. */
static int g_qm_vol = 10;

/* --shot <t_us:out.ppm>: at t_us grab a frame over the SPI SHOT_ARM/STATUS/
 * READ commands (shot_cap.v line capture) and write it as a PPM — the same
 * sweep the MCU firmware runs for the USB screen grab.  The sim LCD is the
 * native 480x272 window (no 2x doubling like the 800x480 panel), so the
 * sweep arms every line directly and the subsampled width is 240.
 * Implies --qspi. */
static uint32_t g_shot_t0 = 0;
static char     g_shot_path[256] = {0};
/* Grab geometry.  The defaults are the sim panel's 480x272 halved; a harness
 * that runs the FPGA-mode video path overrides them to the board's numbers
 * (400x240 logical out of an 800x480 panel, VSTEP=2 — the panel line the MCU
 * arms is logical*VSTEP, exactly what the board firmware's screen grab does). */
#ifndef QM_SHOT_W
#define QM_SHOT_W 240
#endif
#ifndef QM_SHOT_H
#define QM_SHOT_H 272
#endif
#ifndef QM_SHOT_VSTEP
#define QM_SHOT_VSTEP 1
#endif
/* Pair arms (SHOT_ARM flags bit1: line + line+2 per round-trip, second line
 * at byte offset 1024) mirror the board firmware's screen grab's subsampled grabs — only
 * correct when a logical line is 2 panel lines.  Freeze (SHOT_FREEZE 0x33)
 * halts the machine for the whole sweep like shot.c does. */
#ifndef QM_SHOT_PAIR
#define QM_SHOT_PAIR (QM_SHOT_VSTEP == 2)
#endif
#ifndef QM_SHOT_FREEZE
#define QM_SHOT_FREEZE 1
#endif
#define QM_SHOT_CHUNK 200

/* --rom-bank <bank>:<file.hex> / --rom-bin <bank>:<file> (repeatable): push a
 * ROM bank into a ROM-free
 * bitstream over the ROM_BEGIN/ROM_DATA/ROM_END commands, the way the MCU
 * firmware will after configuration (bitstreams/README.md phase 3).
 * The file is the same one-byte-per-line hex the baked build feeds to
 * $readmemh, so both paths load identical bytes.  Implies --qspi.
 * A ROMLESS fabric holds its machine in reset until every bank it needs has
 * been ended, so without this a ROMLESS sim shows a blank screen — correctly. */
/* --rom-bin <bank>:<file> is the same thing for a RAW binary image, which is
 * what a whole-ROM dump actually is (the hex
 * form exists because the Commodore banks are also fed to $readmemh). */
static std::vector<std::pair<uint8_t, std::string>> g_rom_push;
static std::vector<std::pair<uint8_t, std::string>> g_rom_push_bin;
#define QM_ROM_CHUNK 256          /* bytes per ROM_DATA frame */

/* Header-local µs clock (sim_top's g_sim_us is declared after this include):
 * qspi_mcu_tick() counts sys clocks, divided by cycles_per_us from the
 * parse call (pass the sim's CYCLES_PER_US; only --biostest timing uses it). */
static uint64_t g_qm_cycles = 0;
static uint32_t g_qm_cyc_per_us = 28;

static inline void qspi_mcu_parse_args(int argc, char** argv,
                                       uint32_t cycles_per_us = 28)
{
    g_qm_cyc_per_us = cycles_per_us;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--qspi"))
            g_qspi_mcu_enabled = true;
        else if (!strcmp(argv[i], "--biostest") && i + 1 < argc) {
            if (sscanf(argv[++i], "%u:%u", &g_bios_t0, &g_bios_t1) == 2)
                g_qspi_mcu_enabled = true;
            else
                fprintf(stderr, "bad --biostest (want t0us:t1us)\n");
        }
        else if (!strcmp(argv[i], "--btnmode") && i + 1 < argc) {
            unsigned m = 0, t = 0;
            if (sscanf(argv[++i], "%u:%u", &m, &t) == 2 && m <= 2) {
                g_btnmode_sched.push_back({(uint32_t)t, (uint8_t)m});
                g_qspi_mcu_enabled = true;
            } else
                fprintf(stderr, "bad --btnmode (want mode0..2:t_us)\n");
        }
        else if (!strcmp(argv[i], "--drivemode") && i + 1 < argc) {
            unsigned m = 0, t = 0;
            if (sscanf(argv[++i], "%u:%u", &m, &t) == 2 && m <= 2) {
                g_drivemode_sched.push_back({(uint32_t)t, (uint8_t)m});
                g_qspi_mcu_enabled = true;
            } else
                fprintf(stderr, "bad --drivemode (want mode0..2:t_us)\n");
        }
        else if (!strcmp(argv[i], "--fdstat") && i + 1 < argc) {
            unsigned p = 0;
            if (sscanf(argv[++i], "%u", &p) == 1 && p) {
                g_fdstat_ms = (uint32_t)p;
                g_qspi_mcu_enabled = true;
            } else
                fprintf(stderr, "bad --fdstat (want a period in ms)\n");
        }
        else if (!strcmp(argv[i], "--lanes") && i + 1 < argc) {
            unsigned l = 0;
            if (sscanf(argv[++i], "%u", &l) == 1 &&
                (l == 1 || l == 2 || l == 4)) {
                g_qm_lanes_want = (int)l;
                g_qspi_mcu_enabled = true;
            } else
                fprintf(stderr, "bad --lanes (want 1|2|4)\n");
        }
        else if (!strcmp(argv[i], "--vol") && i + 1 < argc) {
            unsigned v = 0;
            if (sscanf(argv[++i], "%u", &v) == 1 && v <= 10) {
                g_qm_vol = (int)v;
                g_qspi_mcu_enabled = true;
            } else
                fprintf(stderr, "bad --vol (want 0..10)\n");
        }
        else if (!strcmp(argv[i], "--rom-bin") && i + 1 < argc) {
            unsigned bank = 0;
            char path[512] = {0};
            if (sscanf(argv[++i], "%u:%511s", &bank, path) == 2 && bank < 8) {
                g_rom_push_bin.push_back({(uint8_t)bank, std::string(path)});
                g_qspi_mcu_enabled = true;
            } else
                fprintf(stderr, "bad --rom-bin (want bank0..7:file)\n");
        }
        else if (!strcmp(argv[i], "--rom-bank") && i + 1 < argc) {
            unsigned b = 0;
            char path[256] = {0};
            if (sscanf(argv[++i], "%u:%255s", &b, path) == 2 && b < 8) {
                g_rom_push.push_back({(uint8_t)b, std::string(path)});
                g_qspi_mcu_enabled = true;
            } else
                fprintf(stderr, "bad --rom-bank (want bank0..7:file.hex)\n");
        }
        else if (!strcmp(argv[i], "--shot") && i + 1 < argc) {
            if (sscanf(argv[++i], "%u:%255s", &g_shot_t0, g_shot_path) == 2)
                g_qspi_mcu_enabled = true;
            else
                fprintf(stderr, "bad --shot (want t_us:out.ppm)\n");
        }
    }
}

struct QspiMcuSim {
    /* SPI bit engine (1/2/4 data lanes; see qspi_slave.v multi-lane doc) */
    int divcnt = 0;
    int state  = 0;            /* 0 idle, 1 ss-assert gap, 2 bits, 3 ss gap */
    int phase  = 0;
    int chunk  = 0;            /* chunk index within the byte (8/lanes) */
    size_t bytepos = 0;
    std::vector<uint8_t> tx, rx;
    size_t mlen = 0;           /* master-driven byte count (lanes>1: rest is
                                  turnaround + slave response) */
    int lanes = 1;             /* active lane count */
    int lanes_next = 1;        /* applied after the LINK_CFG frame */
    bool lanecfg_sent = false;
    bool vol_sent = false;     /* boot SET_VOLUME (biosApplyVolume mirror) */
    bool rom_sent = false;     /* --rom banks queued (once, at t=0) */
    int mode = 0;              /* 1 fetch, 2 push, 3 end */
    int gap  = 0;

    /* server */
    bool active = false;
    std::vector<uint8_t> file;
    size_t   pos = 0;
    uint8_t  end_flags = 0x01;
    uint64_t stall = 0;

    /* --biostest state: queued BIOS frames + progress step */
    std::vector<std::vector<uint8_t>> bq;
    size_t bq_pos = 0;
    int    bios_step = 0;      /* 0 idle, 1 entered, 2 exited */

    /* --shot state machine: 0 off, 1 arm line, 2 poll status, 3 read chunk,
     * 4 done, 5 send freeze-on, 6 send freeze-off */
    int      shot_step = 0;
    int      shot_line = 0;    /* logical line 0..239 (panel line = 2x) */
    int      shot_sub  = 0;    /* pair arms: which of the 2 lines is read */
    int      shot_off  = 0;    /* byte offset into the current line */
    bool     shot_frozen = false;  /* machine halted by SHOT_FREEZE */
    std::vector<uint8_t> shot_px;

    /* --fdstat poll (fabric-1541 status + load-done counter) */
    uint32_t fdstat_next_us = 0;
    int      fdstat_stat = -1; /* last printed values; -1 = nothing yet */
    int      fdstat_done = -1;
};
static QspiMcuSim g_qm;

/* ── BIOS test screen (exercises MODE_SET/TEXT_FILL/TEXT_WRITE/BTN_READ) ── */
static inline void qm_bios_text(int col, int row, const char* s, uint8_t attr)
{
    int addr = row * 80 + col;
    std::vector<uint8_t> f = {0x21, (uint8_t)(addr & 0xFF), (uint8_t)(addr >> 8)};
    for (const char* p = s; *p; p++) {
        f.push_back((uint8_t)*p);
        f.push_back(attr);
    }
    g_qm.bq.push_back(std::move(f));
}

/* ── ROM bank push (ROM-free bitstreams; --rom bank:file.hex) ──────────── */
/* Queue one BEGIN, N DATA frames and one END per bank, mirroring what
 * rom_push.c will do on the MCU.  Queued at t=0: the fabric holds the machine
 * in reset until the banks are ended, so the sooner they land the sooner the
 * machine starts. */
/* Queue BEGIN + N x DATA + END for one bank's worth of bytes. */
static inline void qm_rom_queue_bytes(uint8_t bank, const char* path,
                                      const std::vector<uint8_t>& bytes)
{
    g_qm.bq.push_back({0x60, bank});                    /* ROM_BEGIN */
    for (size_t o = 0; o < bytes.size(); o += QM_ROM_CHUNK) {
        size_t n = bytes.size() - o;
        if (n > QM_ROM_CHUNK)
            n = QM_ROM_CHUNK;
        std::vector<uint8_t> fr;
        fr.reserve(n + 1);
        fr.push_back(0x61);                             /* ROM_DATA */
        fr.insert(fr.end(), bytes.begin() + (long)o,
                  bytes.begin() + (long)(o + n));
        g_qm.bq.push_back(std::move(fr));
    }
    g_qm.bq.push_back({0x62});                          /* ROM_END */
    fprintf(stderr, "qspi-mcu: ROM bank %u <- %s (%u bytes)\n",
            bank, path, (unsigned)bytes.size());
}

static inline void qm_rom_queue()
{
    /* Binaries first: a fabric may treat one bank's END as the "go" signal
     * that releases its machine,
     * so the caller's order is preserved and callers push the optional
     * banks first. */
    for (size_t i = 0; i < g_rom_push_bin.size(); i++) {
        uint8_t bank = g_rom_push_bin[i].first;
        const char* path = g_rom_push_bin[i].second.c_str();
        FILE* f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "qspi-mcu: --rom-bin: cannot open %s\n", path);
            continue;
        }
        std::vector<uint8_t> bytes;
        uint8_t buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, f)) > 0)
            bytes.insert(bytes.end(), buf, buf + n);
        fclose(f);
        qm_rom_queue_bytes(bank, path, bytes);
    }

    for (size_t i = 0; i < g_rom_push.size(); i++) {
        uint8_t bank = g_rom_push[i].first;
        const char* path = g_rom_push[i].second.c_str();
        FILE* f = fopen(path, "r");
        if (!f) {
            fprintf(stderr, "qspi-mcu: --rom-bank: cannot open %s\n", path);
            continue;
        }
        std::vector<uint8_t> bytes;
        unsigned v;
        while (fscanf(f, "%x", &v) == 1)
            bytes.push_back((uint8_t)v);
        fclose(f);

        qm_rom_queue_bytes(bank, path, bytes);
    }
}

static inline void qm_bios_paint()
{
    /* enter BIOS mode, clear to grey-on-blue */
    g_qm.bq.push_back({0x20, 0x01});
    g_qm.bq.push_back({0x22, ' ', 0x17, 0x00, 0x00, 0xD0, 0x07});   /* 2000 cells */

    /* double-line box rows 1..4, cols 1..60 (CP437 C9/BB/C8/BC/CD/BA) */
    {
        std::vector<uint8_t> top = {0x21, 81 % 256, 81 / 256};      /* (1,1) */
        top.push_back(0xC9); top.push_back(0x1F);
        for (int i = 0; i < 58; i++) { top.push_back(0xCD); top.push_back(0x1F); }
        top.push_back(0xBB); top.push_back(0x1F);
        g_qm.bq.push_back(std::move(top));
        std::vector<uint8_t> bot = {0x21, (uint8_t)((4 * 80 + 1) & 0xFF), (uint8_t)((4 * 80 + 1) >> 8)};
        bot.push_back(0xC8); bot.push_back(0x1F);
        for (int i = 0; i < 58; i++) { bot.push_back(0xCD); bot.push_back(0x1F); }
        bot.push_back(0xBC); bot.push_back(0x1F);
        g_qm.bq.push_back(std::move(bot));
        for (int r = 2; r <= 3; r++) {
            qm_bios_text(1,  r, "\xBA", 0x1F);
            qm_bios_text(60, r, "\xBA", 0x1F);
        }
    }
    qm_bios_text(4, 2, "FPGAGO BIOS TEST (v0.1)", 0x1F);
    qm_bios_text(4, 3, "Press U21 to resume", 0x17);
    qm_bios_text(24, 3, "BLINK", 0x9E);                 /* yellow, blink */

    /* Energy Star logo as a 20x7 block, top-right (glyph slots across all
     * the spare CP437 ranges, same map as bios_font.py logo_glyph()); the
     * bottom row is the green diameter rule + "EDUCATIONAL PLATFORM" line */
    for (int r = 0; r < 7; r++) {
        std::vector<uint8_t> f = {0x21,
            (uint8_t)((r * 80 + 60) & 0xFF),
            (uint8_t)((r * 80 + 60) >> 8)};
        for (int c = 0; c < 20; c++) {
            int idx = r * 20 + c;
            uint8_t g = (uint8_t)(idx < 48  ? 0x80 + idx :
                                  idx < 80  ? 0xE0 + idx - 48 :
                                  idx < 95  ? 0x01 + idx - 80 :
                                  idx < 102 ? 0x11 + idx - 95 :
                                  idx < 106 ? 0x1C + idx - 102 :
                                  idx < 108 ? 0xB1 + idx - 106 :
                                  idx < 114 ? 0xB4 + idx - 108 :
                                  idx < 116 ? 0xBD + idx - 114 :
                                  idx < 119 ? 0xC1 + idx - 116 :
                                  idx < 122 ? 0xC5 + idx - 119 :
                                  idx < 125 ? 0xCA + idx - 122 :
                                  idx < 127 ? 0xCE + idx - 125 :
                                  idx < 136 ? 0xD0 + idx - 127 :
                                              0xDC + idx - 136);
            f.push_back(g);
            f.push_back(r == 6 ? 0x1A : 0x1E);          /* green / yellow */
        }
        g_qm.bq.push_back(std::move(f));
    }

    /* one BTN_READ (response printed in qm_frame_done) */
    g_qm.bq.push_back({0x23, 0x00, 0x00, 0x00});
}

/* SPI half period in sys clocks (8 = ~1.75 MHz, the default the checks run
 * at).  Settable so a test can push at the rate a REAL link runs: the board's
 * 4-lane mode is 3 MHz SCK, i.e. ~5 sys clocks per half period on a 31.5 MHz
 * fabric, which is how the c64 cart loader was caught outrunning its PSRAM
 * writer (retro-arch/c64/README.md).  Lower = faster master. */
static int g_qm_half = 8;
static inline void qspi_mcu_set_half(int half) { g_qm_half = half > 0 ? half : 1; }
#define QM_HALF g_qm_half

/* master-driven byte count for a frame at the given lane count: 1-lane is
 * legacy full-duplex (master drives every byte); multi-lane read commands
 * hand the bus over after the command byte, echo commands after cmd+alen+arg
 * (see the qspi_slave.v multi-lane framing doc). */
static inline size_t qm_mlen(const std::vector<uint8_t>& f, int lanes)
{
    if (lanes == 1 || f.empty())
        return f.size();
    switch (f[0]) {
        case 0x04: case 0x09: case 0x0D: case 0x10:     /* read commands */
        case 0x23: case 0x31:                           /* BTN / SHOT_STATUS */
            return 1;
        case 0x07: case 0x08: case 0x0A: case 0x0B:     /* echo commands */
        case 0x32:                                      /* SHOT_READ (cmd+off) */
            return 3;
        default:                                        /* pure writes */
            return f.size();
    }
}

static inline void qm_start_frame(int mode, std::vector<uint8_t> bytes)
{
    g_qm.tx = std::move(bytes);
    g_qm.rx.assign(g_qm.tx.size(), 0);
    g_qm.mlen = qm_mlen(g_qm.tx, g_qm.lanes);
    g_qm.mode = mode;
    g_qm.bytepos = 0;
    g_qm.chunk = 0;
    g_qm.phase = 0;
    g_qm.state = 1;
    g_qm.gap = 4;
}

static inline void qm_frame_done()
{
    QspiMcuSim& q = g_qm;
    if (q.mode == 1) {                         /* REQ_FETCH result */
#ifdef QM_NO_FLOPPY
        (void)0;   /* no 1541 model in this sim — nothing to serve */
#else
        /* type 0x02 = bus bytes from the KERNAL detours (DOS over link).
         * Replay each into the DOS with its under-ATN tag, then, if that
         * addressed us to talk, buffer the channel's answer for the push
         * path — the same shape qspi_link.c uses on the real MCU. */
        if (q.rx.size() >= 22 && q.rx[2] == 0x02) {
            int n = q.rx[3] & 31;
            fprintf(stderr, "qspi-mcu: [%uus] bus batch n=%d mask=%02X%02X"
                    " [%02X %02X %02X]\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), n,
                    q.rx[21], q.rx[20], q.rx[4],
                    n > 1 ? q.rx[5] : 0, n > 2 ? q.rx[6] : 0);
            unsigned mask = (unsigned)q.rx[20] | ((unsigned)q.rx[21] << 8);
            for (int i = 0; i < n && i < 16; i++)
                floppy1541_bus_send(&g_floppy, q.rx[4 + i], (mask >> i) & 1);
            if (floppy1541_bus_talking(&g_floppy)) {
                q.file.clear();
                for (;;) {
                    int eoi = 0;
                    int b = floppy1541_bus_recv(&g_floppy, &eoi);
                    if (b < 0) break;
                    q.file.push_back((uint8_t)b);
                    if (eoi) break;
                }
                q.active = true;
                q.pos = 0;
                q.stall = 0;
                q.end_flags = 0x01;
                fprintf(stderr, "qspi-mcu: [%uus] bus TALK ch -> %d bytes"
                        " [%02X %02X %02X]\n",
                        (uint32_t)(g_qm_cycles / g_qm_cyc_per_us),
                        (int)q.file.size(),
                        q.file.size() > 0 ? q.file[0] : 0,
                        q.file.size() > 1 ? q.file[1] : 0,
                        q.file.size() > 2 ? q.file[2] : 0);
            }
        }
        else if (q.rx.size() >= 22 && q.rx[2] != 0x00 && q.rx[2] != 0x01)
            fprintf(stderr, "qspi-mcu: fetch: unknown reqtype %02X (rx=%zu)\n",
                    q.rx[2], q.rx.size());
        else if (q.rx.size() >= 20 && q.rx[2] == 0x01) {
            int len = q.rx[3] & 31;
            char name[20];
            for (int i = 0; i < len && i < 16; i++) name[i] = (char)q.rx[4 + i];
            name[len < 16 ? len : 16] = 0;

            static uint8_t buf[66000];
            int n;
            if (len >= 1 && name[0] == '$')
                n = floppy1541_read_dir(&g_floppy, buf, (int)sizeof(buf));
            else
                n = floppy1541_read_prg(&g_floppy, name, len, buf, (int)sizeof(buf));
            q.active = true;
            q.pos = 0;
            q.stall = 0;
            if (n < 2) {
                q.file.clear();
                q.end_flags = 0x03;            /* EOF + error (not found) */
                fprintf(stderr, "qspi-mcu: [%uus] LOAD \"%s\" not found\n",
                        (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), name);
            } else {
                q.file.assign(buf, buf + n);
                q.end_flags = 0x01;
                fprintf(stderr, "qspi-mcu: [%uus] LOAD \"%s\" -> %d bytes\n",
                        (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), name, n);
            }
        }
#endif  /* QM_NO_FLOPPY */
    } else if (q.mode == 2) {
        q.pos += q.tx.size() - 2;              /* chunk advanced */
        q.stall = 0;
    } else if (q.mode == 3) {
        q.active = false;
        fprintf(stderr, "qspi-mcu: [%uus] XFER_END\n",
                (uint32_t)(g_qm_cycles / g_qm_cyc_per_us));
    } else if (q.mode == 4) {                  /* BIOS frame */
        /* echo commands land one byte later than legacy in multi-lane mode */
        int eo = (q.lanes > 1) ? 1 : 0;
        if (q.tx.size() >= 4 && q.tx[0] == 0x23)
            fprintf(stderr, "qspi-mcu: BTN_READ -> %02X (check %02X)\n",
                    q.rx[2], (uint8_t)~q.rx[3]);
        /* FD_STATUS is a read command: legacy byte positions at any lane
         * count, so no echo offset here. */
        if (q.tx.size() >= 6 && q.tx[0] == 0x0D && q.rx[2] == 0xA5 &&
            ((int)q.rx[3] != q.fdstat_stat || (int)q.rx[4] != q.fdstat_done)) {
            q.fdstat_stat = q.rx[3];
            q.fdstat_done = q.rx[4];
            fprintf(stderr, "qspi-mcu: [%uus] FD_STATUS %s%s%s%s loads=%d\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us),
                    (q.rx[3] & 0x01) ? "pushed " : "empty ",
                    (q.rx[3] & 0x02) ? "motor " : "",
                    (q.rx[3] & 0x04) ? "led " : "",
                    (q.rx[3] & 0x08) ? "armed" : "PARKED",
                    q.fdstat_done);
        }
        if (q.tx.size() >= 2 && q.tx[0] == 0x20)
            fprintf(stderr, "qspi-mcu: [%uus] MODE_SET %d\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), q.tx[1]);
        if (q.tx.size() >= 6 && q.tx[0] == 0x08)
            fprintf(stderr, "qspi-mcu: [%uus] SET_BTNMODE %d -> echo %d %s\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), q.tx[2],
                    q.rx[4 + eo],
                    (q.rx[3 + eo] == 0xA5 && q.rx[4 + eo] == q.tx[2] &&
                     q.rx[5 + eo] == (uint8_t)~0x08) ? "OK" : "BAD");
        if (q.tx.size() >= 6 && q.tx[0] == 0x07)
            fprintf(stderr, "qspi-mcu: [%uus] SET_VOLUME %d -> echo %d %s\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), q.tx[2],
                    q.rx[4 + eo],
                    (q.rx[3 + eo] == 0xA5 && q.rx[4 + eo] == q.tx[2] &&
                     q.rx[5 + eo] == (uint8_t)~0x07) ? "OK" : "BAD");
        if (q.tx.size() >= 6 && q.tx[0] == 0x0B)
            fprintf(stderr, "qspi-mcu: [%uus] DRIVE_MODE %d -> echo %d %s\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), q.tx[2],
                    q.rx[4 + eo],
                    (q.rx[3 + eo] == 0xA5 && q.rx[4 + eo] == q.tx[2] &&
                     q.rx[5 + eo] == (uint8_t)~0x0B) ? "OK" : "BAD");
        if (q.tx.size() >= 6 && q.tx[0] == 0x0A) {
            int ok = (q.rx[3 + eo] == 0xA5 && q.rx[4 + eo] == q.tx[2] &&
                      q.rx[5 + eo] == (uint8_t)~0x0A);
            fprintf(stderr, "qspi-mcu: [%uus] LINK_CFG %d -> echo %d %s\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us), q.tx[2],
                    q.rx[4 + eo], ok ? "OK" : "BAD");
            if (ok)
                q.lanes_next = q.tx[2];        /* both ends shift together */
        }
    } else if (q.mode == 5) {                  /* --shot sweep frame */
        int eo = (q.lanes > 1) ? 1 : 0;
        if (q.tx[0] == 0x33) {                 /* SHOT_FREEZE applied */
            q.shot_frozen = q.tx[1] != 0;
            fprintf(stderr, "qspi-mcu: [%uus] SHOT freeze %s\n",
                    (uint32_t)(g_qm_cycles / g_qm_cyc_per_us),
                    q.shot_frozen ? "ON (machine halted)" : "released");
            q.shot_step = q.shot_frozen ? 1 : 4;
        } else if (q.tx[0] == 0x30) {
            q.shot_step = 2;                   /* armed -> poll */
        } else if (q.tx[0] == 0x31) {
            /* [A5][state] at rx[2..3] in both modes (read-class command) */
            if (q.rx[2] == 0xA5 && (q.rx[3] & 1)) {
                q.shot_step = 3;               /* line(s) ready -> read */
                q.shot_off = 0;
                q.shot_sub = 0;
            }
        } else if (q.tx[0] == 0x32) {
            /* data at rx[4+eo ...] (echo-shaped: +1 in multi-lane) */
            int n = (int)q.rx.size() - (4 + eo);
            for (int i = 0; i < n; i++)
                q.shot_px.push_back(q.rx[(size_t)(4 + eo + i)]);
            q.shot_off += n;
            if (q.shot_off >= 2 * QM_SHOT_W) { /* line complete */
                q.shot_line++;
                if (q.shot_line % 60 == 0)
                    fprintf(stderr, "qspi-mcu: [%uus] SHOT %d/%d lines\n",
                            (uint32_t)(g_qm_cycles / g_qm_cyc_per_us),
                            q.shot_line, QM_SHOT_H);
                if (QM_SHOT_PAIR && !q.shot_sub && q.shot_line < QM_SHOT_H) {
                    q.shot_sub = 1;            /* pair's 2nd line, same arm */
                    q.shot_off = 0;
                    /* stay in step 3: next read starts at byte 1024 */
                } else if (q.shot_line < QM_SHOT_H) {
                    q.shot_step = 1;
                } else {
                    q.shot_step = QM_SHOT_FREEZE ? 6 : 4;
                    FILE* f = fopen(g_shot_path, "wb");
                    if (f) {
                        fprintf(f, "P6\n%d %d\n255\n", QM_SHOT_W, QM_SHOT_H);
                        for (size_t px = 0; px + 1 < q.shot_px.size(); px += 2) {
                            uint16_t v = (uint16_t)(q.shot_px[px] |
                                                    (q.shot_px[px + 1] << 8));
                            uint8_t rgb[3] = {
                                (uint8_t)(((v >> 11) & 0x1F) << 3),
                                (uint8_t)(((v >> 5)  & 0x3F) << 2),
                                (uint8_t)(( v        & 0x1F) << 3)
                            };
                            fwrite(rgb, 1, 3, f);
                        }
                        fclose(f);
                        fprintf(stderr, "qspi-mcu: [%uus] SHOT frame -> %s\n",
                                (uint32_t)(g_qm_cycles / g_qm_cyc_per_us),
                                g_shot_path);
                    } else
                        fprintf(stderr, "qspi-mcu: SHOT: cannot write %s\n",
                                g_shot_path);
                }
            }
        }
    }
    q.mode = 0;
    q.lanes = q.lanes_next;                    /* LINK_CFG applies between frames */
}

/* present the current master chunk on spi_sd_in, or release the bus to the
 * pull-ups (0xF) during the turnaround/response phase */
template <class TOP> static inline void qm_present(TOP* top)
{
    QspiMcuSim& q = g_qm;
    int L = q.lanes;
    uint8_t v = 0x0F;                          /* pull-ups own the bus */
    if (q.bytepos < q.mlen) {
        int shift = 8 - L * (q.chunk + 1);
        uint8_t c = (uint8_t)((q.tx[q.bytepos] >> shift) & ((1 << L) - 1));
        v = (uint8_t)((0x0F & ~((1 << L) - 1)) | c);
    }
    top->spi_sd_in = v;
}

/* sample the resolved pad chunk at the SCK rise (slave lanes per oe/out,
 * everything else pulled up; 1-lane samples the MISO pad = SD1) */
template <class TOP> static inline uint8_t qm_sample(TOP* top)
{
    QspiMcuSim& q = g_qm;
    int L = q.lanes;
    uint8_t oe  = (uint8_t)top->spi_sd_oe;
    uint8_t out = (uint8_t)top->spi_sd_out;
    if (L == 1)
        return (oe & 2) ? (uint8_t)((out >> 1) & 1) : (uint8_t)1;
    uint8_t chunk = 0;
    for (int i = 0; i < L; i++) {
        int pad;
        if (q.bytepos < q.mlen)
            pad = (top->spi_sd_in >> i) & 1;   /* our own driven level */
        else
            pad = ((oe >> i) & 1) ? ((out >> i) & 1) : 1;
        chunk |= (uint8_t)(pad << i);
    }
    return chunk;
}

template <class TOP> static inline void qspi_mcu_tick(TOP* top)
{
    if (!g_qspi_mcu_enabled) {
        return;                                /* pins keep their init state */
    }
    QspiMcuSim& q = g_qm;
    g_qm_cycles++;

    if (q.state == 0) {                        /* idle: decide next frame */
        if (q.gap) { q.gap--; return; }

        /* --biostest schedule + queued BIOS frames (work without a floppy) */
        uint32_t now_us = (uint32_t)(g_qm_cycles / g_qm_cyc_per_us);
        if (g_bios_t0 && q.bios_step == 0 && now_us >= g_bios_t0) {
            qm_bios_paint();
            q.bios_step = 1;
        }
        if (g_bios_t1 && q.bios_step == 1 && now_us >= g_bios_t1) {
            q.bq.push_back({0x20, 0x00});
            q.bios_step = 2;
        }
        for (size_t i = 0; i < g_btnmode_sched.size(); i++)
            if (g_btnmode_sched[i].first <= now_us) {
                q.bq.push_back({0x08, 0x01, g_btnmode_sched[i].second,
                                0, 0, 0, 0, 0});
                g_btnmode_sched.erase(g_btnmode_sched.begin() + (long)i);
                break;
            }
        for (size_t i = 0; i < g_drivemode_sched.size(); i++)
            if (g_drivemode_sched[i].first <= now_us) {
                /* mode 2 serves the DOS itself: put the drive model in
                 * high-level DOS mode so the command channel exists, and
                 * PARK the wire state machine — the firmware's
                 * iec1541DosLinkConfig() suspends core 1 for exactly this
                 * reason, and both transports share one floppy1541_t (see
                 * g_floppy_wire_park in iec_floppy_sim.h). */
#ifndef QM_NO_FLOPPY
                if (g_drivemode_sched[i].second == 2) {
                    floppy1541_dos_mode(&g_floppy, NULL);
                    g_floppy_wire_park = true;
                } else
                    g_floppy_wire_park = false;
#endif
                q.bq.push_back({0x0B, 0x01, g_drivemode_sched[i].second,
                                0, 0, 0, 0, 0});
                g_drivemode_sched.erase(g_drivemode_sched.begin() + (long)i);
                break;
            }
        /* --fdstat: the fabric-1541 status poll (see g_fdstat_ms) */
        if (g_fdstat_ms && now_us >= q.fdstat_next_us) {
            q.fdstat_next_us = now_us + g_fdstat_ms * 1000;
            q.bq.push_back({0x0D, 0x00, 0x00, 0x00, 0x00, 0x00});
        }
        /* ROM banks first: a ROM-free fabric is held in reset until they
         * land, so nothing else the model does matters before this. */
        if (!q.rom_sent && (!g_rom_push.empty() || !g_rom_push_bin.empty())) {
            q.rom_sent = true;
            qm_rom_queue();
        }
        if (!q.vol_sent && now_us >= 100000) {
            q.vol_sent = true;
            fprintf(stderr, "qspi-mcu: [%uus] SET_VOLUME %d (boot apply)\n",
                    now_us, g_qm_vol);
            q.bq.push_back({0x07, 0x01, (uint8_t)g_qm_vol, 0, 0, 0, 0, 0});
        }
        if (g_qm_lanes_want != 1 && !q.lanecfg_sent && now_us >= 200000) {
            q.lanecfg_sent = true;
            q.bq.push_back({0x0A, 0x01, (uint8_t)g_qm_lanes_want,
                            0, 0, 0, 0, 0});
        }
        if (q.bq_pos < q.bq.size()) {
            qm_start_frame(4, q.bq[q.bq_pos++]);
            if (q.bq_pos == q.bq.size()) { q.bq.clear(); q.bq_pos = 0; }
            return;
        }

        /* --shot sweep: freeze -> (arm line(s) -> poll ready -> read chunks)*
         * -> unfreeze (mode 5), the same sequence the board firmware's screen grab runs */
        if (g_shot_t0 && q.shot_step == 0 && now_us >= g_shot_t0) {
            q.shot_step = QM_SHOT_FREEZE ? 5 : 1;
            q.shot_line = 0;
            q.shot_sub = 0;
            q.shot_px.clear();
            q.shot_px.reserve((size_t)2 * QM_SHOT_W * QM_SHOT_H);
            fprintf(stderr, "qspi-mcu: [%uus] SHOT sweep start (%dx%d%s%s)\n",
                    now_us, QM_SHOT_W, QM_SHOT_H,
                    QM_SHOT_PAIR ? ", paired" : "",
                    QM_SHOT_FREEZE ? ", frozen" : "");
        }
        if (q.shot_step == 5) {                /* SHOT_FREEZE: halt machine */
            qm_start_frame(5, {0x33, 0x01});
            return;
        }
        if (q.shot_step == 6) {                /* SHOT_FREEZE: resume */
            qm_start_frame(5, {0x33, 0x00});
            return;
        }
        if (q.shot_step == 1) {                /* SHOT_ARM the next sim line */
            uint16_t pl = (uint16_t)(q.shot_line * QM_SHOT_VSTEP);
            qm_start_frame(5, {0x30, (uint8_t)(QM_SHOT_PAIR ? 0x02 : 0x00),
                               (uint8_t)(pl & 0xFF), (uint8_t)(pl >> 8)});
            return;
        }
        if (q.shot_step == 2) {                /* SHOT_STATUS until ready */
            qm_start_frame(5, {0x31, 0, 0, 0, 0});
            return;
        }
        if (q.shot_step == 3) {                /* SHOT_READ next chunk */
            int base = q.shot_sub ? 1024 : 0;  /* pair's 2nd line lands here */
            int n = 2 * QM_SHOT_W - q.shot_off;
            if (n > QM_SHOT_CHUNK) n = QM_SHOT_CHUNK;
            std::vector<uint8_t> f(
                (size_t)(4 + (q.lanes > 1 ? 1 : 0) + n), 0);
            f[0] = 0x32;
            f[1] = (uint8_t)((base + q.shot_off) & 0xFF);
            f[2] = (uint8_t)((base + q.shot_off) >> 8);
            qm_start_frame(5, std::move(f));
            return;
        }

#ifdef QM_NO_FLOPPY
        return;                 /* link only: no LOAD path to service */
#else
        if (!g_floppy_enabled) return;
        if (q.active && q.pos >= q.file.size()) {
            qm_start_frame(3, {0x12, q.end_flags});
        } else if (q.active && top->spi_req) {
            size_t n = q.file.size() - q.pos;
            if (n > 32) n = 32;
            std::vector<uint8_t> f = {0x11, (uint8_t)n};
            f.insert(f.end(), q.file.begin() + q.pos, q.file.begin() + q.pos + n);
            qm_start_frame(2, std::move(f));
        } else if (!q.active && top->spi_req) {
            std::vector<uint8_t> f(22, 0);
            f[0] = 0x10;
            qm_start_frame(1, std::move(f));
        } else if (q.active) {
            /* mid-transfer but REQ low: CPU stopped draining (hardware
             * watchdog will close the engine) — give up after ~2 s.
             * NOT while BIOS mode is on: the machine is frozen on purpose
             * (the FPGA watchdog is paused too) and resumes draining after
             * MODE_SET 0. */
            if (q.bios_step != 1 && ++q.stall > 56000000ull) {
                fprintf(stderr, "qspi-mcu: transfer stalled, aborting\n");
                q.active = false;
            }
        }
#endif  /* QM_NO_FLOPPY */
        return;
    }

    if (++q.divcnt < QM_HALF) return;
    q.divcnt = 0;

    if (q.state == 1) {                        /* assert SS, settle */
        top->spi_ss = 0;
        top->spi_sck = 0;
        qm_present(top);                       /* first chunk on the lanes */
        if (--q.gap == 0) { q.state = 2; q.phase = 0; }
        return;
    }

    if (q.state == 2) {                        /* clock chunks, mode 0 */
        int L = q.lanes;
        if (q.phase == 0) {
            top->spi_sck = 1;                  /* slave latches our lanes */
            {
                int shift = 8 - L * (q.chunk + 1);
                q.rx[q.bytepos] |= (uint8_t)(qm_sample(top) << shift);
            }
            q.phase = 1;
        } else {
            top->spi_sck = 0;
            q.phase = 0;
            if (++q.chunk >= 8 / L) {
                q.chunk = 0;
                q.bytepos++;
                if (q.bytepos >= q.tx.size()) {
                    q.state = 3;
                    q.gap = 4;
                    return;
                }
            }
            qm_present(top);
        }
        return;
    }

    if (q.state == 3) {                        /* deassert SS, settle */
        if (--q.gap == 0) {
            top->spi_ss = 1;
            top->spi_sck = 0;
            top->spi_sd_in = 0xF;              /* release the lanes */
            q.state = 0;
            q.gap = 8;
            qm_frame_done();
        }
        return;
    }
}
