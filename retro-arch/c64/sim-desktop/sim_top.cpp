/*
 * sim_top.cpp — Commodore 64 Verilator + SDL2 desktop simulation
 *
 * Build:  cd retro-arch/c64/sim-desktop && make
 * Run:    ./obj_dir/Vsoc
 *
 * Keys: see retro-arch/common/sdl_kbd_input.h (shared PETSCII protocol,
 * arrows = cursor keys or joystick via the board buttons, F12 toggles).
 */

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <queue>
#include <vector>

#include "verilated.h"
#include "Vsoc.h"

/* The C64 CPU's PC, robust to Verilator's inlining choice: with a single
 * `cpu` instance the signal is flattened into the root; the FDRIVE build
 * instantiates a second one (the fabric 1541's) and the module becomes its
 * own class reached through a pointer. */
#ifdef FDRIVE
#include "Vsoc_cpu.h"
#define C64_CPU_PC ((uint16_t)top->rootp->__PVT__soc__DOT__cpu__DOT__cpu_inst->PC)
#else
#define C64_CPU_PC ((uint16_t)top->rootp->soc__DOT__cpu__DOT__cpu_inst__DOT__PC)
#endif
#include "Vsoc___024root.h"   /* fast-loader RAM access: top->rootp->soc__DOT__ram */

double sc_time_stamp() { return 0; }

#include <SDL.h>

/* Shared 1541 floppy + IEC-bus glue (same code for c16 / plus4 / c64). */
#include "iec_floppy_sim.h"
#include "qspi_mcu_sim.h"   /* --qspi: MCU model serving the fastload link */
/* Shared SDL keyboard/button input glue (PETSCII protocol + board buttons). */
#include "sdl_kbd_input.h"

static const int LCD_W     = 480;
static const int LCD_H     = 272;
static const int WIN_SCALE = 2;

static const int RESET_CYCLES = 32;
static const int UART_BIT_TIME = 3;

/* The C64 CPU (6510) advances once per phi cycle = once per 32 Verilator
 * clocks (the Kawari VIC divides dot4x by 32 into phi), so 32 clocks =
 * 1 sim-µs keeps the CPU:1541 ratio ~1:1 on the IEC bus.  (PAL phi is
 * really 0.985 MHz, so the emulated drive runs ~1.5% slow relative to the
 * computer — same direction as real-world drift, fine for the protocol
 * and fastloader handshakes.) */
static const int CYCLES_PER_US = 32;
static uint32_t  g_sim_us         = 0;
static int       g_us_cycle_count = 0;

/* ── SID audio capture ─────────────────────────────────────────────
 * soc.audio_pcm is one signed 16-bit sample per phi cycle (≈0.985 MHz,
 * sampled once per sim-µs).  --wav <path> / --audio; true WAV rate is
 * 985248/20 = 49262.4 Hz (header says 50000 — scale measured freqs). */
#include "sim_audio.h"
/* Scripted board-button presses for headless runs: --btn mask:start:end */
#include "sim_btn.h"

/* ── RGB565 → ARGB8888 ────────────────────────────────────────────── */
static uint32_t rgb565_to_argb8888(uint16_t px)
{
    uint32_t r = (px >> 11) & 0x1Fu;
    uint32_t g = (px >>  5) & 0x3Fu;
    uint32_t b = (px      ) & 0x1Fu;
    r = (r << 3) | (r >> 2);
    g = (g << 2) | (g >> 4);
    b = (b << 3) | (b >> 2);
    return (0xFFu << 24) | (r << 16) | (g << 8) | b;
}

/* ── Software UART transmitter ─────────────────────────────────────── */

static void uart_drive(Vsoc* top)
{
    static int     state     = 0;
    static int     clk_count = 0;
    static uint8_t tx_byte   = 0;

    if (state == 0) {
        top->rx = 1;
        if (!g_uart_queue.empty()) {
            tx_byte   = g_uart_queue.front();
            g_uart_queue.pop();
            state     = 1;
            clk_count = 0;
        }
        return;
    }

    if (++clk_count < UART_BIT_TIME + 1)
        return;
    clk_count = 0;

    if (state == 1) {
        top->rx = 0;        // start bit
        state   = 2;
    } else if (state >= 2 && state <= 9) {
        top->rx = (tx_byte >> (state - 2)) & 1u;
        state++;
    } else {
        top->rx = 1;        // stop bit
        state   = 0;
    }
}

/* ── Main ──────────────────────────────────────────────────────────── */

#ifndef SIM_TITLE
#define SIM_TITLE "Commodore 64 — Verilator Simulation"
#endif

/* ── EasyFlash cart (EASYFLASH builds) ──────────────────────────────
 * --ef <flat>        preload a 1 MiB flat cart image straight into the
 *                    behavioural PSRAM and force cart_mounted: the machine
 *                    boots from the cart at reset (Ultimax), no QSPI push.
 * --check-ef <us>    headless check: at <us> read the mk_ef_testcart.py
 *                    result tokens from RAM, print EF-TEST: PASS/FAIL,
 *                    exit(0/1).
 * --ef-verify c:file after --check-ef time, ALSO compare PSRAM chunk c
 *                    (c*0x40000) against <file> — verifies the qspi
 *                    ROM_BEGIN/DATA/END push path end-to-end.
 * --qspi-half N      sys clocks per SPI half period for the emulated MCU
 *                    (default 8).  The push FIFO in front of the PSRAM
 *                    writer has no flow control, so the loader is only
 *                    correct while the master is SLOWER than the drain:
 *                    this is how that limit gets measured instead of
 *                    guessed.  N=5 with --lanes 4 is the board's real
 *                    3 MHz 4-lane rate, which overflows.               */
static const char* g_ef_path     = nullptr;
static uint32_t    g_ef_check_us = 0;
static struct { int chunk; const char* path; } g_ef_verify[4];
static int         g_ef_nverify  = 0;
static bool        g_ef_trace    = false;   /* --ef-trace: PC ring buffer */
/* --ef-check: every byte the cart path commits to the CPU, checked against
 * the image that was loaded.  A game that dies on a single wrong byte deep
 * into a level load (PoP, 2026-08-06) cannot be found any other way: the
 * corruption lands in RAM and only kills minutes later. */
static bool        g_ef_check    = false;
static uint8_t*    g_ef_ref      = nullptr;
static uint32_t    g_ef_reads    = 0, g_ef_bad = 0;
/* --watch-w <addr>: log every CPU write to one address with the PC that did
 * it.  "which byte is wrong" is answerable from a RAM dump; "who put it
 * there" is not, and that is the half that names the bug. */
static int         g_watch_w     = -1;
static uint8_t     g_watch_last  = 0;
/* WATCH_AFTER=<us>: ignore writes before this time.  A cell that is written
 * constantly (a stack slot) is useless to watch from t=0 — the interesting
 * write is the one during the failure window. */
static uint32_t    g_watch_after = 0;
/* PC_TRAP=<lo>:<hi> — freeze a PC ring the first time the CPU enters a range.
 * The complement of --watch-w: that one names who wrote a byte, this one names
 * who jumped somewhere.  Power of two so the wrap is a mask. */
#define PC_TRAP_N 512
static int         g_pct_lo      = -1, g_pct_hi = -1;
/* PC_TRAP_AFTER=<us>: don't arm before this time.  A range that the program
 * enters LEGITIMATELY earlier on would otherwise freeze the ring on the wrong
 * event — Axe of Rage's boot stub really does `JMP $0100`, so trapping the
 * stack page from t=0 catches the boot, not the runaway 80 s later. */
static uint32_t    g_pct_after   = 0;
static unsigned    g_pct_last    = 0xFFFFFFFFu;
static uint64_t    g_pct_pos     = 0;
static int         g_pct_frozen  = 0;
static uint16_t    g_pct_ring[PC_TRAP_N];
static uint32_t    g_pct_us  [PC_TRAP_N];
static bool        g_ef_trace_frozen = false;
/* ~1.5 s of 6502 execution.  4096 entries covered 11 ms, which is fine for
 * "what did the wild jump do" and useless for "what went wrong during the
 * level load a second earlier".  8 bytes an entry, host-side only. */
#define EF_TRACE_N (1 << 19)
static struct { uint32_t us; uint16_t pc; uint8_t bank, mode; } g_trace[EF_TRACE_N];
static int         g_trace_wp    = 0;

static void ef_parse_args(int argc, char** argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--ef") && i + 1 < argc)
            g_ef_path = argv[++i];
        else if (!strcmp(argv[i], "--check-ef") && i + 1 < argc)
            g_ef_check_us = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--ef-trace"))
            g_ef_trace = true;
        else if (!strcmp(argv[i], "--qspi-half") && i + 1 < argc)
            qspi_mcu_set_half(atoi(argv[++i]));
        else if (!strcmp(argv[i], "--ef-check"))
            g_ef_check = true;
        else if (!strcmp(argv[i], "--watch-w") && i + 1 < argc) {
            g_watch_w = (int)strtoul(argv[++i], nullptr, 0);
            if (const char* wa = getenv("WATCH_AFTER"))
                g_watch_after = (uint32_t)strtoul(wa, nullptr, 0);
        }
        else if (!strcmp(argv[i], "--ef-verify") && i + 1 < argc && g_ef_nverify < 4) {
            char* a = argv[++i];
            char* c = strchr(a, ':');
            if (c) { *c = 0; g_ef_verify[g_ef_nverify].chunk = atoi(a);
                     g_ef_verify[g_ef_nverify].path = c + 1; g_ef_nverify++; }
        }
    }
}

#ifdef EASYFLASH
static uint8_t* ef_psram_mem(Vsoc* top)
{
#ifdef FDRIVE
    /* combined bit: cart and drive share psram_cmd_behav through psram_hub,
     * so the cart image goes into the behavioural array (offset 0 — the
     * drive lives at 0x200000, see drive_psram.v's map) */
    return (uint8_t*)&top->rootp->soc__DOT__fd_ps0__DOT__mem[0];
#else
    return (uint8_t*)&top->rootp->soc__DOT__psram_chip0__DOT__mem[0];
#endif
}

/* Result contract with roms/mk_ef_testcart.py:
 *   $03C0/$03C1 = $EF $64  base tests passed (PLA, banking, EF RAM, kill)
 *   $03C4/$03C5 = $EF $65  flash tests passed (autoselect, program, erase)
 *   $03C0 = $BA            failed; $03C1 = stage, $03C2 = aux, $03C3 = got
 *   $02                    progress marker (last stage reached)          */
static int ef_check_result(Vsoc* top)
{
    auto& ram = top->rootp->soc__DOT__ram;
    int t0 = ram[0x03C0], t1 = ram[0x03C1];
    int f0 = ram[0x03C4], f1 = ram[0x03C5];
    int prog = ram[0x02];
    if (t0 == 0xBA) {
        fprintf(stderr, "EF-TEST: FAIL stage=%d aux=$%02X got=$%02X (progress=%d)\n",
                t1, ram[0x03C2], ram[0x03C3], prog);
        return 1;
    }
    if (t0 == 0xEF && t1 == 0x64 && f0 == 0xEF && f1 == 0x65) {
        fprintf(stderr, "EF-TEST: PASS (base + flash, progress=%d)\n", prog);
        return 0;
    }
    if (t0 == 0xEF && t1 == 0x64) {
        fprintf(stderr, "EF-TEST: FAIL flash tests never finished (progress=%d)\n", prog);
        return 1;
    }
    fprintf(stderr, "EF-TEST: FAIL inconclusive $03C0=$%02X (progress=%d)\n", t0, prog);
    return 1;
}

static int ef_verify_push(Vsoc* top)
{
    int rc = 0;
    if (g_ef_nverify) {
        /* The FIFO in front of the PSRAM writer has NO flow control: a master
         * faster than the drain rate loses bytes, the image ends up full of
         * holes, and every bank still reports valid — a blank screen with
         * nothing to see.  The byte-compare below can miss it (a dropped byte
         * that happened to be $FF reads back correct), so the counter is the
         * real gate.  Board-reported 2026-08-06; the fix was to push at one
         * lane.  Run with --qspi-half to find where the limit actually is. */
        uint8_t ovr = top->rootp->soc__DOT__ef0__DOT__push_ovr;
        fprintf(stderr, "EF-PUSH: loader drops = %u\n", ovr);
        if (ovr) {
            fprintf(stderr, "EF-PUSH: FAIL the master outran the PSRAM writer\n");
            rc = 1;
        }
    }
    for (int i = 0; i < g_ef_nverify; i++) {
        FILE* f = fopen(g_ef_verify[i].path, "rb");
        if (!f) { fprintf(stderr, "EF-PUSH: cannot open %s\n", g_ef_verify[i].path); return 1; }
        uint8_t* mem = ef_psram_mem(top);
        long base = (long)g_ef_verify[i].chunk * 0x40000;
        long off = 0; int c; long bad = -1, nbad = 0;
        while ((c = fgetc(f)) != EOF) {
            if (mem[base + off] != (uint8_t)c) { if (bad < 0) bad = off; nbad++; }
            off++;
        }
        fclose(f);
        if (bad >= 0) {
            /* how many and where matters: ONE bad byte is a lost push, a bad
             * byte every N is a rate problem, and everything-after-X is the
             * writer having walked off its address */
            fprintf(stderr, "EF-PUSH: FAIL chunk %d — %ld of %ld bytes differ, "
                    "first at +0x%lX (psram=$%02X)\n",
                    g_ef_verify[i].chunk, nbad, off, bad, mem[base + bad]);
            rc = 1;
        } else
            fprintf(stderr, "EF-PUSH: chunk %d OK (%ld bytes)\n", g_ef_verify[i].chunk, off);
    }
    if (!rc && g_ef_nverify) fprintf(stderr, "EF-PUSH: PASS\n");
    return rc;
}
#endif

int main(int argc, char** argv)
{
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};
    ef_parse_args(argc, argv);

    if (const char* pt = getenv("PC_TRAP")) {          /* "lo:hi", hex */
        unsigned lo = 0, hi = 0;
        if (sscanf(pt, "%x:%x", &lo, &hi) == 2) {
            g_pct_lo = (int)lo; g_pct_hi = (int)hi;
            if (const char* af = getenv("PC_TRAP_AFTER"))
                g_pct_after = (uint32_t)strtoul(af, nullptr, 0);
            fprintf(stderr, "PC_TRAP: freeze the PC ring on entry to "
                            "$%04X-$%04X after %u us (%d entries)\n",
                            lo, hi, g_pct_after, PC_TRAP_N);
        } else
            fprintf(stderr, "bad PC_TRAP '%s' (want lo:hi in hex)\n", pt);
    }

    /* Shared 1541 floppy + IEC glue: parse CLI, init drive (device 8). */
    iec_floppy_parse_args(argc, argv, 8);

    /* SID audio options (unknown flags are ignored by the shared parser) */
    sim_audio_parse_args(argc, argv);
    sim_btn_parse_args(argc, argv);
    sim_joy_parse_args(argc, argv);
    qspi_mcu_parse_args(argc, argv, CYCLES_PER_US);

    /* Fast-load config — C64 KERNAL: LOAD vector $0330, SETNAM→$B7/$BB,
     * SETLFS→$B9, LOAD saves reloc addr to $C3/$C4.  Stub in cassette buffer. */
    g_flcfg = { /*load_vec*/0x0330, /*stub*/0x033C, /*fnadr*/0xBB, /*fnlen*/0xB7,
                /*sa*/0xB9, /*reloc_ptr*/0xC3, /*status*/0x90,
                /*ram_mask*/0xFFFF, /*valid*/true,
                /*kernal_load_default*/0xF4A5 };

    /* ── SDL2 init (skipped in --headless mode) ── */
    SDL_Window*   window   = nullptr;
    SDL_Renderer* renderer = nullptr;
    SDL_Texture*  texture  = nullptr;
    if (!g_headless) {
        if (SDL_Init(SDL_INIT_VIDEO | sim_audio_sdl_flags()) < 0) {
            fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
            return 1;
        }
        SDL_StartTextInput();
        sim_audio_open();

        window = SDL_CreateWindow(
            SIM_TITLE,
            SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
            LCD_W * WIN_SCALE, LCD_H * WIN_SCALE,
            0);
        if (!window) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return 1; }

        renderer = SDL_CreateRenderer(
            window, -1,
            SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
        if (!renderer) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return 1; }

        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
        SDL_RenderSetLogicalSize(renderer, LCD_W, LCD_H);

        texture = SDL_CreateTexture(
            renderer,
            SDL_PIXELFORMAT_ARGB8888,
            SDL_TEXTUREACCESS_STREAMING,
            LCD_W, LCD_H);
        if (!texture) { fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError()); return 1; }
    }

    /* ── Framebuffer ── */
    static uint32_t fb[LCD_W * LCD_H];
    memset(fb, 0, sizeof(fb));

    /* ── Simulation state ── */
    int  pixel_idx  = 0;
    bool prev_vsync = true;
    bool running    = true;
    int  rst_count  = 0;

    /* ── Assert reset ── */
    top->rst = 0;
    top->rx  = 1;
    top->clk = 0;
    top->iec_clk_in  = 1;   /* released */
    top->iec_data_in = 1;
    top->spi_ss    = 1;    /* link deselected until the MCU model speaks */
    top->spi_sck   = 0;
    top->spi_sd_in = 0xF;  /* all lanes idle high (board pull-ups) */
    top->joy = 0x1F;  /* all released (active-low) */
    top->btn = 0xFF;  /* all released (active-low) */
    top->eval();

#ifdef EASYFLASH
    /* AFTER the first eval (the model's junk-fill initial has run), drop
     * the flat cart image into the behavioural PSRAM and force the mount:
     * reset is still asserted, so the machine boots straight into the
     * cart's Ultimax reset vector — the same first fetch the board does. */
    if (g_ef_path) {
        FILE* f = fopen(g_ef_path, "rb");
        if (!f) { fprintf(stderr, "--ef: cannot open %s\n", g_ef_path); return 1; }
        size_t n = fread(ef_psram_mem(top), 1, 8u << 20, f);
        fclose(f);
        /* keep a reference copy: --ef-check compares every byte the cart
         * path hands the CPU against what the image says it should be */
        g_ef_ref = (uint8_t*)malloc(1u << 20);
        if (g_ef_ref) memcpy(g_ef_ref, ef_psram_mem(top), 1u << 20);
        top->rootp->soc__DOT__cart_force = 1;
        fprintf(stderr, "EasyFlash: %zu bytes preloaded from %s, cart mounted\n",
                n, g_ef_path);
    }
#else
    if (g_ef_path) {
        fprintf(stderr, "--ef needs an EASYFLASH build (make ... EASYFLASH=1?)\n");
        return 1;
    }
#endif

    if (!g_headless)
        retro_kbd_init(window, SIM_TITLE);

    fprintf(stderr,
        SIM_TITLE " — started.\n"
        "LCD: %d x %d  window: %d x %d\n"
        "Controls: type normally, ESC = quit\n"
        "Arrows: CURSOR keys (default) or JOYSTICK — F12 toggles, Ctrl=fire/RETURN\n"
        "F1-F8=function keys  F9=RUN/STOP  Home/Ins/Del as labeled\n",
        LCD_W, LCD_H, LCD_W * WIN_SCALE, LCD_H * WIN_SCALE);

    /* ── Main simulation loop ── */
    long long cycle_count = 0;
    int last_dbg = -1;

    /* GAME_PRG autorun now lives in RTL (common/boot_typer.v reads
     * roms/autorun.hex), so the sim exercises the same hands-free path the
     * FPGA bitstream uses.  No C++-side typing needed. */

    while (running && !ctx->gotFinish())
    {
        /* Rising edge */
        top->clk = 1;
        top->eval();
        cycle_count++;

        /* Release reset */
        if (rst_count < RESET_CYCLES) {
            if (++rst_count == RESET_CYCLES)
                top->rst = 1;
        }

        /* IEC: fine feedback every cycle, advance drive once per sim-µs. */
        iec_floppy_feedback(top);
        fastload_trap(top, (uint16_t)top->dbg_cpu_addr);
        qspi_mcu_tick(top);

        if (getenv("QSPI_DEBUG")) {
            static uint16_t qprev = 0;
            uint16_t a = (uint16_t)top->dbg_cpu_addr;
            if (a != qprev &&
                (a == 0xF4A5 || (a >= 0xDE00 && a <= 0xDE7F) ||
                 (a >= 0xDF00 && a <= 0xDF02))) {
                static int budget = 60;
                if (budget > 0) { budget--;
                    fprintf(stderr, "[qspi-cpu] addr=$%04X\n", a);
                }
            }
            qprev = a;
        }
        if (++g_us_cycle_count >= CYCLES_PER_US) {
            g_us_cycle_count = 0;
            g_sim_us++;
#ifdef EASYFLASH
            /* --ef-trace: ring of executed PCs (+EF bank/mode), frozen the
             * moment the game's BRK crash-trap is entered, dumped at exit —
             * finds the wild jump that a plain exit dump can't (the trap
             * spins forever, flushing every histogram). */
            if (g_ef_trace) {
                static uint16_t prev_pc = 0;
                uint16_t pc = C64_CPU_PC;
                if (pc != prev_pc && !g_ef_trace_frozen) {
                    prev_pc = pc;
                    g_trace[g_trace_wp] = { g_sim_us, pc,
                        (uint8_t)top->rootp->soc__DOT__ef_bank,
                        (uint8_t)top->rootp->soc__DOT__ef_mode };
                    g_trace_wp = (g_trace_wp + 1) % EF_TRACE_N;
                    if (pc >= 0x0538 && pc <= 0x0543) {  /* PoP BRK trap
                        (Arlet's PC register runs a fetch ahead, so match
                        the whole trap range, not one address) */
                        g_ef_trace_frozen = true;
                        fprintf(stderr, "[ef-trace] BRK trap entered at %u us — ring frozen\n",
                                g_sim_us);
                    }
                }
            }
            if (g_ef_check_us && g_sim_us >= g_ef_check_us) {
                /* a push-only run has no test cart executing, so its RAM
                 * result tokens are meaningless — asking for them printed a
                 * "FAIL inconclusive" next to a passing push */
                int rc = (g_ef_nverify ? 0 : ef_check_result(top))
                       | ef_verify_push(top);
                top->final();
                return rc;
            }
#endif
            sim_audio_sample((int16_t)top->audio_pcm);
            if (sim_btn_active()) top->btn = sim_btn_frame(g_sim_us);
            if (sim_joy_active()) top->joy = sim_joy_frame(g_sim_us);
            iec_floppy_step(top, g_sim_us);
            if (getenv("ST_DEBUG")) {
                /* watch the KERNAL serial status byte $90 (and $A5 EOI
                 * counter): FNF/timeout diagnosis for IEC bring-up */
                static int pst = -1, pa5 = -1;
                int st = (int)top->rootp->soc__DOT__ram[0x90];
                int a5 = (int)top->rootp->soc__DOT__ram[0xA5];
                if (st != pst || a5 != pa5) {
                    fprintf(stderr, "[%7u us] ST=$%02X A5=$%02X\n",
                            g_sim_us, st, a5);
                    pst = st; pa5 = a5;
                }
            }
            if (getenv("IEC_DEBUG")) {
                static int pa=-1,pc=-1,pd=-1,poc=-1,pod=-1;
                int a=top->iec_atn_out, c=top->iec_clk_out, d=top->iec_data_out;
                if (a!=pa||c!=pc||d!=pd||g_floppy.out_clk!=poc||g_floppy.out_data!=pod){
                    fprintf(stderr,"[%7u us] C64 atn=%d clk=%d data=%d  drive out_clk=%d out_data=%d drive_cyc=%llu\n",
                        g_sim_us,a,c,d,g_floppy.out_clk,g_floppy.out_data,
                        (unsigned long long)g_floppy.cpu.cycles);
                    pa=a;pc=c;pd=d;poc=g_floppy.out_clk;pod=g_floppy.out_data;
                }
            }
        }

        uart_drive(top);

        /* UART TX sniffer: decodes the FPGA->MCU serial line so the debug
         * 'P' status dump is visible in simulation.  UART_BIT_TIME=3 in
         * sim builds and uart.v's real bit period is BIT_TIME+1 clocks. */
        {
            static const int BT = 3 + 1;
            static int st = 0, prev_tx = 1, t = 0, nbits = 0;
            static unsigned byte = 0;
            static char lbuf[128];
            static int llen = 0;
            int txv = (int)top->tx;
            if (st == 0) {
                if (prev_tx && !txv) { st = 1; t = 0; nbits = 0; byte = 0; }
            } else if (++t == BT + BT/2 + nbits*BT) {  /* middle of data bit */
                byte |= (unsigned)txv << nbits;
                if (++nbits == 8) {
                    if (byte == '\n' || llen >= 120) {
                        lbuf[llen] = 0;
                        fprintf(stderr, "uart-tx: %s\n", lbuf);
                        llen = 0;
                    } else if (byte != '\r') {
                        lbuf[llen++] = (byte >= 32 && byte < 127) ? (char)byte : '.';
                    }
                    st = 0;
                }
            }
            prev_tx = txv;
        }

        /* Temporary VIC-read trace: dump signals around $D011 reads */
        if (getenv("VICREAD_DEBUG")) {
            static int trace = 0;
            if ((uint16_t)top->dbg_cpu_addr == 0xD011) trace = 40;
            if (trace > 0) {
                trace--;
                fprintf(stderr, "[t] phi=%d aec=%d addr=%04X adl=%02X ald=%d dbo=%02X din=%02X\n",
                    (int)(top->rootp->soc__DOT__vic0__DOT__phi_gen & 1),
                    (int)top->rootp->soc__DOT__vic_aec,
                    (int)(uint16_t)top->dbg_cpu_addr,
                    (int)top->rootp->soc__DOT__vic0__DOT__vic_registers__DOT__addr_latched,
                    (int)top->rootp->soc__DOT__vic0__DOT__vic_registers__DOT__addr_latch_done,
                    (int)top->rootp->soc__DOT__vic_dbo,
                    (int)top->rootp->soc__DOT__cpu_data_in);
            }
        }

        /* RAM watch (RAM_WATCH=<hex addr>): one line per value change, once
         * per sim-µs.  Used to follow a game's own state flags — e.g. Save
         * New York gates its demo-exit key test on $C1E8 bit 7. */
        if (g_us_cycle_count == 0) {
            static const char* wa = getenv("RAM_WATCH");
            if (wa) {
                static uint16_t addr = (uint16_t)strtoul(wa, nullptr, 16);
                static int prev = -1;
                int v = (int)top->rootp->soc__DOT__ram[addr];
                if (v != prev) {
                    fprintf(stderr, "[%7u us] $%04X = $%02X\n", g_sim_us, addr, v);
                    prev = v;
                }
            }
        }

        /* Keyboard-port trace (KBD_DEBUG): every read of CIA1 $DC00/$DC01
         * with the row select the game sees.  Games that never write PRA
         * themselves (Save New York) inherit whatever the last KERNAL
         * SCNKEY left there — this shows which row is actually selected. */
        if (getenv("KBD_DEBUG")) {
            static uint16_t kprev = 0;
            static int budget = 400;
            uint16_t a = (uint16_t)top->dbg_cpu_addr;
            static uint32_t from_us = (uint32_t)atoi(getenv("KBD_DEBUG"));
            if (a != kprev && (a == 0xDC00 || a == 0xDC01) && budget > 0 &&
                g_sim_us >= from_us) {
                budget--;
                fprintf(stderr,
                    "[%7u us] read $%04X  pa_out=%02X rowsel=%02X pa_in=%02X "
                    "matrix=%016llX\n",
                    g_sim_us, a,
                    (int)top->rootp->soc__DOT__cia1_pa_out,
                    (int)top->rootp->soc__DOT__key_row_select,
                    (int)top->rootp->soc__DOT__cia1_pa_in,
                    (unsigned long long)top->rootp->soc__DOT__typer_matrix);
            }
            kprev = a;
        }

        /* LCD pixel capture */
        if (top->lcd_de && pixel_idx < LCD_W * LCD_H) {
            fb[pixel_idx] = rgb565_to_argb8888((uint16_t)top->lcd_data);
            pixel_idx++;
        }

        /* Frame boundary: vsync falling edge — update display + auto-typer */
        bool cur_vsync = (bool)top->lcd_vsync;
        if (prev_vsync && !cur_vsync) {
            if (!g_headless) {
                SDL_UpdateTexture(texture, NULL, fb, LCD_W * (int)sizeof(uint32_t));
                SDL_RenderClear(renderer);
                SDL_RenderCopy(renderer, texture, NULL, NULL);
                SDL_RenderPresent(renderer);
            }
            pixel_idx = 0;
            autotype_tick(g_sim_us);
            fastload_maintain(top);
            screenshot_tick(g_sim_us, fb, LCD_W, LCD_H);
            if (g_exit_us && g_sim_us >= g_exit_us) running = false;
        }
        prev_vsync = cur_vsync;

        /* Poll SDL events every 100K clocks */
        if (!g_headless && cycle_count % 100000 == 0) {
            SDL_Event ev;
            while (SDL_PollEvent(&ev))
                retro_kbd_event(&ev, &running);   /* shared key/button glue */
            top->btn = retro_kbd_btn_frame();
        }

        /* Watch the RAM CELL, not the CPU write cycle: the RAM commit fires
         * on phi2_n while the rdy tick is separately gated by the cart
         * stall, so a "write happened" test on cpu_rdy misses commits and a
         * test on cpu_we misses whoever else can reach the array.  A cell
         * that changes with no CPU write behind it is the interesting case
         * and this is the only way to see it. */
        /* PC_TRAP=<lo>:<hi> (hex): ring of the last PC_TRAP_N distinct PCs,
         * FROZEN the first time the PC enters [lo,hi].  "Where did it come
         * from" is the one question a hot-PC sample cannot answer — by the
         * time a runaway is visible the trail is gone.  Freezing on ENTRY
         * keeps the instructions that jumped there.
         *
         * Records only on a CHANGE of PC, so one entry per instruction rather
         * than one per clock, and only while the CPU is really ticking. */
        if (g_pct_lo >= 0) {
            unsigned pc = (unsigned)
                C64_CPU_PC;
            if (pc != g_pct_last && top->rootp->soc__DOT__cpu_rdy) {
                g_pct_last = pc;
                if (!g_pct_frozen) {
                    g_pct_ring[g_pct_pos & (PC_TRAP_N - 1)] = (uint16_t)pc;
                    g_pct_us  [g_pct_pos & (PC_TRAP_N - 1)] = g_sim_us;
                    g_pct_pos++;
                    if ((int)pc >= g_pct_lo && (int)pc <= g_pct_hi &&
                        g_sim_us >= g_pct_after) {
                        g_pct_frozen = 1;
                        fprintf(stderr, "PC_TRAP: [%u us] PC entered "
                                "$%04X-$%04X at $%04X; last %d PCs:\n",
                                g_sim_us, g_pct_lo, g_pct_hi, pc,
                                (int)(g_pct_pos < PC_TRAP_N
                                      ? g_pct_pos : PC_TRAP_N));
                        uint64_t n = g_pct_pos < PC_TRAP_N
                                     ? g_pct_pos : PC_TRAP_N;
                        for (uint64_t k = 0; k < n; k++) {
                            uint64_t idx = g_pct_pos - n + k;
                            fprintf(stderr, "  %6llu us  $%04X\n",
                                    (unsigned long long)
                                        g_pct_us[idx & (PC_TRAP_N - 1)],
                                    g_pct_ring[idx & (PC_TRAP_N - 1)]);
                        }
                    }
                }
            }
        }
        if (g_watch_w >= 0 && g_sim_us >= g_watch_after &&
            top->rootp->soc__DOT__ram[g_watch_w] != g_watch_last) {
            fprintf(stderr, "WATCH: [%u us] $%04X: $%02X -> $%02X  "
                    "(pc=%04X we=%d a=%04X do=%02X bank=%02X mode=%02X)\n",
                    g_sim_us, g_watch_w, g_watch_last,
                    (unsigned)top->rootp->soc__DOT__ram[g_watch_w],
                    (unsigned)C64_CPU_PC,
                    (int)top->rootp->soc__DOT__cpu_we,
                    (unsigned)(uint16_t)top->dbg_cpu_addr,
                    (unsigned)top->rootp->soc__DOT__cpu_data_out,
#ifdef EASYFLASH
                    (unsigned)top->rootp->soc__DOT__ef_bank,
                    (unsigned)top->rootp->soc__DOT__ef_mode);
#else
                    0u, 0u);
#endif
            g_watch_last = top->rootp->soc__DOT__ram[g_watch_w];
        }
#ifdef EASYFLASH
        /* --ef-check: the cart path just handed the CPU a byte — is it the
         * byte the image holds?  The address is the one latched at the rdy
         * tick (dbg_addr_q), the bank is the live $DE00, and the chip is
         * which window the address falls in ($8000 = ROML, $A000/$E000 =
         * ROMH), i.e. exactly the flat layout crt2flat.py writes. */
        if (g_ef_check && g_ef_ref &&
            top->rootp->soc__DOT__ef_commit && top->rootp->soc__DOT__sel_cart_q) {
            uint16_t a    = (uint16_t)top->rootp->soc__DOT__dbg_addr_q;
            uint8_t  got  = (uint8_t)top->rootp->soc__DOT__ef_rdata_q;
            uint8_t  bank = (uint8_t)(top->rootp->soc__DOT__ef_bank & 0x3F);
            int      chip = (a >= 0xA000) ? 1 : 0;
            uint32_t flat = (uint32_t)chip * 0x80000u
                          + (uint32_t)bank * 0x2000u + (a & 0x1FFF);
            uint8_t  want = g_ef_ref[flat];
            g_ef_reads++;
            if (got != want && g_ef_bad < 20) {
                g_ef_bad++;
                fprintf(stderr, "EF-CHECK: [%u us] $%04X bank=%02X chip=%d "
                        "flat=%05X got=$%02X want=$%02X  (read #%u)\n",
                        g_sim_us, a, bank, chip, flat, got, want, g_ef_reads);
            }
        }
#endif
        /* Falling edge */
        top->clk = 0;
        top->eval();
    }

#ifdef EASYFLASH
    if (g_ef_check)
        fprintf(stderr, "EF-CHECK: %u cart reads, %u wrong\n",
                g_ef_reads, g_ef_bad);
    if (g_ef_trace) {
        FILE* tf = fopen("/tmp/ef_trace.txt", "w");
        fprintf(tf ? tf : stderr, "[ef-trace] last %d PCs before %s:\n",
                EF_TRACE_N,
                g_ef_trace_frozen ? "the BRK trap" : "exit (trap never hit)");
        for (int i = 0; i < EF_TRACE_N; i++) {
            int idx = (g_trace_wp + i) % EF_TRACE_N;
            if (g_trace[idx].us == 0 && g_trace[idx].pc == 0) continue;
            fprintf(tf ? tf : stderr, "[%8u us] pc=%04X bank=%02X mode=%02X\n",
                    g_trace[idx].us, g_trace[idx].pc,
                    g_trace[idx].bank, g_trace[idx].mode);
        }
        if (tf) { fclose(tf); fprintf(stderr, "[ef-trace] ring written to /tmp/ef_trace.txt\n"); }
    }
#endif

    /* Exit diagnostic: sample the CPU address bus over the last few phi
     * cycles so a hung/looping CPU is immediately localizable. */
    {
        uint16_t lo = 0xFFFF, hi = 0;
        for (int i = 0; i < 32 * 400; i++) {
            top->clk = 1; top->eval();
            top->clk = 0; top->eval();
            uint16_t a = (uint16_t)top->dbg_cpu_addr;
            if (a < lo) lo = a;
            if (a > hi) hi = a;
        }
        {   /* text screen at $0400 as PETSCII -> ASCII, blank lines dropped:
             * the fastest way to see what BASIC actually said (error message,
             * prompt state) on a headless run. */
            fprintf(stderr, "exit: screen:\n");
            for (int row = 0; row < 25; row++) {
                char line[41];
                int any = 0;
                for (int col = 0; col < 40; col++) {
                    uint8_t sc = top->rootp->soc__DOT__ram[0x0400 + row * 40 + col];
                    char c = ' ';
                    if (sc >= 1 && sc <= 26)       c = (char)('A' + sc - 1);
                    else if (sc >= 48 && sc <= 57) c = (char)sc;
                    else if (sc == 32 || sc == 0)  c = ' ';
                    else if (sc >= 33 && sc <= 47) c = (char)sc;
                    else if (sc >= 58 && sc <= 63) c = (char)sc;
                    else                            c = '.';
                    if (c != ' ') any = 1;
                    line[col] = c;
                }
                line[40] = 0;
                if (any) fprintf(stderr, "  |%s|\n", line);
            }
        }
        fprintf(stderr, "exit: cpu addr window [$%04X..$%04X]  kbd $C6=%d  $0801=%02X %02X  $0810=%02X\n",
                lo, hi,
                top->rootp->soc__DOT__ram[0xC6],
                top->rootp->soc__DOT__ram[0x0801], top->rootp->soc__DOT__ram[0x0802],
                top->rootp->soc__DOT__ram[0x0810]);
        /* Where is the CPU? Sample the (registered) PC over ~12k phi cycles
         * and print the hottest addresses — a hung/looping program shows up
         * as 2-5 dominant PCs, ready to disassemble from the RAM dump. */
        {
            static uint32_t pc_hist[65536];
            memset(pc_hist, 0, sizeof(pc_hist));
            for (int i = 0; i < 32 * 12000; i++) {
                top->clk = 1; top->eval();
                top->clk = 0; top->eval();
                pc_hist[C64_CPU_PC & 0xFFFF]++;
            }
            fprintf(stderr, "exit: hot PCs:");
            for (int rank = 0; rank < 6; rank++) {
                uint32_t best = 0; int besta = -1;
                for (int a = 0; a < 65536; a++)
                    if (pc_hist[a] > best) { best = pc_hist[a]; besta = a; }
                if (besta < 0 || best == 0) break;
                fprintf(stderr, " $%04X(x%u)", besta, best / 32);
                pc_hist[besta] = 0;
            }
            fprintf(stderr, "\n");
        }
        if (const char* rd = getenv("RAM_DUMP")) {
            FILE* rf = fopen(rd, "wb");
            if (rf) {
                for (int a = 0; a < 65536; a++) fputc(top->rootp->soc__DOT__ram[a], rf);
                fclose(rf);
                fprintf(stderr, "exit: RAM dumped to %s\n", rd);
            }
        }
        fprintf(stderr, "exit: VIC den=%d ecm=%d bmm=%d rsel=%d csel=%d ec=%X b0c=%X sprite_en=%02X\n",
                (int)top->rootp->soc__DOT__vic0__DOT__den,
                (int)top->rootp->soc__DOT__vic0__DOT__ecm,
                (int)top->rootp->soc__DOT__vic0__DOT__bmm,
                (int)top->rootp->soc__DOT__vic0__DOT__rsel,
                (int)top->rootp->soc__DOT__vic0__DOT__csel,
                (int)top->rootp->soc__DOT__vic0__DOT__ec,
                (int)top->rootp->soc__DOT__vic0__DOT__b0c,
                (int)top->rootp->soc__DOT__vic0__DOT__sprite_en);
    }

    /* Cleanup */
    top->final();

    if (g_screenshot_path)
        dump_ppm(g_screenshot_path, fb, LCD_W, LCD_H);

    sim_audio_finish();

    delete top;
    delete ctx;

    if (!g_headless) {
        SDL_DestroyTexture(texture);
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
    }

    return 0;
}
