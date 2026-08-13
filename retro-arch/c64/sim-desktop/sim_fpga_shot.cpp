/*
 * sim_fpga_shot.cpp — screen grab against the *FPGA* build of the C64 SoC.
 *
 * The regular --shot sweep in sim_top runs the SIMULATION video path (a
 * framebuffer replayed through lcd_out).  The board runs the other branch:
 * the genlocked line buffer in soc.v, whose de/vsync timing shot_cap.v
 * counts lines from.  That pairing — shot_cap on the real panel timing —
 * had never been simulated, which is exactly where a grab that works in sim
 * and dies on the board can hide.
 *
 * So: build the SoC with SIMULATION undefined, drive the QSPI link with the
 * same MCU model the other sims use (SHOT_ARM/STATUS/READ), and arm the
 * lines the way the board firmware's screen grab does — logical line * 2 on the 800x480
 * panel, 400 subsampled pixels per line.
 *
 * Usage: ./obj_dir_shot/Vsoc <exit_us> <out.ppm> [shot_t0_us]
 */
#define QM_NO_FLOPPY 1          /* link only: no 1541 model in this harness */
#define QM_SHOT_W    400        /* board geometry: 800x480 panel, subsampled */
#define QM_SHOT_H    240
#define QM_SHOT_VSTEP 2         /* panel line = logical line * 2 (shot.c) */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include "Vsoc.h"
#include "Vsoc___024root.h"     /* soc__DOT__cpu_rdy (public_flat_rd) */
#include "verilated.h"
#include "qspi_mcu_sim.h"

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    uint64_t exit_us  = (argc > 1) ? strtoull(argv[1], nullptr, 10) : 6000000;
    const char* out   = (argc > 2) ? argv[2] : "/tmp/c64_fpga_shot.ppm";
    uint32_t shot_t0  = (argc > 3) ? (uint32_t)strtoul(argv[3], nullptr, 10)
                                   : 3000000;

    /* feed the header's own arg parser a synthetic --shot/--qspi pair */
    char a0[] = "sim", a1[] = "--qspi", a2[] = "--shot", a3[300];
    snprintf(a3, sizeof a3, "%u:%s", shot_t0, out);
    char* qargv[] = {a0, a1, a2, a3};
    qspi_mcu_parse_args(4, qargv, 32);          /* ~31.5 MHz sys clock */

    Vsoc* top = new Vsoc;
    top->clk = 0; top->rst = 0; top->rx = 1;
    top->joy = 0x1F; top->btn = 0xFF;
    top->iec_clk_in = 1; top->iec_data_in = 1;
    top->spi_sck = 0; top->spi_ss = 1; top->spi_sd_in = 0xF;

    const uint64_t CYCLES_PER_US = 32;
    uint64_t max_cyc = exit_us * CYCLES_PER_US;

    /* panel-side sanity: what a real panel would latch, and how many de
     * lines a frame actually has — shot_cap can only capture lines that
     * exist, so a mismatch here explains a grab that never goes ready. */
    int prev_vs = 1, prev_de = 0, de_lines = 0, de_lines_frame = 0;

    /* freeze sanity: SHOT_FREEZE must halt the CPU (zero cpu_rdy ticks while
     * the grab runs) yet the panel must keep scanning (vsyncs still coming) */
    uint64_t frozen_rdy = 0, frozen_vs = 0;
    bool was_frozen = false;

    for (uint64_t cyc = 0; cyc < max_cyc; cyc++) {
        top->clk = 1; top->eval();
        if (cyc == 256) top->rst = 1;           // timed POR like the board

        int vs = top->lcd_vsync, de = top->lcd_de;
        if (de && !prev_de) de_lines++;
        if (!vs && prev_vs) {                   // vsync falling edge
            de_lines_frame = de_lines;
            de_lines = 0;
            if (g_qm.shot_frozen) frozen_vs++;
        }
        prev_vs = vs; prev_de = de;

        /* shot_step 6 = the freeze-off frame is in flight: the fabric drops
         * shot_freeze at the command byte, the model flag only at frame end —
         * cpu_rdy ticks in that tail are the machine resuming, not a leak */
        if (g_qm.shot_frozen && g_qm.shot_step != 6) {
            was_frozen = true;
            if (top->rootp->soc__DOT__cpu_rdy) frozen_rdy++;
        }

        qspi_mcu_tick(top);
        top->clk = 0; top->eval();
    }

    fprintf(stderr, "fpga-shot: de lines per frame = %d (panel expects 480)\n",
            de_lines_frame);
    fprintf(stderr, "fpga-shot: SHOT sweep reached line %d of %d\n",
            g_qm.shot_line, QM_SHOT_H);
    fprintf(stderr, "fpga-shot: freeze %s: cpu_rdy ticks while frozen = %llu"
            " (want 0), vsyncs while frozen = %llu (want > 0)\n",
            was_frozen ? "seen" : "NEVER SEEN",
            (unsigned long long)frozen_rdy, (unsigned long long)frozen_vs);
    int ok = (g_qm.shot_line >= QM_SHOT_H) &&
             was_frozen && frozen_rdy == 0 && frozen_vs > 0;
    delete top;
    return ok ? 0 : 1;
}
