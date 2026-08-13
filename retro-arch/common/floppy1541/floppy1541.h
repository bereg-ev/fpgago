/*
 * Commodore 1541 Floppy Drive Emulator
 *
 * Two operating modes:
 *   1. Protocol-level: IEC serial bus state machine (LOAD, SAVE, $, status)
 *   2. Full emulation: 6502 CPU + dual 6522 VIA + GCR disk mechanism
 *      (supports fastloaders — requires 1541 ROM image)
 *
 * IEC bus signals use electrical levels: 0 = LOW (pulled), 1 = HIGH (released).
 * Wire encoding: bit 0 = wire HIGH, bit 1 = wire LOW (IEC inversion).
 */

#ifndef FLOPPY1541_H
#define FLOPPY1541_H

#include <stdint.h>
#include "cpu6502.h"
#include "via6522.h"

#ifdef __cplusplus
extern "C" {
#endif

#define F1541_NUM_CHANNELS   16
#define F1541_FILENAME_MAX   17
#define F1541_LISTING_MAX    5120
#define F1541_STATUS_MAX     48
#define F1541_RAM_SIZE       2048
#define F1541_ROM_SIZE       16384
#define F1541_GCR_SECTOR_MAX 400   /* max GCR bytes per sector */
/* Every sector encodes to the same length: 5 sync + 10 header + 9 gap +
 * 5 data sync + 325 data + 9 gap.  Uniform, so the rotational position maps
 * straight onto it. */
#define F1541_GCR_SECTOR_LEN (5 + 10 + 9 + 5 + 325 + 9)   /* 363 */

/* DOS emulation (protocol mode): command / open-name buffer.  Must hold a
 * full channel-15 command — M-W ships up to 3+3+35 binary bytes. */
#define F1541_CMD_MAX        64
/* Direct-access ("#") buffers live in ram[] at the real drive's addresses
 * $0300..$07FF — 5 buffers of 256 bytes, so M-R of a buffer works too. */
#define F1541_NUM_BUFS       5
#define F1541_BUF_BASE       0x0300

/* IEC protocol state machine (protocol-level mode) */
typedef enum {
    S_IDLE,
    S_RX_WAIT, S_RX_EOI_CHECK, S_RX_EOI_ACK, S_RX_BITS, S_RX_ACK,
    S_TX_TURNAROUND, S_TX_READY, S_TX_EOI_HOLD,
    S_TX_EOI_ACK_WAIT, S_TX_EOI_ACK_DONE,
    S_TX_BIT_SETUP, S_TX_BIT_CLOCK, S_TX_ACK_WAIT,
    S_TX_TURNAROUND_HOLD,   /* released CLK, holding for listener to detect "bus idle" */
} floppy_state_t;

/* Per-channel state */
typedef struct {
    uint8_t  open;
    char     filename[F1541_FILENAME_MAX];
    /* Read state (D64 sector chain) */
    uint8_t  cur_track;
    uint8_t  cur_sector;
    uint16_t sector_pos;    /* 16-bit: the ">255 → next sector" check must
                             * be reachable (a uint8_t wrapped instead) */
    uint8_t  last_sector;
    uint8_t  last_byte_pos;
    uint8_t  eof;
    /* Write state (SAVE) */
    uint8_t  writing;
    uint8_t  wr_track;
    uint8_t  wr_sector;
    uint16_t wr_pos;        /* next write offset within sector (2-255) */
    uint8_t  first_track;   /* first sector of file chain              */
    uint8_t  first_sector;
    uint16_t block_count;
    uint8_t  wr_type;       /* dir type of the file being written ($81/$82) */
    /* Direct-access ("#") state — DOS emulation */
    uint8_t  direct;        /* 1 = channel owns a 256-byte buffer      */
    uint8_t  buf_num;       /* which of the F1541_NUM_BUFS buffers     */
    uint16_t buf_pos;       /* read/write pointer within the buffer    */
    uint16_t buf_len;       /* readable bytes: 256 after U1, hdr byte after B-R */
} f1541_channel_t;

typedef struct floppy1541 {
    /* ---- Configuration ---- */
    uint8_t device_num;

    /* ---- D64 disk image ---- */
    uint8_t *d64;           /* writable pointer (NULL if no disk)      */
    uint32_t d64_size;
    uint8_t  d64_writable;  /* 1 = SAVE allowed                        */

    /* ---- Channels ---- */
    f1541_channel_t channels[F1541_NUM_CHANNELS];

    /* ---- Directory listing ---- */
    uint8_t  listing_buf[F1541_LISTING_MAX];
    uint32_t listing_len;
    uint32_t listing_pos;
    int      listing_channel;

    /* ---- Fastload stream (floppy1541_stream_open/_read) ---- */
    uint8_t  stream_open;   /* 1 = a stream is live                     */
    uint8_t  stream_dir;    /* 1 = serving the "$" listing              */
    uint8_t  stream_t;      /* current chain track (0 = chain ended)    */
    uint8_t  stream_s;      /* current chain sector                     */
    uint16_t stream_guard;  /* sectors walked (runaway-chain stop)      */
    uint32_t stream_pos;    /* payload index in sector / listing offset */

    /* ---- Status channel (15) ---- */
    char     status_str[F1541_STATUS_MAX];
    int      status_len;
    int      status_pos;

    /* ---- Protocol-level IEC state ---- */
    floppy_state_t state;
    uint8_t  under_atn;
    uint8_t  addressed;
    uint8_t  listening;
    uint8_t  talking;
    uint8_t  cur_channel;
    uint8_t  open_pending;
    uint8_t  recv_filename;
    uint8_t  got_secondary;   /* a $6x/$Ex/$Fx arrived in this ATN round */

    char     fn_buf[F1541_CMD_MAX];   /* OPEN name / ch15 command string */
    uint8_t  fn_len;

    /* ---- DOS emulation (protocol mode) ---- */
    uint8_t  cmd_buf[F1541_CMD_MAX];  /* PRINT#15 bytes, exec on UNLISTEN */
    uint8_t  cmd_len;
    uint8_t  cmd_pending;
    uint8_t  buf_used;                /* "#" buffer allocation bitmask    */
    uint8_t  ch15_bin[256];           /* binary M-R reply (before status) */
    int      ch15_bin_len, ch15_bin_pos;

    uint8_t  shift_reg;
    uint8_t  bit_count;
    uint8_t  rx_eoi;
    uint8_t  rx_clk_armed;    /* S_RX_WAIT: CLK seen LOW since entry      */

    uint8_t  tx_byte;
    uint8_t  tx_eoi;
    uint8_t  tx_has_byte;

    uint32_t timer_us;
    uint8_t  out_clk;
    uint8_t  out_data;
    uint8_t  prev_atn;
    uint8_t  prev_clk;

    uint8_t  error_num;
    uint8_t  error_track;
    uint8_t  error_sector;

    /* ---- Full emulation mode ---- */
    uint8_t  emu_mode;      /* 1 = 6502 emulation (fastloaders)        */
    cpu6502_t cpu;
    via6522_t via1;         /* IEC bus interface                        */
    via6522_t via2;         /* disk controller                          */
    uint8_t  ram[F1541_RAM_SIZE];
    const uint8_t *rom;     /* 16KB ROM pointer (NULL = protocol mode)  */

    uint32_t prev_us;       /* previous timestamp for cycle calculation */

    /* ---- Disk mechanism (full emulation) ---- */
    uint8_t  head_halftrack;    /* 0-69 (track = halftrack/2 + 1)      */
    uint8_t  step_phase;        /* stepper motor phase (0-3)           */
    uint8_t  motor_on;
    uint32_t rotation_counter;  /* cycles into current rotation        */
    uint32_t byte_counter;      /* cycles until next GCR byte ready    */
    uint8_t  byte_ready;        /* 1 = new GCR byte available          */

    /* Incremental GCR encoder — one 5-byte group at a time, on demand.
     *
     * The old code encoded a WHOLE sector (~20µs of C work) every time the
     * rotating head crossed a sector boundary — i.e. every ~10ms for as long
     * as the motor runs, INCLUDING in the middle of a transfer.  On the board
     * that is a ~20µs blackout of core 1, and a drive-code fastloader cannot
     * survive one: those clock the drive off the host's ATN line and give it
     * only ~23µs to answer each 2-bit handshake (WWDOS class — see
     * retro-arch/COMPATIBILITY.md).  A ~20µs stall inside a ~23µs deadline is
     * a missed bit, and the inner loop has no retry.
     *
     * So nothing is precomputed.  The head consumes one GCR byte every 26-32
     * cycles; each byte is served straight out of a cached 5-byte group, and
     * only every 5th byte re-encodes one (~0.3µs).  Peak work per byte drops
     * ~60x and no single step can eat the handshake budget.  Caching the
     * whole track instead would be ~7.6KB — this firmware is copy_to_ram and
     * had ~450 bytes of headroom, so that never fit; this costs ~20 bytes and
     * gives the same freedom from mid-transfer stalls. */
    const uint8_t *gcr_src;     /* the 256 data bytes under the head   */
    uint8_t  gcr_id1, gcr_id2;  /* disk ID (header field)              */
    uint8_t  gcr_xorsum;        /* data-block checksum for gcr_src     */
    uint8_t  gcr_group[5];      /* the one encoded group we hold       */
    int      gcr_group_id;      /* which group that is (-1 = none)     */
    int      gcr_pos;           /* rotational offset within the sector */
    int      gcr_track;         /* which track is prepared (-1 = none) */
    int      gcr_sector;        /* which sector is prepared            */
    uint8_t  gcr_data_byte;     /* last byte delivered to VIA2 PA      */
    uint8_t  sync_detected;     /* 1 = head is in a sync region        */
    uint8_t  ff_run;            /* consecutive 0xFF GCR bytes (>=2 = real sync) */

    /* Progress: total bytes the ROM has shipped over the serial bus (TALK).
     * Bumped each time the 6502 enters the 1541 "send one byte" routine
     * ($E958).  Read by the MCU to print live transfer progress. */
    uint32_t tx_bytes;

    /* ---- Per-instruction IEC bus I/O hooks (firmware core-1 ONLY) ----
     * When set, emu_update samples the live IEC inputs (iec_sample fills
     * hw_atn/hw_clk/hw_data) and drives its outputs (iec_drive from
     * out_clk/out_data) ONCE PER 6502 INSTRUCTION instead of once per
     * (batched) call.  This decouples bus fidelity from the core-1 loop
     * rate: even if core 1 falls behind and emu_update runs a batch of
     * instructions in one call, each instruction still sees a fresh bus and
     * drives a fresh output — so a hiccup can no longer make the drive miss
     * an IEC edge mid-transfer (the "idle, drive still spinning" deadlock).
     * NULL in the SDL sim → emu_update keeps its exact once-per-call
     * behaviour (byte-identical to the sim-proven path). */
    void (*iec_sample)(struct floppy1541 *f);  /* GPIO -> hw_atn/clk/data   */
    void (*iec_drive)(struct floppy1541 *f);   /* out_clk/out_data -> GPIO  */
    int hw_atn, hw_clk, hw_data;               /* live bus, filled by hook  */
} floppy1541_t;

/* ---- Public API ---- */

/* d64 geometry + the reference GCR group encoder — shared with the
 * fabric-1541 mount path (fdrive_push.c), which must produce EXACTLY the
 * byte stream this emulation would. */
int  d64_sectors_per_track(int track);
int  d64_offset(int track, int sector);
void gcr_encode_group(const uint8_t *src, uint8_t *dst);

void floppy1541_init(floppy1541_t *f, uint8_t device_num);

/* Insert D64 image. writable=1 enables SAVE. */
void floppy1541_insert_d64(floppy1541_t *f, uint8_t *d64, uint32_t size,
                           int writable);

void floppy1541_eject(floppy1541_t *f);

/*
 * Load 1541 ROM to enable full 6502 emulation (fastloaders).
 * Without ROM, falls back to protocol-level emulation.
 * ROM must be 16KB. Pointer must remain valid.
 */
void floppy1541_load_rom(floppy1541_t *f, const uint8_t *rom);

/*
 * Switch to (or reset) high-level DOS-emulation mode: the protocol-level
 * IEC state machine plus full command-channel DOS (U1/U2, B-P/B-R/B-W,
 * M-R/M-W, "#" buffers, SEQ, scratch/rename/format).  No 6502 — every
 * disk operation completes at bus speed with zero mechanical latency.
 * rom_for_mr (may be NULL) backs M-R reads of $C000+ for drive-detect.
 */
void floppy1541_dos_mode(floppy1541_t *f, const uint8_t *rom_for_mr);

/* Update IEC bus. atn/clk/data: wire states (0=LOW, 1=HIGH). */
void floppy1541_update(floppy1541_t *f, uint32_t us,
                       int atn, int clk, int data);

/* ---- Byte-level bus API (transport-independent DOS) ----
 * The DOS emulation consumes bytes, not edges: one byte from the computer
 * tagged "sent under ATN" (bus command) or not (channel data), and one byte
 * back from the addressed channel tagged EOI (last byte of the transfer).
 * floppy1541_update()'s bit-level state machine is one transport for these;
 * the QSPI link (qspi_link.c, DOS-over-link mode) is the other, and it moves
 * the same bytes without the 1.35 ms per byte the serial wire costs.  Both
 * go through exactly these calls, so the DOS behaves identically either way.
 *
 * recv returns the byte, or -1 with *eoi set when the channel is exhausted.
 * addressed() reports whether the drive currently owns the bus (it was the
 * device named by the last LISTEN/TALK) — the link transport uses it to know
 * when to hand traffic back to the stock KERNAL path. */
void floppy1541_bus_send(floppy1541_t *f, uint8_t byte, int under_atn);
int  floppy1541_bus_recv(floppy1541_t *f, int *eoi);

/* Give back the last n bytes recv returned on the current channel — for a
 * transport that reads ahead into a buffer the computer may walk away from
 * (the link's FIFO is cleared on the next TALK).  The wire transport never
 * needs it: it ships one byte per handshake.  Returns how many could NOT be
 * undone (a file channel walks a sector chain and cannot rewind cheaply). */
int  floppy1541_bus_unread(floppy1541_t *f, int n);
int  floppy1541_bus_addressed(const floppy1541_t *f);
int  floppy1541_bus_talking(const floppy1541_t *f);

/* Read a PRG file (incl. its 2-byte load-address header) from the mounted D64
 * into out[0..max).  Returns byte count, or 0 if not found.  For the sim
 * fast-loader — direct RAM injection instead of the slow serial transfer. */
int floppy1541_read_prg(floppy1541_t *f, const char *name, int name_len,
                        uint8_t *out, int max);

/* Generate the directory ("$") as a loadable listing PRG.  For fast-load. */
int floppy1541_read_dir(floppy1541_t *f, uint8_t *out, int max);

/* Streaming variant of read_prg/read_dir for the MCU fastload server: open
 * resolves "$" (listing generated into the drive's own listing_buf) or a
 * filename (start of its sector chain); read pulls up to `max` bytes per
 * call, walking the chain in place — no whole-file buffer.  A short read
 * (< max, including 0) means EOF.  One stream per drive (state in f).
 * open returns 1, or 0 when not found / no disk. */
int floppy1541_stream_open(floppy1541_t *f, const char *name, int name_len);
int floppy1541_stream_read(floppy1541_t *f, uint8_t *dst, int max);

#ifdef __cplusplus
}
#endif

#endif /* FLOPPY1541_H */
