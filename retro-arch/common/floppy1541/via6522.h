/*
 * MOS 6522 VIA (Versatile Interface Adapter) Emulator
 *
 * Ports A/B with DDR, Timer 1/2, CA1/CB1 edge detection,
 * interrupt handling (IFR/IER). Used in the 1541 for IEC bus
 * (VIA1) and disk controller (VIA2).
 */

#ifndef VIA6522_H
#define VIA6522_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Interrupt flag/enable bits */
#define VIA_IRQ_CA2   0x01
#define VIA_IRQ_CA1   0x02
#define VIA_IRQ_SR    0x04
#define VIA_IRQ_CB2   0x08
#define VIA_IRQ_CB1   0x10
#define VIA_IRQ_T2    0x20
#define VIA_IRQ_T1    0x40
#define VIA_IRQ_ANY   0x80  /* bit 7 of IFR: set if any enabled IRQ active */

typedef struct via6522 {
    /* Output and data direction registers */
    uint8_t  orb, ora;     /* output register B/A                    */
    uint8_t  ddrb, ddra;   /* data direction (1 = output)            */

    /* Timers */
    uint16_t t1c;          /* Timer 1 counter                        */
    uint16_t t1l;          /* Timer 1 latch                          */
    uint16_t t2c;          /* Timer 2 counter                        */
    uint8_t  t2l;          /* Timer 2 latch (low byte only)          */
    uint8_t  t1_active;    /* T1 loaded and running                  */
    uint8_t  t2_active;    /* T2 loaded and running                  */
    uint8_t  t1_pb7;       /* PB7 toggle state (free-run mode)       */

    /* Shift register */
    uint8_t  sr;

    /* Control registers */
    uint8_t  acr;          /* Auxiliary Control Register              */
    uint8_t  pcr;          /* Peripheral Control Register             */

    /* Interrupt state */
    uint8_t  ifr;          /* Interrupt Flag Register (bits 0-6)     */
    uint8_t  ier;          /* Interrupt Enable Register (bits 0-6)   */
    uint8_t  irq;          /* Combined IRQ output: 1 = active        */

    /* External port pins (set by glue code before tick) */
    uint8_t  pa_in;        /* Port A input pin states                */
    uint8_t  pb_in;        /* Port B input pin states                */

    /* Control line inputs (active HIGH in emulation) */
    uint8_t  ca1, ca2;
    uint8_t  cb1, cb2;
    uint8_t  ca1_prev;     /* previous CA1 for edge detection        */
    uint8_t  cb1_prev;     /* previous CB1 for edge detection        */
} via6522_t;

void    via6522_init(via6522_t *v);
void    via6522_reset(via6522_t *v);
uint8_t via6522_read(via6522_t *v, uint8_t reg);
void    via6522_write(via6522_t *v, uint8_t reg, uint8_t val);
void    via6522_tick(via6522_t *v, int cycles);

#ifdef __cplusplus
}
#endif

#endif /* VIA6522_H */
