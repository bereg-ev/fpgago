/*
 * sdram_model.v — Functional SDRAM stub for desktop simulation (Verilator + SDL2)
 *
 * Replaces peripheral/sdram.v in the sim-desktop build.
 * Port signature is IDENTICAL to sdram.v so that lcd_sdram.v instantiates it
 * without any changes.
 *
 * Behaviour:
 *   Power-up memory: 512×512 words (18-bit address), filled with $random data
 *                    to simulate real SDRAM capacitor leakage at startup.
 *   Init:  rdy goes high after one clock; start_init is accepted but ignored.
 *   Read:  when start_read toggles, burst r_stop+1 pixels starting at column 0
 *          of SDRAM row r_row; drives bram_we=1, r_addr, bram_di each cycle.
 *          rdy=0 during burst, rdy=1 when idle.
 *   Write: when start_write toggles, burst w_stop+1 pixels into SDRAM row w_row
 *          starting at column w_col.  Data source depends on fill_en:
 *            fill_en=1 → fill_const (solid colour, e.g. CLEAR_FB)
 *            fill_en=0 → bram_do   (pixel BRAM from GPU; 1-cycle read latency
 *                                   accounted for by sampling one cycle after
 *                                   w_addr is presented, matching real sdram.v)
 *
 * Memory layout (must match gpu3d.v double-buffer addressing):
 *   Frame A: rows   0..271 (front when front_buf=0)
 *   Frame B: rows 512..783 (front when front_buf=1)
 *   Pixel(row, col) = mem[ {row[8:0], col[8:0]} ]
 */

module sdram(
    input  wire        clk,
    input  wire        rst,

    /* BRAM interface */
    input  wire [14:0] r_row,
    input  wire [14:0] w_row,
    output reg  [15:0] bram_di,
    input  wire [15:0] bram_do,
    output reg         bram_we,

    /* Handshake toggles */
    input  wire        start_read,
    input  wire        start_write,
    input  wire        start_init,
    output reg         rdy,

    /* Burst address outputs */
    output reg  [ 9:0] w_addr,
    output reg  [ 9:0] r_addr,
    input  wire [ 9:0] w_stop,
    input  wire [ 9:0] w_col,
    input  wire [ 9:0] w_addr_start,
    input  wire [ 9:0] r_col,
    input  wire [ 9:0] r_stop,

    /* SDRAM bus — all deasserted / high-Z */
    output reg         sd_cke,
    output reg         sd_cs,
    output reg         sd_ras,
    output reg         sd_cas,
    output reg         sd_we,
    output reg  [12:0] sd_a,
    inout  wire [15:0] sd_d,
    output reg  [ 1:0] sd_ba,
    output wire        sd_ldqm,
    output wire        sd_udqm,

    /* Optional fill (unused) */
    input  wire        fill_en,
    input  wire [15:0] fill_const,

    /* Debug */
    output wire [ 7:0] dbg,

    /* Write pending: asserted from start_write toggle until burst starts */
    output wire        write_pending
);

    /* SDRAM bus driven to safe NOP / high-Z */
    assign sd_d           = 16'bZ;
    assign sd_ldqm        = 1'b0;
    assign sd_udqm        = 1'b0;
    assign dbg            = {7'h0, rdy};
    assign write_pending  = (start_write != start_write0);

    /* ── Pixel memory: 1024 rows × 512 cols = 524 288 words ──────────────────
     * Row index is 10 bits (r_row[9:0] / w_row[9:0]):
     *   Frame A: r_row[9:0] = {0, display_row[8:0]}  rows   0..271
     *   Frame B: r_row[9:0] = {1, display_row[8:0]}  rows 512..783
     * Using only r_row[8:0] (as before) would make both buffers alias to
     * the same 512 rows — causing the back buffer to overwrite the front.
     * ─────────────────────────────────────────────────────────────────────── */
    reg [15:0] mem [0:524287];

    integer mi;
    initial begin
        for (mi = 0; mi < 524288; mi = mi + 1)
            mem[mi] = $random & 16'hFFFF;
    end

    /* ── Burst-read/write state machine ── */
    reg        start_read0;     /* last seen value of start_read toggle */
    reg        start_write0;    /* last seen value of start_write toggle */
    reg [ 9:0] burst_cnt;
    reg        bursting;
    reg        writing;         /* 1=write burst, 0=read burst */

    /* Per-burst latched inputs.  Real sdram.v captures address/control at
     * the start command; the master is then free to set up the *next*
     * command on its own clock.  Without these latches, icache.v's quick
     * start-write→start-write back-to-back (FS_WRITE_HI then FS_WRITE_LO)
     * lets the model sample the wrong w_col / fill_const for the first
     * burst.  Framebuffer prefetch is unaffected because dcache holds its
     * inputs stable across the burst. */
    reg [ 9:0] r_col_lat,  w_col_lat;
    reg [ 9:0] r_stop_lat, w_stop_lat;
    reg [14:0] r_row_lat,  w_row_lat;
    reg [15:0] fill_const_lat;
    reg        fill_en_lat;
    reg [ 9:0] w_addr_start_lat;

    /* Pipeline registers for write path: 1-cycle delay matches real sdram.v
     * (write_burst2 and synchronous BRAM read latency in gpu3d.v). */
    reg [15:0] wr_data_r;       /* registered pixel data (fill_const or bram_do) */
    reg [ 8:0] wr_col_r;        /* registered write column */
    reg [ 9:0] wr_row_r;        /* registered write row (10-bit: includes front_buf) */
    reg        wr_valid;        /* 1 cycle after burst starts */

    always @(posedge clk or negedge rst)
    if (!rst)
    begin
        rdy          <= 1'b0;
        bram_we      <= 1'b0;
        bram_di      <= 16'h0;
        r_addr       <= 10'h0;
        w_addr       <= 10'h0;
        start_read0  <= 1'b0;
        start_write0 <= 1'b0;
        burst_cnt    <= 10'h0;
        bursting     <= 1'b0;
        writing      <= 1'b0;
        wr_valid     <= 1'b0;
        wr_data_r    <= 16'h0;
        wr_col_r     <= 9'h0;
        wr_row_r     <= 9'h0;
        /* SDRAM bus: CKE=1, CS=1 (deselect), RAS/CAS/WE=1 (NOP) */
        sd_cke      <= 1'b1;
        sd_cs       <= 1'b1;
        sd_ras      <= 1'b1;
        sd_cas      <= 1'b1;
        sd_we       <= 1'b1;
        sd_a        <= 13'h0;
        sd_ba       <= 2'h0;
    end
    else
    begin
        /* One clock after reset, SDRAM is "ready" */
        if (!bursting)
            rdy <= 1'b1;

        /* Detect start_read toggle → begin read burst.  Latch inputs here
         * so a same-cycle change on the master side does not feed the burst. */
        if (!bursting && (start_read != start_read0))
        begin
            start_read0 <= start_read;
            bursting    <= 1'b1;
            burst_cnt   <= 10'h0;
            rdy         <= 1'b0;
            writing     <= 1'b0;
            r_row_lat   <= r_row;
            r_col_lat   <= r_col;
            r_stop_lat  <= r_stop;
        end
        else if (!bursting && (start_write != start_write0))
        begin
            start_write0     <= start_write;
            bursting         <= 1'b1;
            burst_cnt        <= w_addr_start;
            rdy              <= 1'b0;
            writing          <= 1'b1;
            w_row_lat        <= w_row;
            w_col_lat        <= w_col;
            w_stop_lat       <= w_stop;
            fill_en_lat      <= fill_en;
            fill_const_lat   <= fill_const;
            w_addr_start_lat <= w_addr_start;
        end

        /* Burst: one pixel per clock.  Use the per-burst latches so the
         * master can set up the next command without disturbing this one. */
        if (bursting)
        begin
            if (!writing)
            begin
                /* READ: drive bram_we/r_addr/bram_di for the LCD line buffer.
                 * Index mem from r_col_lat + burst_cnt — full-row prefetch
                 * still works (r_col_lat=0), and icache.v's data fills with
                 * non-zero r_col now hit the right row offsets. */
                bram_we <= 1'b1;
                r_addr  <= burst_cnt;
                bram_di <= mem[{r_row_lat[9:0], r_col_lat[8:0] + burst_cnt[8:0]}];
            end
            else
            begin
                w_addr  <= burst_cnt;
                bram_we <= 1'b0;
                wr_valid  <= 1'b1;
                wr_col_r  <= w_col_lat[8:0] + burst_cnt[8:0] - w_addr_start_lat[8:0];
                wr_row_r  <= w_row_lat[9:0];
                wr_data_r <= fill_en_lat ? fill_const_lat : bram_do;
            end

            burst_cnt <= burst_cnt + 1;

            /* Reads: terminate after (r_stop_lat - r_col_lat) since burst_cnt
             * is now an offset within the requested window.  Writes: keep
             * the existing absolute compare (w_addr_start handles the offset).
             *
             * Off-by-one fix: do NOT deassert bram_we here.  The
             * `bram_we <= 1` and `bram_di <= mem[...]` above have just
             * scheduled the LAST halfword for next cycle — letting them
             * propagate ensures icache.v's burst counter sees all 8
             * halfwords (and the framebuffer's last pixel of the row gets
             * latched too).  bram_we drops in the `else` branch below the
             * cycle after, when !bursting. */
            if (burst_cnt == (writing ? w_stop_lat : (r_stop_lat - r_col_lat)))
            begin
                bursting <= 1'b0;
                writing  <= 1'b0;
                rdy      <= 1'b1;
            end
        end
        else
        begin
            bram_we  <= 1'b0;
            wr_valid <= 1'b0;
        end

        /* Delayed pixel write: one cycle after w_addr was presented to GPU BRAM */
        if (wr_valid)
            mem[{wr_row_r[9:0], wr_col_r[8:0]}] <= wr_data_r;
    end

endmodule
