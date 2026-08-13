/*
 * MOS 6502 CPU Emulator
 *
 * Complete implementation: 151 official + common illegal opcodes.
 * Written from the public 6502 instruction set specification.
 * No third-party code — safe for closed-source distribution.
 */

#include "cpu6502.h"
#include <string.h>

/* ---- Memory helpers ---------------------------------------------------- */

static inline uint8_t rd(cpu6502_t *c, uint16_t a)
{
    return c->read(c->ctx, a);
}

static inline void wr(cpu6502_t *c, uint16_t a, uint8_t v)
{
    c->write(c->ctx, a, v);
}

static inline uint16_t rd16(cpu6502_t *c, uint16_t a)
{
    return rd(c, a) | ((uint16_t)rd(c, a + 1) << 8);
}

/* Zero-page 16-bit read with wrapping (for indirect addressing) */
static inline uint16_t rd16zp(cpu6502_t *c, uint8_t a)
{
    return rd(c, a) | ((uint16_t)rd(c, (uint8_t)(a + 1)) << 8);
}

/* ---- Stack helpers ----------------------------------------------------- */

static inline void push(cpu6502_t *c, uint8_t v)
{
    wr(c, 0x100 | c->sp, v);
    c->sp--;
}

static inline uint8_t pull(cpu6502_t *c)
{
    c->sp++;
    return rd(c, 0x100 | c->sp);
}

static inline void push16(cpu6502_t *c, uint16_t v)
{
    push(c, v >> 8);
    push(c, v & 0xFF);
}

static inline uint16_t pull16(cpu6502_t *c)
{
    uint16_t lo = pull(c);
    return lo | ((uint16_t)pull(c) << 8);
}

/* ---- Flag helpers ------------------------------------------------------ */

static inline void set_nz(cpu6502_t *c, uint8_t v)
{
    c->p = (c->p & ~(P_N | P_Z)) | (v & P_N) | (v ? 0 : P_Z);
}

static inline int page_cross(uint16_t base, uint16_t addr)
{
    return (base ^ addr) & 0xFF00;
}

/* ---- Addressing modes -------------------------------------------------- */
/* Return effective address. _p variants add 1 cycle on page cross. */

static uint16_t am_imm(cpu6502_t *c)   { return c->pc++; }
static uint16_t am_zpg(cpu6502_t *c)   { return rd(c, c->pc++); }
static uint16_t am_zpx(cpu6502_t *c)   { return (rd(c, c->pc++) + c->x) & 0xFF; }
static uint16_t am_zpy(cpu6502_t *c)   { return (rd(c, c->pc++) + c->y) & 0xFF; }
static uint16_t am_abs(cpu6502_t *c)   { uint16_t lo = rd(c, c->pc++); return lo | ((uint16_t)rd(c, c->pc++) << 8); }
static uint16_t am_abx(cpu6502_t *c)   { return am_abs(c) + c->x; }
static uint16_t am_aby(cpu6502_t *c)   { return am_abs(c) + c->y; }
static uint16_t am_izx(cpu6502_t *c)   { uint8_t z = rd(c, c->pc++) + c->x; return rd16zp(c, z); }
static uint16_t am_izy(cpu6502_t *c)   { uint8_t z = rd(c, c->pc++); return rd16zp(c, z) + c->y; }

/* Page-cross penalty variants (for read instructions) */
static uint16_t am_abx_p(cpu6502_t *c) { uint16_t b = am_abs(c); uint16_t a = b + c->x; if (page_cross(b, a)) c->cycles++; return a; }
static uint16_t am_aby_p(cpu6502_t *c) { uint16_t b = am_abs(c); uint16_t a = b + c->y; if (page_cross(b, a)) c->cycles++; return a; }
static uint16_t am_izy_p(cpu6502_t *c) { uint8_t z = rd(c, c->pc++); uint16_t b = rd16zp(c, z); uint16_t a = b + c->y; if (page_cross(b, a)) c->cycles++; return a; }

/* ---- ALU operations ---------------------------------------------------- */

static void op_ora(cpu6502_t *c, uint8_t v) { c->a |= v; set_nz(c, c->a); }
static void op_and(cpu6502_t *c, uint8_t v) { c->a &= v; set_nz(c, c->a); }
static void op_eor(cpu6502_t *c, uint8_t v) { c->a ^= v; set_nz(c, c->a); }

static void op_cmp(cpu6502_t *c, uint8_t a, uint8_t v)
{
    uint16_t r = (uint16_t)a - v;
    c->p = (c->p & ~(P_N | P_Z | P_C)) | (r & P_N) | ((r & 0xFF) ? 0 : P_Z) | (a >= v ? P_C : 0);
}

static void op_bit(cpu6502_t *c, uint8_t v)
{
    c->p = (c->p & ~(P_N | P_V | P_Z)) | (v & (P_N | P_V)) | ((c->a & v) ? 0 : P_Z);
}

static uint8_t op_asl(cpu6502_t *c, uint8_t v)
{
    c->p = (c->p & ~P_C) | (v >> 7);
    v <<= 1;
    set_nz(c, v);
    return v;
}

static uint8_t op_lsr(cpu6502_t *c, uint8_t v)
{
    c->p = (c->p & ~P_C) | (v & 1);
    v >>= 1;
    set_nz(c, v);
    return v;
}

static uint8_t op_rol(cpu6502_t *c, uint8_t v)
{
    uint8_t oc = c->p & P_C;
    c->p = (c->p & ~P_C) | (v >> 7);
    v = (v << 1) | oc;
    set_nz(c, v);
    return v;
}

static uint8_t op_ror(cpu6502_t *c, uint8_t v)
{
    uint8_t oc = c->p & P_C;
    c->p = (c->p & ~P_C) | (v & 1);
    v = (v >> 1) | (oc << 7);
    set_nz(c, v);
    return v;
}

static void op_branch(cpu6502_t *c, int cond)
{
    int8_t off = (int8_t)rd(c, c->pc++);
    if (cond) {
        uint16_t old = c->pc;
        c->pc = (uint16_t)(c->pc + off);
        c->cycles++;
        if (page_cross(old, c->pc)) c->cycles++;
    }
}

/* ---- Interrupt handling ------------------------------------------------ */

static void do_irq(cpu6502_t *c)
{
    push16(c, c->pc);
    push(c, (c->p | P_U) & ~P_B);
    c->p |= P_I;
    c->pc = rd16(c, 0xFFFE);
    c->cycles += 7;
}

static void do_nmi(cpu6502_t *c)
{
    push16(c, c->pc);
    push(c, (c->p | P_U) & ~P_B);
    c->p |= P_I;
    c->pc = rd16(c, 0xFFFA);
    c->cycles += 7;
}

/* ---- Public API -------------------------------------------------------- */

void cpu6502_init(cpu6502_t *c)
{
    memset(c, 0, sizeof(*c));
    c->p = P_U | P_I;
    c->sp = 0xFD;
}

void cpu6502_reset(cpu6502_t *c)
{
    c->sp -= 3; /* reset consumes 3 stack cycles but doesn't write */
    c->p |= P_I;
    c->pc = rd16(c, 0xFFFC);
    c->cycles += 7;
    c->halted = 0;
}

void cpu6502_run(cpu6502_t *c, int max_cycles)
{
    uint32_t target = c->cycles + (uint32_t)max_cycles;
    while (c->cycles < target && !c->halted)
        cpu6502_step(c);
}

/* ---- ADC/SBC reimplemented cleanly ------------------------------------- */
/* (replacing the messy version above) */

static void adc_bin(cpu6502_t *c, uint8_t v)
{
    uint8_t a = c->a;
    uint16_t s = (uint16_t)a + v + (c->p & P_C);
    c->p &= ~(P_N | P_V | P_Z | P_C);
    c->a = (uint8_t)s;
    if (!c->a) c->p |= P_Z;
    c->p |= (c->a & P_N);
    if (s > 0xFF) c->p |= P_C;
    if (~(a ^ v) & (a ^ c->a) & 0x80) c->p |= P_V;
}

static void adc_bcd(cpu6502_t *c, uint8_t v)
{
    uint8_t a = c->a;
    uint16_t s = (uint16_t)a + v + (c->p & P_C);
    int al = (a & 0x0F) + (v & 0x0F) + (c->p & P_C);
    if (al > 9) al += 6;
    int ah = (a >> 4) + (v >> 4) + (al > 15 ? 1 : 0);
    c->p &= ~(P_N | P_V | P_Z | P_C);
    if (!(s & 0xFF)) c->p |= P_Z;         /* Z from binary (NMOS) */
    c->p |= ((ah << 4) & P_N);
    if (~(a ^ v) & (a ^ (uint8_t)(ah << 4)) & 0x80) c->p |= P_V;
    if (ah > 9) ah += 6;
    if (ah > 15) c->p |= P_C;
    c->a = (uint8_t)(((ah & 0x0F) << 4) | (al & 0x0F));
}

static void sbc_bcd(cpu6502_t *c, uint8_t v)
{
    uint8_t a = c->a;
    uint16_t s = (uint16_t)a - v - ((c->p & P_C) ? 0 : 1);
    int al = (a & 0x0F) - (v & 0x0F) - ((c->p & P_C) ? 0 : 1);
    int ah = (a >> 4) - (v >> 4);
    if (al < 0) { al -= 6; ah--; }
    if (ah < 0) ah -= 6;
    c->p &= ~(P_N | P_V | P_Z | P_C);
    uint8_t bin = (uint8_t)s;
    if (!bin) c->p |= P_Z;
    c->p |= (bin & P_N);
    if (s < 0x100) c->p |= P_C;
    if ((a ^ v) & (a ^ bin) & 0x80) c->p |= P_V;
    c->a = (uint8_t)(((ah & 0x0F) << 4) | (al & 0x0F));
}

static void do_adc(cpu6502_t *c, uint8_t v)
{
    if (c->p & P_D) adc_bcd(c, v); else adc_bin(c, v);
}

static void do_sbc(cpu6502_t *c, uint8_t v)
{
    if (c->p & P_D) sbc_bcd(c, v); else adc_bin(c, v ^ 0xFF);
}

/* ---- Main instruction decode ------------------------------------------- */

void cpu6502_step(cpu6502_t *c)
{
    if (c->halted) { c->cycles++; return; }

    /* NMI edge detection */
    if (c->nmi && !c->nmi_prev) {
        c->nmi_prev = c->nmi;
        do_nmi(c);
        return;
    }
    c->nmi_prev = c->nmi;

    /* IRQ (level triggered, masked by I flag) */
    if (c->irq && !(c->p & P_I)) {
        do_irq(c);
        return;
    }

    uint8_t op = rd(c, c->pc++);

    switch (op) {

    /* ---- Row 0x00-0x0F ---- */
    case 0x00: /* BRK */ rd(c,c->pc++); push16(c,c->pc); push(c,c->p|P_B|P_U); c->p|=P_I; c->pc=rd16(c,0xFFFE); c->cycles+=7; break;
    case 0x01: /* ORA izx */ op_ora(c, rd(c, am_izx(c))); c->cycles += 6; break;
    case 0x02: c->halted = 1; break;
    case 0x03: /* SLO izx */ { uint16_t a=am_izx(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v>>7); v<<=1; wr(c,a,v); c->a|=v; set_nz(c,c->a); c->cycles+=8; } break;
    case 0x04: /* NOP zpg */ am_zpg(c); c->cycles += 3; break;
    case 0x05: /* ORA zpg */ op_ora(c, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0x06: /* ASL zpg */ { uint16_t a=am_zpg(c); wr(c,a,op_asl(c,rd(c,a))); c->cycles+=5; } break;
    case 0x07: /* SLO zpg */ { uint16_t a=am_zpg(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v>>7); v<<=1; wr(c,a,v); c->a|=v; set_nz(c,c->a); c->cycles+=5; } break;
    case 0x08: /* PHP */ push(c, c->p | P_B | P_U); c->cycles += 3; break;
    case 0x09: /* ORA imm */ op_ora(c, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0x0A: /* ASL acc */ c->a = op_asl(c, c->a); c->cycles += 2; break;
    case 0x0B: /* ANC imm */ op_and(c, rd(c, am_imm(c))); c->p = (c->p & ~P_C) | ((c->a >> 7) & P_C); c->cycles += 2; break;
    case 0x0C: /* NOP abs */ am_abs(c); c->cycles += 4; break;
    case 0x0D: /* ORA abs */ op_ora(c, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0x0E: /* ASL abs */ { uint16_t a=am_abs(c); wr(c,a,op_asl(c,rd(c,a))); c->cycles+=6; } break;
    case 0x0F: /* SLO abs */ { uint16_t a=am_abs(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v>>7); v<<=1; wr(c,a,v); c->a|=v; set_nz(c,c->a); c->cycles+=6; } break;

    /* ---- Row 0x10-0x1F ---- */
    case 0x10: /* BPL */ op_branch(c, !(c->p & P_N)); c->cycles += 2; break;
    case 0x11: /* ORA izy */ op_ora(c, rd(c, am_izy_p(c))); c->cycles += 5; break;
    case 0x12: c->halted = 1; break;
    case 0x13: /* SLO izy */ { uint16_t a=am_izy(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v>>7); v<<=1; wr(c,a,v); c->a|=v; set_nz(c,c->a); c->cycles+=8; } break;
    case 0x14: /* NOP zpx */ am_zpx(c); c->cycles += 4; break;
    case 0x15: /* ORA zpx */ op_ora(c, rd(c, am_zpx(c))); c->cycles += 4; break;
    case 0x16: /* ASL zpx */ { uint16_t a=am_zpx(c); wr(c,a,op_asl(c,rd(c,a))); c->cycles+=6; } break;
    case 0x17: /* SLO zpx */ { uint16_t a=am_zpx(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v>>7); v<<=1; wr(c,a,v); c->a|=v; set_nz(c,c->a); c->cycles+=6; } break;
    case 0x18: /* CLC */ c->p &= ~P_C; c->cycles += 2; break;
    case 0x19: /* ORA aby */ op_ora(c, rd(c, am_aby_p(c))); c->cycles += 4; break;
    case 0x1A: /* NOP */ c->cycles += 2; break;
    case 0x1B: /* SLO aby */ { uint16_t a=am_aby(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v>>7); v<<=1; wr(c,a,v); c->a|=v; set_nz(c,c->a); c->cycles+=7; } break;
    case 0x1C: /* NOP abx */ am_abx_p(c); c->cycles += 4; break;
    case 0x1D: /* ORA abx */ op_ora(c, rd(c, am_abx_p(c))); c->cycles += 4; break;
    case 0x1E: /* ASL abx */ { uint16_t a=am_abx(c); wr(c,a,op_asl(c,rd(c,a))); c->cycles+=7; } break;
    case 0x1F: /* SLO abx */ { uint16_t a=am_abx(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v>>7); v<<=1; wr(c,a,v); c->a|=v; set_nz(c,c->a); c->cycles+=7; } break;

    /* ---- Row 0x20-0x2F ---- */
    case 0x20: /* JSR abs */ { uint16_t t=am_abs(c); push16(c,c->pc-1); c->pc=t; c->cycles+=6; } break;
    case 0x21: /* AND izx */ op_and(c, rd(c, am_izx(c))); c->cycles += 6; break;
    case 0x22: c->halted = 1; break;
    case 0x23: /* RLA izx */ { uint16_t a=am_izx(c); uint8_t v=rd(c,a); v=op_rol(c,v); wr(c,a,v); c->a&=v; set_nz(c,c->a); c->cycles+=8; } break;
    case 0x24: /* BIT zpg */ op_bit(c, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0x25: /* AND zpg */ op_and(c, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0x26: /* ROL zpg */ { uint16_t a=am_zpg(c); wr(c,a,op_rol(c,rd(c,a))); c->cycles+=5; } break;
    case 0x27: /* RLA zpg */ { uint16_t a=am_zpg(c); uint8_t v=op_rol(c,rd(c,a)); wr(c,a,v); c->a&=v; set_nz(c,c->a); c->cycles+=5; } break;
    case 0x28: /* PLP */ c->p = (pull(c) & ~(P_B)) | P_U; c->cycles += 4; break;
    case 0x29: /* AND imm */ op_and(c, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0x2A: /* ROL acc */ c->a = op_rol(c, c->a); c->cycles += 2; break;
    case 0x2B: /* ANC imm */ op_and(c, rd(c, am_imm(c))); c->p = (c->p & ~P_C) | ((c->a >> 7) & P_C); c->cycles += 2; break;
    case 0x2C: /* BIT abs */ op_bit(c, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0x2D: /* AND abs */ op_and(c, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0x2E: /* ROL abs */ { uint16_t a=am_abs(c); wr(c,a,op_rol(c,rd(c,a))); c->cycles+=6; } break;
    case 0x2F: /* RLA abs */ { uint16_t a=am_abs(c); uint8_t v=op_rol(c,rd(c,a)); wr(c,a,v); c->a&=v; set_nz(c,c->a); c->cycles+=6; } break;

    /* ---- Row 0x30-0x3F ---- */
    case 0x30: /* BMI */ op_branch(c, c->p & P_N); c->cycles += 2; break;
    case 0x31: /* AND izy */ op_and(c, rd(c, am_izy_p(c))); c->cycles += 5; break;
    case 0x32: c->halted = 1; break;
    case 0x33: /* RLA izy */ { uint16_t a=am_izy(c); uint8_t v=op_rol(c,rd(c,a)); wr(c,a,v); c->a&=v; set_nz(c,c->a); c->cycles+=8; } break;
    case 0x34: /* NOP zpx */ am_zpx(c); c->cycles += 4; break;
    case 0x35: /* AND zpx */ op_and(c, rd(c, am_zpx(c))); c->cycles += 4; break;
    case 0x36: /* ROL zpx */ { uint16_t a=am_zpx(c); wr(c,a,op_rol(c,rd(c,a))); c->cycles+=6; } break;
    case 0x37: /* RLA zpx */ { uint16_t a=am_zpx(c); uint8_t v=op_rol(c,rd(c,a)); wr(c,a,v); c->a&=v; set_nz(c,c->a); c->cycles+=6; } break;
    case 0x38: /* SEC */ c->p |= P_C; c->cycles += 2; break;
    case 0x39: /* AND aby */ op_and(c, rd(c, am_aby_p(c))); c->cycles += 4; break;
    case 0x3A: /* NOP */ c->cycles += 2; break;
    case 0x3B: /* RLA aby */ { uint16_t a=am_aby(c); uint8_t v=op_rol(c,rd(c,a)); wr(c,a,v); c->a&=v; set_nz(c,c->a); c->cycles+=7; } break;
    case 0x3C: /* NOP abx */ am_abx_p(c); c->cycles += 4; break;
    case 0x3D: /* AND abx */ op_and(c, rd(c, am_abx_p(c))); c->cycles += 4; break;
    case 0x3E: /* ROL abx */ { uint16_t a=am_abx(c); wr(c,a,op_rol(c,rd(c,a))); c->cycles+=7; } break;
    case 0x3F: /* RLA abx */ { uint16_t a=am_abx(c); uint8_t v=op_rol(c,rd(c,a)); wr(c,a,v); c->a&=v; set_nz(c,c->a); c->cycles+=7; } break;

    /* ---- Row 0x40-0x4F ---- */
    case 0x40: /* RTI */ c->p=(pull(c)&~P_B)|P_U; c->pc=pull16(c); c->cycles+=6; break;
    case 0x41: /* EOR izx */ op_eor(c, rd(c, am_izx(c))); c->cycles += 6; break;
    case 0x42: c->halted = 1; break;
    case 0x43: /* SRE izx */ { uint16_t a=am_izx(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v&1); v>>=1; wr(c,a,v); c->a^=v; set_nz(c,c->a); c->cycles+=8; } break;
    case 0x44: /* NOP zpg */ am_zpg(c); c->cycles += 3; break;
    case 0x45: /* EOR zpg */ op_eor(c, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0x46: /* LSR zpg */ { uint16_t a=am_zpg(c); wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=5; } break;
    case 0x47: /* SRE zpg */ { uint16_t a=am_zpg(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v&1); v>>=1; wr(c,a,v); c->a^=v; set_nz(c,c->a); c->cycles+=5; } break;
    case 0x48: /* PHA */ push(c, c->a); c->cycles += 3; break;
    case 0x49: /* EOR imm */ op_eor(c, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0x4A: /* LSR acc */ c->a = op_lsr(c, c->a); c->cycles += 2; break;
    case 0x4B: /* ALR imm */ c->a &= rd(c, c->pc++); c->a = op_lsr(c, c->a); c->cycles += 2; break;
    case 0x4C: /* JMP abs */ c->pc = am_abs(c); c->cycles += 3; break;
    case 0x4D: /* EOR abs */ op_eor(c, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0x4E: /* LSR abs */ { uint16_t a=am_abs(c); wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=6; } break;
    case 0x4F: /* SRE abs */ { uint16_t a=am_abs(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v&1); v>>=1; wr(c,a,v); c->a^=v; set_nz(c,c->a); c->cycles+=6; } break;

    /* ---- Row 0x50-0x5F ---- */
    case 0x50: /* BVC */ op_branch(c, !(c->p & P_V)); c->cycles += 2; break;
    case 0x51: /* EOR izy */ op_eor(c, rd(c, am_izy_p(c))); c->cycles += 5; break;
    case 0x52: c->halted = 1; break;
    case 0x53: /* SRE izy */ { uint16_t a=am_izy(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v&1); v>>=1; wr(c,a,v); c->a^=v; set_nz(c,c->a); c->cycles+=8; } break;
    case 0x54: /* NOP zpx */ am_zpx(c); c->cycles += 4; break;
    case 0x55: /* EOR zpx */ op_eor(c, rd(c, am_zpx(c))); c->cycles += 4; break;
    case 0x56: /* LSR zpx */ { uint16_t a=am_zpx(c); wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=6; } break;
    case 0x57: /* SRE zpx */ { uint16_t a=am_zpx(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v&1); v>>=1; wr(c,a,v); c->a^=v; set_nz(c,c->a); c->cycles+=6; } break;
    case 0x58: /* CLI */ c->p &= ~P_I; c->cycles += 2; break;
    case 0x59: /* EOR aby */ op_eor(c, rd(c, am_aby_p(c))); c->cycles += 4; break;
    case 0x5A: /* NOP */ c->cycles += 2; break;
    case 0x5B: /* SRE aby */ { uint16_t a=am_aby(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v&1); v>>=1; wr(c,a,v); c->a^=v; set_nz(c,c->a); c->cycles+=7; } break;
    case 0x5C: /* NOP abx */ am_abx_p(c); c->cycles += 4; break;
    case 0x5D: /* EOR abx */ op_eor(c, rd(c, am_abx_p(c))); c->cycles += 4; break;
    case 0x5E: /* LSR abx */ { uint16_t a=am_abx(c); wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=7; } break;
    case 0x5F: /* SRE abx */ { uint16_t a=am_abx(c); uint8_t v=rd(c,a); c->p=(c->p&~P_C)|(v&1); v>>=1; wr(c,a,v); c->a^=v; set_nz(c,c->a); c->cycles+=7; } break;

    /* ---- Row 0x60-0x6F ---- */
    case 0x60: /* RTS */ c->pc = pull16(c) + 1; c->cycles += 6; break;
    case 0x61: /* ADC izx */ do_adc(c, rd(c, am_izx(c))); c->cycles += 6; break;
    case 0x62: c->halted = 1; break;
    case 0x63: /* RRA izx */ { uint16_t a=am_izx(c); uint8_t v=op_ror(c,rd(c,a)); wr(c,a,v); do_adc(c,v); c->cycles+=8; } break;
    case 0x64: /* NOP zpg */ am_zpg(c); c->cycles += 3; break;
    case 0x65: /* ADC zpg */ do_adc(c, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0x66: /* ROR zpg */ { uint16_t a=am_zpg(c); wr(c,a,op_ror(c,rd(c,a))); c->cycles+=5; } break;
    case 0x67: /* RRA zpg */ { uint16_t a=am_zpg(c); uint8_t v=op_ror(c,rd(c,a)); wr(c,a,v); do_adc(c,v); c->cycles+=5; } break;
    case 0x68: /* PLA */ c->a = pull(c); set_nz(c, c->a); c->cycles += 4; break;
    case 0x69: /* ADC imm */ do_adc(c, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0x6A: /* ROR acc */ c->a = op_ror(c, c->a); c->cycles += 2; break;
    case 0x6B: /* ARR imm */ { uint8_t v = rd(c,c->pc++) & c->a; c->a = (v>>1)|((c->p&P_C)<<7); set_nz(c,c->a); c->p=(c->p&~(P_C|P_V))|(((c->a>>6)&1)?P_C:0)|(((c->a>>6)^(c->a>>5))&1?P_V:0); c->cycles+=2; } break;
    case 0x6C: /* JMP ind */ { uint16_t ptr=am_abs(c); c->pc=rd(c,ptr)|((uint16_t)rd(c,(ptr&0xFF00)|((ptr+1)&0xFF))<<8); c->cycles+=5; } break;
    case 0x6D: /* ADC abs */ do_adc(c, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0x6E: /* ROR abs */ { uint16_t a=am_abs(c); wr(c,a,op_ror(c,rd(c,a))); c->cycles+=6; } break;
    case 0x6F: /* RRA abs */ { uint16_t a=am_abs(c); uint8_t v=op_ror(c,rd(c,a)); wr(c,a,v); do_adc(c,v); c->cycles+=6; } break;

    /* ---- Row 0x70-0x7F ---- */
    case 0x70: /* BVS */ op_branch(c, c->p & P_V); c->cycles += 2; break;
    case 0x71: /* ADC izy */ do_adc(c, rd(c, am_izy_p(c))); c->cycles += 5; break;
    case 0x72: c->halted = 1; break;
    case 0x73: /* RRA izy */ { uint16_t a=am_izy(c); uint8_t v=op_ror(c,rd(c,a)); wr(c,a,v); do_adc(c,v); c->cycles+=8; } break;
    case 0x74: /* NOP zpx */ am_zpx(c); c->cycles += 4; break;
    case 0x75: /* ADC zpx */ do_adc(c, rd(c, am_zpx(c))); c->cycles += 4; break;
    case 0x76: /* ROR zpx */ { uint16_t a=am_zpx(c); wr(c,a,op_ror(c,rd(c,a))); c->cycles+=6; } break;
    case 0x77: /* RRA zpx */ { uint16_t a=am_zpx(c); uint8_t v=op_ror(c,rd(c,a)); wr(c,a,v); do_adc(c,v); c->cycles+=6; } break;
    case 0x78: /* SEI */ c->p |= P_I; c->cycles += 2; break;
    case 0x79: /* ADC aby */ do_adc(c, rd(c, am_aby_p(c))); c->cycles += 4; break;
    case 0x7A: /* NOP */ c->cycles += 2; break;
    case 0x7B: /* RRA aby */ { uint16_t a=am_aby(c); uint8_t v=op_ror(c,rd(c,a)); wr(c,a,v); do_adc(c,v); c->cycles+=7; } break;
    case 0x7C: /* NOP abx */ am_abx_p(c); c->cycles += 4; break;
    case 0x7D: /* ADC abx */ do_adc(c, rd(c, am_abx_p(c))); c->cycles += 4; break;
    case 0x7E: /* ROR abx */ { uint16_t a=am_abx(c); wr(c,a,op_ror(c,rd(c,a))); c->cycles+=7; } break;
    case 0x7F: /* RRA abx */ { uint16_t a=am_abx(c); uint8_t v=op_ror(c,rd(c,a)); wr(c,a,v); do_adc(c,v); c->cycles+=7; } break;

    /* ---- Row 0x80-0x8F ---- */
    case 0x80: /* NOP imm */ c->pc++; c->cycles += 2; break;
    case 0x81: /* STA izx */ wr(c, am_izx(c), c->a); c->cycles += 6; break;
    case 0x82: /* NOP imm */ c->pc++; c->cycles += 2; break;
    case 0x83: /* SAX izx */ wr(c, am_izx(c), c->a & c->x); c->cycles += 6; break;
    case 0x84: /* STY zpg */ wr(c, am_zpg(c), c->y); c->cycles += 3; break;
    case 0x85: /* STA zpg */ wr(c, am_zpg(c), c->a); c->cycles += 3; break;
    case 0x86: /* STX zpg */ wr(c, am_zpg(c), c->x); c->cycles += 3; break;
    case 0x87: /* SAX zpg */ wr(c, am_zpg(c), c->a & c->x); c->cycles += 3; break;
    case 0x88: /* DEY */ c->y--; set_nz(c, c->y); c->cycles += 2; break;
    case 0x89: /* NOP imm */ c->pc++; c->cycles += 2; break;
    case 0x8A: /* TXA */ c->a = c->x; set_nz(c, c->a); c->cycles += 2; break;
    case 0x8B: /* ANE imm (unstable) */ c->pc++; c->cycles += 2; break;
    case 0x8C: /* STY abs */ wr(c, am_abs(c), c->y); c->cycles += 4; break;
    case 0x8D: /* STA abs */ wr(c, am_abs(c), c->a); c->cycles += 4; break;
    case 0x8E: /* STX abs */ wr(c, am_abs(c), c->x); c->cycles += 4; break;
    case 0x8F: /* SAX abs */ wr(c, am_abs(c), c->a & c->x); c->cycles += 4; break;

    /* ---- Row 0x90-0x9F ---- */
    case 0x90: /* BCC */ op_branch(c, !(c->p & P_C)); c->cycles += 2; break;
    case 0x91: /* STA izy */ wr(c, am_izy(c), c->a); c->cycles += 6; break;
    case 0x92: c->halted = 1; break;
    case 0x93: /* SHA izy (unstable) */ { am_izy(c); c->cycles += 6; } break;
    case 0x94: /* STY zpx */ wr(c, am_zpx(c), c->y); c->cycles += 4; break;
    case 0x95: /* STA zpx */ wr(c, am_zpx(c), c->a); c->cycles += 4; break;
    case 0x96: /* STX zpy */ wr(c, am_zpy(c), c->x); c->cycles += 4; break;
    case 0x97: /* SAX zpy */ wr(c, am_zpy(c), c->a & c->x); c->cycles += 4; break;
    case 0x98: /* TYA */ c->a = c->y; set_nz(c, c->a); c->cycles += 2; break;
    case 0x99: /* STA aby */ wr(c, am_aby(c), c->a); c->cycles += 5; break;
    case 0x9A: /* TXS */ c->sp = c->x; c->cycles += 2; break;
    case 0x9B: /* TAS (unstable) */ c->cycles += 5; am_aby(c); break;
    case 0x9C: /* SHY (unstable) */ am_abx(c); c->cycles += 5; break;
    case 0x9D: /* STA abx */ wr(c, am_abx(c), c->a); c->cycles += 5; break;
    case 0x9E: /* SHX (unstable) */ am_aby(c); c->cycles += 5; break;
    case 0x9F: /* SHA (unstable) */ am_aby(c); c->cycles += 5; break;

    /* ---- Row 0xA0-0xAF ---- */
    case 0xA0: /* LDY imm */ c->y = rd(c, am_imm(c)); set_nz(c, c->y); c->cycles += 2; break;
    case 0xA1: /* LDA izx */ c->a = rd(c, am_izx(c)); set_nz(c, c->a); c->cycles += 6; break;
    case 0xA2: /* LDX imm */ c->x = rd(c, am_imm(c)); set_nz(c, c->x); c->cycles += 2; break;
    case 0xA3: /* LAX izx */ c->a = c->x = rd(c, am_izx(c)); set_nz(c, c->a); c->cycles += 6; break;
    case 0xA4: /* LDY zpg */ c->y = rd(c, am_zpg(c)); set_nz(c, c->y); c->cycles += 3; break;
    case 0xA5: /* LDA zpg */ c->a = rd(c, am_zpg(c)); set_nz(c, c->a); c->cycles += 3; break;
    case 0xA6: /* LDX zpg */ c->x = rd(c, am_zpg(c)); set_nz(c, c->x); c->cycles += 3; break;
    case 0xA7: /* LAX zpg */ c->a = c->x = rd(c, am_zpg(c)); set_nz(c, c->a); c->cycles += 3; break;
    case 0xA8: /* TAY */ c->y = c->a; set_nz(c, c->y); c->cycles += 2; break;
    case 0xA9: /* LDA imm */ c->a = rd(c, am_imm(c)); set_nz(c, c->a); c->cycles += 2; break;
    case 0xAA: /* TAX */ c->x = c->a; set_nz(c, c->x); c->cycles += 2; break;
    case 0xAB: /* LAX imm (unstable) */ c->a = c->x = rd(c, am_imm(c)); set_nz(c, c->a); c->cycles += 2; break;
    case 0xAC: /* LDY abs */ c->y = rd(c, am_abs(c)); set_nz(c, c->y); c->cycles += 4; break;
    case 0xAD: /* LDA abs */ c->a = rd(c, am_abs(c)); set_nz(c, c->a); c->cycles += 4; break;
    case 0xAE: /* LDX abs */ c->x = rd(c, am_abs(c)); set_nz(c, c->x); c->cycles += 4; break;
    case 0xAF: /* LAX abs */ c->a = c->x = rd(c, am_abs(c)); set_nz(c, c->a); c->cycles += 4; break;

    /* ---- Row 0xB0-0xBF ---- */
    case 0xB0: /* BCS */ op_branch(c, c->p & P_C); c->cycles += 2; break;
    case 0xB1: /* LDA izy */ c->a = rd(c, am_izy_p(c)); set_nz(c, c->a); c->cycles += 5; break;
    case 0xB2: c->halted = 1; break;
    case 0xB3: /* LAX izy */ c->a = c->x = rd(c, am_izy_p(c)); set_nz(c, c->a); c->cycles += 5; break;
    case 0xB4: /* LDY zpx */ c->y = rd(c, am_zpx(c)); set_nz(c, c->y); c->cycles += 4; break;
    case 0xB5: /* LDA zpx */ c->a = rd(c, am_zpx(c)); set_nz(c, c->a); c->cycles += 4; break;
    case 0xB6: /* LDX zpy */ c->x = rd(c, am_zpy(c)); set_nz(c, c->x); c->cycles += 4; break;
    case 0xB7: /* LAX zpy */ c->a = c->x = rd(c, am_zpy(c)); set_nz(c, c->a); c->cycles += 4; break;
    case 0xB8: /* CLV */ c->p &= ~P_V; c->cycles += 2; break;
    case 0xB9: /* LDA aby */ c->a = rd(c, am_aby_p(c)); set_nz(c, c->a); c->cycles += 4; break;
    case 0xBA: /* TSX */ c->x = c->sp; set_nz(c, c->x); c->cycles += 2; break;
    case 0xBB: /* LAS (unstable) */ { uint16_t a=am_aby_p(c); c->a=c->x=c->sp=rd(c,a)&c->sp; set_nz(c,c->a); c->cycles+=4; } break;
    case 0xBC: /* LDY abx */ c->y = rd(c, am_abx_p(c)); set_nz(c, c->y); c->cycles += 4; break;
    case 0xBD: /* LDA abx */ c->a = rd(c, am_abx_p(c)); set_nz(c, c->a); c->cycles += 4; break;
    case 0xBE: /* LDX aby */ c->x = rd(c, am_aby_p(c)); set_nz(c, c->x); c->cycles += 4; break;
    case 0xBF: /* LAX aby */ c->a = c->x = rd(c, am_aby_p(c)); set_nz(c, c->a); c->cycles += 4; break;

    /* ---- Row 0xC0-0xCF ---- */
    case 0xC0: /* CPY imm */ op_cmp(c, c->y, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0xC1: /* CMP izx */ op_cmp(c, c->a, rd(c, am_izx(c))); c->cycles += 6; break;
    case 0xC2: /* NOP imm */ c->pc++; c->cycles += 2; break;
    case 0xC3: /* DCP izx */ { uint16_t a=am_izx(c); uint8_t v=rd(c,a)-1; wr(c,a,v); op_cmp(c,c->a,v); c->cycles+=8; } break;
    case 0xC4: /* CPY zpg */ op_cmp(c, c->y, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0xC5: /* CMP zpg */ op_cmp(c, c->a, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0xC6: /* DEC zpg */ { uint16_t a=am_zpg(c); uint8_t v=rd(c,a)-1; wr(c,a,v); set_nz(c,v); c->cycles+=5; } break;
    case 0xC7: /* DCP zpg */ { uint16_t a=am_zpg(c); uint8_t v=rd(c,a)-1; wr(c,a,v); op_cmp(c,c->a,v); c->cycles+=5; } break;
    case 0xC8: /* INY */ c->y++; set_nz(c, c->y); c->cycles += 2; break;
    case 0xC9: /* CMP imm */ op_cmp(c, c->a, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0xCA: /* DEX */ c->x--; set_nz(c, c->x); c->cycles += 2; break;
    case 0xCB: /* SBX imm */ { uint8_t v=rd(c,c->pc++); uint16_t r=(uint16_t)(c->a&c->x)-v; c->x=r&0xFF; c->p=(c->p&~(P_N|P_Z|P_C))|(c->x&P_N)|(c->x?0:P_Z)|(r<0x100?P_C:0); c->cycles+=2; } break;
    case 0xCC: /* CPY abs */ op_cmp(c, c->y, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0xCD: /* CMP abs */ op_cmp(c, c->a, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0xCE: /* DEC abs */ { uint16_t a=am_abs(c); uint8_t v=rd(c,a)-1; wr(c,a,v); set_nz(c,v); c->cycles+=6; } break;
    case 0xCF: /* DCP abs */ { uint16_t a=am_abs(c); uint8_t v=rd(c,a)-1; wr(c,a,v); op_cmp(c,c->a,v); c->cycles+=6; } break;

    /* ---- Row 0xD0-0xDF ---- */
    case 0xD0: /* BNE */ op_branch(c, !(c->p & P_Z)); c->cycles += 2; break;
    case 0xD1: /* CMP izy */ op_cmp(c, c->a, rd(c, am_izy_p(c))); c->cycles += 5; break;
    case 0xD2: c->halted = 1; break;
    case 0xD3: /* DCP izy */ { uint16_t a=am_izy(c); uint8_t v=rd(c,a)-1; wr(c,a,v); op_cmp(c,c->a,v); c->cycles+=8; } break;
    case 0xD4: /* NOP zpx */ am_zpx(c); c->cycles += 4; break;
    case 0xD5: /* CMP zpx */ op_cmp(c, c->a, rd(c, am_zpx(c))); c->cycles += 4; break;
    case 0xD6: /* DEC zpx */ { uint16_t a=am_zpx(c); uint8_t v=rd(c,a)-1; wr(c,a,v); set_nz(c,v); c->cycles+=6; } break;
    case 0xD7: /* DCP zpx */ { uint16_t a=am_zpx(c); uint8_t v=rd(c,a)-1; wr(c,a,v); op_cmp(c,c->a,v); c->cycles+=6; } break;
    case 0xD8: /* CLD */ c->p &= ~P_D; c->cycles += 2; break;
    case 0xD9: /* CMP aby */ op_cmp(c, c->a, rd(c, am_aby_p(c))); c->cycles += 4; break;
    case 0xDA: /* NOP */ c->cycles += 2; break;
    case 0xDB: /* DCP aby */ { uint16_t a=am_aby(c); uint8_t v=rd(c,a)-1; wr(c,a,v); op_cmp(c,c->a,v); c->cycles+=7; } break;
    case 0xDC: /* NOP abx */ am_abx_p(c); c->cycles += 4; break;
    case 0xDD: /* CMP abx */ op_cmp(c, c->a, rd(c, am_abx_p(c))); c->cycles += 4; break;
    case 0xDE: /* DEC abx */ { uint16_t a=am_abx(c); uint8_t v=rd(c,a)-1; wr(c,a,v); set_nz(c,v); c->cycles+=7; } break;
    case 0xDF: /* DCP abx */ { uint16_t a=am_abx(c); uint8_t v=rd(c,a)-1; wr(c,a,v); op_cmp(c,c->a,v); c->cycles+=7; } break;

    /* ---- Row 0xE0-0xEF ---- */
    case 0xE0: /* CPX imm */ op_cmp(c, c->x, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0xE1: /* SBC izx */ do_sbc(c, rd(c, am_izx(c))); c->cycles += 6; break;
    case 0xE2: /* NOP imm */ c->pc++; c->cycles += 2; break;
    case 0xE3: /* ISB izx */ { uint16_t a=am_izx(c); uint8_t v=rd(c,a)+1; wr(c,a,v); do_sbc(c,v); c->cycles+=8; } break;
    case 0xE4: /* CPX zpg */ op_cmp(c, c->x, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0xE5: /* SBC zpg */ do_sbc(c, rd(c, am_zpg(c))); c->cycles += 3; break;
    case 0xE6: /* INC zpg */ { uint16_t a=am_zpg(c); uint8_t v=rd(c,a)+1; wr(c,a,v); set_nz(c,v); c->cycles+=5; } break;
    case 0xE7: /* ISB zpg */ { uint16_t a=am_zpg(c); uint8_t v=rd(c,a)+1; wr(c,a,v); do_sbc(c,v); c->cycles+=5; } break;
    case 0xE8: /* INX */ c->x++; set_nz(c, c->x); c->cycles += 2; break;
    case 0xE9: /* SBC imm */ do_sbc(c, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0xEA: /* NOP */ c->cycles += 2; break;
    case 0xEB: /* SBC imm (illegal mirror) */ do_sbc(c, rd(c, am_imm(c))); c->cycles += 2; break;
    case 0xEC: /* CPX abs */ op_cmp(c, c->x, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0xED: /* SBC abs */ do_sbc(c, rd(c, am_abs(c))); c->cycles += 4; break;
    case 0xEE: /* INC abs */ { uint16_t a=am_abs(c); uint8_t v=rd(c,a)+1; wr(c,a,v); set_nz(c,v); c->cycles+=6; } break;
    case 0xEF: /* ISB abs */ { uint16_t a=am_abs(c); uint8_t v=rd(c,a)+1; wr(c,a,v); do_sbc(c,v); c->cycles+=6; } break;

    /* ---- Row 0xF0-0xFF ---- */
    case 0xF0: /* BEQ */ op_branch(c, c->p & P_Z); c->cycles += 2; break;
    case 0xF1: /* SBC izy */ do_sbc(c, rd(c, am_izy_p(c))); c->cycles += 5; break;
    case 0xF2: c->halted = 1; break;
    case 0xF3: /* ISB izy */ { uint16_t a=am_izy(c); uint8_t v=rd(c,a)+1; wr(c,a,v); do_sbc(c,v); c->cycles+=8; } break;
    case 0xF4: /* NOP zpx */ am_zpx(c); c->cycles += 4; break;
    case 0xF5: /* SBC zpx */ do_sbc(c, rd(c, am_zpx(c))); c->cycles += 4; break;
    case 0xF6: /* INC zpx */ { uint16_t a=am_zpx(c); uint8_t v=rd(c,a)+1; wr(c,a,v); set_nz(c,v); c->cycles+=6; } break;
    case 0xF7: /* ISB zpx */ { uint16_t a=am_zpx(c); uint8_t v=rd(c,a)+1; wr(c,a,v); do_sbc(c,v); c->cycles+=6; } break;
    case 0xF8: /* SED */ c->p |= P_D; c->cycles += 2; break;
    case 0xF9: /* SBC aby */ do_sbc(c, rd(c, am_aby_p(c))); c->cycles += 4; break;
    case 0xFA: /* NOP */ c->cycles += 2; break;
    case 0xFB: /* ISB aby */ { uint16_t a=am_aby(c); uint8_t v=rd(c,a)+1; wr(c,a,v); do_sbc(c,v); c->cycles+=7; } break;
    case 0xFC: /* NOP abx */ am_abx_p(c); c->cycles += 4; break;
    case 0xFD: /* SBC abx */ do_sbc(c, rd(c, am_abx_p(c))); c->cycles += 4; break;
    case 0xFE: /* INC abx */ { uint16_t a=am_abx(c); uint8_t v=rd(c,a)+1; wr(c,a,v); set_nz(c,v); c->cycles+=7; } break;
    case 0xFF: /* ISB abx */ { uint16_t a=am_abx(c); uint8_t v=rd(c,a)+1; wr(c,a,v); do_sbc(c,v); c->cycles+=7; } break;
    }
}

/* ---- Cycle-cost lookahead ---------------------------------------------- */

/* Base cycles charged by cpu6502_step() per opcode — generated from the
 * `c->cycles += N` constants in the switch above (so it can never disagree
 * with the implementation; regenerate if the switch changes).  Excludes the
 * conditional penalties (branch taken +1, page cross +1) the helpers add —
 * callers gate dispatch on the base and absorb penalties as cycle debt.
 * KIL/jam opcodes read as 1 (step() charges 1 per call while halted).
 *
 * Packed two opcodes per byte (even opcode = low nibble; max cost is 8):
 * the firmware is copy_to_ram and was 32 bytes from the RAM ceiling, so a
 * flat 256-byte table did not fit. */
static const uint8_t cyc_packed[128] = {
    0x67, 0x81, 0x33, 0x55, 0x23, 0x22, 0x44, 0x66,   /* 00-0F */
    0x52, 0x81, 0x44, 0x66, 0x42, 0x72, 0x44, 0x77,   /* 10-1F */
    0x66, 0x81, 0x33, 0x55, 0x24, 0x22, 0x44, 0x66,   /* 20-2F */
    0x52, 0x81, 0x44, 0x66, 0x42, 0x72, 0x44, 0x77,   /* 30-3F */
    0x66, 0x81, 0x33, 0x55, 0x23, 0x22, 0x43, 0x66,   /* 40-4F */
    0x52, 0x81, 0x44, 0x66, 0x42, 0x72, 0x44, 0x77,   /* 50-5F */
    0x66, 0x81, 0x33, 0x55, 0x24, 0x22, 0x45, 0x66,   /* 60-6F */
    0x52, 0x81, 0x44, 0x66, 0x42, 0x72, 0x44, 0x77,   /* 70-7F */
    0x62, 0x62, 0x33, 0x33, 0x22, 0x22, 0x44, 0x44,   /* 80-8F */
    0x62, 0x61, 0x44, 0x44, 0x52, 0x52, 0x55, 0x55,   /* 90-9F */
    0x62, 0x62, 0x33, 0x33, 0x22, 0x22, 0x44, 0x44,   /* A0-AF */
    0x52, 0x51, 0x44, 0x44, 0x42, 0x42, 0x44, 0x44,   /* B0-BF */
    0x62, 0x82, 0x33, 0x55, 0x22, 0x22, 0x44, 0x66,   /* C0-CF */
    0x52, 0x81, 0x44, 0x66, 0x42, 0x72, 0x44, 0x77,   /* D0-DF */
    0x62, 0x82, 0x33, 0x55, 0x22, 0x22, 0x44, 0x66,   /* E0-EF */
    0x52, 0x81, 0x44, 0x66, 0x42, 0x72, 0x44, 0x77    /* F0-FF */
};

/* What the NEXT cpu6502_step() call will cost, given the opcode at PC
 * (fetched side-effect-free by the caller, who knows the memory map).
 * Mirrors the dispatch order at the top of step(): jam, NMI edge, IRQ,
 * then the opcode. */
int cpu6502_next_cost(const cpu6502_t *c, uint8_t op)
{
    if (c->halted) return 1;
    if (c->nmi && !c->nmi_prev) return 7;
    if (c->irq && !(c->p & P_I)) return 7;
    return (cyc_packed[op >> 1] >> ((op & 1) * 4)) & 0x0F;
}
