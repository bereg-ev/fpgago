/*
 * ddr3-test/main.c — UART-driven DDR3 memory tester for the RISC2 SoC.
 *
 * The peripheral exposes two staging BRAMs (256 x 32 = 1 KB each) and a tiny
 * register file at 0x008300 (see ddr3_iface.v).  The CPU stages a buffer
 * worth of data into WBRAM, points DDR3_ADDR / DDR3_LEN at the target, then
 * writes DDR3_CMD to fire a single AXI burst.  Polling DDR3_STATUS bit 0
 * waits for completion; bit 1 latches AXI BRESP/RRESP errors.
 *
 * The program is a UART menu — single keys, no Enter:
 *
 *     i   Info banner (region size, fixed burst length).
 *     q   Quick sanity (one burst at addr 0).
 *     w   Walking-1s + walking-0s patterns at a few addresses.
 *     a   Address-as-data sweep over the lower 1 MB.
 *     r   LFSR pseudo-random sweep across the full 128 MB region.
 *     R   Same as 'r' but exits early on the first failure.
 *     h   Help.
 *
 * Each test prints a single line per stage and finishes with PASS/FAIL.
 */

#include <stdint.h>

/* ── UART ──────────────────────────────────────────────────────────────── */
#define UART_STATUS    (*(volatile uint32_t*)0x008100u)
#define UART_TX        (*(volatile uint32_t*)0x008104u)
#define UART_RX        (*(volatile uint32_t*)0x008108u)
#define UART_RXRDY     (1u << 0)
#define UART_TXBUSY    (1u << 2)

/* ── DDR3 test peripheral (page 0x008300..0x0083FF) ────────────────────── */
#define WBRAM_ADDR     (*(volatile uint32_t*)0x008300u)
#define WBRAM_DATA     (*(volatile uint32_t*)0x008304u)
#define RBRAM_ADDR     (*(volatile uint32_t*)0x008308u)
#define RBRAM_DATA     (*(volatile uint32_t*)0x00830Cu)
#define DDR3_ADDR      (*(volatile uint32_t*)0x008310u)
#define DDR3_LEN       (*(volatile uint32_t*)0x008314u)
#define DDR3_CMD       (*(volatile uint32_t*)0x008318u)
#define DDR3_STATUS    (*(volatile uint32_t*)0x00831Cu)

#define DDR3_BUSY      (1u << 0)
#define DDR3_ERR       (1u << 1)
#define CMD_WRITE      1u
#define CMD_READ       2u
#define CMD_CLEAR_ERR  3u

/* Buffer is exactly 256 entries (1 KB) per direction.  Match the BRAM. */
#define BURST_WORDS    256u

/* DDR3 chip: Winbond W631GG6MB-12, 1 Gb x16 = 128 MB. */
#define DDR3_REGION_BYTES 0x08000000u  /* 128 MB */

/* ── UART helpers ──────────────────────────────────────────────────────── */
static void uart_putc(int c) {
    while (UART_STATUS & UART_TXBUSY) { /* spin */ }
    UART_TX = (uint32_t)(c & 0xFF);
}
static int  uart_getc(void) {
    while (!(UART_STATUS & UART_RXRDY)) { /* spin */ }
    return (int)(UART_RX & 0xFF);
}
static int  uart_pollc(void) {
    if (UART_STATUS & UART_RXRDY) return (int)(UART_RX & 0xFF);
    return -1;
}
static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}
static void puthex(uint32_t v) {
    static const char H[] = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i--)
        uart_putc(H[(v >> (i*4)) & 0xF]);
}
static void putdec(uint32_t v) {
    char buf[11]; int n = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) uart_putc(buf[n]);
}

/* ── LFSR (Galois, 32-bit, period 2^32 - 1) ───────────────────────────── */
static uint32_t lfsr_next(uint32_t s) {
    uint32_t lsb = s & 1u;
    s >>= 1;
    if (lsb) s ^= 0xD0000001u;
    return s;
}

/* ── Wait for DDR3 transaction to drain.  Returns 0 OK, 1 if AXI error. ─ */
static int ddr3_wait(void) {
    while (DDR3_STATUS & DDR3_BUSY) { /* spin */ }
    return (DDR3_STATUS & DDR3_ERR) ? 1 : 0;
}

/* Stream `n_words` from a pattern function into WBRAM. */
typedef uint32_t (*pat_fn)(uint32_t i, uint32_t ctx);

static void fill_wbram(pat_fn fn, uint32_t ctx, uint32_t n_words) {
    uint32_t i;
    WBRAM_ADDR = 0;
    for (i = 0; i < n_words; i++)
        WBRAM_DATA = fn(i, ctx);
}

/* Return -1 on AXI error, otherwise the index of the first mismatch
 * (or n_words on full success). */
static int check_rbram(pat_fn fn, uint32_t ctx, uint32_t n_words) {
    uint32_t i;
    RBRAM_ADDR = 0;
    for (i = 0; i < n_words; i++) {
        uint32_t got = RBRAM_DATA;
        uint32_t exp = fn(i, ctx);
        if (got != exp) return (int)i;
    }
    return (int)n_words;
}

static int do_burst(uint32_t ddr3_byte_addr, uint32_t n_words) {
    DDR3_ADDR = ddr3_byte_addr;
    DDR3_LEN  = n_words;
    DDR3_CMD  = CMD_WRITE;
    if (ddr3_wait()) return -1;
    DDR3_ADDR = ddr3_byte_addr;
    DDR3_LEN  = n_words;
    DDR3_CMD  = CMD_READ;
    if (ddr3_wait()) return -2;
    return 0;
}

/* ── Pattern generators ───────────────────────────────────────────────── */
static uint32_t pat_walking(uint32_t i, uint32_t ctx) {
    /* Alternates between walking-1 and walking-0 across the buffer.
     * ctx selects which: 0 = walking 1s, 1 = walking 0s. */
    uint32_t bit = i & 31u;
    uint32_t v   = 1u << bit;
    return ctx ? ~v : v;
}
static uint32_t pat_addr(uint32_t i, uint32_t ctx) {
    /* Address-as-data: each word encodes its full byte address (XORed with
     * a fixed key so a stuck-bit DDR3 line is more visible). */
    return (ctx + i*4u) ^ 0xA5A5A5A5u;
}
static uint32_t pat_lfsr(uint32_t i, uint32_t ctx) {
    /* Re-run the LFSR from `ctx` and step `i` times — the pattern is
     * deterministic so we can regenerate the expected value cheaply. */
    uint32_t s = ctx;
    uint32_t k;
    for (k = 0; k < i; k++) s = lfsr_next(s);
    return s;
}

/* ── Reporting helper ──────────────────────────────────────────────────── */
static void report(const char *label, uint32_t addr, int idx,
                   uint32_t expected, uint32_t got) {
    uart_puts(label);
    if (idx == (int)BURST_WORDS) {
        uart_puts(" PASS @ 0x"); puthex(addr); uart_puts("\r\n");
    } else if (idx < 0) {
        uart_puts(" AXI-ERR(");  putdec((uint32_t)-idx);
        uart_puts(") @ 0x");     puthex(addr);
        uart_puts("\r\n");
    } else {
        uart_puts(" FAIL @ 0x"); puthex(addr);
        uart_puts(" word[");     putdec((uint32_t)idx);
        uart_puts("] exp=0x");   puthex(expected);
        uart_puts(" got=0x");    puthex(got);
        uart_puts("\r\n");
    }
}

/* Run one full burst (write+read+check) of `pat_fn(i, ctx)`. */
static int test_one(const char *label, uint32_t addr,
                    pat_fn fn, uint32_t ctx) {
    int rc;
    fill_wbram(fn, ctx, BURST_WORDS);
    rc = do_burst(addr, BURST_WORDS);
    if (rc) {
        report(label, addr, rc, 0, 0);
        DDR3_CMD = CMD_CLEAR_ERR;
        return 1;
    }
    /* Read back the rbram to figure out the failing index, if any. */
    {
        int idx;
        uint32_t exp = 0, got = 0;
        idx = check_rbram(fn, ctx, BURST_WORDS);
        if (idx != (int)BURST_WORDS) {
            /* Re-fetch the failing word for the error message.  RBRAM_ADDR
             * was bumped past the buffer end by the loop; reset and step. */
            uint32_t i;
            RBRAM_ADDR = (uint8_t)idx;
            got = RBRAM_DATA;
            exp = fn((uint32_t)idx, ctx);
        }
        report(label, addr, idx, exp, got);
        return idx != (int)BURST_WORDS;
    }
}

/* ── Tests ────────────────────────────────────────────────────────────── */
static void test_walking(void) {
    static const uint32_t addrs[] = { 0x0u, 0x100000u, 0x4000000u, 0x7FFFC00u };
    int i, fails = 0;
    uart_puts("\r\n[walking 1s/0s]\r\n");
    for (i = 0; i < (int)(sizeof(addrs)/sizeof(addrs[0])); i++) {
        fails += test_one("  walk1s", addrs[i], pat_walking, 0);
        fails += test_one("  walk0s", addrs[i], pat_walking, 1);
    }
    uart_puts(fails ? "[walking] FAIL\r\n" : "[walking] PASS\r\n");
}

static void test_address(void) {
    /* Sweep the lower 1 MB (1024 bursts) writing addr-derived data. */
    uint32_t addr;
    int fails = 0;
    uart_puts("\r\n[address-as-data, lower 1 MB]\r\n");
    for (addr = 0; addr < 0x100000u; addr += BURST_WORDS * 4u) {
        if (test_one("  addr", addr, pat_addr, addr)) {
            fails++;
            if (fails >= 3) { uart_puts("  ... aborting (>=3 fails)\r\n"); break; }
        }
        /* every 16 bursts emit a progress dot */
        if ((addr & 0x3FFFu) == 0) uart_putc('.');
    }
    uart_puts(fails ? "\r\n[address] FAIL\r\n" : "\r\n[address] PASS\r\n");
}

static void test_random_full(int stop_on_fail) {
    /* Phase 1: write LFSR bursts across the full 128 MB region.
     * Phase 2: read each burst back and compare against the same LFSR. */
    uint32_t addr;
    uint32_t seed;
    int fails = 0;
    uart_puts("\r\n[random sweep, full 128 MB]\r\n");

    /* Write phase. */
    uart_puts("  writing");
    seed = 0xDEADBEEFu;
    for (addr = 0; addr < DDR3_REGION_BYTES; addr += BURST_WORDS * 4u) {
        fill_wbram(pat_lfsr, seed, BURST_WORDS);
        DDR3_ADDR = addr;
        DDR3_LEN  = BURST_WORDS;
        DDR3_CMD  = CMD_WRITE;
        if (ddr3_wait()) {
            uart_puts(" AXI-ERR @ 0x"); puthex(addr); uart_puts("\r\n");
            DDR3_CMD = CMD_CLEAR_ERR;
            return;
        }
        /* advance seed by BURST_WORDS LFSR steps so the next burst's seed
         * continues the same stream */
        { uint32_t k; for (k = 0; k < BURST_WORDS; k++) seed = lfsr_next(seed); }
        if ((addr & 0xFFFFFFu) == 0) uart_putc('.');
    }
    uart_puts(" done\r\n");

    /* Read-and-check phase. */
    uart_puts("  reading");
    seed = 0xDEADBEEFu;
    for (addr = 0; addr < DDR3_REGION_BYTES; addr += BURST_WORDS * 4u) {
        int idx;
        DDR3_ADDR = addr;
        DDR3_LEN  = BURST_WORDS;
        DDR3_CMD  = CMD_READ;
        if (ddr3_wait()) {
            uart_puts(" AXI-ERR @ 0x"); puthex(addr); uart_puts("\r\n");
            DDR3_CMD = CMD_CLEAR_ERR;
            return;
        }
        idx = check_rbram(pat_lfsr, seed, BURST_WORDS);
        if (idx != (int)BURST_WORDS) {
            uint32_t exp, got;
            RBRAM_ADDR = (uint8_t)idx;
            got = RBRAM_DATA;
            exp = pat_lfsr((uint32_t)idx, seed);
            uart_puts("\r\n  FAIL @ 0x"); puthex(addr);
            uart_puts(" word["); putdec((uint32_t)idx);
            uart_puts("] exp=0x"); puthex(exp);
            uart_puts(" got=0x"); puthex(got);
            uart_puts("\r\n");
            fails++;
            if (stop_on_fail) { DDR3_CMD = CMD_CLEAR_ERR; return; }
        }
        { uint32_t k; for (k = 0; k < BURST_WORDS; k++) seed = lfsr_next(seed); }
        if ((addr & 0xFFFFFFu) == 0) uart_putc('.');
    }
    uart_puts(fails ? "\r\n[random] FAIL\r\n" : "\r\n[random] PASS\r\n");
}

static void test_quick(void) {
    int fails = 0;
    uart_puts("\r\n[quick sanity]\r\n");
    fails += test_one("  walk1s @0", 0x0u, pat_walking, 0);
    fails += test_one("  walk0s @0", 0x0u, pat_walking, 1);
    fails += test_one("  addr   @0", 0x0u, pat_addr,    0u);
    fails += test_one("  lfsr   @0", 0x0u, pat_lfsr,    0xDEADBEEFu);
    uart_puts(fails ? "[quick] FAIL\r\n" : "[quick] PASS\r\n");
}

static void print_help(void) {
    uart_puts(
        "\r\n=== DDR3 Test ===\r\n"
        " i  info banner\r\n"
        " q  quick sanity (single burst @ 0)\r\n"
        " w  walking 1s / 0s at a few addresses\r\n"
        " a  address-as-data sweep, lower 1 MB\r\n"
        " r  random LFSR sweep, full 128 MB\r\n"
        " R  same as r, abort on first fail\r\n"
        " s  show DDR3_STATUS\r\n"
        " c  clear sticky AXI error\r\n"
        " h  help\r\n");
}

static void print_info(void) {
    uart_puts("\r\nDDR3 region: 128 MB (0x00000000..0x07FFFFFF)\r\n"
              "Burst:       256 words (1 KB) per CMD\r\n"
              "Controller:  ultraembedded core_ddr3 @ 50 MHz, DLL-off\r\n");
}

static void print_status(void) {
    uint32_t s = DDR3_STATUS;
    uart_puts("DDR3_STATUS=0x"); puthex(s); uart_puts(" busy=");
    uart_putc('0' + ((s & DDR3_BUSY) ? 1 : 0));
    uart_puts(" err=");
    uart_putc('0' + ((s & DDR3_ERR) ? 1 : 0));
    uart_puts("\r\n");
}

/* ── Main ──────────────────────────────────────────────────────────────── */
int main(void) {
    print_help();
    print_info();
    uart_puts("\r\n> ");

    for (;;) {
        int ch = uart_getc();
        switch (ch) {
        case 'i': print_info();           break;
        case 'q': test_quick();           break;
        case 'w': test_walking();         break;
        case 'a': test_address();         break;
        case 'r': test_random_full(0);    break;
        case 'R': test_random_full(1);    break;
        case 's': print_status();         break;
        case 'c': DDR3_CMD = CMD_CLEAR_ERR;
                  uart_puts("err cleared\r\n"); break;
        case 'h':
        case '?': print_help();           break;
        case '\r':
        case '\n': /* swallow */          break;
        default:                          break;
        }
        uart_puts("> ");
    }
    return 0;
}
