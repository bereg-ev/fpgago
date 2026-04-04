`include "project.vh"

/*
 * lcd_sdram.v — SDRAM-backed full-screen pixel framebuffer
 *
 * Drives a continuous pixel stream from SDRAM to the LCD via a ping-pong
 * line buffer (one ram_1k_18 split into two 512-word halves):
 *
 *   Addresses   0– 511  = half for even display rows  (row[0] = 0)
 *   Addresses 512–1023  = half for odd  display rows  (row[0] = 1)
 *
 * Prefetch schedule (SIMULATION_SDL: h3=480, h4=550, v4=290):
 *   At col=1 of row R, the SDRAM burst for row R+1 is triggered into buf_fill
 *   (~row[0]).  The burst completes around col=491 — before row R ends
 *   (col=549).  When row R+1 starts, row[0] flips so buf_disp automatically
 *   becomes the freshly-filled half.
 *
 * sdram_pixel_out is bram_dout_b (1-cycle synchronous BRAM read latency).
 * soc.v latches it into lcd_data on posedge when lcd_de=1.
 *
 * sd_clk (SDRAM clock output) is NOT a port here — soc.v drives yclk = clk.
 */

module lcd_sdram(
    input  wire        clk,
    input  wire        rst,

    /* Display scan position from lcd_out */
    input  wire [10:0] row,
    input  wire [10:0] col,

    /* RGB565 pixel output to soc.v blending mux */
    output wire [15:0] sdram_pixel_out,

    /* CPU write interface */
    input  wire [23:0] ctrl_addr,
    input  wire [15:0] ctrl_data,
    input  wire        ctrl_we,
    output wire        cpu_rdy,     /* = rdy from internal sdram_y */

    /* Y SDRAM physical bus */
    output wire        sd_cke,
    output wire        sd_cs,
    output wire        sd_ras,
    output wire        sd_cas,
    output wire        sd_we,
    output wire [12:0] sd_a,
    inout  wire [15:0] sd_d,
    output wire [ 1:0] sd_ba,
    output wire        sd_ldqm,
    output wire        sd_udqm
);

// ── Timing constants — must match lcd_out.v SIMULATION_SDL / hardware values ─
localparam V_TOTAL = 290;               // v4_reg: total rows per frame
localparam V_LAST  = V_TOTAL - 1;       // 289: last row before frame wrap

// ── SDRAM instance connections ────────────────────────────────────────────────
wire [15:0] bram_di;        // pixel data: SDRAM → line buffer port A
wire        bram_we;        // write enable from SDRAM burst
wire [ 9:0] bram_r_addr;    // burst address counter (r_addr output of sdram)
wire        rdy;            // SDRAM ready flag
wire        write_pending;  // write request queued but not yet started

reg  [14:0] r_row_reg;      // SDRAM row address for the next prefetch
reg         start_read;     // toggle to start a burst read
reg         start_init;     // toggle to start SDRAM initialisation

/* CPU write interface registers */
reg [14:0] w_row_reg;       /* which SDRAM row (= display row) to write */
reg [15:0] fill_const_reg;  /* RGB565 fill colour */
reg [ 9:0] w_col_reg;       /* starting column (default 0) */
reg [ 9:0] w_stop_reg;      /* burst length - 1 (default 479) */
reg        start_write;     /* toggle-to-trigger (like start_read) */

assign cpu_rdy = rdy && !write_pending;

sdram sdram_y(
    .clk(clk),               .rst(rst),
    .r_row(r_row_reg),        .w_row(w_row_reg),
    .bram_di(bram_di),        .bram_do(16'b0),     .bram_we(bram_we),
    .start_read(start_read),  .start_write(start_write),  .start_init(start_init),
    .rdy(rdy),
    .w_addr(),                .r_addr(bram_r_addr),
    .w_stop(w_stop_reg),      .w_col(w_col_reg),
    .w_addr_start(10'b0),
    .r_col(10'b0),            .r_stop(10'd479),
    .fill_en(1'b1),           .fill_const(fill_const_reg),
    .sd_cke(sd_cke),          .sd_cs(sd_cs),
    .sd_ras(sd_ras),          .sd_cas(sd_cas),     .sd_we(sd_we),
    .sd_a(sd_a),              .sd_d(sd_d),         .sd_ba(sd_ba),
    .sd_ldqm(sd_ldqm),        .sd_udqm(sd_udqm),
    .dbg(),
    .write_pending(write_pending)
);

// ── Ping-pong line buffer ─────────────────────────────────────────────────────
// buf_disp = row[0] selects which half is currently displayed.
// buf_fill = ~row[0] is the half being filled by the SDRAM burst.
wire buf_disp = row[0];
wire buf_fill = ~row[0];

// Port A (SDRAM writes fill half)
wire [9:0] bram_addr_a = {buf_fill, bram_r_addr[8:0]};

// Port B (display reads active half at current column)
wire [9:0] bram_addr_b = {buf_disp, col[8:0]};

wire [17:0] bram_dout_b;

ram_1k_18 linebuf(
    .clk_a(clk), .we_a(bram_we),
    .addr_a(bram_addr_a), .din_a({2'b0, bram_di}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b(bram_addr_b), .din_b(18'b0), .dout_b(bram_dout_b)
);

assign sdram_pixel_out = bram_dout_b[15:0];

// ── Prefetch controller ───────────────────────────────────────────────────────
reg        init_sent;
reg [10:0] prev_col;
reg        row_triggered;   // set once per row to prevent double-triggering

/* CPU write decode: address range 0x0d0000-0x0d0004 */
always @(posedge clk or negedge rst)
if (!rst)
begin
    w_row_reg      <= 15'b0;
    fill_const_reg <= 16'b0;
    w_col_reg      <= 10'b0;
    w_stop_reg     <= 10'd479;
    start_write    <= 1'b0;
end
else
begin
    if (ctrl_we && ctrl_addr[23:16] == 8'h0d)
    begin
        case (ctrl_addr[3:0])
            4'd0: w_row_reg      <= ctrl_data[14:0];
            4'd1: fill_const_reg <= ctrl_data[15:0];
            4'd2: w_col_reg      <= ctrl_data[9:0];
            4'd3: w_stop_reg     <= ctrl_data[9:0];
            4'd4: start_write    <= ~start_write;
        endcase
    end
end

always @(posedge clk or negedge rst)
if (!rst)
begin
    start_init    <= 1'b0;
    start_read    <= 1'b0;
    r_row_reg     <= 15'b0;
    init_sent     <= 1'b0;
    prev_col      <= 11'b0;
    row_triggered <= 1'b0;
end
else
begin
    prev_col <= col;

    /* Issue SDRAM init toggle once after reset */
    if (!init_sent)
    begin
        start_init <= ~start_init;
        init_sent  <= 1'b1;
    end

    /* Rising edge col=0→1: prefetch (row+1) into buf_fill */
    if (col == 11'd1 && prev_col == 11'd0 && !row_triggered)
    begin
        r_row_reg     <= (row == V_LAST[10:0]) ? 15'b0
                                               : {4'b0, row[10:0]} + 15'd1;
        start_read    <= ~start_read;
        row_triggered <= 1'b1;
    end

    /* Clear flag on col wrap (start of new row) */
    if (col == 11'd0 && prev_col != 11'd0)
        row_triggered <= 1'b0;
end

endmodule
