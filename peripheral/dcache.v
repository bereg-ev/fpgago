`include "project.vh"

/*
 * dcache.v — Memory-mapped framebuffer with write-combining cache
 *
 * Replaces gpu3d.v.  The CPU writes pixels directly to a scanline write
 * buffer (BRAM), sets the target row, and issues a FLUSH command.  The
 * dcache burst-writes the dirty portion of the buffer to Y SDRAM.
 *
 * Double-buffered framebuffer layout (same as gpu3d.v):
 *   Frame A: Y SDRAM rows   0..271   (front when front_buf=0)
 *   Frame B: Y SDRAM rows 512..783   (front when front_buf=1)
 *
 * Address map:
 *   0x200000 + col*4   Write pixel (RGB565 in lower 16 bits) to buffer
 *                      col = ctrl_addr[10:2] (word-addressed, 0-479)
 *   0x0A0000  (reg 0)  ROW — target back-buffer row for FLUSH (0-271)
 *   0x0A001C  (reg 7)  CLEAR_COLOR — RGB565 fill color for CLEAR_FB
 *   0x0A0020  (reg 8)  CMD — 1=FLUSH, 2=CLEAR_FB, 3=SWAP_BUFFERS
 *   0x0A0024  (reg 9)  STATUS — bit 0 = busy (read-only)
 *
 * Notes:
 *   - FLUSH writes only the dirty column range (dirty_first..dirty_last).
 *   - Chunked writes: max 64 pixels per SDRAM burst so LCD reads interleave.
 *   - CLEAR_FB and SWAP_BUFFERS use the same command values as gpu3d.v,
 *     so character-LCD games (tic-tac-toe, char-gomoku) need no changes.
 *   - The write buffer is NOT cleared between flushes; the CPU must write
 *     every pixel it intends to flush.
 */

module dcache(
    input  wire        clk,
    input  wire        rst,

    /* Display scan position from lcd_out */
    input  wire [10:0] row,
    input  wire [10:0] col,

    /* RGB565 pixel output to soc.v */
    output wire [15:0] sdram_pixel_out,

    /* CPU interface (active for ALL data_wr — dcache decodes internally) */
    input  wire [23:0] ctrl_addr,
    input  wire [15:0] ctrl_data,
    input  wire        ctrl_we,
    output wire        gpu_busy,

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

// ── Display timing (must match lcd_out.v) ─────────────────────────────────────
localparam V_TOTAL = 290;

// ── State machine encoding ────────────────────────────────────────────────────
localparam S_IDLE        = 3'd0;
localparam S_FLUSH_WAIT  = 3'd1;   // wait for SDRAM ready, set up chunk
localparam S_FLUSH_KICK  = 3'd2;   // toggle start_write
localparam S_FLUSH_DONE  = 3'd3;   // wait for chunk completion
localparam S_CLEAR_WAIT  = 3'd4;   // CLEAR: wait for SDRAM slot
localparam S_CLEAR_KICK  = 3'd5;   // CLEAR: trigger row fill
localparam S_CLEAR_NEXT  = 3'd6;   // CLEAR: next row or done

// ── Address decode ────────────────────────────────────────────────────────────
wire buf_sel  = ctrl_we && (ctrl_addr[23:20] == 4'h2);     // 0x200000-0x2FFFFF
wire mmio_sel = ctrl_we && (ctrl_addr[23:8] == 16'h0A00);  // 0x0A0000-0x0A00FF
wire [3:0] reg_idx = ctrl_addr[5:2];
wire [8:0] buf_col = ctrl_addr[10:2];   // word-addressed column index

// ── Control registers ─────────────────────────────────────────────────────────
reg [8:0]  row_reg;         // target SDRAM row for FLUSH
reg [15:0] clear_color;     // fill color for CLEAR_FB
reg        front_buf;       // 0 = display frame A, 1 = display frame B

// ── Dirty tracking ───────────────────────────────────────────────────────────
reg [8:0]  dirty_first;     // leftmost dirty column  (reset to 9'h1FF)
reg [8:0]  dirty_last;      // rightmost dirty column (reset to 9'h000)
wire       dirty = (dirty_first <= dirty_last);

// ── SDRAM write control registers ────────────────────────────────────────────
reg        fill_en_r;
reg [15:0] fill_const_r;
reg [14:0] w_row_r;
reg [9:0]  w_col_r, w_stop_r;
reg        start_write;

// ── Write chunking (max 64 px per burst so LCD reads can interleave) ─────────
localparam [9:0] CHUNK_MAX = 10'd63;
reg [9:0]  chunk_col;       // current chunk starting column

// ── CLEAR_FB loop counter ────────────────────────────────────────────────────
reg [8:0]  clear_row;

// ── State register ───────────────────────────────────────────────────────────
reg [2:0]  state;

// ── LCD prefetch state (from gpu3d.v / lcd_sdram.v) ──────────────────────────
reg [14:0] r_row_reg;
reg        start_read, start_init;
reg        init_sent;
reg [10:0] prev_col;
reg        row_triggered;

// ── SDRAM controller wires ───────────────────────────────────────────────────
wire [15:0] bram_di;
wire        bram_we;
wire [9:0]  bram_r_addr;
wire [9:0]  w_addr_out;
wire        rdy;
wire        write_pending;

// ── Write buffer BRAM (512 × 16-bit, using lower half of ram_1k_18) ─────────
// Port A: CPU writes pixels at column index
// Port B: SDRAM reads pixel data during FLUSH burst
wire [17:0] wbuf_dout_b;

ram_1k_18 wbuf(
    .clk_a(clk), .we_a(buf_sel),
    .addr_a({1'b0, buf_col}), .din_a({2'b0, ctrl_data}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b(w_addr_out), .din_b(18'b0), .dout_b(wbuf_dout_b)
);

// ── LCD line-buffer ping-pong BRAM (from gpu3d.v, unchanged) ─────────────────
wire buf_disp  = row[0];
wire buf_fill  = ~row[0];
wire [9:0] bram_addr_a = {buf_fill, bram_r_addr[8:0]};
wire [9:0] bram_addr_b = {buf_disp, col[8:0]};
wire [17:0] linebuf_dout_b;

ram_1k_18 linebuf(
    .clk_a(clk), .we_a(bram_we),
    .addr_a(bram_addr_a), .din_a({2'b0, bram_di}), .dout_a(),
    .clk_b(clk), .we_b(1'b0),
    .addr_b(bram_addr_b), .din_b(18'b0), .dout_b(linebuf_dout_b)
);

assign sdram_pixel_out = linebuf_dout_b[15:0];

// ── SDRAM controller instance ────────────────────────────────────────────────
sdram sdram_y(
    .clk(clk),              .rst(rst),
    .r_row(r_row_reg),      .w_row(w_row_r),
    .bram_di(bram_di),      .bram_do(wbuf_dout_b[15:0]),   .bram_we(bram_we),
    .start_read(start_read), .start_write(start_write),      .start_init(start_init),
    .rdy(rdy),
    .w_addr(w_addr_out),    .r_addr(bram_r_addr),
    .w_stop(w_stop_r),      .w_col(w_col_r),
    .w_addr_start(chunk_col),
    .r_col(10'b0),          .r_stop(10'd479),
    .fill_en(fill_en_r),    .fill_const(fill_const_r),
    .sd_cke(sd_cke),        .sd_cs(sd_cs),
    .sd_ras(sd_ras),        .sd_cas(sd_cas),                .sd_we(sd_we),
    .sd_a(sd_a),            .sd_d(sd_d),                    .sd_ba(sd_ba),
    .sd_ldqm(sd_ldqm),      .sd_udqm(sd_udqm),
    .dbg(), .write_pending(write_pending)
);

assign gpu_busy = (state != S_IDLE);

// ── MMIO register writes ─────────────────────────────────────────────────────
always @(posedge clk or negedge rst)
if (!rst) begin
    row_reg <= 0;
    clear_color <= 0;
end else if (mmio_sel) begin
    case (reg_idx)
        4'd0: row_reg     <= ctrl_data[8:0];
        4'd7: clear_color <= ctrl_data;
        default: ;
    endcase
end

// ── Dirty tracking update ────────────────────────────────────────────────────
// Updated on every CPU write to the buffer.  Reset after FLUSH completes.
always @(posedge clk or negedge rst)
if (!rst) begin
    dirty_first <= 9'h1FF;
    dirty_last  <= 9'h000;
end else begin
    if (buf_sel) begin
        if (buf_col < dirty_first) dirty_first <= buf_col;
        if (buf_col > dirty_last)  dirty_last  <= buf_col;
    end
    // Reset after flush completes (see state machine below, flush_reset_dirty)
    if (flush_reset_dirty) begin
        dirty_first <= 9'h1FF;
        dirty_last  <= 9'h000;
    end
end

reg flush_reset_dirty;

// ── LCD prefetch controller (from gpu3d.v, verbatim) ─────────────────────────
always @(posedge clk or negedge rst)
if (!rst) begin
    start_init<=0; start_read<=0; r_row_reg<=0;
    init_sent<=0; prev_col<=0; row_triggered<=0;
end else begin
    prev_col <= col;

    if (!init_sent) begin
        start_init <= ~start_init;
        init_sent  <= 1'b1;
    end

    if (col==11'd1 && prev_col==11'd0 && !row_triggered) begin
        r_row_reg     <= (row == (V_TOTAL-1)) ?
            {5'b0, front_buf, 9'b0} :
            ({5'b0, front_buf, row[8:0]} + 15'd1);
        start_read    <= ~start_read;
        row_triggered <= 1'b1;
    end

    if (col==11'd0 && prev_col!=11'd0)
        row_triggered <= 1'b0;
end

// ── Main state machine ───────────────────────────────────────────────────────
always @(posedge clk or negedge rst)
if (!rst) begin
    state <= S_IDLE;
    front_buf <= 0;
    fill_en_r <= 1; fill_const_r <= 0; start_write <= 0;
    w_row_r <= 0; w_col_r <= 0; w_stop_r <= 479;
    clear_row <= 0; chunk_col <= 0;
    flush_reset_dirty <= 0;
end else begin
    flush_reset_dirty <= 0;   // default: one-shot pulse

    case (state)

    // ── Idle: accept CMD writes ─────────────────────────────────────────────
    S_IDLE: begin
        if (mmio_sel && reg_idx == 4'd8) begin
            case (ctrl_data[1:0])
                2'd1: begin  // FLUSH
                    if (dirty) begin
                        chunk_col <= {1'b0, dirty_first};
                        state     <= S_FLUSH_WAIT;
                    end
                    // else: nothing to flush, stay idle
                end
                2'd2: begin  // CLEAR_FB
                    clear_row    <= 9'd0;
                    chunk_col    <= 10'd0;
                    fill_const_r <= clear_color;
                    state        <= S_CLEAR_WAIT;
                end
                2'd3: front_buf <= ~front_buf;  // SWAP_BUFFERS (one cycle)
                default: ;
            endcase
        end
    end

    // ── FLUSH: wait for SDRAM ready, set up chunk parameters ────────────────
    S_FLUSH_WAIT: begin
        if (!write_pending) begin
            w_row_r   <= {5'b0, ~front_buf, row_reg};
            w_col_r   <= chunk_col;
            fill_en_r <= 1'b0;   // use write buffer BRAM data
            if ({1'b0, dirty_last} - chunk_col > CHUNK_MAX) begin
                w_stop_r <= chunk_col + CHUNK_MAX;
            end else begin
                w_stop_r <= {1'b0, dirty_last};
            end
            state <= S_FLUSH_KICK;
        end
    end

    // ── FLUSH: toggle start_write to launch burst ───────────────────────────
    S_FLUSH_KICK: begin
        start_write <= ~start_write;
        state <= S_FLUSH_DONE;
    end

    // ── FLUSH: wait for chunk completion, next chunk or done ────────────────
    S_FLUSH_DONE: begin
        if (!write_pending) begin
            if (chunk_col + CHUNK_MAX >= {1'b0, dirty_last}) begin
                // All chunks done
                flush_reset_dirty <= 1'b1;
                state <= S_IDLE;
            end else begin
                // More chunks
                chunk_col <= chunk_col + CHUNK_MAX + 10'd1;
                state <= S_FLUSH_WAIT;
            end
        end
    end

    // ── CLEAR_FB: fill every row of back buffer (chunked, same as gpu3d) ────
    S_CLEAR_WAIT: begin
        if (!write_pending) begin
            w_row_r      <= {5'b0, ~front_buf, clear_row};
            w_col_r      <= chunk_col;
            fill_en_r    <= 1'b1;
            fill_const_r <= clear_color;
            if (10'd479 - chunk_col > CHUNK_MAX) begin
                w_stop_r <= CHUNK_MAX;
            end else begin
                w_stop_r <= 10'd479 - chunk_col;
            end
            state <= S_CLEAR_KICK;
        end
    end

    S_CLEAR_KICK: begin
        start_write <= ~start_write;
        state <= S_CLEAR_NEXT;
    end

    S_CLEAR_NEXT: begin
        if (!write_pending) begin
            if (chunk_col + CHUNK_MAX >= 10'd479) begin
                // Row done — next row or finish
                chunk_col <= 10'd0;
                if (clear_row == 9'd271)
                    state <= S_IDLE;
                else begin
                    clear_row <= clear_row + 1;
                    state <= S_CLEAR_WAIT;
                end
            end else begin
                chunk_col <= chunk_col + CHUNK_MAX + 10'd1;
                state <= S_CLEAR_WAIT;
            end
        end
    end

    default: state <= S_IDLE;
    endcase
end

endmodule
