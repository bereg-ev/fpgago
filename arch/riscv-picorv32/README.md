# riscv-picorv32

Minimal RISC-V SoC built around [PicoRV32](https://github.com/YosysHQ/picorv32) — a single-file RV32IMC core by Claire Wolf (ISC).  Multi-cycle implementation, ~3–5 cycles per instruction.

## Layout

Same template as `arch/riscv-darkrv/`.  Only the CPU file and adapter differ.

| File | Purpose |
|---|---|
| `picorv32.v` | Upstream CPU (single file, unmodified). |
| `cpu_picorv32.v` | Adapter mapping PicoRV32's unified `mem_valid`/`mem_ready`/`mem_instr` bus onto the SoC's separate fetch + data ports. |
| `soc.v`, `rom.hex`, `test.s`, `sim-desktop/*` | Identical to the DarkRISCV folder. |

## Adapter notes

PicoRV32 uses a **unified** memory bus with `mem_instr` selecting fetch vs data, and a `mem_valid`/`mem_ready` handshake.  The adapter:

1. Demuxes onto the SoC's separate `instr_addr` / `data_addr` ports based on `mem_instr`.
2. Holds an `in_flight` flag that registers the request when `mem_valid` first rises, then pulses `mem_ready` the next cycle once the synchronous BRAM dout is valid.
3. Returns the right port's read data through a small mux into `mem_rdata`.

## Run

```bash
cd sim-desktop
make run
```

Expected output:
```
Hi!
[sim] newline received after 62 cycles, exiting.
```
