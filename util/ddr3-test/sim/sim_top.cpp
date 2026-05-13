/*
 * sim_top.cpp — Verilator harness for the ddr3-test SoC.
 *
 * Runs the stripped-down soc with the behavioural ddr3_axi_sim memory.
 * Drives top->rx with a software UART transmitter sourced from stdin (or
 * a SIM_SCRIPT env var), prints decoded TX bytes to stdout.
 *
 * Usage
 *   ./obj_dir/Vddr3_test_soc                   # interactive — type chars
 *   SIM_SCRIPT="qw" ./obj_dir/Vddr3_test_soc   # send q then w then exit on idle
 *   SIM_MAX_CYCLES=2000000 ./obj_dir/...       # cap the run length
 *
 * UART_BIT_TIME (in soc clocks per bit) must match project.vh's value.
 */

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <queue>

#include "verilated.h"
#include "Vddr3_test_soc.h"

double sc_time_stamp() { return 0; }

/* UART bit period in clocks — must match the SIMULATION value in project.vh. */
static const int UART_BIT_TIME = 3;

static std::queue<uint8_t> tx_queue;     /* bytes to send to soc.rx */

static void uart_drive(Vddr3_test_soc* top) {
    static int     state = 0;            /* 0 idle / 1 start / 2..9 data / 10 stop */
    static int     cnt   = 0;
    static uint8_t byte  = 0;

    if (state == 0) {
        top->rx = 1;
        if (!tx_queue.empty()) {
            byte = tx_queue.front();
            tx_queue.pop();
            state = 1;
            cnt   = 0;
        }
        return;
    }
    if (++cnt < UART_BIT_TIME + 1) return;
    cnt = 0;

    if (state == 1)             { top->rx = 0; state = 2; }
    else if (state >= 2 && state <= 9) {
        top->rx = (byte >> (state - 2)) & 1u;
        state++;
    } else                       { top->rx = 1; state = 0; }
}

static void uart_print(Vddr3_test_soc* top) {
    static int     state = 0;
    static int     cnt   = 0;
    static uint8_t byte  = 0;
    static uint8_t prev  = 1;

    uint8_t cur = (uint8_t)top->tx;
    if (state == 0) {
        if (prev == 1 && cur == 0) { state = 1; cnt = 0; byte = 0; }
    } else {
        if (++cnt >= UART_BIT_TIME + 1) {
            cnt = 0;
            if (state <= 8) {
                if (cur) byte |= (1u << (state - 1));
                state++;
            } else {
                fputc(byte, stdout); fflush(stdout);
                state = 0;
            }
        }
    }
    prev = cur;
}

int main(int argc, char** argv) {
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vddr3_test_soc* top = new Vddr3_test_soc{ctx};

    /* SIM_SCRIPT: optional, otherwise stdin if interactive. */
    const char* script = getenv("SIM_SCRIPT");
    if (script) {
        for (const char* p = script; *p; ++p)
            tx_queue.push((uint8_t)*p);
    }

    long long max_cycles = 2000000;       /* default cap */
    if (const char* env = getenv("SIM_MAX_CYCLES"))
        max_cycles = atoll(env);

    /* Reset */
    top->rst     = 0;
    top->clk_sys = 0;
    top->clk_ddr = 0;
    top->rx      = 1;
    top->eval();

    long long cycle = 0;
    bool resetting  = true;

    while (!ctx->gotFinish() && cycle < max_cycles) {
        /* Simple in-phase clocking: clk_sys and clk_ddr stepped together. */
        top->clk_sys = 1; top->clk_ddr = 1; top->eval();
        if (resetting && cycle >= 32) { top->rst = 1; resetting = false; }

        uart_drive(top);
        uart_print(top);

        top->clk_sys = 0; top->clk_ddr = 0; top->eval();
        cycle++;
    }

    fprintf(stderr, "\n[sim done after %lld cycles]\n", cycle);
    delete top;
    delete ctx;
    return 0;
}
