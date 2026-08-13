/*
 * MOS 6522 VIA Emulator
 *
 * Written from the 6522 data sheet specification.
 * No third-party code — safe for closed-source distribution.
 */

#include "via6522.h"
#include <string.h>

static void update_irq(via6522_t *v)
{
    v->irq = (v->ifr & v->ier & 0x7F) ? 1 : 0;
    if (v->irq)
        v->ifr |= VIA_IRQ_ANY;
    else
        v->ifr &= ~VIA_IRQ_ANY;
}

void via6522_init(via6522_t *v)
{
    memset(v, 0, sizeof(*v));
}

void via6522_reset(via6522_t *v)
{
    v->ora = v->orb = 0;
    v->ddra = v->ddrb = 0;
    v->t1c = v->t1l = 0xFFFF;
    v->t2c = 0xFFFF;
    v->t2l = 0xFF;
    v->sr = 0;
    v->acr = 0;
    v->pcr = 0;
    v->ifr = 0;
    v->ier = 0;
    v->irq = 0;
    v->t1_active = 0;
    v->t2_active = 0;
    v->t1_pb7 = 1;
}

/*
 * Register map:
 *  0 ORB/IRB   Port B
 *  1 ORA/IRA   Port A (with handshake)
 *  2 DDRB
 *  3 DDRA
 *  4 T1C-L     Timer 1 counter low
 *  5 T1C-H     Timer 1 counter high
 *  6 T1L-L     Timer 1 latch low
 *  7 T1L-H     Timer 1 latch high
 *  8 T2C-L     Timer 2 counter low
 *  9 T2C-H     Timer 2 counter high
 *  A SR        Shift register
 *  B ACR       Auxiliary control
 *  C PCR       Peripheral control
 *  D IFR       Interrupt flags
 *  E IER       Interrupt enable
 *  F ORA/IRA   Port A (no handshake)
 */

uint8_t via6522_read(via6522_t *v, uint8_t reg)
{
    switch (reg & 0x0F) {
    case 0x00: {
        /* Port B: output bits from ORB, input bits from pb_in */
        v->ifr &= ~(VIA_IRQ_CB1 | VIA_IRQ_CB2);
        update_irq(v);
        uint8_t val = (v->orb & v->ddrb) | (v->pb_in & ~v->ddrb);
        /* Timer 1 PB7 output (ACR bit 7) */
        if (v->acr & 0x80)
            val = (val & 0x7F) | (v->t1_pb7 ? 0x80 : 0x00);
        return val;
    }
    case 0x01: /* Port A (clears CA1/CA2 flags) */
    case 0x0F: /* Port A (no handshake, but same read behavior for flags on 0x01) */
        if (reg == 0x01) {
            v->ifr &= ~(VIA_IRQ_CA1 | VIA_IRQ_CA2);
            update_irq(v);
        }
        return (v->ora & v->ddra) | (v->pa_in & ~v->ddra);
    case 0x02: return v->ddrb;
    case 0x03: return v->ddra;
    case 0x04: /* T1C-L (clears T1 IRQ) */
        v->ifr &= ~VIA_IRQ_T1;
        update_irq(v);
        return (uint8_t)(v->t1c & 0xFF);
    case 0x05: return (uint8_t)(v->t1c >> 8);
    case 0x06: return (uint8_t)(v->t1l & 0xFF);
    case 0x07: return (uint8_t)(v->t1l >> 8);
    case 0x08: /* T2C-L (clears T2 IRQ) */
        v->ifr &= ~VIA_IRQ_T2;
        update_irq(v);
        return (uint8_t)(v->t2c & 0xFF);
    case 0x09: return (uint8_t)(v->t2c >> 8);
    case 0x0A: return v->sr;
    case 0x0B: return v->acr;
    case 0x0C: return v->pcr;
    case 0x0D: return v->ifr | (v->irq ? VIA_IRQ_ANY : 0);
    case 0x0E: return v->ier | 0x80;
    }
    return 0xFF;
}

void via6522_write(via6522_t *v, uint8_t reg, uint8_t val)
{
    switch (reg & 0x0F) {
    case 0x00: /* ORB */
        v->orb = val;
        v->ifr &= ~(VIA_IRQ_CB1 | VIA_IRQ_CB2);
        update_irq(v);
        break;
    case 0x01: /* ORA */
    case 0x0F:
        v->ora = val;
        if (reg == 0x01) {
            v->ifr &= ~(VIA_IRQ_CA1 | VIA_IRQ_CA2);
            update_irq(v);
        }
        break;
    case 0x02: v->ddrb = val; break;
    case 0x03: v->ddra = val; break;
    case 0x04: /* T1L-L (write to latch low) */
        v->t1l = (v->t1l & 0xFF00) | val;
        break;
    case 0x05: /* T1C-H (write starts timer) */
        v->t1l = (v->t1l & 0x00FF) | ((uint16_t)val << 8);
        v->t1c = v->t1l;
        v->ifr &= ~VIA_IRQ_T1;
        update_irq(v);
        v->t1_active = 1;
        v->t1_pb7 = 1; /* PB7 starts high */
        break;
    case 0x06: v->t1l = (v->t1l & 0xFF00) | val; break;
    case 0x07: /* T1L-H (write to latch only, clears T1 flag) */
        v->t1l = (v->t1l & 0x00FF) | ((uint16_t)val << 8);
        v->ifr &= ~VIA_IRQ_T1;
        update_irq(v);
        break;
    case 0x08: /* T2L-L */
        v->t2l = val;
        break;
    case 0x09: /* T2C-H (write starts timer) */
        v->t2c = ((uint16_t)val << 8) | v->t2l;
        v->ifr &= ~VIA_IRQ_T2;
        update_irq(v);
        v->t2_active = 1;
        break;
    case 0x0A: v->sr = val; break;
    case 0x0B: v->acr = val; break;
    case 0x0C: v->pcr = val; break;
    case 0x0D: /* IFR: writing 1 clears that bit */
        v->ifr &= ~(val & 0x7F);
        update_irq(v);
        break;
    case 0x0E: /* IER: bit 7 controls set/clear */
        if (val & 0x80)
            v->ier |= (val & 0x7F);
        else
            v->ier &= ~(val & 0x7F);
        update_irq(v);
        break;
    }
}

void via6522_tick(via6522_t *v, int cycles)
{
    /* ---- CA1 edge detection ---- */
    if (v->ca1 != v->ca1_prev) {
        int pos_edge = (v->ca1 && !v->ca1_prev);
        int neg_edge = (!v->ca1 && v->ca1_prev);
        int want_pos = (v->pcr & 0x01); /* PCR bit 0: 1=positive, 0=negative */
        if ((want_pos && pos_edge) || (!want_pos && neg_edge))
            v->ifr |= VIA_IRQ_CA1;
        v->ca1_prev = v->ca1;
    }

    /* ---- CB1 edge detection ---- */
    if (v->cb1 != v->cb1_prev) {
        int pos_edge = (v->cb1 && !v->cb1_prev);
        int neg_edge = (!v->cb1 && v->cb1_prev);
        int want_pos = (v->pcr & 0x10); /* PCR bit 4 */
        if ((want_pos && pos_edge) || (!want_pos && neg_edge))
            v->ifr |= VIA_IRQ_CB1;
        v->cb1_prev = v->cb1;
    }

    /* ---- Timer 1 ---- */
    if (v->t1_active) {
        uint32_t old = v->t1c;
        v->t1c -= (uint16_t)cycles;
        if (v->t1c > old || v->t1c == 0xFFFF) {
            /* Underflow */
            v->ifr |= VIA_IRQ_T1;
            v->t1_pb7 ^= 1; /* toggle PB7 */

            if (v->acr & 0x40) {
                /* Free-running: reload from latch */
                v->t1c = v->t1l;
            } else {
                /* One-shot: stop */
                v->t1_active = 0;
            }
        }
    }

    /* ---- Timer 2 ---- */
    if (v->t2_active && !(v->acr & 0x20)) {
        /* Timed mode (not pulse counting) */
        uint32_t old = v->t2c;
        v->t2c -= (uint16_t)cycles;
        if (v->t2c > old || v->t2c == 0xFFFF) {
            /* Underflow */
            v->ifr |= VIA_IRQ_T2;
            v->t2_active = 0; /* T2 is always one-shot */
        }
    }

    update_irq(v);
}
