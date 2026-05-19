# riscv-darkrv

Minimal RISC-V SoC built around [DarkRISCV](https://github.com/darklife/darkriscv) — a small open-source RV32I core by Marcelo Samsoniuk (BSD-3).

This folder is intentionally self-contained: drop-in source for the CPU, a minimal SoC that only wires up ROM + UART, a hand-assembled "Hi!" test, and a Verilator harness that prints UART output to stdout.

## Files

| File | Purpose |
|---|---|
| `darkriscv.v` | Upstream RV32I CPU (3-stage, Harvard, `__RESETPC__=0`). Single edit: the `\`include "../rtl/config.vh"` is commented out — config macros live in `cpu_darkrv.v` instead. |
| `cpu_darkrv.v` | Thin adapter that maps DarkRISCV's `IADDR`/`DADDR`/`DRD`/`DWR` bus to the simple `instr_addr` / `data_addr` interface the SoC expects. Also sets the `\`define`s the upstream CPU needs (`__3STAGE__`, `__HARVARD__`, `__RESETPC__`, `RLEN`). |
| `soc.v` | Minimal SoC: CPU + 32 KB ROM BRAM + UART_TX register at `0x008000`. Reads from MMIO return 0. |
| `rom.hex` | Hand-assembled RISC-V program that writes `"Hi!\n"` to UART then loops. See `test.s` for the source and per-instruction encoding notes. |
| `test.s` | Annotated RISC-V assembly for `rom.hex`. Hand-encoded into the hex; no assembler needed. |
| `sim-desktop/sim_top.cpp` | Verilator C++ harness. Watches `uart_tx_pulse` and prints each byte to stdout. |
| `sim-desktop/Makefile` | `make run` builds via Verilator and prints the test output. |

## Run the test

```bash
cd sim-desktop
make run     # builds Verilator model, runs, prints "Hi!"
```

Expected output:
```
Hi!
[sim] newline received after 16 cycles, exiting.
```

## Adding a different RISC-V core

This folder is the template. To add e.g. PicoRV32 or SERV, create a sibling folder (`arch/riscv-picorv32/`, `arch/riscv-serv/`) and:

1. Drop the new core's Verilog in.
2. Write `cpu_<core>.v` — an adapter mapping the core's bus to this SoC's interface (`instr_addr`/`instr_value` for fetch, `data_addr`/`data_in_value`/`data_out_value`/`data_rd`/`data_wr`/`data_out_strobe` for memory).
3. Keep `soc.v`, `rom.hex`, and `sim-desktop/` largely unchanged — only the CPU instance line in `soc.v` differs.

The SoC's bus convention is intentionally close to the cpu_risc2 family in `arch/risc2/` so adapters look similar.

## Address map

| Range | Purpose |
|---|---|
| `0x000000`–`0x007FFF` | ROM (32 KB, executes the test program) |
| `0x008000`–`0x008003` | UART_TX (byte-write triggers a `uart_tx_pulse`; reads return 0) |
| everything else | reads return 0, writes ignored |

The CPU resets with `pc = 0`, so execution begins at the first word of `rom.hex`.
