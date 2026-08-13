/*
 * drive_psram.v — PSRAM backend for the fabric 1541 (c64/README.md
 * phase 3).
 *
 * Serves drive_1541.v's two memory ports out of the board's APS6404L
 * through the psram.v / psram_fast.v command contract (cmd_* pulse +
 * latch, rdy pulse, busy), plus the MCU's byte-push port for loading the
 * DOS ROM and the pre-encoded GCR tracks at mount time.
 *
 * TIMING MODEL — the stretchable phi.  A byte read costs ~15-20 clk
 * (psram_fast transaction + CDC), so ROM + GCR cannot BOTH fit inside one
 * 32-clk phi, and the DOS's sector-read loop (`CLV/BVC *`) executes from
 * ROM for ~10 ms straight while the GCR stream must keep flowing.  So:
 *
 *  · GCR refills issue whenever the engine is free — they may collide
 *    with a ROM fetch.
 *  · `stall` (comb) = "this phi's ROM byte is not ready".  The phi
 *    GENERATOR (drive_tick.v / the TB wrapper) HOLDS the tick while
 *    stall is high, stretching that one drive cycle by the tail of the
 *    fetch (~0.3-0.6 us).  The whole drive — CPU, VIAs, GCR rotation —
 *    counts the same ticks, so the drive stays internally consistent; it
 *    just runs a hair slow against the C64 while executing FROM ROM.
 *    ROM code is IEC-handshaked or timer-driven — tolerant by design.
 *  · Drive-code fastloaders (the cycle-counted class this whole project
 *    exists for) run FROM DRIVE RAM with RAM buffers: no ROM fetches, no
 *    stalls, cycle-exact.  `stall_clks` counts stretched clks for the
 *    sim gate / BIOS diagnostics.
 *
 * GCR: an 8-deep sequential prefetch FIFO; the engine consumes one byte
 * per >=26 us and presents the next address a full byte-time early.  Any
 * address jump (seek, track wrap) flushes; the refetch lands ~1 us later.
 * Push: single-byte writes, lowest priority, `push_busy` paces the MCU
 * (the drive is held in reset while an image streams in).
 */

`default_nettype none

module drive_psram #(
    parameter [23:0] ROM_BASE = 24'h20_0000,
    parameter [23:0] GCR_BASE = 24'h21_0000
)(
    input  wire        clk,
    input  wire        rst,             /* active high — POWER/machine reset
                                         * only: a push may arrive on the very
                                         * clk the first byte wakes the system,
                                         * so this must NOT gate the FIFO */
    input  wire        gcr_flush,       /* hold while the DRIVE is in reset:
                                         * empties the prefetch FIFO so no
                                         * stale (pre-push) bytes survive a
                                         * mount */

    /* drive_1541 side */
    input  wire [13:0] rom_addr,
    input  wire        rom_sel,
    output reg  [7:0]  rom_data,
    input  wire [21:0] gcr_addr,
    output wire [7:0]  gcr_data,

    output wire        stall,           /* hold the drive tick while high */

    /* MCU push (drive in reset while streaming) */
    input  wire        push_we,
    input  wire [21:0] push_addr,
    input  wire [7:0]  push_data,
    output wire        push_busy,

    /* psram.v / psram_fast.v command port */
    output reg  [23:0] ps_addr,
    output reg         ps_rd,
    output reg         ps_wr,
    output wire        ps_byte,
    output wire [3:0]  ps_words,
    output wire [31:0] ps_wdata,
    input  wire [31:0] ps_rdata,
    input  wire        ps_rdy,
    input  wire        ps_busy
);

assign ps_byte  = 1'b1;
assign ps_words = 4'd1;

/* ── ROM byte cache-of-one ────────────────────────────────────────────── */
reg [13:0] rom_last = 14'h0;
reg        rom_valid = 1'b0;
wire       rom_hit = rom_valid && (rom_last == rom_addr);

assign stall = rom_sel && !rom_hit;

/* ── GCR prefetch FIFO ────────────────────────────────────────────────── */
reg [7:0]  gbuf [0:7];
reg [3:0]  gcount = 4'd0;
reg [21:0] gbase = 22'd0;
assign gcr_data = gbuf[0];

/* ── push FIFO (16 deep — never assume the
 * link's byte rate; count drops, they must stay 0) ───────────────────── */
reg [29:0] pfifo [0:15];
reg [3:0]  pf_wp = 4'd0, pf_rp = 4'd0;
reg [4:0]  pf_cnt = 5'd0;
reg [7:0]  push_drops = 8'd0;
wire       pf_empty = (pf_cnt == 5'd0);
wire       pf_full  = (pf_cnt >= 5'd16);
assign push_busy = pf_full;
wire [29:0] pf_head = pfifo[pf_rp];
assign ps_wdata  = {24'b0, pf_head[7:0]};

localparam ST_IDLE = 2'd0, ST_ROM = 2'd1, ST_GCR = 2'd2, ST_PUSH = 2'd3;
reg [1:0]  st = ST_IDLE;
reg [21:0] gfetch;                       /* in-flight GCR fetch address */

integer i;
`ifdef SIMULATION
integer dbg_romn = 0;
integer dbg_lat = 0, dbg_latmax = 0, dbg_nfetch = 0;
/* +fdchk=<hexfile>: verify every ROM fetch against a reference image
 * (one hex byte per line; ROM-derived — keep it OUT of the repo, e.g.
 * in the gitignored roms/ dir or /tmp) */
reg [7:0] fdref [0:16383];
reg [1023:0] fdchk_path;
integer dbg_chk = 0, dbg_bad = 0;
initial if ($value$plusargs("fdchk=%s", fdchk_path)) begin
    dbg_chk = 1;
    $readmemh(fdchk_path, fdref);
end
`endif
always @(posedge clk) begin
    ps_rd <= 1'b0;
    ps_wr <= 1'b0;
`ifdef SIMULATION
    if (st == ST_ROM) dbg_lat = dbg_lat + 1;
`endif

    if (push_we) begin
        if (pf_full)
            push_drops <= push_drops + 8'd1;
        else begin
            pfifo[pf_wp] <= {push_addr, push_data};
            pf_wp  <= pf_wp + 4'd1;
            pf_cnt <= pf_cnt + 5'd1;
        end
    end

    begin : engine
        reg [3:0]  gcount_n;
        reg [21:0] gbase_n;
        reg [1:0]  st_n;

        gcount_n = gcount;
        gbase_n  = gbase;
        st_n     = st;

        if (gcr_flush)
            gcount_n = 4'd0;
        /* GCR consume / seek tracking (the engine owns gcr_addr) */
        else if (gcr_addr != gbase_n) begin
            if (gcr_addr == gbase_n + 22'd1 && gcount_n != 4'd0) begin
                for (i = 0; i < 7; i = i + 1)
                    gbuf[i] <= gbuf[i + 1];
                gbase_n  = gbase_n + 22'd1;
                gcount_n = gcount_n - 4'd1;
            end else begin
                gbase_n  = gcr_addr;     /* seek / wrap: flush */
                gcount_n = 4'd0;
            end
        end

        /* transaction completion */
        if (ps_rdy) begin
            case (st)
                ST_ROM: begin
                    rom_data  <= ps_rdata[7:0];
                    rom_last  <= ps_addr[13:0];
                    rom_valid <= 1'b1;
`ifdef SIMULATION
                    if ($test$plusargs("fdmem") && dbg_romn < 24) begin
                        dbg_romn <= dbg_romn + 1;
                        $display("[fdmem] rom[%h] = %h  (drops=%d)",
                                 ps_addr[13:0], ps_rdata[7:0], push_drops);
                    end
                    if (dbg_chk && ps_rdata[7:0] != fdref[ps_addr[13:0]]
                        && dbg_bad < 20) begin
                        dbg_bad = dbg_bad + 1;
                        $display("[fdchk] rom[%h] = %h want %h",
                                 ps_addr[13:0], ps_rdata[7:0],
                                 fdref[ps_addr[13:0]]);
                    end
                    if (dbg_lat > dbg_latmax) dbg_latmax = dbg_lat;
                    dbg_nfetch = dbg_nfetch + 1;
                    if ($test$plusargs("fdlat") && (dbg_nfetch % 100000) == 0)
                        $display("[fdlat] n=%0d latmax=%0d", dbg_nfetch, dbg_latmax);
`endif
                end
                ST_GCR:
                    /* accept only if still the byte the FIFO wants next
                     * (a flush while in flight orphans the fetch) */
                    if (gfetch == gbase_n + {18'd0, gcount_n} &&
                        gcount_n != 4'd8) begin
                        gbuf[gcount_n[2:0]] <= ps_rdata[7:0];
                        gcount_n = gcount_n + 4'd1;
                    end
                default: begin                   /* ST_PUSH */
                    /* this assignment wins over the enqueue's (later in
                     * source order is irrelevant — it's the same always
                     * block, last NBA wins), so fold a simultaneous
                     * enqueue in */
                    pf_rp  <= pf_rp + 4'd1;
                    pf_cnt <= pf_cnt - 5'd1 + {4'd0, push_we && !pf_full};
                end
            endcase
            st_n = ST_IDLE;
        end

        /* issue next transaction: ROM need > GCR refill > push */
        if (st_n == ST_IDLE && !ps_busy && !ps_rd && !ps_wr && !ps_rdy) begin
            if (rom_sel && !rom_hit) begin
                ps_addr <= ROM_BASE + {10'd0, rom_addr};
                ps_rd   <= 1'b1;
                st_n    = ST_ROM;
`ifdef SIMULATION
                dbg_lat = 0;
`endif
            end else if (gcount_n < 4'd8 && !gcr_flush) begin
                gfetch  <= gbase_n + {18'd0, gcount_n};
                ps_addr <= GCR_BASE + gbase_n + {18'd0, gcount_n};
                ps_rd   <= 1'b1;
                st_n    = ST_GCR;
            end else if (!pf_empty) begin
                ps_addr <= {2'b00, pf_head[29:8]};
                ps_wr   <= 1'b1;
                st_n    = ST_PUSH;
            end
        end

        gcount <= gcount_n;
        gbase  <= gbase_n;
        st     <= st_n;
    end

    if (rst) begin
        rom_valid <= 1'b0;
        gcount <= 4'd0;
        st <= ST_IDLE;
        pf_wp <= 4'd0; pf_rp <= 4'd0; pf_cnt <= 5'd0;
        ps_rd <= 1'b0; ps_wr <= 1'b0;
    end
end

endmodule
