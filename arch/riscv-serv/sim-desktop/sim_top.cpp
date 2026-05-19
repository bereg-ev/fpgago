/*
 * sim_top.cpp — Verilator harness for the riscv-darkrv minimal SoC.
 *
 * Drives clock + reset, watches uart_tx_pulse, and prints each byte the
 * SoC pushes to UART_TX to stdout.  Exits after either:
 *   - N cycles (set via SIM_MAX_CYCLES env, default 10000), or
 *   - SIM_EXIT_ON_NEWLINE=1 + a '\n' arrives.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <verilated.h>
#include "Vsoc.h"

int main(int argc, char** argv)
{
    const char* mc_env  = getenv("SIM_MAX_CYCLES");
    unsigned long max_cycles = mc_env ? strtoul(mc_env, nullptr, 0) : 10000;
    const char* eol_env = getenv("SIM_EXIT_ON_NEWLINE");
    bool exit_on_nl = eol_env && (*eol_env == '1');

    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vsoc* top = new Vsoc{ctx};

    // Hold reset low for a few cycles, then release.
    top->rst = 0;
    top->clk = 0;

    unsigned long cyc = 0;
    while (cyc < max_cycles && !ctx->gotFinish())
    {
        if (cyc == 5)
            top->rst = 1;

        top->clk = 1;
        top->eval();

        if (top->uart_tx_pulse) {
            uint8_t ch = top->uart_tx_data;
            fputc(ch, stdout);
            fflush(stdout);
            if (exit_on_nl && ch == '\n') {
                fprintf(stderr, "\n[sim] newline received after %lu cycles, exiting.\n", cyc);
                break;
            }
        }

        top->clk = 0;
        top->eval();

        cyc++;
    }

    if (cyc >= max_cycles)
        fprintf(stderr, "\n[sim] reached SIM_MAX_CYCLES=%lu without exit.\n", max_cycles);

    top->final();
    delete top;
    delete ctx;
    return 0;
}
