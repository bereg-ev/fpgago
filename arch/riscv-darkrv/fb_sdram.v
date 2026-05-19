/*
 * fb_sdram.v — 1-row write-back cache between the CPU bus and peripheral/sdram.v
 *
 * Replaces the BRAM framebuffer at 0x00100000-0x001FFFFF when RAM=sdram.
 * Only the framebuffer goes to SDRAM — code and data RAM stay on-chip.
 *
 * Why a row cache:
 *   peripheral/sdram.v is row-burst oriented (Elpida EDS2516ADTA, 13×9 = 8K
 *   rows × 512 columns × 16-bit).  A single random word touches a whole row
 *   activate/burst/precharge cycle, so we cache the most-recently-touched row
 *   in BRAM (512 × 16-bit) and write it back when the CPU strays to a
 *   different row.
 *
 * Performance notes:
 *   - Sequential pixel writes within a scanline are FAST (single row, all
 *     hits after the first miss).
 *   - Column-style writes (raycast vertical strips) are SLOW: every pixel
 *     potentially evicts the previous row → flush 512 halfwords, read 512
 *     halfwords back.  ~1000+ SDRAM cycles per pixel.  This is a known
 *     trade-off; a scanline-buffering renderer mitigates it.
 *
 * Bus contract to the SoC:
 *   addr  — byte address INSIDE the FB region (0..0x000FFFFF expected)
 *   rd/wr — level signals from the CPU (DarkRISCV bus)
 *   ack   — 1-cycle pulse when the access has completed; soc.v ANDs this
 *           into data_ack → DDACK so DarkRISCV stalls cleanly on misses.
 */
`default_nettype none
`include "project.vh"

module fb_sdram (
    input  wire        clk,
    input  wire        rst,                // active-low

    input  wire [19:0] addr,                // FB-region byte offset
    input  wire        rd,
    input  wire        wr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrobe,
    output wire [31:0] rdata,
    output reg         ack,

    output wire        sd_cke,
    output wire        sd_cs,
    output wire        sd_ras,
    output wire        sd_cas,
    output wire        sd_we,
    output wire [12:0] sd_a,
    inout  wire [15:0] sd_d,
    output wire [1:0]  sd_ba,
    output wire        sd_ldqm,
    output wire        sd_udqm
);

    // ── Row buffer: 512 × 16-bit (1 KB) ─────────────────────────────────
    reg [15:0] row_buf [0:511];

    // Cached-row bookkeeping
    reg [14:0] cached_row;
    reg        row_valid;
    reg        row_dirty;

    // ── Address decode (FB byte offset → SDRAM row + word column) ───────
    wire [9:0]  req_row_in_fb = addr[19:10];                  // 1024 rows max
    wire [14:0] req_row       = {5'b0, req_row_in_fb};        // pad to 15 bits
    wire [7:0]  req_word_idx  = addr[9:2];                    // 256 words/row
    wire [8:0]  req_lo_col    = {req_word_idx, 1'b0};         // low halfword
    wire [8:0]  req_hi_col    = {req_word_idx, 1'b1};         // high halfword

    wire        is_hit        = row_valid && (req_row == cached_row);

    // CPU read combinationally from buffer (only meaningful on hit).
    assign rdata = {row_buf[req_hi_col], row_buf[req_lo_col]};

    // ── SDRAM control signals ───────────────────────────────────────────
    reg        sd_start_read;
    reg        sd_start_write;
    reg        sd_start_init;
    reg [14:0] sd_r_row;
    reg [14:0] sd_w_row;

    wire                                sd_rdy;
    wire                                sd_bram_we;
    wire [15:0]                         sd_bram_di;
    wire [`BRAM_ADDR_WIDTH-1:0]         sd_r_addr;
    wire [`BRAM_ADDR_WIDTH-1:0]         sd_w_addr;
    reg  [15:0]                         sd_bram_do_reg;

    // ── BRAM ports shared between CPU side and SDRAM side ───────────────
    // SDRAM-side write (read burst from SDRAM lands in buffer)
    always @(posedge clk) begin
        if (sd_bram_we) row_buf[sd_r_addr[8:0]] <= sd_bram_di;
        sd_bram_do_reg <= row_buf[sd_w_addr[8:0]];
    end

    // CPU-side write (byte-strobed) — only when state is IDLE and hit.
    // We allow writing the buffer in the same cycle ack pulses for a hit.
    reg cpu_buf_we;
    always @(posedge clk) begin
        if (cpu_buf_we) begin
            if (wstrobe[0]) row_buf[req_lo_col][ 7: 0] <= wdata[ 7: 0];
            if (wstrobe[1]) row_buf[req_lo_col][15: 8] <= wdata[15: 8];
            if (wstrobe[2]) row_buf[req_hi_col][ 7: 0] <= wdata[23:16];
            if (wstrobe[3]) row_buf[req_hi_col][15: 8] <= wdata[31:24];
        end
    end

    // ── FSM ─────────────────────────────────────────────────────────────
    localparam ST_INIT_WAIT      = 4'd0;
    localparam ST_IDLE           = 4'd1;
    localparam ST_FLUSH_START    = 4'd2;
    localparam ST_FLUSH_WAIT     = 4'd3;
    localparam ST_LOAD_START     = 4'd4;
    localparam ST_LOAD_WAIT      = 4'd5;
    localparam ST_SETTLE         = 4'd6;

    reg [3:0] state;
    reg       saw_busy;        // tracks rdy-drop seen during FLUSH/LOAD wait
    reg [15:0] init_cnt;       // power-up settle counter

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state          <= ST_INIT_WAIT;
            sd_start_read  <= 1'b0;
            sd_start_write <= 1'b0;
            sd_start_init  <= 1'b1;    // kick off init at reset release
            sd_r_row       <= 15'b0;
            sd_w_row       <= 15'b0;
            cached_row     <= 15'b0;
            row_valid      <= 1'b0;
            row_dirty      <= 1'b0;
            ack            <= 1'b0;
            cpu_buf_we     <= 1'b0;
            saw_busy       <= 1'b0;
            init_cnt       <= 16'd0;
        end else begin
            // Defaults
            sd_start_read  <= 1'b0;
            sd_start_write <= 1'b0;
            sd_start_init  <= 1'b0;
            ack            <= 1'b0;
            cpu_buf_we     <= 1'b0;

            case (state)
                ST_INIT_WAIT: begin
                    init_cnt <= init_cnt + 16'd1;
                    // sdram.v needs a few cycles + start_init asserted briefly.
                    // After init_cnt reaches a comfortable margin AND rdy is
                    // high, treat it as ready.
                    if (init_cnt > 16'd100 && sd_rdy) state <= ST_IDLE;
                end

                ST_IDLE: begin
                    if (rd || wr) begin
                        if (is_hit) begin
                            // Serve immediately.
                            if (wr) begin
                                cpu_buf_we <= 1'b1;
                                row_dirty  <= 1'b1;
                            end
                            ack   <= 1'b1;
                            state <= ST_SETTLE;
                        end else begin
                            // Miss.  Flush first if dirty; else go straight to load.
                            if (row_valid && row_dirty) begin
                                sd_w_row       <= cached_row;
                                sd_start_write <= 1'b1;
                                saw_busy       <= 1'b0;
                                state          <= ST_FLUSH_WAIT;
                            end else begin
                                sd_r_row      <= req_row;
                                sd_start_read <= 1'b1;
                                saw_busy      <= 1'b0;
                                state         <= ST_LOAD_WAIT;
                            end
                        end
                    end
                end

                ST_FLUSH_WAIT: begin
                    if (!sd_rdy) saw_busy <= 1'b1;
                    if (saw_busy && sd_rdy) begin
                        row_dirty     <= 1'b0;
                        // Now load the requested row.
                        sd_r_row      <= req_row;
                        sd_start_read <= 1'b1;
                        saw_busy      <= 1'b0;
                        state         <= ST_LOAD_WAIT;
                    end
                end

                ST_LOAD_WAIT: begin
                    if (!sd_rdy) saw_busy <= 1'b1;
                    if (saw_busy && sd_rdy) begin
                        cached_row <= req_row;
                        row_valid  <= 1'b1;
                        // Don't ack yet — go back through IDLE so the hit
                        // path runs cleanly (combinational rdata reads from
                        // the freshly-loaded buffer).
                        state      <= ST_IDLE;
                    end
                end

                ST_SETTLE: begin
                    // 1-cycle gap so CPU can advance its pipeline before we
                    // accept a new (still level-held) rd/wr.
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // ── SDRAM controller instance ───────────────────────────────────────
    // We always do full-row bursts: 512 halfwords (cols 0..511, buf positions 0..511).
    sdram u_sdram (
        .clk          (clk),
        .rst          (rst),
        .r_row        (sd_r_row),
        .w_row        (sd_w_row),
        .bram_di      (sd_bram_di),
        .bram_do      (sd_bram_do_reg),
        .bram_we      (sd_bram_we),
        .start_read   (sd_start_read),
        .start_write  (sd_start_write),
        .start_init   (sd_start_init),
        .rdy          (sd_rdy),
        .w_addr       (sd_w_addr),
        .r_addr       (sd_r_addr),
        .w_stop       (12'd511),
        .w_col        (12'd0),
        .w_addr_start (12'd0),
        .r_col        (12'd0),
        .r_stop       (12'd511),
        .sd_cke       (sd_cke),
        .sd_cs        (sd_cs),
        .sd_ras       (sd_ras),
        .sd_cas       (sd_cas),
        .sd_we        (sd_we),
        .sd_a         (sd_a),
        .sd_d         (sd_d),
        .sd_ba        (sd_ba),
        .sd_ldqm      (sd_ldqm),
        .sd_udqm      (sd_udqm),
        .fill_en      (1'b0),
        .fill_const   (16'b0),
        .dbg          (),
        .write_pending()
    );

endmodule

`default_nettype wire
