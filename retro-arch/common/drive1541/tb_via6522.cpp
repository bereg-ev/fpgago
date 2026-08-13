/*
 * tb_via6522.cpp — lockstep conformance test: via6522.v vs the PROVEN
 * reference model common/floppy1541/via6522.c (the one the whole 1541 compat
 * corpus was verified against).
 *
 * Every cycle: maybe one register access (read compares rdata against the
 * C model's return), random pin/CA1/CB1 wiggling, one tick on both — then
 * the FULL register state is compared.  Runs random soup plus targeted
 * timer/IFR sequences.  Any divergence prints and exits 1.
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include "Vvia6522.h"
#include "verilated.h"

extern "C" {
#include "via6522.c"    /* the reference, compiled in whole */
}

static via6522_t ref;
static Vvia6522 *dut;
static uint64_t cyc = 0;
static int errors = 0;

static uint32_t rng_state = 0x1541c64d;
static uint32_t rng() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

static void clock_dut() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
}

#define CHK(name, got, want) do { \
    if ((uint32_t)(got) != (uint32_t)(want)) { \
        printf("MISMATCH @%llu %s: rtl=%02X ref=%02X\n", \
               (unsigned long long)cyc, name, (unsigned)(got), \
               (unsigned)(want)); \
        if (++errors > 20) { printf("too many, aborting\n"); exit(1); } \
    } } while (0)

static void compare_state() {
    CHK("orb",  dut->orb_q,  ref.orb);
    CHK("ora",  dut->ora_q,  ref.ora);
    CHK("ddrb", dut->ddrb_q, ref.ddrb);
    CHK("ddra", dut->ddra_q, ref.ddra);
    CHK("t1c",  dut->dbg_t1c, ref.t1c);
    CHK("t1l",  dut->dbg_t1l, ref.t1l);
    CHK("t2c",  dut->dbg_t2c, ref.t2c);
    CHK("t2l",  dut->dbg_t2l, ref.t2l);
    CHK("sr",   dut->dbg_sr,  ref.sr);
    CHK("acr",  dut->dbg_acr, ref.acr);
    CHK("pcr",  dut->dbg_pcr, ref.pcr);
    CHK("ifr",  dut->dbg_ifr, ref.ifr & 0x7F);
    CHK("ier",  dut->dbg_ier, ref.ier & 0x7F);
    CHK("irq",  dut->irq,     ref.irq);
    CHK("t1a",  dut->dbg_t1_active, ref.t1_active);
    CHK("t2a",  dut->dbg_t2_active, ref.t2_active);
    CHK("pb7",  dut->t1_pb7_q, ref.t1_pb7);
}

/* one lockstep cycle: optional access + pin state + tick, both models */
static void step(int do_acc, int we, uint8_t addr, uint8_t val,
                 uint8_t pa, uint8_t pb, int ca1, int cb1) {
    /* pins first (the C model's glue sets them before tick) */
    ref.pa_in = pa;  ref.pb_in = pb;
    ref.ca1 = ca1;   ref.cb1 = cb1;
    dut->pa_in = pa; dut->pb_in = pb;
    dut->ca1 = ca1;  dut->cb1 = cb1;

    dut->tick = 1;
    dut->acc_stb = do_acc ? 1 : 0;
    dut->acc_we = we;
    dut->acc_addr = addr & 0x0F;
    dut->acc_wdata = val;
    dut->eval();                       /* rdata is combinational */

    if (do_acc) {
        if (we) {
            via6522_write(&ref, addr & 0x0F, val);
        } else {
            uint8_t want = via6522_read(&ref, addr & 0x0F);
            CHK("rdata", dut->rdata, want);
        }
    }
    via6522_tick(&ref, 1);

    clock_dut();
    dut->acc_stb = 0; dut->tick = 0;
    cyc++;
    compare_state();
}

static void reset_both() {
    via6522_init(&ref);
    via6522_reset(&ref);
    dut->rst = 1; dut->tick = 0; dut->acc_stb = 0;
    dut->ca1 = 0; dut->cb1 = 0; dut->pa_in = 0; dut->pb_in = 0;
    clock_dut();
    dut->rst = 0;
    compare_state();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vvia6522;

    reset_both();

    /* ── targeted: T1 one-shot + free-run reload, PB7 toggle ── */
    step(1, 1, 0x0B, 0x40, 0, 0, 0, 0);          /* ACR: T1 free-run   */
    step(1, 1, 0x04, 0x05, 0, 0, 0, 0);          /* T1L-L = 5          */
    step(1, 1, 0x05, 0x00, 0, 0, 0, 0);          /* T1C-H: start       */
    for (int i = 0; i < 40; i++) step(0, 0, 0, 0, 0, 0, 0, 0);
    step(1, 0, 0x04, 0, 0, 0, 0, 0);             /* read T1C-L: clear  */
    step(1, 1, 0x0B, 0x00, 0, 0, 0, 0);          /* ACR: one-shot      */
    step(1, 1, 0x05, 0x00, 0, 0, 0, 0);          /* restart            */
    for (int i = 0; i < 40; i++) step(0, 0, 0, 0, 0, 0, 0, 0);

    /* ── targeted: T2 timed one-shot ── */
    step(1, 1, 0x08, 0x03, 0, 0, 0, 0);          /* T2L-L = 3          */
    step(1, 1, 0x09, 0x00, 0, 0, 0, 0);          /* T2C-H: start       */
    for (int i = 0; i < 20; i++) step(0, 0, 0, 0, 0, 0, 0, 0);
    step(1, 0, 0x08, 0, 0, 0, 0, 0);             /* read clears flag   */

    /* ── targeted: CA1/CB1 edges both polarities, IER gating ── */
    step(1, 1, 0x0E, 0x92, 0, 0, 0, 0);          /* IER: set CA1+CB1   */
    step(1, 1, 0x0C, 0x01, 0, 0, 0, 0);          /* PCR: CA1 pos edge  */
    step(0, 0, 0, 0, 0, 0, 1, 0);                /* CA1 rises → IRQ    */
    step(0, 0, 0, 0, 0, 0, 0, 0);                /* falls (no flag)    */
    step(1, 0, 0x01, 0, 0, 0, 0, 0);             /* read ORA clears    */
    step(1, 1, 0x0C, 0x00, 0, 0, 0, 0);          /* PCR: neg edges     */
    step(0, 0, 0, 0, 0, 0, 1, 1);                /* rise: no flags     */
    step(0, 0, 0, 0, 0, 0, 0, 0);                /* fall: both flags   */
    step(1, 1, 0x0D, 0x7F, 0, 0, 0, 0);          /* IFR write-clear    */
    step(1, 1, 0x0E, 0x12, 0, 0, 0, 0);          /* IER clear CA1+CB1  */

    /* ── random soup ── */
    long n = (argc > 1) ? atol(argv[1]) : 2000000;
    uint8_t pa = 0, pb = 0; int ca1 = 0, cb1 = 0;
    for (long i = 0; i < n; i++) {
        uint32_t r = rng();
        int do_acc = 0, we = 0; uint8_t addr = 0, val = 0;
        if ((r & 0xF) < 5) { do_acc = 1; we = 1; }       /* 5/16 write */
        else if ((r & 0xF) < 8) { do_acc = 1; we = 0; }  /* 3/16 read  */
        addr = (r >> 8) & 0x0F;
        val = (r >> 16) & 0xFF;
        if (((r >> 24) & 7) == 0) pa = rng();
        if (((r >> 24) & 7) == 1) pb = rng();
        if (((r >> 27) & 7) == 0) ca1 ^= 1;
        if (((r >> 27) & 7) == 1) cb1 ^= 1;
        step(do_acc, we, addr, val, pa, pb, ca1, cb1);
        if (errors) break;
    }

    printf("via6522 lockstep: %llu cycles, %d mismatches — %s\n",
           (unsigned long long)cyc, errors, errors ? "FAIL" : "PASS");
    delete dut;
    return errors ? 1 : 0;
}
