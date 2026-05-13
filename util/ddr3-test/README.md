# ddr3-test — DDR3 controller bring-up test

Stripped-down RISC2 SoC + UART menu used to validate the DDR3 path on
hardware version 2 (Winbond W631GG6MB-12, 1 Gb x16, 128 MB total).

## What's in here

| File                   | Purpose                                          |
| ---------------------- | ------------------------------------------------ |
| `main.c`               | UART menu test app (PASS/FAIL + error details)   |
| `ddr3_test_top.v`      | FPGA top: OSCG → EHXPLLL → SoC + DDR3 pins       |
| `ddr3_test_soc.v`      | CPU + 32 KB ROM + 16 KB scratch BRAM + UART + DDR3 peripheral |
| `project.vh`           | UART_BIT_TIME, EXTENDED_MEM, address-map header  |
| `ddr3_test_memmap.vh`  | Address-map (`ADDR_*`, `MEM_*` defines)          |
| `ddr3_test.lpf`        | ECP5 pin constraints (subset of HW v2 LPF)       |
| `Makefile`             | C → `rom.bin`/`rom.hex` → install locally        |
| `run.sh`               | yosys + nextpnr-ecp5 + ecppack → `out.bit`       |
| `sim/`                 | Verilator harness with behavioural AXI memory    |

The DDR3 controller itself is not in this folder — it's vendored at
`peripheral/ddr3/` and pulled in by `ddr3_test_soc.v` directly.

## Architecture

```
              ┌──────────────────────── ddr3_test_top ────────────────────────┐
              │                                                               │
              │   OSCG (155 MHz) → EHXPLLL ┬─ CLKOP (clk_sys, ~52 MHz)         │
              │                            └─ CLKOS (clk_ddr, 90° lead)        │
              │                                                                │
              │  ┌──────────────────────── ddr3_test_soc ────────────────────┐ │
              │  │                                                           │ │
              │  │  cpu_risc2 ─┬─ instr → 32 KB BRAM ROM (8 banks)            │ │
              │  │             ├─ data  → 16 KB BRAM scratch                  │ │
              │  │             ├─ data  → UART (peripheral/uart.v)            │ │
              │  │             └─ data  → ddr3_iface  ──┐                     │ │
              │  │                                       │                    │ │
              │  │                                       │ AXI4 master        │ │
              │  │                                       ▼                    │ │
              │  │                                  ddr3_axi               ┌─┘ │
              │  │                                       │                  │   │
              │  │                                  DFI sequencer           │   │
              │  │                                       │                  │   │
              │  │                                  ddr3_dfi_phy_ecp5  ─→ DDR3 pins
              │  │                                                          │   │
              │  └──────────────────────────────────────────────────────────┘   │
              └────────────────────────────────────────────────────────────────┘
```

`ddr3_iface` owns two 256-word BRAMs (1 KB each):

- **WBRAM** — CPU writes here.  AXI master reads it during a `CMD_WRITE`.
- **RBRAM** — AXI master fills it during a `CMD_READ`.  CPU reads here.

Neither buffer is memory-mapped; both are accessed through register pairs
(`*_ADDR` + `*_DATA`).  Every CPU access to `*_DATA` reads/writes the
buffer at `*_ADDR` and auto-increments the pointer.

## Memory map

| Range                  | Region                                          |
| ---------------------- | ----------------------------------------------- |
| `0x000000..0x007FFF`   | Boot ROM (32 KB)                                 |
| `0x008000..0x00800F`   | SYS  (LEDs, version)                             |
| `0x008100..0x00810F`   | UART (status / TX / RX)                          |
| `0x008300..0x0083FF`   | DDR3 test peripheral                             |
| `0x010000..0x013FFF`   | Data BRAM scratch (16 KB)                        |

DDR3 peripheral registers (offsets within `0x008300..`):

| Off    | Reg            | Notes                                         |
| ------ | -------------- | --------------------------------------------- |
| `0x00` | `WBRAM_ADDR`   | write-buffer pointer (8 bits used)            |
| `0x04` | `WBRAM_DATA`   | R/W, ptr++ on every access                    |
| `0x08` | `RBRAM_ADDR`   | read-buffer pointer                           |
| `0x0C` | `RBRAM_DATA`   | R/W, ptr++ on every access                    |
| `0x10` | `DDR3_ADDR`    | byte address in DDR3 (target of CMD)          |
| `0x14` | `DDR3_LEN`     | length in 32-bit words (1..256)               |
| `0x18` | `DDR3_CMD`     | `1`=write→DDR3, `2`=read←DDR3, `3`=clear err  |
| `0x1C` | `DDR3_STATUS`  | bit 0 busy, bit 1 sticky AXI error            |

## Quick start

```sh
# 1. Compile the test app (requires the RISC2 LLVM you built with ./setup.sh llvm)
cd util/ddr3-test
make

# 2. Run in Verilator (uses the behavioural AXI memory under sim/)
SIM_SCRIPT="iq" make sim         # send 'i' (info) then 'q' (quick)

# 3. Synthesise + place + route + bitstream
make synth                        # produces out.bit

# 4. Flash out.bit to the board with your usual tool
```

## UART connection

**115200 baud, 8N1, no flow control.**  `UART_BIT_TIME=448` at the PLL's
~51.67 MHz CPU clock (uart.v bit period is `UART_BIT_TIME+1` clocks, so
51.67e6/449 ≈ 115070 — within ~0.1 % of nominal).

For sim, `UART_BIT_TIME=3` (kept under `\`ifdef SIMULATION`) so each
character flies past in ~30 clocks.

## Test commands (typed at `> ` prompt over UART)

| Key | Action                                                  |
| --- | ------------------------------------------------------- |
| `i` | print region size / config                              |
| `q` | one burst at addr 0 (walking 1s, walking 0s, addr, lfsr)|
| `w` | walking-1s + walking-0s at four scattered addresses     |
| `a` | address-as-data sweep over the lower 1 MB               |
| `r` | LFSR pseudo-random sweep over the full 128 MB           |
| `R` | same as `r` but aborts on the first failure             |
| `s` | dump `DDR3_STATUS`                                      |
| `c` | clear sticky AXI error                                  |
| `h` | help                                                    |

## Known gotchas

- **Single clock domain at first.**  Both `clk_sys` and `clk_ddr` come out
  of the same EHXPLLL at the same frequency (the second is just 90° phase
  shifted).  When you want the DDR3 PHY to run faster than the CPU,
  change `CLKOP_DIV` vs `CLKOS_DIV` and update the controller's
  `DDR_MHZ` parameter in `ddr3_test_soc.v`.
- **Sim memory is 1 MB, not 128 MB.**  The `r` / `R` tests will appear to
  fail in sim because addresses outside the lower 1 MB alias back into
  the model.  Use the FPGA for full-region testing.
- **DDR3 controller boot delay**: 600 µs in synth, shortened to 60 µs in
  sim by `-DXILINX_SIMULATOR` (added automatically by sim/Makefile if you
  uncomment it — by default we skip the controller in sim and use a
  behavioural AXI memory instead).

## Provenance of the controller

`peripheral/ddr3/` is a verbatim vendoring of [ultraembedded/core_ddr3_controller](https://github.com/ultraembedded/core_ddr3_controller)
(Apache-2.0, v0.5).  See `peripheral/ddr3/UPSTREAM` for the file map and
refresh procedure.
