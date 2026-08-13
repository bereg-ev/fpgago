/*
 * tb_drive1541.cpp — DOS-level conformance for the fabric 1541.
 *
 * Boots drive_1541.v with the REAL 16 KB DOS ROM and drives it over the
 * IEC wires with the same KERNAL-style scripted master as
 * the firmware's DOS conformance test (ported; backend = the Verilated RTL).
 * The GCR track stream is pre-encoded with the REFERENCE encoder
 * (floppy1541.c's gcr_encode_group, compiled in whole), so the RTL reads
 * exactly the bytes the proven emulation would produce.
 *
 * Checks, in order:
 *   1. power-on status = "73,CBM DOS..." (boot + IRQ + IEC + ch15 path)
 *   2. M-R $FFFC → the ROM's own reset vector (Street Fighter's probe)
 *   3. M-W + M-E + M-R: code EXECUTES on the drive CPU (the capability
 *      no MCU mode could provide)
 *   4. OPEN "GAME" + TALK: full file readback, byte-exact (spin-up, seek,
 *      GCR read, checksum, sector chaining — the whole mechanism)
 *
 *   ./obj_drive/drive_tb +rom=<1541.bin> [+phi=<clks-per-phi>]
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#ifdef PSRAM_TOP
#include "Vdrive_psram_top.h"
typedef Vdrive_psram_top DUT;
#else
#include "Vdrive_1541.h"
typedef Vdrive_1541 DUT;
#endif
#include "verilated.h"

extern "C" {
#include "floppy1541.c"     /* reference GCR encoder + d64 helpers */
}

/* ── DUT + wall clock ───────────────────────────────────────────────────── */

static DUT *dut;
static int CLKS_PER_PHI = 2;
static uint64_t now_us;                    /* drive phi ticks elapsed */

static uint8_t rom[16384];
#define TRACK_STRIDE 8192
static uint8_t gcr[35 * TRACK_STRIDE];

static int h_atn, h_clk, h_data;           /* host pulls (1 = pull LOW) */

static int use_cmodel = 0;                 /* +cmodel: run the script against
                                            * floppy1541.c full-emu instead —
                                            * proves the SCRIPT before it may
                                            * condemn the RTL */
static floppy1541_t F;

static int tests_run, tests_failed;
#define CHECK(cond, ...) do { \
    tests_run++; \
    if (!(cond)) { \
        tests_failed++; \
        printf("FAIL %s:%d: ", __func__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } } while (0)

static int drv_clk_pull(void)  { return use_cmodel ? F.out_clk  : dut->iec_clk_pull; }
static int drv_data_pull(void) { return use_cmodel ? F.out_data : dut->iec_data_pull; }
static int bus_clk(void)  { return (h_clk  || drv_clk_pull())  ? 0 : 1; }
static int bus_data(void) { return (h_data || drv_data_pull()) ? 0 : 1; }
static int bus_atn(void)  { return h_atn ? 0 : 1; }

/* one drive phi: settle the wired-AND (data_pull is comb in ATN), serve
 * the memories, clock CLKS_PER_PHI fabric cycles with tick on the first */
static long trace_left = 0;
static void bus_step(int us)
{
    while (us-- > 0) {
        now_us++;
        if (use_cmodel) {
            floppy1541_update(&F, (uint32_t)now_us, bus_atn(),
                              (h_clk || F.out_clk) ? 0 : 1,
                              (h_data || F.out_data) ? 0 : 1);
            {   static long from = -1, until = -1;
                if (from < 0) {
                    from  = getenv("PCTRACE") ? atol(getenv("PCTRACE")) : 0;
                    until = from + (getenv("PCLEN") ? atol(getenv("PCLEN")) : 3000);
                }
                if (from > 0 && (long)now_us >= from && (long)now_us < until) {
                    static uint16_t pp = 0; static int pa=-1,pk=-1,pd=-1;
                    int a=bus_atn(),k=(h_clk||F.out_clk)?0:1,d=(h_data||F.out_data)?0:1;
                    if ((now_us % 20) == 0 && F.cpu.pc != pp) {
                        printf("pct %llu pc=%04X\n",(unsigned long long)now_us,F.cpu.pc);
                        pp=F.cpu.pc;
                    }
                    if (a!=pa||k!=pk||d!=pd) {
                        printf("pct %llu wire atn=%d clk=%d data=%d (hatn=%d hclk=%d hdata=%d pb1=%d atna=%d)\n",
                               (unsigned long long)now_us,a,k,d,h_atn,h_clk,h_data,
                               (F.via1.orb>>1)&1,(F.via1.orb>>4)&1);
                        pa=a;pk=k;pd=d;
                    }
                }
            }
            continue;
        }
        for (int i = 0; i < CLKS_PER_PHI; i++) {
#ifndef PSRAM_TOP
            dut->tick = (i == 0);
#endif
            dut->iec_atn = bus_atn();
            dut->eval();                       /* ATN-ack may move pulls */
            dut->iec_clk_in  = bus_clk();
            dut->iec_data_in = bus_data();
            dut->eval();
#ifndef PSRAM_TOP
            dut->rom_data = rom[dut->rom_addr & 0x3FFF];
            dut->gcr_data = gcr[dut->gcr_addr % (uint32_t)sizeof(gcr)];
            dut->eval();
#endif
            if (i == 0 && trace_left > 0) {
                trace_left--;
                printf("[%8llu] AB=%04X DI=%02X WE=%d\n",
                       (unsigned long long)now_us, dut->dbg_cpu_ab,
                       0 /* DI is internal */, 0);
            }
            dut->clk = 1; dut->eval();
            dut->clk = 0; dut->eval();
        }
    }
}

#define BUS_WAIT(cond, max_us) ({ \
    long _t = 0, _max = (max_us); \
    while (!(cond) && _t < _max) { bus_step(1); _t++; } \
    (_t < _max); \
})

/* ── host talker/listener (ported from test_dos1541.c; timeouts widened
 *    because a REAL DOS answers between jobs — spin-up, seeks and sector
 *    reads land inside the ready waits) ──────────────────────────────── */

#define WHY(tag) do { if (getenv("WHY")) \
    printf("why: %s @%llu AB=%04X pc=%04X $98=%02X $85=%02X clkp=%d datap=%d hclk=%d hdata=%d hatn=%d\n", \
           tag, (unsigned long long)now_us, dut->dbg_cpu_ab, \
           use_cmodel ? F.cpu.pc : 0, use_cmodel ? F.ram[0x98] : 0, \
           use_cmodel ? F.ram[0x85] : 0, \
           drv_clk_pull(), drv_data_pull(), h_clk, h_data, h_atn); \
    if (getenv("WHY") && use_cmodel) \
        printf("     via1 orb=%02X ddrb=%02X (pb1=%d atna=%d) 79=%02X 7A=%02X 84=%02X\n", \
               F.via1.orb, F.via1.ddrb, (F.via1.orb>>1)&1, (F.via1.orb>>4)&1, \
               F.ram[0x79], F.ram[0x7A], F.ram[0x84]); } while (0)

static int bittrace = 0;
static int host_send_byte(uint8_t b, int eoi)
{
    h_clk = 0;
    if (!BUS_WAIT(bus_data() == 1, 8000000)) { WHY("send:listener-ready"); return 0; }
    if (bittrace && use_cmodel) {
        /* trace the whole bit frame at 4us resolution */
        bittrace = 0;
        for (int i = 0; i < 8; i++) {
            h_clk = 1; h_data = ((b >> i) & 1) ? 0 : 1;
            for (int k = 0; k < 15; k++) { bus_step(4);
                printf("bit%d A pc=%04X 98=%02X clkw=%d dataw=%d\n",
                       i, F.cpu.pc, F.ram[0x98], bus_clk(), bus_data()); }
            h_clk = 0;
            for (int k = 0; k < 15; k++) { bus_step(4);
                printf("bit%d B pc=%04X 98=%02X clkw=%d dataw=%d\n",
                       i, F.cpu.pc, F.ram[0x98], bus_clk(), bus_data()); }
        }
        h_clk = 1; h_data = 0;
        for (int k = 0; k < 40; k++) { bus_step(10);
            printf("ack pc=%04X 98=%02X 85=%02X datap=%d\n",
                   F.cpu.pc, F.ram[0x98], F.ram[0x85], drv_data_pull()); }
        exit(0);
    }
    if (eoi) {
        if (!BUS_WAIT(drv_data_pull() == 1, 500000)) { WHY("send:eoi-ack1"); return 0; }
        if (!BUS_WAIT(drv_data_pull() == 0, 500000)) { WHY("send:eoi-ack2"); return 0; }
    }
    /* mirror the KERNAL's $ED40 frame ON THE WIRE: CLK asserts immediately
     * at listener-ready ($ED5F) while DATA STAYS RELEASED through the
     * debounce gap — the DOS's $FF20 "wait DATA high" runs in exactly that
     * window, and a 0-bit placed too early wedges it (found the hard way:
     * the C-model cross-check counted 4 of 8 bits).  Every bit ends with
     * CLK-assert + DATA-release in one write ($ED8B). */
    h_clk = 1;
    bus_step(40);
    /* real-KERNAL phase lengths: ~65 us asserted (setup), ~25-30 us
     * released (valid).  The DOS's wait-assert poll ($EA1A: two JSRs,
     * ~50 cycles/iteration) MISSES a shorter assert phase and slips a
     * bit — found against the C model at 35 us. */
    for (int i = 0; i < 8; i++) {
        h_data = ((b >> i) & 1) ? 0 : 1;          /* setup, CLK asserted */
        bus_step(55);
        h_clk = 0;                                /* bit valid */
        bus_step(30);
        h_clk = 1; h_data = 0;                    /* $ED8B */
        bus_step(15);
    }
    if (!BUS_WAIT(drv_data_pull() == 1, 1000000)) { WHY("send:byte-ack"); return 0; }
    bus_step(100);
    return 1;
}

static int host_atn_cmd(const uint8_t *bytes, int n)
{
    if (getenv("MARK"))
        printf("mark atn_cmd @%llu: %02X%s\n", (unsigned long long)now_us,
               bytes[0], n > 1 ? " +sec" : "");
    h_atn = 1; h_clk = 1; h_data = 0;
    bus_step(1000);
    for (int i = 0; i < n; i++)
        if (!host_send_byte(bytes[i], 0)) return 0;
    h_atn = 0;
    bus_step(200);
    return 1;
}

static int host_atn1(uint8_t b0) { return host_atn_cmd(&b0, 1); }
static int host_atn2(uint8_t b0, uint8_t b1)
{ uint8_t b[2] = { b0, b1 }; return host_atn_cmd(b, 2); }

static int host_send_data(const uint8_t *d, int n)
{
    for (int i = 0; i < n; i++)
        if (!host_send_byte(d[i], i == n - 1)) return 0;
    /* the talker HOLDS CLK asserted after a byte — releasing it here walks
     * the DOS through $E9D7 into the $FF20 DATA-wait (which never polls
     * ATN), and the next ATN assert gate-pulls DATA low = deadlock.  Found
     * against the C model; the follow-up ATN round keeps CLK asserted. */
    h_data = 0;
    bus_step(200);
    return 1;
}

static int host_recv_byte(uint8_t *out, int *eoi)
{
    *eoi = 0;
    if (!BUS_WAIT(bus_clk() == 1, 8000000)) { WHY("recv:talker-ready"); return 0; }
    bus_step(30);
    h_data = 0;
    int t = 0;
    while (bus_clk() == 1 && t < 350) { bus_step(1); t++; }
    if (t >= 350) {
        *eoi = 1;
        h_data = 1; bus_step(80); h_data = 0;
        if (!BUS_WAIT(bus_clk() == 0, 100000)) return 0;
    }
    uint8_t b = 0;
    for (int i = 0; i < 8; i++) {
        if (!BUS_WAIT(bus_clk() == 1, 100000)) return 0;
        b |= (uint8_t)((bus_data() & 1) << i);
        if (i < 7 && !BUS_WAIT(bus_clk() == 0, 100000)) return 0;
    }
    bus_step(30);
    h_data = 1;
    bus_step(100);
    *out = b;
    return 1;
}

static int host_read_channel(int ch, uint8_t *buf, int max)
{
    h_atn = 1; h_clk = 1; h_data = 0;
    bus_step(1000);
    if (!host_send_byte(0x48, 0)) return -1;
    if (!host_send_byte((uint8_t)(0x60 | ch), 0)) return -1;
    h_data = 1; h_clk = 0;
    bus_step(50);
    h_atn = 0;                                 /* turnaround */
    if (!BUS_WAIT(drv_clk_pull() == 1, 8000000)) { WHY("talk:turnaround"); h_data = 0; return -1; }
    int n = 0;
    while (n < max) {
        uint8_t b; int eoi;
        if (!host_recv_byte(&b, &eoi)) return -1;
        buf[n++] = b;
        if (eoi) break;
    }
    h_data = 0;
    bus_step(300);
    if (!host_atn1(0x5F)) return -1;           /* UNTALK */
    h_clk = 0;
    bus_step(300);
    return n;
}

static int host_open(int ch, const uint8_t *name, int n)
{
    if (!host_atn2(0x28, (uint8_t)(0xF0 | ch))) return 0;
    if (n && !host_send_data(name, n)) return 0;
    if (!host_atn1(0x3F)) return 0;
    h_clk = 0; bus_step(200);
    return 1;
}

static int host_write_channel(int ch, const uint8_t *d, int n)
{
    if (!host_atn2(0x28, (uint8_t)(0x60 | ch))) return 0;
    if (!host_send_data(d, n)) return 0;
    if (!host_atn1(0x3F)) return 0;
    h_clk = 0; bus_step(200);
    return 1;
}

/* ── test disk: one PRG "GAME" on track 17, GCR-encoded the reference way */

static uint8_t d64img[683 * 256];
static uint8_t game_prg[600];

static void build_disk_and_gcr(void)
{
    memset(d64img, 0, sizeof(d64img));
    uint8_t *bam = d64img + d64_offset(18, 0);
    bam[0] = 18; bam[1] = 1; bam[2] = 'A';
    bam[0xA2] = 'F'; bam[0xA3] = 'G';          /* disk ID */
    for (int t = 1; t <= 35; t++) {            /* all-free BAM bitmap */
        uint32_t map = (1u << d64_sectors_per_track(t)) - 1;
        if (t == 18) map &= ~3u;
        uint8_t *e = bam + 4 + (t - 1) * 4;
        e[0] = (uint8_t)__builtin_popcount(map);
        e[1] = map & 0xFF; e[2] = (map >> 8) & 0xFF; e[3] = (map >> 16) & 0xFF;
    }
    uint8_t *dir = d64img + d64_offset(18, 1);
    dir[0] = 0; dir[1] = 0xFF;
    uint8_t *en = dir + 2;
    en[0] = 0x82; en[1] = 17; en[2] = 0;       /* PRG at 17/0 */
    memset(en + 3, 0xA0, 16);
    memcpy(en + 3, "GAME", 4);
    en[28] = 3;                                /* 3 blocks */

    for (int i = 0; i < (int)sizeof(game_prg); i++)
        game_prg[i] = (uint8_t)(i * 7 + (i >> 3));
    int left = sizeof(game_prg), src = 0;
    for (int s = 0; s < 3; s++) {
        uint8_t *sec = d64img + d64_offset(17, s);
        int chunk = left > 254 ? 254 : left;
        if (left > 254) { sec[0] = 17; sec[1] = (uint8_t)(s + 1); }
        else           { sec[0] = 0;  sec[1] = (uint8_t)(chunk + 1); }
        memcpy(sec + 2, game_prg + src, chunk);
        src += chunk; left -= chunk;
    }

    /* GCR: the reference sector layout, via the reference encoder */
    memset(gcr, 0x55, sizeof(gcr));
    for (int t = 1; t <= 35; t++) {
        uint8_t *out = gcr + (t - 1) * TRACK_STRIDE;
        int ns = d64_sectors_per_track(t);
        for (int s = 0; s < ns; s++) {
            uint8_t *p = out + s * F1541_GCR_SECTOR_LEN;
            const uint8_t *data = d64img + d64_offset(t, s);
            for (int i = 0; i < 5; i++) *p++ = 0xFF;
            uint8_t hdr[8] = { 0x08,
                (uint8_t)(s ^ t ^ bam[0xA3] ^ bam[0xA2]),
                (uint8_t)s, (uint8_t)t, bam[0xA3], bam[0xA2], 0x0F, 0x0F };
            gcr_encode_group(hdr, p);     p += 5;
            gcr_encode_group(hdr + 4, p); p += 5;
            for (int i = 0; i < 9; i++) *p++ = 0x55;
            for (int i = 0; i < 5; i++) *p++ = 0xFF;
            uint8_t dblk[260];
            dblk[0] = 0x07;
            memcpy(dblk + 1, data, 256);
            uint8_t xs = 0;
            for (int i = 0; i < 256; i++) xs ^= data[i];
            dblk[257] = xs; dblk[258] = 0; dblk[259] = 0;
            for (int i = 0; i < 65; i++) { gcr_encode_group(dblk + i * 4, p); p += 5; }
            for (int i = 0; i < 9; i++) *p++ = 0x55;
        }
    }
}

/* ── tests ──────────────────────────────────────────────────────────────── */

static uint8_t buf[4096];

#ifdef PSRAM_TOP
static void push_byte(uint32_t addr, uint8_t d)
{
    while (dut->push_busy) bus_step(1);
    dut->push_addr = addr & 0x3FFFFF;
    dut->push_data = d;
    dut->push_we = 1;
    bus_step(1);
    dut->push_we = 0;
}
#endif

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *rom_path = "../../plus4/roms/1541.bin";
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "+rom=", 5)) rom_path = argv[i] + 5;
        if (!strncmp(argv[i], "+phi=", 5)) CLKS_PER_PHI = atoi(argv[i] + 5);
    }
    if (getenv("CMODEL")) use_cmodel = 1;
    if (getenv("BITTRACE")) bittrace = 1;
    FILE *f = fopen(rom_path, "rb");
    if (!f || fread(rom, 1, sizeof(rom), f) != sizeof(rom)) {
        printf("cannot load 16KB ROM from %s (+rom=)\n", rom_path);
        return 1;
    }
    fclose(f);

    build_disk_and_gcr();

    dut = new DUT;
    if (use_cmodel) {
        floppy1541_init(&F, 8);
        floppy1541_insert_d64(&F, d64img, sizeof(d64img), 0);
        floppy1541_load_rom(&F, rom);      /* full 6502 emulation mode */
    }
    dut->rst = 1; dut->disk_writable = 0;
    h_atn = h_clk = h_data = 0;
#ifdef PSRAM_TOP
    /* stream ROM + GCR through the push port with the drive held in
     * reset (push_mode) — the mount-time path the MCU will drive */
    if (!use_cmodel) {
        CLKS_PER_PHI = 32;                /* the wrapper's real PHI_DIV */
        dut->push_mode = 1; dut->push_we = 0;
        bus_step(10);
        dut->rst = 0;
        for (uint32_t i = 0; i < sizeof(rom); i++)
            push_byte(0x200000u + i, rom[i]);
        for (uint32_t i = 0; i < sizeof(gcr); i++)
            push_byte(0x210000u + i, gcr[i]);
        dut->push_mode = 0;
        printf("pushed %u bytes into PSRAM\n",
               (unsigned)(sizeof(rom) + sizeof(gcr)));
    } else {
        bus_step(10);
        dut->rst = 0;
    }
#else
    bus_step(10);
    dut->rst = 0;
#endif
    if (getenv("TRACE"))
        trace_left = atol(getenv("TRACE"));

    printf("booting DOS (%d clks/phi)...\n", CLKS_PER_PHI);
    if (getenv("BOOTNOISE")) {
        /* replicate the soc: the C64 wiggles ATN/CLK/DATA while the
         * drive runs its power-on tests */
        uint32_t nz = 0x1541beef;
        for (int i = 0; i < 18000; i++) {
            nz ^= nz << 13; nz ^= nz >> 17; nz ^= nz << 5;
            uint32_t r = nz;
            h_atn  = r & 1;
            h_clk  = (r >> 1) & 1;
            h_data = (r >> 2) & 1;
            bus_step(100);
        }
        h_atn = h_clk = h_data = 0;
    } else
        bus_step(1800000);                    /* ROM+RAM test ≈ 1.2 s */

    if (getenv("POSTBOOT")) {                 /* where did the DOS park? */
        printf("post-boot: motor=%d led=%d ht=%d clk_pull=%d data_pull=%d\n",
               dut->dbg_motor, dut->dbg_led, dut->dbg_halftrack,
               dut->iec_clk_pull, dut->iec_data_pull);
        for (int i = 0; i < 24; i++) {
            printf("%04X ", dut->dbg_cpu_ab);
            bus_step(1);
        }
        printf("\n");
        h_atn = 1;                            /* poke ATN, watch the ack */
        bus_step(2000);
        printf("ATN asserted: data_pull=%d (hw ack)\n", dut->iec_data_pull);
        for (int i = 0; i < 24; i++) {
            printf("%04X ", dut->dbg_cpu_ab);
            bus_step(1);
        }
        printf("\n");
        h_atn = 0;
        bus_step(2000);
    }

    /* 1: power-on status */
    int n = host_read_channel(15, buf, sizeof(buf) - 1);
    buf[n > 0 ? n : 0] = 0;
    printf("status: %s\n", n > 0 ? (char *)buf : "(none)");
    CHECK(n > 2 && buf[0] == '7' && buf[1] == '3',
          "power-on status not 73 (n=%d)", n);

    /* 2: M-R $FFFC — the Street Fighter drive-detect probe */
    { uint8_t c[6] = { 'M','-','R', 0xFC, 0xFF, 2 };
      CHECK(host_write_channel(15, c, 6), "M-R cmd");
      n = host_read_channel(15, buf, 4);
      CHECK(n >= 2 && buf[0] == rom[0x3FFC] && buf[1] == rom[0x3FFD],
            "M-R $FFFC: got %02X %02X want %02X %02X (n=%d)",
            buf[0], buf[1], rom[0x3FFC], rom[0x3FFD], n); }

    /* 3: M-W + M-E — code runs on the fabric CPU.  The scratch target must
     * live OUTSIDE $0200-$02FF: that's the DOS command buffer, and the
     * follow-up M-R command string itself lands there. */
    { uint8_t prog[7] = { 0xA9, 0x42, 0x8D, 0x08, 0x05, 0x60, 0x00 };
      uint8_t mw[6 + 7] = { 'M','-','W', 0x00, 0x05, 7 };
      memcpy(mw + 6, prog, 7);
      CHECK(host_write_channel(15, mw, 13), "M-W cmd");
      uint8_t me[5] = { 'M','-','E', 0x00, 0x05 };
      CHECK(host_write_channel(15, me, 5), "M-E cmd");
      bus_step(2000);
      uint8_t mr[6] = { 'M','-','R', 0x08, 0x05, 1 };
      CHECK(host_write_channel(15, mr, 6), "M-R after M-E");
      n = host_read_channel(15, buf, 2);
      CHECK(n >= 1 && buf[0] == 0x42,
            "M-E did not execute: $0508 = %02X (n=%d)", buf[0], n); }

    /* 4: LOAD — OPEN 0,"GAME", read the whole file */
    CHECK(host_open(0, (const uint8_t *)"GAME", 4), "OPEN GAME");
    n = host_read_channel(0, buf, sizeof(buf));
    CHECK(n == (int)sizeof(game_prg), "GAME length %d want %d",
          n, (int)sizeof(game_prg));
    if (n == (int)sizeof(game_prg)) {
        int bad = -1;
        for (int i = 0; i < n; i++)
            if (buf[i] != game_prg[i]) { bad = i; break; }
        CHECK(bad < 0, "GAME data differs at %d: %02X want %02X",
              bad, buf[bad < 0 ? 0 : bad], game_prg[bad < 0 ? 0 : bad]);
    }

#ifdef PSRAM_TOP
    if (!use_cmodel)
        printf("stall_clks (stretched drive clks, ROM-exec only): %u\n",
               (unsigned)dut->stall_clks);
#endif
    printf("drive_1541 DOS conformance: %d checks, %d failed  [%llu us]\n",
           tests_run, tests_failed, (unsigned long long)now_us);
    delete dut;
    return tests_failed ? 1 : 0;
}
