# riscv-serv

Minimal RISC-V SoC built around [SERV](https://github.com/olofk/serv) — the world's smallest RISC-V CPU, a bit-serial RV32I core by Olof Kindgren (ISC).  Each instruction takes ~33 cycles, but the CPU is so small it routinely fits in ~125 LUTs.

## Layout

Same template as `arch/riscv-darkrv/`.

| File | Purpose |
|---|---|
| `serv_*.v` | Upstream CPU files (17 small modules), unmodified.  Top-level is `serv_rf_top` which bundles `serv_top` with the register-file RAM. |
| `cpu_serv.v` | Adapter mapping SERV's Wishbone-like `cyc`/`ack` ibus + dbus onto the SoC's simple bus. |
| `soc.v`, `rom.hex`, `test.s`, `sim-desktop/*` | Identical to the DarkRISCV folder. |

## Adapter notes

SERV uses **Wishbone classic** handshaking:

- Master asserts `cyc`; slave responds with a 1-cycle `ack` pulse and (for reads) drives `rdt`.

The adapter:

1. Delays `ack` by 1 cycle (a single `cyc_d` flop) so the synchronous BRAM's `dout` has time to settle before SERV captures it through `rdt`.
2. Pulses `data_rd` / `data_wr` only during the ack cycle — without this, the SoC's UART would see a multi-cycle write pulse and print each character twice.

## Run

```bash
cd sim-desktop
make run
```

Expected output:
```
Hi!
[sim] newline received after 432 cycles, exiting.
```

The 432-cycle figure reflects SERV's bit-serial nature: ~33 cycles per RV32I instruction × ~13 instructions in the test (counting `lui` + 4×(`addi`+`sb`) + the fetches and acks).
