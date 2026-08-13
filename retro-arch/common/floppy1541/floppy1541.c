/*
 * Commodore 1541 Floppy Drive Emulator
 *
 * Protocol-level IEC bus + D64 image + SAVE support.
 * Full 6502 emulation mode with GCR disk mechanism for fastloaders.
 * Written from public specifications — no third-party code.
 */

#include "floppy1541.h"
#include <string.h>
#include <stdio.h>

/* Simulation-only tracing (compiled out on the RP2350 firmware build). */
#ifdef SIMULATION
#include <stdlib.h>
#define F1541_DBG(...) do { if (getenv("F1541_DEBUG")) fprintf(stderr, __VA_ARGS__); } while (0)
#else
#define F1541_DBG(...) do {} while (0)
#endif

/* ==== IEC Protocol Timing (microseconds) ================================ */

#define T_EOI_TIMEOUT    200
#define T_EOI_ACK_HOLD    80
/* TX bit phases: a real 1541 clocks ~70-75µs halves against the C64/TED
 * KERNAL listeners (screen on, badlines and all) — 75µs keeps >25µs margin
 * over the worst ~50µs VIC stall while nearly doubling LOAD throughput vs
 * the old conservative 120µs (2.1ms/byte -> ~1.35ms/byte, ~475 -> ~740 B/s). */
#define T_BIT_SETUP       75   /* CLK-low setup time per bit */
#define T_BIT_HOLD        75   /* CLK-high bit-valid window per bit */
#define T_RX_ACK_HOLD      60
#define T_TURNAROUND       80
#define T_TX_READY_HIGH    60   /* CLK-high "ready to send" pulse before each byte's bits */
#define T_TX_FIRST_BYTE_DELAY 200  /* Extra wait after turnaround before first bit, so listener has time to enter RX loop */

/* ==== D64 Disk Image Helpers ============================================ */

int d64_sectors_per_track(int track)
{
    if (track <= 17) return 21;
    if (track <= 24) return 19;
    if (track <= 30) return 18;
    return 17;
}

int d64_offset(int track, int sector)
{
    int off = 0;
    for (int t = 1; t < track; t++)
        off += d64_sectors_per_track(t);
    return (off + sector) * 256;
}

static const uint8_t *d64_sector(const floppy1541_t *f, int track, int sector)
{
    if (!f->d64 || track < 1 || track > 35) return NULL;
    if (sector < 0 || sector >= d64_sectors_per_track(track)) return NULL;
    int off = d64_offset(track, sector);
    if ((uint32_t)(off + 256) > f->d64_size) return NULL;
    return f->d64 + off;
}

static uint8_t *d64_sector_mut(floppy1541_t *f, int track, int sector)
{
    if (!f->d64 || !f->d64_writable) return NULL;
    if (track < 1 || track > 35) return NULL;
    if (sector < 0 || sector >= d64_sectors_per_track(track)) return NULL;
    int off = d64_offset(track, sector);
    if ((uint32_t)(off + 256) > f->d64_size) return NULL;
    return f->d64 + off;
}

/* ==== Filename Helpers ================================================== */

static uint8_t to_petscii(char c)
{
    if (c >= 'a' && c <= 'z') return (uint8_t)(c - 32);
    return (uint8_t)c;
}

static int filename_match(const char *name, int name_len,
                          const uint8_t *dir_name)
{
    if (name_len == 0) return 0;
    if (name_len == 1 && name[0] == '*') return 1;
    for (int i = 0; i < 16; i++) {
        if (i < name_len) {
            uint8_t a = to_petscii(name[i]);
            if (a == '?') continue;
            if (a == '*') return 1;
            if (a != dir_name[i]) return 0;
        } else {
            if (dir_name[i] != 0xA0) return 0;
        }
    }
    return 1;
}

static const char *file_type_str(uint8_t type)
{
    static const char *names[] = {"DEL","SEQ","PRG","USR","REL"};
    int idx = type & 0x07;
    return (idx < 5) ? names[idx] : "???";
}

/* ==== D64 Directory Search ============================================== */

static int d64_scan_dir(const floppy1541_t *f,
                        const char *name, int name_len, int prg_only,
                        uint8_t *out_track, uint8_t *out_sector)
{
    int dt = 18, ds = 1;
    while (dt != 0) {
        const uint8_t *sec = d64_sector(f, dt, ds);
        if (!sec) return 0;
        for (int e = 0; e < 8; e++) {
            const uint8_t *en = sec + e * 32;
            if (!(en[2] & 0x80)) continue;
            if (prg_only && (en[2] & 0x07) != 0x02) continue;
            if (filename_match(name, name_len, en + 5)) {
                *out_track = en[3]; *out_sector = en[4]; return 1;
            }
        }
        dt = sec[0]; ds = sec[1];
    }
    return 0;
}

static int d64_find_file(const floppy1541_t *f,
                         const char *name, int name_len,
                         uint8_t *out_track, uint8_t *out_sector)
{
    /* A bare "*" (LOAD"*",8,1 / the BIOS autostart) means "the game":
     * prefer the first PRG so a leading SEQ/USR/DEL entry on the disk
     * doesn't hijack the load; fall back to any closed entry. */
    if (name_len == 1 && name[0] == '*' &&
        d64_scan_dir(f, name, name_len, 1, out_track, out_sector))
        return 1;
    return d64_scan_dir(f, name, name_len, 0, out_track, out_sector);
}

/* ==== BAM Sector Allocation (for SAVE) ================================== */

static int bam_alloc(floppy1541_t *f, int preferred_track)
{
    uint8_t *bam = d64_sector_mut(f, 18, 0);
    if (!bam) return -1;

    /* Search outward from preferred track, skip directory track 18 */
    for (int dist = 0; dist < 35; dist++) {
        for (int dir = 0; dir < 2; dir++) {
            int t = preferred_track + (dir ? -dist : dist);
            if (t < 1 || t > 35 || t == 18) continue;
            int boff = 4 + (t - 1) * 4;
            if (bam[boff] == 0) continue;
            for (int s = 0; s < d64_sectors_per_track(t); s++) {
                int byte_idx = 1 + (s >> 3);
                int bit = 1 << (s & 7);
                if (bam[boff + byte_idx] & bit) {
                    bam[boff + byte_idx] &= ~(uint8_t)bit;
                    bam[boff]--;
                    return (t << 8) | s;
                }
            }
        }
    }
    return -1; /* disk full */
}

static void bam_free(floppy1541_t *f, int track, int sector)
{
    uint8_t *bam = d64_sector_mut(f, 18, 0);
    if (!bam || track < 1 || track > 35) return;
    int boff = 4 + (track - 1) * 4;
    int byte_idx = 1 + (sector >> 3);
    int bit = 1 << (sector & 7);
    if (!(bam[boff + byte_idx] & bit)) {
        bam[boff + byte_idx] |= (uint8_t)bit;
        bam[boff]++;
    }
}

/* ==== Directory Entry Creation (for SAVE) =============================== */

static int dir_create_entry(floppy1541_t *f, const char *name, int name_len,
                            uint8_t ft, uint8_t fs, uint8_t ftype)
{
    int dt = 18, ds = 1;
    while (1) {
        uint8_t *sec = d64_sector_mut(f, dt, ds);
        if (!sec) return 0;
        for (int e = 0; e < 8; e++) {
            uint8_t *en = sec + e * 32;
            if (en[2] != 0x00) continue;
            memset(en, 0, 32);
            if (e == 0 && sec[0] == 0 && sec[1] == 0xFF) {
                /* preserve chain link in first entry */
            }
            en[2] = ftype; /* $82 PRG / $81 SEQ, closed */
            en[3] = ft; en[4] = fs;
            memset(en + 5, 0xA0, 16);
            for (int i = 0; i < name_len && i < 16; i++)
                en[5 + i] = to_petscii(name[i]);
            return 1;
        }
        if (sec[0] == 0) {
            /* Allocate new dir sector on track 18 */
            int ns = -1;
            uint8_t *bam = d64_sector_mut(f, 18, 0);
            if (bam) {
                int boff = 4 + 17 * 4; /* track 18 */
                for (int s = 0; s < 19; s++) {
                    int bi = 1 + (s >> 3), bt = 1 << (s & 7);
                    if (bam[boff + bi] & bt) {
                        bam[boff + bi] &= ~(uint8_t)bt;
                        bam[boff]--;
                        ns = s; break;
                    }
                }
            }
            if (ns < 0) return 0;
            sec[0] = 18; sec[1] = (uint8_t)ns;
            uint8_t *new_sec = d64_sector_mut(f, 18, ns);
            if (!new_sec) return 0;
            memset(new_sec, 0, 256);
            new_sec[1] = 0xFF;
            dt = 18; ds = ns;
        } else {
            dt = sec[0]; ds = sec[1];
        }
    }
}

static void dir_update_blocks(floppy1541_t *f, uint8_t ft, uint8_t fs,
                               uint16_t blocks)
{
    int dt = 18, ds = 1;
    while (dt != 0) {
        uint8_t *sec = d64_sector_mut(f, dt, ds);
        if (!sec) return;
        for (int e = 0; e < 8; e++) {
            uint8_t *en = sec + e * 32;
            if (en[3] == ft && en[4] == fs && (en[2] & 0x80)) {
                en[30] = blocks & 0xFF;
                en[31] = blocks >> 8;
                return;
            }
        }
        dt = sec[0]; ds = sec[1];
    }
}

/* ==== Directory Listing Generator ======================================= */

static void generate_listing(floppy1541_t *f)
{
    uint8_t *buf = f->listing_buf;
    uint32_t pos = 0;
    uint16_t addr = 0x0401;
    buf[pos++] = addr & 0xFF; buf[pos++] = addr >> 8;

    const uint8_t *bam = d64_sector(f, 18, 0);
    if (!bam) { f->listing_len = 0; return; }

    /* Header line */
    uint16_t ls = pos; pos += 2;
    buf[pos++] = 0; buf[pos++] = 0; buf[pos++] = 0x12; buf[pos++] = 0x22;
    for (int i = 0; i < 16; i++) {
        uint8_t c = bam[0x90 + i]; buf[pos++] = (c == 0xA0) ? 0x20 : c;
    }
    buf[pos++] = 0x22; buf[pos++] = 0x20;
    buf[pos++] = bam[0xA2]; buf[pos++] = bam[0xA3];
    buf[pos++] = 0x20; buf[pos++] = bam[0xA5]; buf[pos++] = bam[0xA6];
    buf[pos++] = 0x00;
    { uint16_t na = addr + (uint16_t)(pos - 2); buf[ls] = na & 0xFF; buf[ls+1] = na >> 8; }

    /* File entries */
    int dt = 18, ds = 1;
    while (dt != 0 && pos + 40 < F1541_LISTING_MAX) {
        const uint8_t *sec = d64_sector(f, dt, ds);
        if (!sec) break;
        for (int e = 0; e < 8 && pos + 40 < F1541_LISTING_MAX; e++) {
            const uint8_t *en = sec + e * 32;
            if (!(en[2] & 0x80)) continue;
            uint16_t blocks = en[30] | ((uint16_t)en[31] << 8);
            ls = pos; pos += 2;
            buf[pos++] = blocks & 0xFF; buf[pos++] = blocks >> 8;
            if (blocks < 10) buf[pos++] = 0x20;
            if (blocks < 100) buf[pos++] = 0x20;
            if (blocks < 1000) buf[pos++] = 0x20;
            buf[pos++] = 0x20; buf[pos++] = 0x22;
            int fe = 15; while (fe >= 0 && en[5+fe] == 0xA0) fe--;
            for (int i = 0; i <= fe; i++) buf[pos++] = en[5+i];
            buf[pos++] = 0x22;
            for (int i = fe + 1; i < 16; i++) buf[pos++] = 0x20;
            buf[pos++] = 0x20;
            const char *ts = file_type_str(en[2]);
            buf[pos++] = (uint8_t)ts[0]; buf[pos++] = (uint8_t)ts[1]; buf[pos++] = (uint8_t)ts[2];
            buf[pos++] = 0x00;
            { uint16_t na = addr + (uint16_t)(pos - 2); buf[ls] = na & 0xFF; buf[ls+1] = na >> 8; }
        }
        dt = sec[0]; ds = sec[1];
    }

    /* Blocks free */
    uint16_t fb = 0;
    for (int t = 1; t <= 35; t++) { if (t == 18) continue; fb += bam[4+(t-1)*4]; }
    ls = pos; pos += 2;
    buf[pos++] = fb & 0xFF; buf[pos++] = fb >> 8;
    const char *fs = "BLOCKS FREE.";
    while (*fs) buf[pos++] = (uint8_t)*fs++;
    buf[pos++] = 0x00;
    buf[ls] = 0x00; buf[ls+1] = 0x00;
    f->listing_len = pos;
}

/* ==== Error / Status ==================================================== */

static void set_error(floppy1541_t *f, int err, int track, int sector)
{
    f->error_num = (uint8_t)err;
    f->error_track = (uint8_t)track;
    f->error_sector = (uint8_t)sector;
    const char *msg = "OK";
    switch (err) {
    case  1: msg = "FILES SCRATCHED"; break;
    case 26: msg = "WRITE PROTECT ON"; break;
    case 30: case 31: case 33: case 34: msg = "SYNTAX ERROR"; break;
    case 61: msg = "FILE NOT OPEN"; break;
    case 62: msg = "FILE NOT FOUND"; break;
    case 63: msg = "FILE EXISTS"; break;
    case 64: msg = "FILE TYPE MISMATCH"; break;
    case 65: msg = "NO BLOCK"; break;
    case 66: msg = "ILLEGAL TRACK AND SECTOR"; break;
    case 70: msg = "NO CHANNEL"; break;
    case 72: msg = "DISK FULL"; break;
    case 73: msg = "CBM DOS V2.6 1541"; break;
    case 74: msg = "DRIVE NOT READY"; break;
    }
    snprintf(f->status_str, F1541_STATUS_MAX, "%02d, %s,%02d,%02d\r", err, msg, track, sector);
    f->status_len = (int)strlen(f->status_str);
    f->status_pos = 0;
}

/* ==== Channel Operations ================================================ */

static void channel_close(floppy1541_t *f, int ch)
{
    f1541_channel_t *c = &f->channels[ch];

    /* Finalize write if saving */
    if (c->writing && f->d64_writable) {
        uint8_t *sec = d64_sector_mut(f, c->wr_track, c->wr_sector);
        if (sec) {
            sec[0] = 0;
            sec[1] = (c->wr_pos > 2) ? c->wr_pos - 1 : 1;
        }
        c->block_count++;
        dir_update_blocks(f, c->first_track, c->first_sector, c->block_count);
    }
    if (c->direct) {
        f->buf_used &= (uint8_t)~(1u << c->buf_num);
        c->direct = 0;
    }
    c->writing = 0;
    c->open = 0;
    c->eof = 1;
    if (f->listing_channel == ch) f->listing_channel = -1;
}

/* Parsed OPEN filename: "[@][drv]:NAME[,TYPE][,MODE]".  Everything before
 * the first ':' (within the leading few chars) is the drive/replace prefix;
 * comma fields after the name give file type (S/P/U/L) and mode (R/W/A/M)
 * in either order. */
typedef struct {
    const char *name; int len;
    uint8_t type;       /* 'S','P','U','L' or 0 = unspecified */
    uint8_t mode;       /* 'R','W','A','M' or 0 */
    uint8_t overwrite;  /* leading '@' */
} open_name_t;

static void parse_open_name(const char *raw, int raw_len, open_name_t *o)
{
    o->type = 0; o->mode = 0; o->overwrite = 0;
    const char *p = raw; int n = raw_len;
    if (n >= 1 && p[0] == '@') { o->overwrite = 1; p++; n--; }
    for (int i = 0; i < n && i < 2; i++)         /* "0:", ":", "1:" prefixes */
        if (p[i] == ':') { p += i + 1; n -= i + 1; break; }
    /* split off ",T,M" suffix fields */
    int nl = n;
    for (int i = 0; i < n; i++) {
        if (p[i] != ',') continue;
        if (i < nl) nl = i;
        if (i + 1 < n) {
            uint8_t c = to_petscii(p[i + 1]);
            if (c == 'R' || c == 'W' || c == 'A' || c == 'M') o->mode = c;
            else if (c == 'S' || c == 'P' || c == 'U' || c == 'L') o->type = c;
        }
    }
    o->name = p; o->len = nl;
}

static void channel_open_read(floppy1541_t *f, int ch,
                              const char *name, int name_len)
{
    f1541_channel_t *c = &f->channels[ch];
    channel_close(f, ch);

    int len = (name_len < F1541_FILENAME_MAX - 1) ? name_len : F1541_FILENAME_MAX - 1;
    memcpy(c->filename, name, len); c->filename[len] = '\0';

    if (!f->d64) { set_error(f, 74, 0, 0); return; }

    /* Directory load.  Triggered by:
     *   - Filename "$" (standard CBM convention)
     *   - Empty filename on the LOAD channel (channel 0).  Some KERNALs
     *     (notably Plus/4) do not transmit the "$" filename on the IEC bus
     *     for LOAD"$",dev — they expect the device to infer directory from
     *     OPEN on channel 0 with no name. */
    if ((name_len >= 1 && name[0] == '$') || (name_len == 0 && ch == 0)) {
        generate_listing(f);
        f->listing_pos = 0; f->listing_channel = ch;
        c->open = 1; c->eof = 0;
        set_error(f, 0, 0, 0);
        return;
    }

    const char *fn = name; int fl = name_len;
    if (fl == 0) { fn = "*"; fl = 1; }

    uint8_t track, sector;
    if (!d64_find_file(f, fn, fl, &track, &sector)) {
        set_error(f, 62, 0, 0); return;
    }
    const uint8_t *sec = d64_sector(f, track, sector);
    if (!sec) { set_error(f, 74, track, sector); return; }

    c->open = 1; c->eof = 0;
    c->cur_track = track; c->cur_sector = sector;
    c->sector_pos = 2;
    c->last_sector = (sec[0] == 0) ? 1 : 0;
    c->last_byte_pos = sec[1];
    set_error(f, 0, 0, 0);
}

/* Free every sector of the file chain starting at t/s (scratch, "@:"). */
static void chain_free(floppy1541_t *f, uint8_t t, uint8_t s)
{
    int guard = 0;
    while (t != 0 && guard++ < 1000) {
        const uint8_t *sec = d64_sector(f, t, s);
        if (!sec) break;
        uint8_t nt = sec[0], ns = sec[1];
        bam_free(f, t, s);
        t = nt; s = ns;
    }
}

static void channel_open_write(floppy1541_t *f, int ch,
                               const char *fn, int fl,
                               uint8_t ftype, int overwrite)
{
    f1541_channel_t *c = &f->channels[ch];
    channel_close(f, ch);

    if (!f->d64) { set_error(f, 74, 0, 0); return; }
    if (!f->d64_writable) { set_error(f, 26, 0, 0); return; }

    /* Check if file exists */
    uint8_t et, es;
    if (d64_find_file(f, fn, fl, &et, &es)) {
        if (!overwrite) { set_error(f, 63, 0, 0); return; }
        /* "@:" — scratch the old file, then create the new one */
        int dt = 18, ds = 1;
        while (dt != 0) {
            uint8_t *dsec = d64_sector_mut(f, dt, ds);
            if (!dsec) break;
            int hit = 0;
            for (int e = 0; e < 8; e++) {
                uint8_t *en = dsec + e * 32;
                if ((en[2] & 0x80) && en[3] == et && en[4] == es) {
                    en[2] = 0x00; hit = 1; break;
                }
            }
            if (hit) break;
            dt = dsec[0]; ds = dsec[1];
        }
        chain_free(f, et, es);
    }

    /* Allocate first sector */
    int ts = bam_alloc(f, 17); /* start near directory */
    if (ts < 0) { set_error(f, 72, 0, 0); return; }

    uint8_t ft = (uint8_t)(ts >> 8), fs = (uint8_t)(ts & 0xFF);
    uint8_t *sec = d64_sector_mut(f, ft, fs);
    if (!sec) { set_error(f, 74, ft, fs); return; }
    memset(sec, 0, 256);

    /* Create directory entry */
    if (!dir_create_entry(f, fn, fl, ft, fs, ftype)) {
        bam_free(f, ft, fs);
        set_error(f, 72, 0, 0); return;
    }

    int len = (fl < F1541_FILENAME_MAX - 1) ? fl : F1541_FILENAME_MAX - 1;
    memcpy(c->filename, fn, len); c->filename[len] = '\0';

    c->open = 1; c->eof = 0; c->writing = 1; c->wr_type = ftype;
    c->wr_track = ft; c->wr_sector = fs; c->wr_pos = 2;
    c->first_track = ft; c->first_sector = fs; c->block_count = 0;
    set_error(f, 0, 0, 0);
}

/* OPEN n,8,ch,"#" (or "#b"): claim a direct-access buffer for the channel.
 * The buffers live at the real drive's RAM addresses ($0300+), so a
 * follow-up M-R of buffer contents sees the same bytes. */
static void channel_open_direct(floppy1541_t *f, int ch,
                                const char *name, int name_len)
{
    f1541_channel_t *c = &f->channels[ch];
    channel_close(f, ch);

    int want = -1;                          /* "#b" = specific buffer */
    if (name_len >= 2 && name[1] >= '0' && name[1] <= '9')
        want = name[1] - '0';
    if (want >= F1541_NUM_BUFS) { set_error(f, 70, 0, 0); return; }

    int b = want;
    if (b < 0)
        for (int i = 0; i < F1541_NUM_BUFS; i++)
            if (!(f->buf_used & (1u << i))) { b = i; break; }
    if (b < 0 || (f->buf_used & (1u << b))) { set_error(f, 70, 0, 0); return; }

    f->buf_used |= (uint8_t)(1u << b);
    c->open = 1; c->eof = 0; c->direct = 1;
    c->buf_num = (uint8_t)b;
    c->buf_pos = 0; c->buf_len = 256;
    c->filename[0] = '#'; c->filename[1] = '\0';
    set_error(f, 0, 0, 0);
}

static void dos_exec(floppy1541_t *f, const uint8_t *cmd, int len);

static void channel_open(floppy1541_t *f, int ch,
                         const char *name, int name_len)
{
    if (ch == 15) {
        /* OPEN 15,8,15,"CMD": the name IS a DOS command.  A bare OPEN 15
         * leaves the status untouched (73 only appears after init). */
        f->channels[15].open = 1; f->channels[15].eof = 0;
        if (name_len > 0)
            dos_exec(f, (const uint8_t *)name, name_len);
        return;
    }

    open_name_t o;
    parse_open_name(name, name_len, &o);

    if (o.len >= 1 && o.name[0] == '#') {
        channel_open_direct(f, ch, o.name, o.len);
        return;
    }
    /* Directory + "$" bypass the suffix parse (raw name, see open_read). */
    if ((name_len >= 1 && name[0] == '$') || ch == 0 || ch == 1) {
        if (ch == 1)
            channel_open_write(f, ch, o.name, o.len,
                               o.type == 'S' ? 0x81 : 0x82, o.overwrite);
        else
            channel_open_read(f, ch, name_len >= 1 && name[0] == '$'
                                         ? name : o.name,
                              name_len >= 1 && name[0] == '$'
                                         ? name_len : o.len);
        return;
    }
    /* append not supported — treating it as a fresh write would clobber the
     * old file, so refuse A with a type mismatch */
    if (o.mode == 'A') { set_error(f, 64, 0, 0); return; }
    if (o.mode == 'W')
        channel_open_write(f, ch, o.name, o.len,
                           o.type == 'P' ? 0x82 : 0x81, o.overwrite);
    else
        channel_open_read(f, ch, o.name, o.len);
}

static void channel_write_byte(floppy1541_t *f, int ch, uint8_t byte)
{
    f1541_channel_t *c = &f->channels[ch];
    if (c->open && c->direct) {          /* PRINT# into a "#" buffer */
        f->ram[F1541_BUF_BASE + c->buf_num * 256 + (c->buf_pos & 0xFF)] = byte;
        c->buf_pos = (uint16_t)((c->buf_pos + 1) & 0xFF);
        return;
    }
    if (!c->writing || !f->d64_writable) return;

    uint8_t *sec = d64_sector_mut(f, c->wr_track, c->wr_sector);
    if (!sec) return;

    sec[c->wr_pos++] = byte;

    if (c->wr_pos > 255) {
        int next = bam_alloc(f, c->wr_track);
        if (next < 0) { set_error(f, 72, 0, 0); c->writing = 0; return; }
        c->block_count++;
        sec[0] = (uint8_t)(next >> 8);
        sec[1] = (uint8_t)(next & 0xFF);
        c->wr_track = (uint8_t)(next >> 8);
        c->wr_sector = (uint8_t)(next & 0xFF);
        c->wr_pos = 2;
        uint8_t *ns = d64_sector_mut(f, c->wr_track, c->wr_sector);
        if (ns) memset(ns, 0, 256);
    }
}

static int channel_read_byte(floppy1541_t *f, int ch, int *is_last)
{
    *is_last = 0;
    if (ch == 15) {
        /* A pending M-R reply preempts the status string */
        if (f->ch15_bin_pos < f->ch15_bin_len) {
            int b = f->ch15_bin[f->ch15_bin_pos++];
            if (f->ch15_bin_pos >= f->ch15_bin_len) {
                f->ch15_bin_len = f->ch15_bin_pos = 0;
                *is_last = 1;
            }
            return b;
        }
        if (f->status_pos >= f->status_len) return -1;
        int b = (uint8_t)f->status_str[f->status_pos++];
        if (f->status_pos >= f->status_len) {
            *is_last = 1; set_error(f, 0, 0, 0);
        }
        return b;
    }
    {
        f1541_channel_t *dc = &f->channels[ch];
        if (dc->open && dc->direct) {    /* GET# from a "#" buffer */
            const uint8_t *b =
                f->ram + F1541_BUF_BASE + dc->buf_num * 256;
            uint16_t end = dc->buf_len ? dc->buf_len : 256;
            int byte = b[dc->buf_pos & 0xFF];
            if (dc->buf_pos + 1 >= end) {
                *is_last = 1;            /* EOI on the last valid byte */
                dc->buf_pos = 0;
            } else
                dc->buf_pos++;
            return byte;
        }
    }
    if (f->listing_channel == ch) {
        if (f->listing_pos >= f->listing_len) return -1;
        int b = f->listing_buf[f->listing_pos++];
        if (f->listing_pos >= f->listing_len) *is_last = 1;
        return b;
    }

    f1541_channel_t *c = &f->channels[ch];
    if (!c->open || c->eof) return -1;
    const uint8_t *sec = d64_sector(f, c->cur_track, c->cur_sector);
    if (!sec) { c->eof = 1; return -1; }
    int byte = sec[c->sector_pos];

    /* EOI accompanies the LAST valid byte (pos == last_byte_pos), never
     * earlier — flagging it one byte ahead made receivers stop short. */
    if (c->last_sector && c->sector_pos >= c->last_byte_pos) {
        c->eof = 1; *is_last = 1;
    } else {
        c->sector_pos++;
        if (c->sector_pos > 255) {
            uint8_t nt = sec[0], ns = sec[1];
            if (nt == 0) { c->eof = 1; *is_last = 1; }
            else {
                c->cur_track = nt; c->cur_sector = ns; c->sector_pos = 2;
                const uint8_t *nx = d64_sector(f, nt, ns);
                if (nx) { c->last_sector = (nx[0]==0)?1:0; c->last_byte_pos = nx[1]; }
                else c->eof = 1;
                /* degenerate final sector with no data bytes: the byte we
                 * just returned was the file's last */
                if (c->last_sector && c->last_byte_pos < 2) {
                    c->eof = 1; *is_last = 1;
                }
            }
        }
    }
    return byte;
}

/* ==== DOS Command Channel (channel 15) ==================================
 * High-level DOS emulation: commands arrive either as the OPEN name on
 * channel 15 or as PRINT#15 data bytes (executed on UNLISTEN), exactly like
 * the real DOS command buffer at $0200.  This is what lets full-DOS titles
 * (Pirates! class: U1/B-P/B-R sector access, SEQ files, SAVE) run without
 * the cycle-exact 6502 drive — every operation completes at bus speed with
 * zero rotational latency. */

static int ts_valid(int track, int sector)
{
    return track >= 1 && track <= 35 &&
           sector >= 0 && sector < d64_sectors_per_track(track);
}

/* Parse up to max ASCII numbers after the command token; separators are any
 * non-digit chars ("U1:2 0 18 0", "U1: 2,0,18,0", "B-P 2 1" all work). */
static int parse_nums(const uint8_t *s, int len, int *out, int max)
{
    int n = 0, i = 0;
    while (i < len && n < max) {
        while (i < len && !(s[i] >= '0' && s[i] <= '9')) i++;
        if (i >= len) break;
        int v = 0;
        while (i < len && s[i] >= '0' && s[i] <= '9')
            v = v * 10 + (s[i++] - '0');
        out[n++] = v;
    }
    return n;
}

/* Mirror the executed command into ram[$0200..] (the real DOS command
 * buffer) so the firmware's ATN transaction log shows it. */
static void dos_log_mirror(floppy1541_t *f, const uint8_t *cmd, int len)
{
    int n = len < 24 ? len : 24;
    memcpy(f->ram + 0x0200, cmd, (size_t)n);
    if (n < 24) memset(f->ram + 0x0200 + n, 0, (size_t)(24 - n));
}

/* Refresh the drive's idea of the disk/header ID in zero page (games check
 * it via M-R after U1, and the real DOS keeps it at $12/$13 + $16/$17). */
static void dos_update_ids(floppy1541_t *f, int track, int sector)
{
    const uint8_t *bam = d64_sector(f, 18, 0);
    if (bam) {
        f->ram[0x12] = bam[0xA2]; f->ram[0x13] = bam[0xA3];
        f->ram[0x16] = bam[0xA2]; f->ram[0x17] = bam[0xA3];
    }
    f->ram[0x18] = (uint8_t)track;
    f->ram[0x19] = (uint8_t)sector;
}

/* U1/U2/B-R/B-W/B-P/B-A/B-F share the "channel + block" parameter shape. */
static f1541_channel_t *dos_direct_ch(floppy1541_t *f, int ch)
{
    if (ch < 0 || ch > 14) return NULL;
    f1541_channel_t *c = &f->channels[ch];
    return (c->open && c->direct) ? c : NULL;
}

static void dos_block_read(floppy1541_t *f, int ch, int track, int sector,
                           int raw)
{
    f1541_channel_t *c = dos_direct_ch(f, ch);
    if (!c) { set_error(f, 70, 0, 0); return; }
    if (!ts_valid(track, sector)) { set_error(f, 66, track, sector); return; }
    const uint8_t *sec = d64_sector(f, track, sector);
    if (!sec) { set_error(f, 66, track, sector); return; }
    uint8_t *buf = f->ram + F1541_BUF_BASE + c->buf_num * 256;
    memcpy(buf, sec, 256);
    if (raw) {                       /* U1: all 256 bytes, pointer at 0    */
        c->buf_pos = 0; c->buf_len = 256;
    } else {                         /* B-R: byte 0 = last valid index     */
        c->buf_pos = 1; c->buf_len = (uint16_t)(buf[0] ? buf[0] + 1 : 256);
    }
    c->eof = 0;
    dos_update_ids(f, track, sector);
    set_error(f, 0, 0, 0);
}

static void dos_block_write(floppy1541_t *f, int ch, int track, int sector,
                            int raw)
{
    f1541_channel_t *c = dos_direct_ch(f, ch);
    if (!c) { set_error(f, 70, 0, 0); return; }
    if (!ts_valid(track, sector)) { set_error(f, 66, track, sector); return; }
    if (!f->d64_writable) { set_error(f, 26, track, sector); return; }
    uint8_t *sec = d64_sector_mut(f, track, sector);
    if (!sec) { set_error(f, 66, track, sector); return; }
    uint8_t *buf = f->ram + F1541_BUF_BASE + c->buf_num * 256;
    if (!raw)                        /* B-W: byte 0 = current pointer      */
        buf[0] = (uint8_t)(c->buf_pos > 1 ? c->buf_pos : 1);
    memcpy(sec, buf, 256);
    set_error(f, 0, 0, 0);
}

static void dos_scratch(floppy1541_t *f, const char *pat, int len)
{
    if (!f->d64_writable) { set_error(f, 26, 0, 0); return; }
    int count = 0;
    int dt = 18, ds = 1;
    while (dt != 0) {
        uint8_t *sec = d64_sector_mut(f, dt, ds);
        if (!sec) break;
        for (int e = 0; e < 8; e++) {
            uint8_t *en = sec + e * 32;
            if (!(en[2] & 0x80)) continue;
            if ((en[2] & 0x07) == 0x04) continue;      /* REL: leave alone */
            if (!filename_match(pat, len, en + 5)) continue;
            chain_free(f, en[3], en[4]);
            en[2] = 0x00;
            count++;
        }
        dt = sec[0]; ds = sec[1];
    }
    set_error(f, 1, count, 0);       /* "01, FILES SCRATCHED,tt,00"       */
}

static void dos_rename(floppy1541_t *f, const char *arg, int len)
{
    /* "NEW=OLD" */
    int eq = -1;
    for (int i = 0; i < len; i++) if (arg[i] == '=') { eq = i; break; }
    if (eq <= 0 || eq >= len - 1) { set_error(f, 30, 0, 0); return; }
    if (!f->d64_writable) { set_error(f, 26, 0, 0); return; }
    uint8_t t, s;
    if (d64_find_file(f, arg, eq, &t, &s)) { set_error(f, 63, 0, 0); return; }
    int dt = 18, ds = 1;
    while (dt != 0) {
        uint8_t *sec = d64_sector_mut(f, dt, ds);
        if (!sec) break;
        for (int e = 0; e < 8; e++) {
            uint8_t *en = sec + e * 32;
            if (!(en[2] & 0x80)) continue;
            if (!filename_match(arg + eq + 1, len - eq - 1, en + 5)) continue;
            memset(en + 5, 0xA0, 16);
            for (int i = 0; i < eq && i < 16; i++)
                en[5 + i] = to_petscii(arg[i]);
            set_error(f, 0, 0, 0);
            return;
        }
        dt = sec[0]; ds = sec[1];
    }
    set_error(f, 62, 0, 0);
}

static void dos_format(floppy1541_t *f, const char *arg, int len)
{
    /* "NAME[,ID]" — full format: wipe the image, fresh BAM + empty dir */
    if (!f->d64 || !f->d64_writable) { set_error(f, 26, 0, 0); return; }
    int comma = -1;
    for (int i = 0; i < len; i++) if (arg[i] == ',') { comma = i; break; }
    int nlen = comma >= 0 ? comma : len;

    memset(f->d64, 0, f->d64_size);
    uint8_t *bam = d64_sector_mut(f, 18, 0);
    uint8_t *dir = d64_sector_mut(f, 18, 1);
    if (!bam || !dir) { set_error(f, 74, 18, 0); return; }
    bam[0] = 18; bam[1] = 1; bam[2] = 'A';
    for (int t = 1; t <= 35; t++) {
        int n = d64_sectors_per_track(t);
        uint32_t map = (t == 18) ? 0xFFFFFFFCu & ((1u << n) - 1)   /* 18/0+18/1 used */
                                 : (1u << n) - 1;
        int free_count = 0;
        for (int s = 0; s < n; s++) if (map & (1u << s)) free_count++;
        bam[4 + (t - 1) * 4 + 0] = (uint8_t)free_count;
        bam[4 + (t - 1) * 4 + 1] = map & 0xFF;
        bam[4 + (t - 1) * 4 + 2] = (map >> 8) & 0xFF;
        bam[4 + (t - 1) * 4 + 3] = (map >> 16) & 0xFF;
    }
    memset(bam + 0x90, 0xA0, 0x1B);
    for (int i = 0; i < nlen && i < 16; i++)
        bam[0x90 + i] = to_petscii(arg[i]);
    bam[0xA2] = (comma >= 0 && comma + 1 < len) ? to_petscii(arg[comma + 1]) : '0';
    bam[0xA3] = (comma >= 0 && comma + 2 < len) ? to_petscii(arg[comma + 2]) : '0';
    bam[0xA5] = 0xA0; bam[0xA6] = '2'; bam[0xA7] = 'A';
    dir[0] = 0; dir[1] = 0xFF;
    dos_update_ids(f, 18, 0);
    set_error(f, 0, 0, 0);
}

static void dos_exec(floppy1541_t *f, const uint8_t *cmd, int len)
{
    /* trim trailing CR(s) */
    while (len > 0 && cmd[len - 1] == 0x0D) len--;
    if (len <= 0) return;
    dos_log_mirror(f, cmd, len);
    if (!f->d64) { set_error(f, 74, 0, 0); return; }

    uint8_t c0 = to_petscii((char)cmd[0]);
    uint8_t c1 = len > 1 ? to_petscii((char)cmd[1]) : 0;
    uint8_t c2 = len > 2 ? to_petscii((char)cmd[2]) : 0;
    int p[4], np;

    F1541_DBG("[f1541-dos] exec \"%.*s\" (%d bytes)\n", len, (const char*)cmd, len);

    switch (c0) {
    case 'U':
        /* U1/UA block-read, U2/UB block-write, UI/UJ/U9/U: reset-ish */
        if (c1 == '1' || c1 == 'A') {
            np = parse_nums(cmd + 2, len - 2, p, 4);
            if (np < 4) { set_error(f, 30, 0, 0); return; }
            dos_block_read(f, p[0], p[2], p[3], 1);
        } else if (c1 == '2' || c1 == 'B') {
            np = parse_nums(cmd + 2, len - 2, p, 4);
            if (np < 4) { set_error(f, 30, 0, 0); return; }
            dos_block_write(f, p[0], p[2], p[3], 1);
        } else if (c1 == 'I' || c1 == 'J' || c1 == '9' || c1 == ':' ||
                   c1 == 0) {
            if (len > 2 && (cmd[2] == '+' || cmd[2] == '-'))
                set_error(f, 0, 0, 0);           /* UI+/UI- speed: no-op */
            else
                set_error(f, 73, 0, 0);          /* soft reset           */
        } else
            set_error(f, 30, 0, 0);
        return;

    case 'B':
        if (c1 != '-') { set_error(f, 30, 0, 0); return; }
        np = parse_nums(cmd + 3, len - 3, p, 4);
        switch (c2) {
        case 'P':                                /* B-P: ch pos          */
            if (np < 2) { set_error(f, 30, 0, 0); return; }
            {
                f1541_channel_t *c = dos_direct_ch(f, p[0]);
                if (!c) { set_error(f, 70, 0, 0); return; }
                c->buf_pos = (uint16_t)(p[1] & 0xFF);
                set_error(f, 0, 0, 0);
            }
            return;
        case 'R':                                /* B-R: ch dr t s       */
            if (np < 4) { set_error(f, 30, 0, 0); return; }
            dos_block_read(f, p[0], p[2], p[3], 0);
            return;
        case 'W':                                /* B-W: ch dr t s       */
            if (np < 4) { set_error(f, 30, 0, 0); return; }
            dos_block_write(f, p[0], p[2], p[3], 0);
            return;
        case 'A':                                /* B-A: dr t s          */
            if (np < 3) { set_error(f, 30, 0, 0); return; }
            {
                int t = p[1], s = p[2];
                if (!ts_valid(t, s)) { set_error(f, 66, t, s); return; }
                uint8_t *bam = d64_sector_mut(f, 18, 0);
                if (!bam) { set_error(f, 26, t, s); return; }
                int boff = 4 + (t - 1) * 4;
                int bi = 1 + (s >> 3), bit = 1 << (s & 7);
                if (bam[boff + bi] & bit) {      /* free: allocate it    */
                    bam[boff + bi] &= (uint8_t)~bit;
                    bam[boff]--;
                    set_error(f, 0, 0, 0);
                    return;
                }
                /* taken: report 65 NO BLOCK with the next free t/s      */
                for (int tt = t; tt <= 35; tt++) {
                    if (tt == 18) continue;
                    int n = d64_sectors_per_track(tt);
                    for (int ss = (tt == t) ? s + 1 : 0; ss < n; ss++) {
                        int o = 4 + (tt - 1) * 4;
                        if (bam[o + 1 + (ss >> 3)] & (1 << (ss & 7))) {
                            set_error(f, 65, tt, ss);
                            return;
                        }
                    }
                }
                set_error(f, 65, 0, 0);
            }
            return;
        case 'F':                                /* B-F: dr t s          */
            if (np < 3) { set_error(f, 30, 0, 0); return; }
            if (!ts_valid(p[1], p[2])) { set_error(f, 66, p[1], p[2]); return; }
            bam_free(f, p[1], p[2]);
            set_error(f, 0, 0, 0);
            return;
        case 'E':                                /* B-E: can't execute   */
            set_error(f, 0, 0, 0);
            return;
        default:
            set_error(f, 30, 0, 0);
            return;
        }

    case 'M':
        if (c1 != '-') { set_error(f, 30, 0, 0); return; }
        if (c2 == 'R') {                         /* M-R lo hi [count]    */
            if (len < 5) { set_error(f, 30, 0, 0); return; }
            uint16_t addr = (uint16_t)(cmd[3] | (cmd[4] << 8));
            int count = (len >= 6) ? cmd[5] : 1;
            if (count < 1) count = 1;
            if (count > F1541_CMD_MAX) count = F1541_CMD_MAX;
            for (int i = 0; i < count; i++) {
                uint16_t a = (uint16_t)(addr + i);
                uint8_t v = 0x00;
                if (a < F1541_RAM_SIZE) v = f->ram[a];
                else if (a >= 0xC000 && f->rom) v = f->rom[a - 0xC000];
                f->ch15_bin[i] = v;
            }
            f->ch15_bin_len = count; f->ch15_bin_pos = 0;
            /* status untouched: the reply IS the channel data */
            return;
        }
        if (c2 == 'W') {                         /* M-W lo hi count data */
            if (len < 6) { set_error(f, 30, 0, 0); return; }
            uint16_t addr = (uint16_t)(cmd[3] | (cmd[4] << 8));
            int count = cmd[5];
            if (count > len - 6) count = len - 6;
            for (int i = 0; i < count; i++) {
                uint16_t a = (uint16_t)(addr + i);
                if (a < F1541_RAM_SIZE) f->ram[a] = cmd[6 + i];
            }
            set_error(f, 0, 0, 0);
            return;
        }
        if (c2 == 'E') {                         /* M-E: can't execute   */
            set_error(f, 0, 0, 0);
            return;
        }
        set_error(f, 30, 0, 0);
        return;

    case 'I':                                    /* initialize           */
        dos_update_ids(f, 18, 0);
        set_error(f, 0, 0, 0);
        return;
    case 'V':                                    /* validate: no-op OK   */
        set_error(f, 0, 0, 0);
        return;

    case 'N': case 'S': case 'R': case 'C': {
        /* file commands take "[drv:]args" — strip through the colon      */
        const char *arg = (const char *)cmd; int alen = len;
        for (int i = 0; i < alen; i++)
            if (arg[i] == ':') { arg += i + 1; alen -= i + 1; break; }
        if (arg == (const char *)cmd) {          /* no colon at all      */
            set_error(f, c0 == 'S' ? 34 : 30, 0, 0);
            return;
        }
        if (c0 == 'N')      dos_format(f, arg, alen);
        else if (c0 == 'S') dos_scratch(f, arg, alen);
        else if (c0 == 'R') dos_rename(f, arg, alen);
        else                set_error(f, 30, 0, 0);   /* C= copy: not yet */
        return;
    }

    case 'P':                                    /* REL positioning      */
        set_error(f, 64, 0, 0);
        return;

    default:
        set_error(f, 30, 0, 0);
        return;
    }
}

/* ==== IEC Command Processing ============================================ */

static void process_atn_byte(floppy1541_t *f, uint8_t byte)
{
    F1541_DBG("[f1541] ATN byte=$%02X (listen=%d talk=%d ch=%d open_pending=%d)\n",
              byte, f->listening, f->talking, f->cur_channel, f->open_pending);
    f->ram[0x85] = byte;             /* mirror for the firmware's DOS log  */
    if (byte == 0x3F) {
        if (f->listening && f->open_pending) {
            f->fn_buf[f->fn_len] = 0;
            F1541_DBG("[f1541] UNLISTEN -> OPEN ch=%d name=\"%s\" len=%d\n",
                      f->cur_channel, f->fn_buf, f->fn_len);
            dos_log_mirror(f, (const uint8_t *)f->fn_buf, f->fn_len);
            channel_open(f, f->cur_channel, f->fn_buf, f->fn_len);
            f->open_pending = 0;
        }
        if (f->cmd_pending) {        /* PRINT#15 command executes now      */
            dos_exec(f, f->cmd_buf, f->cmd_len);
            f->cmd_pending = 0; f->cmd_len = 0;
        }
        f->listening = 0; f->recv_filename = 0;
    }
    else if (byte == 0x5F) { f->talking = 0; }
    else if ((byte & 0xE0) == 0x20 && (byte & 0x1F) != 0x1F) {
        uint8_t dev = byte & 0x1F;
        f->talking = 0;
        f->listening = (dev == f->device_num) ? 1 : 0;
        f->addressed = f->listening;
        f->got_secondary = 0;        /* a fresh round awaits its secondary */
    }
    else if ((byte & 0xE0) == 0x40 && (byte & 0x1F) != 0x1F) {
        uint8_t dev = byte & 0x1F;
        f->listening = 0;
        f->talking = (dev == f->device_num) ? 1 : 0;
        f->addressed = f->talking;
        f->got_secondary = 0;
    }
    else if ((byte & 0xF0) == 0xF0) {
        f->cur_channel = byte & 0x0F;
        f->open_pending = 1; f->fn_len = 0; f->recv_filename = 1;
        f->got_secondary = 1;
    }
    else if ((byte & 0xF0) == 0xE0) {
        int ch = byte & 0x0F;
        channel_close(f, ch);
        if (ch == 15)                /* CLOSE 15 closes every channel      */
            for (int i = 0; i < 15; i++)
                channel_close(f, i);
        f->cur_channel = (uint8_t)ch;
        f->got_secondary = 1;
    }
    else if ((byte & 0xF0) == 0x60) {
        f->cur_channel = byte & 0x0F;
        f->got_secondary = 1;
    }
    f->ram[0x79] = f->listening;     /* log mirror: listen/talk flags      */
    f->ram[0x7A] = f->talking;
}

/* ==== Byte-level bus API ================================================
 * The DOS above this line never touches the wire: it consumes bytes tagged
 * "under ATN or not" and produces channel bytes tagged EOI.  The bit-level
 * IEC state machine below is one transport for that; the QSPI link is the
 * other (kbd of the drive world — same bytes, no 1.35 ms each).  Both call
 * exactly these two functions, so the DOS cannot drift between paths.     */

void floppy1541_bus_send(floppy1541_t *f, uint8_t byte, int under_atn)
{
    /* The wire transport does per-round work on the ATN edges; over the link
     * the edges are implied by the tag changing, so derive them here.  (On
     * the wire path under_atn == f->under_atn always, so neither branch
     * fires and protocol_update keeps owning the transitions.) */
    if (under_atn && !f->under_atn) {
        f->under_atn = 1;
        f->got_secondary = 0;
    } else if (!under_atn && f->under_atn) {
        f->under_atn = 0;
        if (f->listening) {
            /* LISTEN with no secondary: the bytes that follow are a
             * filename on channel 0 (see protocol_update's ATN rise) */
            if (!f->open_pending && !f->got_secondary) {
                f->cur_channel  = 0;
                f->open_pending = 1;
                f->fn_len       = 0;
            }
            f->recv_filename = f->open_pending ? 1 : 0;
        }
    }

    if (under_atn) {
        process_atn_byte(f, byte);
    } else if (f->listening && f->recv_filename) {
        if (f->fn_len < F1541_CMD_MAX - 1)
            f->fn_buf[f->fn_len++] = (char)byte;
    } else if (f->listening && f->cur_channel == 15) {
        /* PRINT#15 — accumulate the DOS command, exec on UNLISTEN */
        if (f->cmd_len < F1541_CMD_MAX)
            f->cmd_buf[f->cmd_len++] = byte;
        f->cmd_pending = 1;
    } else if (f->listening &&
               (f->channels[f->cur_channel].writing ||
                f->channels[f->cur_channel].direct)) {
        channel_write_byte(f, f->cur_channel, byte);
    }
}

int floppy1541_bus_recv(floppy1541_t *f, int *eoi)
{
    int is_last = 0;
    int b = channel_read_byte(f, f->cur_channel, &is_last);
    if (b < 0) {
        *eoi = 1;
        return -1;
    }
    *eoi = is_last;
    f->tx_bytes++;                  /* live progress (firmware console) */
    return b;
}

int floppy1541_bus_unread(floppy1541_t *f, int n)
{
    /* Hand back bytes the transport took from the channel but never actually
     * delivered.  On the wire this cannot happen — the drive ships one byte
     * per handshake — but the link pushes ahead into a FIFO, and anything
     * still sitting there when the computer stops talking is discarded.
     * Without this the channel pointer would run ahead of what the machine
     * saw, and the EOI byte in particular could vanish: Pirates! reads its
     * text with B-R + a loop of INPUT#, each of which is its own
     * TALK..UNTALK, and a lost EOI leaves `IFST=0THEN8620` spinning forever.
     *
     * Only the buffer-backed readers can rewind: a "#" channel and the status
     * string are plain indices.  A file channel walks a sector chain and has
     * no cheap way back, so it reports what it could not undo. */
    f1541_channel_t *c;

    if (n <= 0)
        return 0;

    if (f->cur_channel == 15) {
        int back = n;
        if (back > f->status_pos)
            back = f->status_pos;
        f->status_pos -= back;
        return n - back;
    }

    c = &f->channels[f->cur_channel];
    if (c->open && c->direct) {
        uint16_t end = c->buf_len ? c->buf_len : 256;
        /* channel_read_byte parks the pointer at 0 after the last byte, so
         * un-reading from there starts at the end of the valid range */
        uint16_t pos = c->buf_pos ? c->buf_pos : end;
        int back = n;
        if (back > (int)pos)
            back = (int)pos;
        c->buf_pos = (uint16_t)(pos - back);
        return n - back;
    }

    if (f->listing_channel == (int)f->cur_channel) {
        int back = n;
        if (back > (int)f->listing_pos)
            back = (int)f->listing_pos;
        f->listing_pos -= (uint32_t)back;
        return n - back;
    }

    return n;                   /* file channel: nothing undone */
}

int floppy1541_bus_addressed(const floppy1541_t *f)
{
    return f->listening || f->talking;
}

int floppy1541_bus_talking(const floppy1541_t *f)
{
    /* Addressed to talk AND told which channel: TALK and TKSA are two
     * separate KERNAL calls, so the link transport can see the first
     * without the second and must not read the previous round's channel. */
    return f->talking && f->got_secondary;
}

static int prepare_tx_byte(floppy1541_t *f)
{
    int eoi = 0;
    int b = floppy1541_bus_recv(f, &eoi);
    if (b < 0) { f->tx_has_byte = 0; F1541_DBG("[f1541] TX ch=%d: no more data (EOF)\n", f->cur_channel); return 0; }
    f->tx_byte = (uint8_t)b;
    f->tx_eoi = eoi ? 1 : 0;
    f->tx_has_byte = 1;
    F1541_DBG("[f1541] TX ch=%d byte=$%02X eoi=%d\n", f->cur_channel, f->tx_byte, f->tx_eoi);
    return 1;
}

/* ==== Protocol-Level IEC State Machine ================================== */

static void protocol_update(floppy1541_t *f, uint32_t us,
                            int atn, int clk, int data)
{
    int atn_fell = (!atn && f->prev_atn);
    int atn_rose = (atn && !f->prev_atn);
    int clk_rose = (clk && !f->prev_clk);
    int clk_fell = (!clk && f->prev_clk);
    f->prev_atn = (uint8_t)atn;
    f->prev_clk = (uint8_t)clk;

#ifdef SIMULATION
    /* F1541_STATE=1: log every protocol-state change with bus levels */
    {
        static int last_state = -1;
        if (getenv("F1541_STATE") && (int)f->state != last_state) {
            fprintf(stderr, "[f1541-st] %uus state=%d atn=%d clk=%d data=%d "
                    "oC=%d oD=%d bits=%d\n", us, f->state, atn, clk, data,
                    f->out_clk, f->out_data, f->bit_count);
            last_state = (int)f->state;
        }
    }
#endif

    if (atn_fell) {
        F1541_DBG("[f1541] %uus ATN fell (listen=%d talk=%d recv_fn=%d)\n",
                  us, f->listening, f->talking, f->recv_filename);
        f->under_atn = 1;
        f->got_secondary = 0;
        f->out_data = 1; f->out_clk = 0;
        f->bit_count = 0; f->shift_reg = 0; f->rx_eoi = 0;
        f->rx_clk_armed = clk ? 0 : 1;
        f->state = S_RX_WAIT; f->timer_us = us;
        return;
    }

    if (atn_rose && f->under_atn) {
        F1541_DBG("[f1541] %uus ATN rose (listen=%d talk=%d recv_fn=%d)\n",
                  us, f->listening, f->talking, f->recv_filename);
        f->under_atn = 0;
        if (f->talking) {
            f->out_clk = 1; f->out_data = 0;
            f->timer_us = us; f->state = S_TX_TURNAROUND; return;
        }
        if (f->listening) {
            /* If an OPEN secondary ($F0+ch) was received under ATN, the
             * following data bytes are the filename. Some KERNALs (e.g.
             * Plus/4) instead send LISTEN as a standalone ATN sequence
             * and immediately follow with filename bytes — no secondary.
             * Treat that as an implicit OPEN on channel 0.  A DATA
             * secondary ($6x) means the bytes are channel data (PRINT#15
             * commands, SAVE payload) — do NOT hijack those into an OPEN. */
            if (!f->open_pending && !f->got_secondary) {
                f->cur_channel = 0;
                f->open_pending = 1;
                f->fn_len = 0;
            }
            f->recv_filename = f->open_pending ? 1 : 0;
            /* Keep holding DATA LOW: as the listener we must signal
             * "present / not ready" after ATN release, and only release DATA
             * once the talker raises CLK (handled in S_RX_WAIT).  Releasing
             * it here makes the Plus/4 abort the byte and re-assert ATN. */
            f->out_data = 1; f->out_clk = 0;
            f->bit_count = 0; f->shift_reg = 0; f->rx_eoi = 0;
            f->rx_clk_armed = clk ? 0 : 1;
            f->state = S_RX_WAIT; f->timer_us = us; return;
        }
        f->out_clk = 0; f->out_data = 0; f->state = S_IDLE; return;
    }

    if (!atn && f->state >= S_TX_TURNAROUND) {
        f->under_atn = 1; f->out_data = 1; f->out_clk = 0;
        f->bit_count = 0; f->shift_reg = 0;
        f->rx_clk_armed = clk ? 0 : 1;
        f->state = S_RX_WAIT; f->timer_us = us; return;
    }

    switch (f->state) {
    case S_IDLE:
        f->out_clk = 0; f->out_data = 0; break;

    /* ---- RECEIVE ----
     * IEC RX handshake (per byte, including the one right after ATN-fall):
     *  1. Listener holds DATA low (ACK from atn-fall or previous byte).
     *  2. Talker eventually releases CLK to HIGH = "ready".
     *  3. Listener releases DATA = "ready to receive".
     *  4. Talker pulls CLK low (and sets bit on DATA).
     *  5. Talker releases CLK = "bit valid"; listener samples on clk_rose.
     *  6. Repeat (4)(5) 8 times.
     *  7. After bit 7, listener pulls DATA low = byte ACK; back to (1).
     * EOI: between (3) and (4), if talker holds CLK high > 200µs, that
     * signals EOI; listener acks with a brief DATA pulse, then continues
     * receiving the byte. */
    case S_RX_WAIT:
        /* DATA is low (ACK held).  "Ready to send" is the talker RELEASING
         * CLK — which the listener may only honor after having seen CLK
         * LOW first (rx_clk_armed).  A plain level check broke against the
         * C64 KERNAL: UNLSN asserts ATN ~20µs BEFORE pulling CLK, so the
         * drive saw the stale CLK-high, released DATA instantly, and the
         * KERNAL's device-present check (DATA must be low) timed out.
         * The real 1541 ROM waits for CLK low, then its release, too. */
        f->out_clk = 0;
        if (!clk)
            f->rx_clk_armed = 1;
        else if (f->rx_clk_armed) {
            f->out_data = 0;
            f->timer_us = us;
            f->bit_count = 0;
            f->shift_reg = 0;
            f->rx_eoi = 0;
            f->state = S_RX_EOI_CHECK;
        }
        break;
    case S_RX_EOI_CHECK:
        /* DATA released, CLK high. Wait for CLK to fall (= talker is about
         * to send bit 0) or for the EOI timeout.  This state is only used
         * for EOI ACK signaling. */
        if (!clk) {
            f->state = S_RX_BITS;
        } else if ((uint32_t)(us - f->timer_us) > T_EOI_TIMEOUT) {
            f->rx_eoi = 1; f->out_data = 1; f->timer_us = us;
            f->state = S_RX_EOI_ACK;
        }
        break;
    case S_RX_EOI_ACK:
        if ((uint32_t)(us - f->timer_us) > T_EOI_ACK_HOLD) {
            f->out_data = 0; f->bit_count = 0; f->shift_reg = 0;
            f->state = S_RX_BITS;
        }
        break;
    case S_RX_BITS:
        /* CLK is low, DATA released. Each clk_rose samples one bit.
         * Bit polarity follows CBM standard: DATA wire HIGH = bit 1,
         * DATA wire LOW = bit 0 (per Anatomy of the 1541). This is the
         * opposite of the active-low handshake semantics. */
        if (clk_rose) {
            f->shift_reg |= (uint8_t)((data & 1) << f->bit_count);
            f->bit_count++;
            if (f->bit_count >= 8) {
                f->out_data = 1; f->timer_us = us; f->state = S_RX_ACK;
            }
        }
        break;
    case S_RX_ACK:
        if ((uint32_t)(us - f->timer_us) > T_RX_ACK_HOLD) {
            uint8_t byte = f->shift_reg;
            F1541_DBG("[f1541] RX byte=$%02X (under_atn=%d listen=%d recv_fn=%d eoi=%d)\n",
                      byte, f->under_atn, f->listening, f->recv_filename, f->rx_eoi);
            floppy1541_bus_send(f, byte, f->under_atn);
            /* Stay a listener even after the EOI byte: an addressed device
             * HOLDS DATA low between transfers ("present"), and the C64's
             * SENDBYTE tail verifies that within 1ms of the EOI ack —
             * releasing here (the old S_IDLE exit) read as "listener
             * vanished", set ST=$03 and turned every LOAD into ?FILE NOT
             * FOUND.  DATA is finally released on the ATN round that
             * un-addresses us (atn_rose with neither listen nor talk). */
            f->rx_clk_armed = clk ? 0 : 1;
            f->state = S_RX_WAIT;
        }
        break;

    /* ---- TRANSMIT ----
     * IEC turnaround (TALK direction switch):
     *   - Plus/4 was talker, holding CLK low for bit-banging
     *   - ATN released; Plus/4 becomes listener and must release CLK
     *   - Floppy becomes talker and must pull CLK low to take over
     * Problem: Plus/4 takes some time (often 100-300µs) to release CLK after
     * ATN release. If the floppy aggressively starts bit-banging CLK before
     * Plus/4 releases, the bus CLK never actually reaches HIGH for the first
     * "bit valid" edge — Plus/4 misses the first bit.
     * Solution: floppy releases CLK first, waits until bus CLK actually goes
     * HIGH (proving Plus/4 also released), then takes over by pulling LOW. */
    case S_TX_TURNAROUND:
        /* We became talker on ATN-release and are holding CLK LOW (out_clk=1,
         * set in the atn_rose handler) — this tells the Plus/4, now the
         * listener, that the drive has taken over the clock line.  Hold it
         * low briefly so the listener registers the takeover, then move on to
         * the per-byte ready handshake. */
        f->out_clk = 1;          /* keep CLK pulled low: "drive owns the clock" */
        f->out_data = 0;         /* release DATA (bit line) */
        if ((uint32_t)(us - f->timer_us) > T_TURNAROUND) {
            if (!prepare_tx_byte(f)) { f->state = S_IDLE; }
            else { f->timer_us = us; f->state = S_TX_READY; }
        }
        break;
    case S_TX_TURNAROUND_HOLD:   /* legacy state, no longer entered */
    case S_TX_READY:
        /* Per-byte "ready to send" handshake.  Release CLK HIGH and hold it
         * there for T_TX_READY_HIGH: this rising edge is what the CBM
         * listener waits on to know a byte is coming.  It responds by keeping
         * DATA released.  We then pull CLK low (start of bit 0) within the
         * 256µs the listener allows before it would treat the gap as EOI.
         * The previous code held CLK LOW throughout this window, so the
         * listener never saw the ready edge and never entered its bit loop. */
        f->out_clk = 0;          /* release CLK HIGH = "ready to send" */
        f->out_data = 0;
        /* Proceed only once the listener has released DATA (=1, "ready to
         * receive") AND the ready pulse has been visible long enough.  For
         * the first byte DATA is already high; for later bytes this waits for
         * the listener to finish ACKing the previous byte and loop back. */
        if (data && (uint32_t)(us - f->timer_us) > T_TX_READY_HIGH) {
            if (f->tx_eoi) { f->timer_us = us; f->state = S_TX_EOI_HOLD; }
            else {
                f->bit_count = 0; f->timer_us = us;
                /* out_data drives DATA LOW when 1. To put bit value V on the
                 * wire (HIGH for 1, LOW for 0), set out_data = !V. */
                f->out_data = (f->tx_byte & 1) ? 0 : 1;
                f->out_clk = 1;  /* pull CLK low → start clocking bit 0 */
                f->state = S_TX_BIT_SETUP;
            }
        }
        break;
    case S_TX_EOI_HOLD:
        /* EOI = the talker simply does NOT start clocking: CLK stays
         * RELEASED past the listener's ~200-256µs timeout, and the listener
         * acknowledges with a brief DATA-low pulse (C64 KERNAL ACPTR).
         * Pulling CLK low here (the old code) reads as "bit 0 coming" to a
         * real KERNAL, which then waits forever for a bit clock — EOI was
         * never signaled on the wire. */
        f->out_clk = 0; f->out_data = 0;
        if (!data) f->state = S_TX_EOI_ACK_WAIT;   /* ack pulse started    */
        break;
    case S_TX_EOI_ACK_WAIT:                        /* wait ack release     */
        f->out_clk = 0;
        if (data) {
            f->bit_count = 0; f->timer_us = us;
            f->out_data = (f->tx_byte & 1) ? 0 : 1;
            f->out_clk = 1;                        /* CLK low: bit setup   */
            f->state = S_TX_BIT_SETUP;
        }
        break;
    case S_TX_EOI_ACK_DONE:      /* legacy state, no longer entered */
        f->state = S_IDLE;
        break;
    case S_TX_BIT_SETUP:
        f->out_clk = 1;
        if ((uint32_t)(us - f->timer_us) > T_BIT_SETUP) {
            f->out_clk = 0; f->timer_us = us; f->state = S_TX_BIT_CLOCK;
        }
        break;
    case S_TX_BIT_CLOCK:
        f->out_clk = 0;
        if ((uint32_t)(us - f->timer_us) > T_BIT_HOLD) {
            f->bit_count++;
            if (f->bit_count >= 8) {
                /* Byte complete.  Pull CLK back LOW (idle/asserted): the
                 * C64 KERNAL bit loop waits for this final CLK-low after
                 * bit 7 BEFORE it acks with DATA — leaving CLK released
                 * here deadlocked both sides (listener waiting CLK-low,
                 * talker waiting DATA-low). */
                f->out_clk = 1; f->out_data = 0; f->state = S_TX_ACK_WAIT;
            } else {
                f->out_clk = 1;
                f->out_data = ((f->tx_byte >> f->bit_count) & 1) ? 0 : 1;
                f->timer_us = us; f->state = S_TX_BIT_SETUP;
            }
        }
        break;
    case S_TX_ACK_WAIT:
        f->out_clk = 1;  /* CLK held low (byte over), wait for DATA-low ACK */
        if (!data) {
            if (f->tx_eoi) { f->out_clk = 0; f->out_data = 0; f->state = S_IDLE; }
            else {
                f->timer_us = us;
                if (prepare_tx_byte(f)) f->state = S_TX_READY;
                else { f->out_clk = 0; f->out_data = 0; f->state = S_IDLE; }
            }
        }
        break;
    }
}

/* ==== GCR Encoding (for full emulation disk reads) ====================== */

static const uint8_t gcr_encode_tab[16] = {
    0x0A, 0x0B, 0x12, 0x13, 0x0E, 0x0F, 0x16, 0x17,
    0x09, 0x19, 0x1A, 0x1B, 0x0D, 0x1D, 0x1E, 0x15
};

/* Encode 4 source bytes → 5 GCR bytes */
void gcr_encode_group(const uint8_t *src, uint8_t *dst)
{
    uint8_t g[8];
    for (int i = 0; i < 4; i++) {
        g[i*2]   = gcr_encode_tab[src[i] >> 4];
        g[i*2+1] = gcr_encode_tab[src[i] & 0x0F];
    }
    dst[0] = (g[0] << 3) | (g[1] >> 2);
    dst[1] = (g[1] << 6) | (g[2] << 1) | (g[3] >> 4);
    dst[2] = (g[3] << 4) | (g[4] >> 1);
    dst[3] = (g[4] << 7) | (g[5] << 2) | (g[6] >> 3);
    dst[4] = (g[6] << 5) | g[7];
}

/* ---- Incremental GCR encoder (state lives in floppy1541.h: gcr_src..) ----
 *
 * A sector's F1541_GCR_SECTOR_LEN bytes are laid out:
 *   [  0.. 4]  sync       5 x $FF
 *   [  5..14]  header     2 groups  (8 source bytes)
 *   [ 15..23]  gap        9 x $55
 *   [ 24..28]  data sync  5 x $FF
 *   [ 29..353] data      65 groups  (260 source bytes)
 *   [354..362] gap        9 x $55
 * None of it is materialised.  gcr_byte_at() maps a rotational offset onto
 * that layout and encodes only the 5-byte group the offset lands in, holding
 * it so the next four bytes cost nothing.  That is the whole point: no step
 * of the read path is long enough to blow a fastloader's handshake window.
 */

/* Section boundaries, derived from the layout above so they cannot drift
 * apart from F1541_GCR_SECTOR_LEN (which is the same sum). */
#define GCR_O_HDR    5                      /* end of leading sync   */
#define GCR_O_HGAP   (GCR_O_HDR  + 10)      /* end of header groups  */
#define GCR_O_SYNC2  (GCR_O_HGAP + 9)       /* end of header gap     */
#define GCR_O_DATA   (GCR_O_SYNC2 + 5)      /* end of data sync      */
#define GCR_O_TAIL   (GCR_O_DATA + 325)     /* end of data groups    */
_Static_assert(GCR_O_TAIL + 9 == F1541_GCR_SECTOR_LEN,
               "GCR section layout must sum to F1541_GCR_SECTOR_LEN");

/* Group numbering: 0,1 = the two header groups, 2..66 = the 65 data groups */
#define GCR_G_HDR   0
#define GCR_G_DATA  2

/* Head arrived at a new sector: latch the source pointer, disk ID and the
 * data checksum.  The 256-byte XOR is ~3µs and runs once per sector (every
 * ~10ms), instead of the old ~20µs full-sector encode at the same boundary. */
static void gcr_prepare_sector(floppy1541_t *f, int track, int sector)
{
    const uint8_t *bam = d64_sector(f, 18, 0);
    f->gcr_id1    = bam ? bam[0xA2] : 0;
    f->gcr_id2    = bam ? bam[0xA3] : 0;
    f->gcr_src    = d64_sector(f, track, sector);
    f->gcr_track  = track;
    f->gcr_sector = sector;
    f->gcr_group_id = -1;                 /* nothing encoded yet */

    uint8_t x = 0;
    if (f->gcr_src)
        for (int i = 0; i < 256; i++) x ^= f->gcr_src[i];
    f->gcr_xorsum = x;

    F1541_DBG("[f1541-disk] prepare track=%d sector=%d (head_ht=%d motor=%d)\n",
              track, sector, f->head_halftrack, f->motor_on);
}

/* The 4 source bytes feeding group g of the prepared sector. */
static void gcr_group_src(floppy1541_t *f, int g, uint8_t *src)
{
    if (g < GCR_G_DATA) {                 /* header: 8 bytes, 2 groups */
        uint8_t hdr[8] = {
            0x08,
            (uint8_t)(f->gcr_sector ^ f->gcr_track ^ f->gcr_id2 ^ f->gcr_id1),
            (uint8_t)f->gcr_sector, (uint8_t)f->gcr_track,
            f->gcr_id2, f->gcr_id1, 0x0F, 0x0F
        };
        memcpy(src, hdr + g * 4, 4);
        return;
    }
    /* data block: $07, the 256 data bytes, checksum, $00, $00 */
    int base = (g - GCR_G_DATA) * 4;
    for (int i = 0; i < 4; i++) {
        int idx = base + i;
        src[i] = (idx == 0)   ? 0x07
               : (idx <= 256) ? f->gcr_src[idx - 1]
               : (idx == 257) ? f->gcr_xorsum
                              : 0x00;
    }
}

/* GCR byte at rotational offset `p` within the prepared sector. */
static uint8_t gcr_byte_at(floppy1541_t *f, int p)
{
    /* No such sector (truncated image): the head sees gap, finds no header,
     * and the DOS retries — the same thing the old gap fill produced. */
    if (!f->gcr_src) return 0x55;

    int g, b, o;
    if      (p < GCR_O_HDR)   return 0xFF;                /* sync      */
    else if (p < GCR_O_HGAP)  { o = p - GCR_O_HDR;
                                g = GCR_G_HDR  + o / 5; b = o % 5; }
    else if (p < GCR_O_SYNC2) return 0x55;                /* header gap*/
    else if (p < GCR_O_DATA)  return 0xFF;                /* data sync */
    else if (p < GCR_O_TAIL)  { o = p - GCR_O_DATA;
                                g = GCR_G_DATA + o / 5; b = o % 5; }
    else                      return 0x55;                /* tail gap  */

    if (f->gcr_group_id != g) {
        uint8_t src[4];
        gcr_group_src(f, g, src);
        gcr_encode_group(src, f->gcr_group);
        f->gcr_group_id = g;
    }
    return f->gcr_group[b];
}

#ifdef SIMULATION
/* Equivalence self-check (sim only, first few sectors): the incremental
 * encoder must reproduce the old whole-sector builder byte for byte, because
 * the board's read path is the same code and a one-byte drift is a checksum
 * error the DOS retries forever.  Builds the reference the old way and
 * compares all F1541_GCR_SECTOR_LEN offsets. */
static void gcr_selfcheck(floppy1541_t *f, int track, int sector)
{
    static int checked = 0;
    if (checked >= 8 || !f->gcr_src) return;
    checked++;

    const uint8_t *data = f->gcr_src;
    uint8_t ref[F1541_GCR_SECTOR_LEN];
    int pos = 0;
    for (int i = 0; i < 5; i++) ref[pos++] = 0xFF;
    uint8_t hdr_xor = (uint8_t)(sector ^ track ^ f->gcr_id2 ^ f->gcr_id1);
    uint8_t hdr[8] = { 0x08, hdr_xor, (uint8_t)sector, (uint8_t)track,
                       f->gcr_id2, f->gcr_id1, 0x0F, 0x0F };
    gcr_encode_group(hdr, ref + pos);     pos += 5;
    gcr_encode_group(hdr + 4, ref + pos); pos += 5;
    for (int i = 0; i < 9; i++) ref[pos++] = 0x55;
    for (int i = 0; i < 5; i++) ref[pos++] = 0xFF;
    uint8_t dblk[260];
    dblk[0] = 0x07;
    memcpy(dblk + 1, data, 256);
    uint8_t xs = 0;
    for (int i = 0; i < 256; i++) xs ^= data[i];
    dblk[257] = xs; dblk[258] = 0x00; dblk[259] = 0x00;
    for (int i = 0; i < 65; i++) { gcr_encode_group(dblk + i * 4, ref + pos); pos += 5; }
    for (int i = 0; i < 9; i++) ref[pos++] = 0x55;

    for (int p = 0; p < F1541_GCR_SECTOR_LEN; p++) {
        uint8_t got = gcr_byte_at(f, p);
        if (got != ref[p]) {
            fprintf(stderr, "[f1541-gcr] SELFCHECK FAIL t%d s%d off %d: "
                    "got $%02X want $%02X\n", track, sector, p, got, ref[p]);
            checked = 99;               /* stop after the first mismatch */
            f->gcr_group_id = -1;
            return;
        }
    }
    /* We just walked every group; drop the cache rather than restore an id,
     * so the held bytes can never be read as some other group's. */
    f->gcr_group_id = -1;
    fprintf(stderr, "[f1541-gcr] selfcheck OK t%d s%d (%d bytes)\n",
            track, sector, F1541_GCR_SECTOR_LEN);
}
#endif

/* Density zone: bytes per byte-ready (CPU cycles between GCR bytes) */
static int gcr_cycles_per_byte(int zone)
{
    static const int cpb[4] = { 32, 30, 28, 26 };
    return cpb[zone & 3];
}

static int track_density_zone(int track)
{
    if (track <= 17) return 3;
    if (track <= 24) return 2;
    if (track <= 30) return 1;
    return 0;
}

/* ==== Full Emulation: Memory Map ======================================== */

static uint8_t emu_read(void *ctx, uint16_t addr)
{
    floppy1541_t *f = (floppy1541_t *)ctx;
    if (addr < 0x1800) return f->ram[addr & 0x07FF];
    if (addr < 0x1C00) return via6522_read(&f->via1, addr & 0x0F);
    if (addr < 0x2000) return via6522_read(&f->via2, addr & 0x0F);
    if (addr >= 0xC000 && f->rom) return f->rom[addr - 0xC000];
    return 0xFF;
}

static void emu_write(void *ctx, uint16_t addr, uint8_t val)
{
    floppy1541_t *f = (floppy1541_t *)ctx;
    if (addr < 0x1800) { f->ram[addr & 0x07FF] = val; return; }
    if (addr < 0x1C00) { via6522_write(&f->via1, addr & 0x0F, val); return; }
    if (addr < 0x2000) { via6522_write(&f->via2, addr & 0x0F, val); return; }
}

/* ==== Full Emulation: Disk Mechanism ==================================== */

static void disk_step_motor(floppy1541_t *f)
{
    uint8_t new_phase = f->via2.orb & 0x03;
    if (new_phase == f->step_phase) return;
    int delta = ((int)new_phase - (int)f->step_phase) & 3;
    if (delta == 1 && f->head_halftrack < 69) f->head_halftrack++;
    else if (delta == 3 && f->head_halftrack > 0) f->head_halftrack--;
    F1541_DBG("[f1541-step] phase %d->%d delta=%d head_ht=%d (track=%d)\n",
              f->step_phase, new_phase, delta, f->head_halftrack,
              f->head_halftrack/2 + 1);
    f->step_phase = new_phase;
}

static void disk_advance(floppy1541_t *f, int cycles)
{
    if (!f->motor_on || !f->d64) return;

    int track = (f->head_halftrack / 2) + 1;
    if (track < 1) track = 1;
    if (track > 35) track = 35;

    int zone = track_density_zone(track);
    int cpb = gcr_cycles_per_byte(zone);
    int num_sectors = d64_sectors_per_track(track);

    /* A seek landed us on a new track — or the new zone has fewer sectors
     * than the old one.  Re-latch the sector under the head; the rotational
     * offset is kept, because the disk keeps spinning while the head moves. */
    if (track != f->gcr_track || f->gcr_sector >= num_sectors) {
        int s = (f->gcr_sector < num_sectors) ? f->gcr_sector : 0;
        gcr_prepare_sector(f, track, s);
#ifdef SIMULATION
        gcr_selfcheck(f, track, s);
#endif
    }

    f->byte_counter += (uint32_t)cycles;
    while (f->byte_counter >= (uint32_t)cpb) {
        f->byte_counter -= (uint32_t)cpb;

        /* Rotate one GCR byte past the head.  Crossing into the next sector
         * re-latches its source (~3µs); every byte in between costs at most
         * one 5-byte group encode (~0.3µs).  Nothing here can stall core 1
         * long enough to miss a fastloader handshake. */
        if (++f->gcr_pos >= F1541_GCR_SECTOR_LEN) {
            f->gcr_pos = 0;
            int s = f->gcr_sector + 1;
            if (s >= num_sectors) s = 0;
            gcr_prepare_sector(f, track, s);
        }

        /* Deliver byte to VIA2 */
        f->gcr_data_byte = gcr_byte_at(f, f->gcr_pos);
        /* SYNC = a RUN of consecutive $FF (the mark is 5 of them).  A LONE $FF
         * is legal GCR *data* — e.g. nibbles $5,$E encode to $0F,$1E which pack
         * to (0x0F<<4)|(0x1E>>1) = $FF — and MUST be delivered as a data byte.
         * The old code treated every single $FF as sync and suppressed its
         * byte-ready, so any sector whose data contained that pattern dropped a
         * byte → the read shifted → DATA CHECKSUM ERROR ($05) → endless retries
         * → head bump to track 1 → hang.  Two consecutive $FF can't occur in
         * valid GCR, so `run >= 2` cleanly distinguishes a real sync mark.
         *
         * The controller does NOT clock a byte-ready while over a sync mark
         * (the bit counter is held reset), so the first byte-ready after sync
         * is the first header/data byte and the read stays byte-aligned. */
        if (f->gcr_data_byte == 0xFF) { if (f->ff_run < 250) f->ff_run++; }
        else                           f->ff_run = 0;
        f->sync_detected = (f->ff_run >= 2) ? 1 : 0;
        f->byte_ready    = (f->ff_run >= 2) ? 0 : 1;
#ifdef SIMULATION
        if (getenv("F1541_SYNC")) {
            static int sync_bytes = 0, total = 0;
            total++;
            if (f->sync_detected) sync_bytes++;
            if ((total % 2000) == 0)
                fprintf(stderr, "[f1541-sync] delivered=%d syncbytes=%d "
                        "(last byte=$%02X trk=%d sec=%d)\n",
                        total, sync_bytes, f->gcr_data_byte,
                        f->gcr_track, f->gcr_sector);
        }
#endif
    }
}

static void update_via2_inputs(floppy1541_t *f)
{
    /* Port A input: GCR data byte from disk */
    f->via2.pa_in = f->gcr_data_byte;

    /* Port B inputs */
    uint8_t pb = f->via2.pb_in;
    /* PB4: write protect (0 = protected). Writable = not protected. */
    if (f->d64_writable) pb |= 0x10; else pb &= ~0x10;
    /* PB7: SYNC line, ACTIVE LOW — the hardware pulls it low while the head
     * is over a sync mark.  The read routine ($F562: BMI $F55D) waits for
     * PB7=0.  (Was inverted, so the drive never detected sync.) */
    if (f->sync_detected) pb &= ~0x80; else pb |= 0x80;
    f->via2.pb_in = pb;

    /* CA1: byte ready (active HIGH pulse) */
    if (f->byte_ready) {
        f->via2.ca1 = 1;
        f->byte_ready = 0;
    } else {
        f->via2.ca1 = 0;
    }
}

/* ==== Full Emulation: Update ============================================ */

/* Map the live IEC bus levels onto VIA1's inputs.  Factored out so the
 * once-per-call path (sim) and the per-instruction hook path (firmware) apply
 * IDENTICAL logic — the only difference is how often it runs.
 *
 * On the real 1541 ALL THREE serial input lines pass through a 74LS14 inverter
 * before reaching the VIA, so each PB input bit reads 1 when its bus line is
 * ASSERTED (electrically LOW).  ATN also reaches CA1 (inverted): CA1=1 when ATN
 * asserted, and PCR is set for a positive edge so the IRQ fires on ATN assert. */
static inline void emu_bus_in(floppy1541_t *f, int atn, int clk, int data)
{
    uint8_t pb_in = 0;
    if (!data) pb_in |= 0x01;  /* PB0 = DATA IN (inverted: 1 = asserted/LOW) */
    if (!clk)  pb_in |= 0x04;  /* PB2 = CLK IN  (inverted: 1 = asserted/LOW) */
    if (!atn)  pb_in |= 0x80;  /* PB7 = ATN IN  (inverted: 1 = asserted/LOW) */
    pb_in |= (f->via1.pb_in & 0x60);          /* preserve device addr PB5-6  */
    f->via1.pb_in = pb_in;
    f->via1.ca1   = atn ? 0 : 1;
}

/* Map VIA1's outputs back onto the IEC bus (out_clk/out_data: 1 = pull LOW),
 * including the hardware attention-acknowledge gate.  See the long comment at
 * the original call site: DATA is pulled low whenever the bus ATN state and the
 * CPU's ATNA (PB4) output DIFFER, so the drive acks ATN the instant it asserts
 * — before the IRQ routine has even set ATNA (the device-present handshake). */
static inline void emu_bus_out(floppy1541_t *f, int atn)
{
    uint8_t pb_out = f->via1.orb & f->via1.ddrb;
    f->out_data = (pb_out & 0x02) ? 1 : 0;    /* PB1 = DATA OUT */
    f->out_clk  = (pb_out & 0x08) ? 1 : 0;    /* PB3 = CLK OUT  */
    int atn_asserted = atn ? 0 : 1;
    int atna         = (pb_out & 0x10) ? 1 : 0;
    if (atn_asserted ^ atna)
        f->out_data = 1;                       /* pull DATA low */
}

/* Max emulated 6502 cycles executed per emu_update call.  Small so a catch-up
 * burst (e.g. after a gcr_build_sector spike) can't emit compressed IEC bit
 * edges; the excess elapsed time is dropped, not replayed.  Well below the ~43µs
 * VIC-badline stall the C64 receiver must tolerate, and far above one 6502
 * instruction (2-7 cycles) so the drive always makes forward progress. */
#define F1541_MAX_BATCH_CYCLES 8

static void emu_update(floppy1541_t *f, uint32_t us,
                       int atn, int clk, int data)
{
    /* Accumulate µs of elapsed time as 1 MHz CPU cycles.  Each instruction
     * consumes 2-7 cycles; the leftover (overshoot) is carried into the
     * next call by saving cycles_to_run after the run loop.  Without this,
     * we'd run 1 instruction per sim-µs (~3x faster than real 1MHz) and
     * the ATN ACK pulse would only last ~17µs instead of ~50µs, causing
     * the host (Plus/4) to miss it. */
    static int cycle_carry = 0;       /* leftover cycles between calls */
    int cycles_to_run = (int)(us - f->prev_us);
    f->prev_us = us;
    if (cycles_to_run < 0) cycles_to_run = 0;
    /* Cap the per-call batch to a SMALL number of cycles and DROP the excess.
     * This is the anti-compression fix (board-confirmed root cause: with the VIC
     * blanked — no badlines — big IEC loads complete reliably; with the screen on
     * they desync at random spots).  Core 1 runs the drive in one tight loop and
     * drives the IEC outputs per emulated instruction, so whenever a single call
     * gets a large elapsed-µs budget (mainly the gcr_build_sector spike, ~20µs of
     * C work mid-send) it would replay those cycles back-to-back at native
     * ~250MHz speed → the ROM's cycle-counted CLK/DATA bit windows come out
     * COMPRESSED on the wire, and a compressed window coinciding with a VIC
     * badline (~43µs stall) makes the C64 miss a CLK edge → desync.  Capping the
     * batch keeps every burst tiny (well inside the badline margin); dropping the
     * surplus (NOT carrying it) makes the drive run a hair slow after a spike —
     * the protocol-safe direction (a listener waits for a slow talker; it can't
     * survive a fast one).  Normal 1MHz pacing is untouched: ordinary per-call
     * budgets are ~1µs (< the cap), so the cycle_carry logic below still governs.
     * MUST stay non-blocking — an earlier wall-clock SPIN here blocked core 1 for
     * ms and hung the drive (?device not present).  See [[iec-random-load-failures]]. */
    if (cycles_to_run > F1541_MAX_BATCH_CYCLES) cycles_to_run = F1541_MAX_BATCH_CYCLES;
    cycles_to_run += cycle_carry;
    if (cycles_to_run <= 0) {
        /* Still in cycle debt from a multi-cycle instruction — keep the
         * (negative) carry and skip.  Resetting it to 0 here was a bug: it
         * discarded the debt, so the CPU effectively ran ~1.7x too fast,
         * out-running the Plus/4 during IEC transfers and losing bit sync. */
        cycle_carry = cycles_to_run;
        return;
    }
    cycle_carry = 0;

    /* Map IEC bus → VIA1 Port B inputs.
     * On the real 1541 ALL THREE serial input lines pass through a 74LS14
     * inverter before reaching the VIA, so each PB input bit reads 1 when its
     * bus line is ASSERTED (electrically LOW).  The ROM's handshake relies on
     * this throughout:
     *   PB7 (ATN):  $E87B loops receiving while PB7=1 (ATN asserted).
     *   PB2 (CLK):  $E9C9 waits for CLK released; $E9DF samples bits on CLK low.
     *   PB0 (DATA): $FF20 waits for DATA released; $EA0B reads the data bit.
     * Reading raw bus level (non-inverted) made the receive time out. */
    /* Seed VIA1 inputs from the batch sample.  When the per-instruction hook
     * is active (firmware) this is refreshed at the top of every loop pass
     * below; in the sim it's the single sample for the whole call. */
    emu_bus_in(f, atn, clk, data);

    /* Motor state from VIA2 PB2 */
    f->motor_on = (f->via2.orb & f->via2.ddrb & 0x04) ? 1 : 0;

    /* Step motor */
    disk_step_motor(f);

    /* Run CPU + peripherals.  An instruction is dispatched only once its
     * FULL cycle window has accumulated (cpu6502_next_cost lookahead), so
     * its bus effects land at the END of the window.  cpu6502_step() is
     * instruction-atomic — with the old `while (budget > 0)` gate a 4-cycle
     * `STA $1800` executed on the first cycle of its window, i.e. its VIA
     * write hit the wire ~3 cycles EARLY.  Byte-handshaked traffic (KERNAL,
     * DOS) never noticed, but cycle-counted drive-code fastloaders did:
     * Street Fighter's unhandshaked 2-bit burst has the C64 sample $DD00 at
     * fixed offsets after a release edge, and the 3-cycles-early drive had
     * its SECOND write on the wire at the C64's FIRST sample point — every
     * corrupt nibble of the diff-vs-VICE matched that one rule (see
     * COMPATIBILITY.md).  Conditional penalties (branch taken, page cross)
     * still overshoot the base gate by 1-2 cycles; the overshoot goes into
     * cycle_carry as debt exactly as before, so the long-run 1 MHz rate is
     * unchanged. */
    for (;;) {
        /* Firmware only: re-sample the live IEC bus onto VIA1 BEFORE this
         * instruction runs, so a poll loop ($E9C9 "wait CLK released", $FF20
         * "wait DATA released", the ATN-IRQ edge …) sees the wire within one
         * instruction of it changing — even if core 1 is running a catch-up
         * batch.  NULL in the sim (batch sample from emu_bus_in above holds). */
        if (f->iec_sample) {
            f->iec_sample(f);
            emu_bus_in(f, f->hw_atn, f->hw_clk, f->hw_data);
        }

        {
            /* Side-effect-free opcode peek (PC only ever runs from RAM or
             * ROM; the VIA window would have read side effects).  Open bus
             * reads $FF — a jammed case the gate need not be exact for. */
            uint16_t pc = f->cpu.pc;
            uint8_t  op = (pc < 0x1800)             ? f->ram[pc & 0x07FF]
                        : (pc >= 0xC000 && f->rom)  ? f->rom[pc - 0xC000]
                        : 0xFF;
            if (cycles_to_run < cpu6502_next_cost(&f->cpu, op))
                break;                 /* window not complete — keep budget */
        }

        uint32_t before = f->cpu.cycles;
        /* Count each byte the ROM ships to the host ($E958 = send-one-byte),
         * so the MCU can print live transfer progress. */
        if (f->cpu.pc == 0xE958)
            f->tx_bytes++;
#ifdef SIMULATION
        if (getenv("F1541_SEND") && f->cpu.pc == 0xE958) {
            /* $E958 = start sending one byte; the byte is in $F2,X-buffer.
             * Log the send buffer pointer & byte count. */
            static int nbytes = 0;
            nbytes++;
            uint8_t x = f->ram[0x82];
            static uint32_t last_us = 0;
            if (nbytes <= 60 || (nbytes % 100) == 0)
                fprintf(stderr, "[f1541-send] %uus (+%uus) byte #%d  bufidx=$%02X "
                        "shiftreg=$%02X\n", us, us - last_us, nbytes, x,
                        f->ram[0x023E + x]);
            last_us = us;
        }
        if (getenv("F1541_POLL") && f->cpu.pc == 0xF562) {
            static int zero = 0, one = 0;
            if (f->via2.pb_in & 0x80) one++; else zero++;
            if (((zero + one) % 5000) == 0)
                fprintf(stderr, "[f1541-poll] $F562 reads PB7=0(sync):%d PB7=1:%d\n",
                        zero, one);
        }
#endif
        cpu6502_step(&f->cpu);
        int consumed = (int)(f->cpu.cycles - before);
        if (consumed <= 0) consumed = 1;
        cycles_to_run -= consumed;

        via6522_tick(&f->via1, consumed);
        via6522_tick(&f->via2, consumed);
        disk_advance(f, consumed);
        /* BYTE READY from the disk controller is wired to the 6502's SO pin,
         * which sets the V flag.  The read routine spins in `CLV; BVC *`
         * ($F3BE) until a GCR byte arrives, then reads VIA2 Port A.  Without
         * this the drive never reads a single disk byte. */
        if (f->byte_ready)
            f->cpu.p |= P_V;
        update_via2_inputs(f);

        /* Motor state may change mid-frame */
        f->motor_on = (f->via2.orb & f->via2.ddrb & 0x04) ? 1 : 0;
        disk_step_motor(f);

        /* IRQ from either VIA */
        f->cpu.irq = (f->via1.irq || f->via2.irq) ? 1 : 0;

        /* Firmware only: recompute + drive the IEC outputs NOW (with the fresh
         * hw_atn from this pass) so the wire follows the VIA within one
         * instruction — critical for the ATN-ack gate and CLK/DATA edges the
         * host clocks off.  The post-loop emu_bus_out below is skipped when
         * this runs, so it doesn't stomp the fresh value with a batch sample. */
        if (f->iec_sample) {
            emu_bus_out(f, f->hw_atn);
            f->iec_drive(f);
        }
    }
#ifdef SIMULATION
    /* Periodic PC sampler (not tied to bus activity) — shows where the CPU
     * spends time during the disk read. */
    {
        static uint32_t pc_last = 0;
        if (getenv("F1541_PC") && us - pc_last >= 20000) {
            pc_last = us;
            fprintf(stderr, "[f1541-pc] %uus pc=$%04X head_ht=%d(trk%d) motor=%d "
                    "gcr_trk=%d gcr_sec=%d sync=%d  "
                    "jobs=%02X %02X %02X %02X %02X %02X  "
                    "buf-ts=%d/%d %d/%d %d/%d %d/%d  curtrk$22=%d\n",
                    us, f->cpu.pc, f->head_halftrack, f->head_halftrack/2+1,
                    f->motor_on, f->gcr_track, f->gcr_sector, f->sync_detected,
                    f->ram[0],f->ram[1],f->ram[2],f->ram[3],f->ram[4],f->ram[5],
                    f->ram[6],f->ram[7], f->ram[8],f->ram[9],
                    f->ram[10],f->ram[11], f->ram[12],f->ram[13],
                    f->ram[0x22]);
        }
    }
#endif

    /* Carry the leftover budget into the next call.  With the dispatch gate
     * above this is normally POSITIVE (0..6): the partial window of the next
     * instruction, still accumulating.  It goes NEGATIVE only when a branch
     * penalty or page cross overshot the base-cycle gate — that debt delays
     * the following instruction, keeping the long-run rate at exactly 1 MHz. */
    cycle_carry = cycles_to_run;

    /* Map VIA1 outputs → IEC bus.  Sim (batch) path only: the per-instruction
     * hook above already drove the outputs with a fresh sample every pass, so
     * re-running it here with the stale batch `atn` would stomp that value. */
    if (!f->iec_sample)
        emu_bus_out(f, atn);

#ifdef SIMULATION
    /* On ATN release, dump the drive's decode state: the command byte it
     * received ($85), its own LISTEN/TALK addresses ($77/$78 = $20/$40 + dev),
     * and the resulting listen/talk flags ($79/$7A). */
    {
        static int dbg_prev_atn = 1;
        if (getenv("F1541_ZP") && atn && !dbg_prev_atn) {
            fprintf(stderr,
                "[f1541-zp] %uus ATN release: rxbyte=$%02X  listenaddr=$%02X "
                "talkaddr=$%02X  listen=%d talk=%d  cmdbuf=\"",
                us, f->ram[0x85], f->ram[0x77], f->ram[0x78],
                f->ram[0x79], f->ram[0x7A]);
            for (int i = 0x0200; i < 0x0210; i++) {
                uint8_t c = f->ram[i];
                fprintf(stderr, "%c", (c >= 32 && c < 127) ? c : '.');
            }
            fprintf(stderr, "\"\n");
            if (getenv("F1541_RAMDUMP")) {
                FILE *rd = fopen("/tmp/drive_ram.bin", "wb");
                if (rd) { fwrite(f->ram, 1, F1541_RAM_SIZE, rd); fclose(rd); }
            }
        }
        dbg_prev_atn = atn;
    }
#endif
}

/* ==== Public API ======================================================== */

/* Read a PRG file from the mounted D64 by name (follows the sector chain).
 * Copies the raw file bytes — INCLUDING the 2-byte load address header — into
 * `out` (up to `max`).  Returns the byte count, or 0 if not found / no disk.
 * Used by the sim's fast-loader (direct RAM injection). */
int floppy1541_read_prg(floppy1541_t *f, const char *name, int name_len,
                        uint8_t *out, int max)
{
    uint8_t t = 0, s = 0;
    if (!f->d64) return 0;
    if (!d64_find_file(f, name, name_len, &t, &s)) return 0;
    int n = 0;
    int guard = 0;                  /* stop runaway chains on a corrupt disk  */
    while (t != 0 && n < max && guard++ < 1000) {
        const uint8_t *sec = d64_sector(f, t, s);
        if (!sec) break;
        uint8_t nt = sec[0], ns = sec[1];
        /* Last sector (next track == 0): sec[1] = index of the last valid
         * byte.  Otherwise the whole 254-byte payload (sec[2..255]). */
        int last = (nt == 0) ? ns : 255;
        for (int i = 2; i <= last && n < max; i++) out[n++] = sec[i];
        t = nt; s = ns;
    }
    return n;
}

/* Generate the directory ("$") as a loadable BASIC-listing PRG (incl. its
 * 2-byte load-address header) into out.  Returns byte count.  For fast-load. */
int floppy1541_read_dir(floppy1541_t *f, uint8_t *out, int max)
{
    if (!f->d64) return 0;
    generate_listing(f);
    int n = (int)f->listing_len;
    if (n > max) n = max;
    memcpy(out, f->listing_buf, (size_t)n);
    return n;
}

/* Streaming reader (see floppy1541.h).  The d64 lives in RAM, so a chunk
 * costs a pointer hop per sector at most — this is what lets the fastload
 * server run without the old whole-file (66 KB) staging buffer. */
int floppy1541_stream_open(floppy1541_t *f, const char *name, int name_len)
{
    f->stream_open = 0;
    if (!f->d64) return 0;
    if (name_len >= 1 && name[0] == '$') {
        generate_listing(f);
        f->stream_dir = 1;
        f->stream_pos = 0;
    } else {
        uint8_t t = 0, s = 0;
        if (!d64_find_file(f, name, name_len, &t, &s))
            return 0;
        f->stream_dir   = 0;
        f->stream_t     = t;
        f->stream_s     = s;
        f->stream_pos   = 2;            /* payload starts at sec[2] */
        f->stream_guard = 0;
    }
    f->stream_open = 1;
    return 1;
}

int floppy1541_stream_read(floppy1541_t *f, uint8_t *dst, int max)
{
    int n = 0;
    if (!f->stream_open || !f->d64)
        return 0;
    if (f->stream_dir) {
        while (n < max && f->stream_pos < f->listing_len)
            dst[n++] = f->listing_buf[f->stream_pos++];
        return n;
    }
    while (n < max && f->stream_t != 0 && f->stream_guard < 1000) {
        const uint8_t *sec = d64_sector(f, f->stream_t, f->stream_s);
        if (!sec) {
            f->stream_t = 0;            /* corrupt chain: EOF */
            break;
        }
        uint8_t nt = sec[0], ns = sec[1];
        /* Last sector (next track == 0): sec[1] = index of the last valid
         * byte.  Otherwise the whole 254-byte payload (sec[2..255]). */
        uint32_t last = (nt == 0) ? ns : 255;
        while (n < max && f->stream_pos <= last)
            dst[n++] = sec[f->stream_pos++];
        if (f->stream_pos > last) {     /* sector drained: advance the chain */
            f->stream_t   = nt;         /* nt == 0 ends the stream */
            f->stream_s   = ns;
            f->stream_pos = 2;
            f->stream_guard++;
        }
    }
    return n;
}

void floppy1541_init(floppy1541_t *f, uint8_t device_num)
{
    memset(f, 0, sizeof(*f));
    f->device_num = device_num;
    f->listing_channel = -1;
    f->state = S_IDLE;
    set_error(f, 73, 0, 0);
}

void floppy1541_insert_d64(floppy1541_t *f, uint8_t *d64, uint32_t size,
                           int writable)
{
    f->d64 = d64;
    f->d64_size = size;
    f->d64_writable = writable ? 1 : 0;
    f->stream_open = 0;     /* a fastload stream on the old disk is void */
    f->gcr_track = -1;      /* and so is the GCR image of the old disk */
    dos_update_ids(f, 18, 0);        /* zero-page disk ID for M-R checks  */
    set_error(f, 0, 0, 0);
}

/* Switch to (or reset) high-level DOS mode: protocol-level IEC with the
 * full command-channel emulation, no 6502.  `rom_for_mr` may be NULL; when
 * given, M-R of $C000+ serves real ROM bytes so drive-detect code sees a
 * stock 1541.  The disk stays inserted; all channels/buffers reset. */
void floppy1541_dos_mode(floppy1541_t *f, const uint8_t *rom_for_mr)
{
    f->rom = rom_for_mr;
    f->emu_mode = 0;
    f->state = S_IDLE;
    f->under_atn = 0;
    f->listening = 0; f->talking = 0; f->addressed = 0;
    f->open_pending = 0; f->recv_filename = 0; f->got_secondary = 0;
    f->cmd_len = 0; f->cmd_pending = 0;
    f->ch15_bin_len = f->ch15_bin_pos = 0;
    f->buf_used = 0;
    f->out_clk = 0; f->out_data = 0;
    f->prev_atn = 1; f->prev_clk = 1;
    f->tx_has_byte = 0;
    f->listing_channel = -1;
    for (int i = 0; i < F1541_NUM_CHANNELS; i++) {
        f->channels[i].direct = 0;
        f->channels[i].writing = 0;
        f->channels[i].open = 0;
    }
    memset(f->ram, 0, F1541_RAM_SIZE);
    if (f->d64)
        dos_update_ids(f, 18, 0);
    set_error(f, 73, 0, 0);
}

void floppy1541_eject(floppy1541_t *f)
{
    f->d64 = NULL; f->d64_size = 0; f->d64_writable = 0;
    for (int i = 0; i < F1541_NUM_CHANNELS; i++)
        channel_close(f, i);
    set_error(f, 74, 0, 0);
}

void floppy1541_load_rom(floppy1541_t *f, const uint8_t *rom)
{
    f->rom = rom;
    f->emu_mode = (rom != NULL) ? 1 : 0;

    if (f->emu_mode) {
        /* Initialize 6502 + VIAs */
        cpu6502_init(&f->cpu);
        f->cpu.read = emu_read;
        f->cpu.write = emu_write;
        f->cpu.ctx = f;
        via6522_reset(&f->via1);
        via6522_reset(&f->via2);
        memset(f->ram, 0, F1541_RAM_SIZE);

        /* Device-number jumpers on VIA1 PB5,PB6.  The ROM computes
         * device = 8 + PB5 + 2*PB6, so device 8 = both bits LOW (jumpers
         * grounded on the real drive).  The old code set both bits high,
         * which the ROM read as device 11 — so it ignored every command
         * addressed to device 8. */
        uint8_t devbits = (uint8_t)((f->device_num - 8) & 0x03);
        f->via1.pb_in = (uint8_t)((f->via1.pb_in & ~0x60) | (devbits << 5));

        /* Reset CPU (reads reset vector from ROM) */
        cpu6502_reset(&f->cpu);

        /* Park the head on track 18 (half-track 34).  At power-on the 1541
         * DOS assumes the head is wherever it was last left — its ROM inits
         * the current-track variable to 18 (the directory track) and does NOT
         * bump.  If the physical head starts elsewhere, the first directory
         * read lands on the wrong track and every file is "not found". */
        f->head_halftrack = 34;
        f->step_phase = 0;
        f->gcr_track = -1;          /* forces a prepare on the first byte */
        f->gcr_sector = 0;
        f->gcr_pos = 0;
        f->gcr_src = NULL;
        f->gcr_group_id = -1;
    }
}

void floppy1541_update(floppy1541_t *f, uint32_t us,
                       int atn, int clk, int data)
{
    if (f->emu_mode) {
        emu_update(f, us, atn, clk, data);
    } else {
        protocol_update(f, us, atn, clk, data);
    }
}
