/*
 * MOS 6502 CPU Emulator
 *
 * All 151 official opcodes + common illegal opcodes used by 1541 fastloaders.
 * BCD mode (NMOS behavior), IRQ/NMI support.
 * Memory access through caller-provided read/write callbacks.
 */

#ifndef CPU6502_H
#define CPU6502_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Status register flags */
#define P_C  0x01  /* Carry        */
#define P_Z  0x02  /* Zero         */
#define P_I  0x04  /* IRQ disable  */
#define P_D  0x08  /* Decimal mode */
#define P_B  0x10  /* Break (push) */
#define P_U  0x20  /* Unused (always 1) */
#define P_V  0x40  /* Overflow     */
#define P_N  0x80  /* Negative     */

typedef struct cpu6502 {
    uint8_t  a, x, y, sp, p;
    uint16_t pc;
    uint32_t cycles;         /* total cycles executed */
    uint8_t  irq;            /* IRQ line: 1 = asserted */
    uint8_t  nmi;            /* NMI line: 1 = asserted */
    uint8_t  nmi_prev;       /* previous NMI state (edge detect) */
    uint8_t  halted;         /* 1 = CPU jammed */

    /* Memory interface (set by caller before use) */
    uint8_t (*read)(void *ctx, uint16_t addr);
    void    (*write)(void *ctx, uint16_t addr, uint8_t val);
    void    *ctx;
} cpu6502_t;

void cpu6502_init(cpu6502_t *c);
void cpu6502_reset(cpu6502_t *c);
void cpu6502_step(cpu6502_t *c);               /* execute one instruction */
void cpu6502_run(cpu6502_t *c, int max_cycles); /* run until cycles consumed */

/* Cycle-cost lookahead: base cycles step() will charge for opcode `op` at
 * PC (7 if an interrupt will be serviced instead).  Lets a caller running
 * the CPU against a real-time budget dispatch an instruction only when its
 * full cycle window has elapsed — so bus effects land at the END of the
 * window, not several cycles early.  `op` must be fetched by the caller
 * (side-effect-free peek; the CPU core itself can't know which addresses
 * are safe to double-read). */
int cpu6502_next_cost(const cpu6502_t *c, uint8_t op);

#ifdef __cplusplus
}
#endif

#endif /* CPU6502_H */
