/*
 * sim_fpga_video.cpp — Verilator harness for the *FPGA* build of the C64
 * SoC (SIMULATION undefined): exercises the real line-buffer video path
 * and the genlocked LCD timing generator, reconstructs what the 800x480
 * panel would latch from lcd_hsync/lcd_vsync/lcd_de/lcd_data, and writes
 * it to a PPM.  Also prints timing stats (hsync period, active px/line,
 * lines/frame) so panel-compatibility can be judged against the c16's
 * known-good numbers.
 *
 * Usage: ./obj_dir/Vsoc_fpga <exit_us> <out.ppm>
 */
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include "Vsoc.h"
#include "verilated.h"

static const int W = 800, H = 520;   // capture a bit more than 480
static uint16_t fb[W * H];

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    uint64_t exit_us = (argc > 1) ? strtoull(argv[1], nullptr, 10) : 7000000;
    const char* out = (argc > 2) ? argv[2] : "/tmp/fpga_video.ppm";

    Vsoc* top = new Vsoc;
    top->clk = 0; top->rst = 0; top->rx = 1;
    top->joy = 0x1F; top->btn = 0xFF;
    top->iec_clk_in = 1; top->iec_data_in = 1;

    uint64_t cyc = 0;
    const uint64_t CYCLES_PER_US = 32;          // ~31.5 MHz
    uint64_t max_cyc = exit_us * CYCLES_PER_US;

    int col = 0, line = 0;
    int prev_hs = 1, prev_vs = 1;
    int de_this_line = 0;
    // stats
    uint64_t last_hs_fall = 0, last_vs_fall = 0;
    long hs_period = 0, vs_period = 0;
    int active_px = 0, lines_per_frame = 0, de_lines = 0;

    while (cyc < max_cyc) {
        top->clk = 1; top->eval();
        if (cyc == 256) top->rst = 1;           // timed POR like the board

        if (top->lcd_de) {
            if (col < W && line >= 0 && line < H)
                fb[line * W + col] = (uint16_t)top->lcd_data;
            col++;
            de_this_line++;
        }
        int hs = top->lcd_hsync, vs = top->lcd_vsync;
        if (prev_hs && !hs) {                   // hsync falling edge
            hs_period = (long)(cyc - last_hs_fall);
            last_hs_fall = cyc;
            if (de_this_line) { active_px = de_this_line; de_lines++; }
            de_this_line = 0;
            col = 0; line++;
            lines_per_frame++;
        }
        if (prev_vs && !vs) {                   // vsync falling edge
            vs_period = (long)(cyc - last_vs_fall);
            last_vs_fall = cyc;
            line = -12;   // vsync fires at VIC line 285; first DE line ~297 later? realign below
            // Actually: count lines from vsync; DE lines start when raster wraps to LCD_VSTART.
            // We just reset to 0 and let the first DE line land where it lands.
            line = 0;
            lines_per_frame = 0;
            de_lines = 0;
        }
        prev_hs = hs; prev_vs = vs;

        top->clk = 0; top->eval();
        cyc++;
    }

    fprintf(stderr, "stats: hsync period %ld clk (%.2f kHz @31.5MHz), "
                    "active px/line %d, de lines/frame %d, vsync period %ld clk (%.2f Hz)\n",
            hs_period, hs_period ? 31527.955 / hs_period : 0.0,
            active_px, de_lines, vs_period,
            vs_period ? 31527955.0 / vs_period : 0.0);

    FILE* f = fopen(out, "wb");
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int i = 0; i < W * H; i++) {
        uint16_t p = fb[i];
        uint8_t rgb[3] = {
            (uint8_t)(((p >> 11) & 0x1F) << 3),
            (uint8_t)(((p >> 5) & 0x3F) << 2),
            (uint8_t)((p & 0x1F) << 3)
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    fprintf(stderr, "wrote %s\n", out);
    delete top;
    return 0;
}
