/*
 * fb_psram.v — PSRAM-backed framebuffer with scanline write-buffer and
 *              LCD scan-out prefetch, for the riscv-darkrv labyrinth SoC.
 *
 *  Memory map (CPU side, all within the FB region 0x00100000-0x001FFFFF):
 *      0x00100000..0x001003BE      FB_BUF[col]   — write pixel(col) to
 *                                                  scanline buffer (480 cols
 *                                                  × 16bpp halfwords; SH)
 *      0x00101000                  GPU_ROW       — target row 0..271
 *      0x00101004                  GPU_CMD       — 1=FLUSH (others reserved)
 *      0x00101008                  GPU_STATUS    — bit0 = busy
 *
 *  PSRAM layout (8 MB chip):
 *      offset = row * 960 + col*2.  Frame fits in 261 120 B from offset 0.
 *
 *  Internal buffers (each 480 × 16-bit BRAM, ≈1 KB):
 *      cpu_buf — CPU writes pixels here; FLUSH bursts it to PSRAM.
 *      lcd_buf — LCD pulls pixels from here; refilled by the PSRAM FSM
 *                whenever lcd_row ticks to the next active line.
 *
 *  Arbitration: one PSRAM-side FSM serializes LCD prefetch vs CPU FLUSH.
 *  LCD prefetch wins when there's a pending row change.
 *
 *  ── Bandwidth caveat ──────────────────────────────────────────────────
 *  peripheral/psram.v is single-word, ~22 cycles per 32-bit read.  A 480-
 *  pixel scanline = 240 words × 22 = 5280 cycles, while one scanline of
 *  display at sysclk = 19 MHz is only ~550 cycles.  Real-HW display will
 *  be glitchy until one of:
 *      a)  burst-read extension to psram.v   (≈10× speedup)
 *      b)  PLL'd PSRAM clock                  (≈4× speedup)
 *      c)  divided-down LCD pixel clock      (≈10× lower pixel rate)
 *  The Verilog architecture stays the same once that's added.
 */
`default_nettype none

module fb_psram (
    input  wire        clk,
    input  wire        rst,                 // active-low

    /* CPU-bus side (simple-bus interface like psram_ram.v) */
    input  wire [23:0] addr,                // byte address within FB region
    input  wire        rd,
    input  wire        wr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrobe,
    output reg  [31:0] rdata,
    output wire        ack,

    /* LCD scan-out port */
    input  wire [10:0] lcd_row,
    input  wire [10:0] lcd_col,
    input  wire        lcd_de,
    output reg  [15:0] lcd_pixel,

    /* PSRAM chip pins */
    output wire        psram_sclk,
    output wire        psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3
);

    localparam SCREEN_W       = 480;
    localparam SCREEN_H       = 272;
    localparam WORDS_PER_LINE = SCREEN_W / 2;   // 240 32-bit PSRAM words

    /* row * 960 = (row<<10) - (row<<6) — keeps things shift-only.
       Result fits in 24 bits for row <= 271 (max 260 160 = 0x3F840). */
    function [23:0] scanline_byte_offset;
        input [10:0] row;
        begin
            scanline_byte_offset = ({13'b0, row} << 10) - ({13'b0, row} << 6);
        end
    endfunction

    /* ── MMIO address decode (within the FB region) ───────────────────── */
    wire is_fb_buf  = (addr[23:12] == 12'h100);   // 0x100xxx
    wire is_ctrl    = (addr[23:12] == 12'h101);   // 0x101xxx
    wire ctrl_row   = is_ctrl && (addr[11:2] == 10'h000);
    wire ctrl_cmd   = is_ctrl && (addr[11:2] == 10'h001);
    wire ctrl_stat  = is_ctrl && (addr[11:2] == 10'h002);
    wire [8:0] fb_buf_col = addr[9:1];

    /* ── PSRAM FSM state (forward-declared so other always blocks can
            reference it without create-before-use complaints) ─────────── */
    reg [3:0]  psram_state;
    localparam ST_IDLE      = 4'd0;
    localparam ST_LCD_START = 4'd1;
    localparam ST_LCD_REQ   = 4'd2;
    localparam ST_LCD_WAIT  = 4'd3;
    localparam ST_CPU_RD    = 4'd4;
    localparam ST_CPU_START = 4'd5;
    localparam ST_CPU_REQ   = 4'd6;
    localparam ST_CPU_WAIT  = 4'd7;
    localparam ST_DONE      = 4'd8;

    /* ── CPU-side scanline buffer (dual-port BRAM, write port from CPU,
            read port from PSRAM FSM during FLUSH) ────────────────────── */
    reg  [15:0] cpu_buf [0:SCREEN_W-1];
    reg         cpu_buf_we;
    reg  [8:0]  cpu_buf_wr_addr;
    reg  [15:0] cpu_buf_wr_data;
    reg  [8:0]  cpu_buf_rd_addr;
    reg  [15:0] cpu_buf_rd_data;
    always @(posedge clk) begin
        if (cpu_buf_we) cpu_buf[cpu_buf_wr_addr] <= cpu_buf_wr_data;
        cpu_buf_rd_data <= cpu_buf[cpu_buf_rd_addr];
    end

    /* ── LCD-side scanline buffer (write port from PSRAM FSM, read port
            from LCD scan-out logic) ─────────────────────────────────── */
    reg  [15:0] lcd_buf [0:SCREEN_W-1];
    reg         lcd_buf_we;
    reg  [8:0]  lcd_buf_wr_addr;
    reg  [15:0] lcd_buf_wr_data;
    reg  [8:0]  lcd_buf_rd_addr;
    reg  [15:0] lcd_buf_rd_data;
    always @(posedge clk) begin
        if (lcd_buf_we) lcd_buf[lcd_buf_wr_addr] <= lcd_buf_wr_data;
        lcd_buf_rd_data <= lcd_buf[lcd_buf_rd_addr];
    end

    /* ── GPU control regs + flush bookkeeping ────────────────────────── */
    reg [10:0] gpu_row;
    reg        flush_request;
    reg        busy_lat;

    /* ── LCD prefetch trigger: kick off whenever lcd_row advances ────── */
    reg [10:0] lcd_row_prev;
    wire       lcd_new_row = (lcd_row != lcd_row_prev) && (lcd_row < SCREEN_H);
    reg        lcd_prefetch_request;
    reg [10:0] lcd_prefetch_row;
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            lcd_row_prev         <= 11'd0;
            lcd_prefetch_request <= 1'b0;
            lcd_prefetch_row     <= 11'd0;
        end else begin
            lcd_row_prev <= lcd_row;
            if (lcd_new_row) begin
                lcd_prefetch_request <= 1'b1;
                lcd_prefetch_row     <= lcd_row;
            end else if (psram_state == ST_LCD_START) begin
                lcd_prefetch_request <= 1'b0;
            end
        end
    end

    /* ── PSRAM controller ─────────────────────────────────────────────── */
    reg        ps_rd_pulse;
    reg        ps_wr_pulse;
    reg [23:0] ps_addr;
    reg [31:0] ps_wdata;
    wire       ps_rdy;
    wire       ps_busy;
    wire [31:0] ps_rdata;

    psram u_psram (
        .clk        (clk),
        .rst        (rst),
        .cmd_addr   (ps_addr),
        .cmd_rd     (ps_rd_pulse),
        .cmd_wr     (ps_wr_pulse),
        .cmd_wdata  (ps_wdata),
        .rdata      (ps_rdata),
        .rdy        (ps_rdy),
        .busy       (ps_busy),
        .psram_sclk (psram_sclk),
        .psram_ce_n (psram_ce_n),
        .psram_sio0 (psram_sio0),
        .psram_sio1 (psram_sio1),
        .psram_sio2 (psram_sio2),
        .psram_sio3 (psram_sio3)
    );

    /* ── PSRAM-side FSM ───────────────────────────────────────────────── */
    reg [7:0]  word_idx;
    reg [23:0] base_addr;
    reg        saw_busy;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            psram_state     <= ST_IDLE;
            ps_rd_pulse     <= 1'b0;
            ps_wr_pulse     <= 1'b0;
            ps_addr         <= 24'b0;
            ps_wdata        <= 32'b0;
            word_idx        <= 8'b0;
            base_addr       <= 24'b0;
            saw_busy        <= 1'b0;
            lcd_buf_we      <= 1'b0;
            lcd_buf_wr_addr <= 9'b0;
            lcd_buf_wr_data <= 16'b0;
            cpu_buf_rd_addr <= 9'b0;
        end else begin
            ps_rd_pulse <= 1'b0;
            ps_wr_pulse <= 1'b0;
            lcd_buf_we  <= 1'b0;

            case (psram_state)
                ST_IDLE: begin
                    if (lcd_prefetch_request) begin
                        base_addr   <= scanline_byte_offset(lcd_prefetch_row);
                        word_idx    <= 8'd0;
                        saw_busy    <= 1'b0;
                        psram_state <= ST_LCD_START;
                    end else if (flush_request) begin
                        base_addr       <= scanline_byte_offset(gpu_row);
                        word_idx        <= 8'd0;
                        saw_busy        <= 1'b0;
                        cpu_buf_rd_addr <= 9'd0;
                        psram_state     <= ST_CPU_RD;
                    end
                end

                /* ── LCD prefetch: 240 × 32-bit reads ──────────────── */
                ST_LCD_START: begin
                    ps_addr     <= base_addr + ({16'b0, word_idx} << 2);
                    ps_rd_pulse <= 1'b1;
                    saw_busy    <= 1'b0;
                    psram_state <= ST_LCD_WAIT;
                end

                ST_LCD_WAIT: begin
                    if (!ps_rdy) saw_busy <= 1'b1;
                    if (saw_busy && ps_rdy) begin
                        lcd_buf_we      <= 1'b1;
                        lcd_buf_wr_addr <= {word_idx[6:0], 1'b0};
                        lcd_buf_wr_data <= ps_rdata[15:0];
                        psram_state     <= ST_LCD_REQ;
                    end
                end

                ST_LCD_REQ: begin
                    lcd_buf_we      <= 1'b1;
                    lcd_buf_wr_addr <= {word_idx[6:0], 1'b1};
                    lcd_buf_wr_data <= ps_rdata[31:16];
                    if (word_idx == WORDS_PER_LINE - 1) begin
                        psram_state <= ST_IDLE;
                    end else begin
                        word_idx    <= word_idx + 8'd1;
                        psram_state <= ST_LCD_START;
                    end
                end

                /* ── CPU FLUSH: 240 × 32-bit writes ────────────────── */
                ST_CPU_RD: begin
                    cpu_buf_rd_addr <= {word_idx[6:0], 1'b0};
                    psram_state     <= ST_CPU_START;
                end

                ST_CPU_START: begin
                    ps_wdata[15:0]  <= cpu_buf_rd_data;
                    cpu_buf_rd_addr <= {word_idx[6:0], 1'b1};
                    psram_state     <= ST_CPU_REQ;
                end

                ST_CPU_REQ: begin
                    ps_wdata[31:16] <= cpu_buf_rd_data;
                    ps_addr         <= base_addr + ({16'b0, word_idx} << 2);
                    ps_wr_pulse     <= 1'b1;
                    saw_busy        <= 1'b0;
                    psram_state     <= ST_CPU_WAIT;
                end

                ST_CPU_WAIT: begin
                    if (!ps_rdy) saw_busy <= 1'b1;
                    if (saw_busy && ps_rdy) begin
                        if (word_idx == WORDS_PER_LINE - 1) begin
                            psram_state <= ST_DONE;
                        end else begin
                            word_idx    <= word_idx + 8'd1;
                            psram_state <= ST_CPU_RD;
                        end
                    end
                end

                ST_DONE: psram_state <= ST_IDLE;

                default: psram_state <= ST_IDLE;
            endcase
        end
    end

    /* ── flush_request / gpu_row / busy_lat ────────────────────────────── */
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            gpu_row       <= 11'd0;
            flush_request <= 1'b0;
            busy_lat      <= 1'b0;
        end else begin
            if (wr && ctrl_row && wstrobe == 4'b1111)
                gpu_row <= wdata[10:0];
            if (wr && ctrl_cmd && wstrobe == 4'b1111 && wdata[1:0] == 2'b01) begin
                flush_request <= 1'b1;
                busy_lat      <= 1'b1;
            end
            if (psram_state == ST_CPU_RD) flush_request <= 1'b0;
            if (psram_state == ST_DONE)   busy_lat      <= 1'b0;
        end
    end

    /* ── CPU-bus: 2-state FSM (IDLE / SETTLE) mirroring psram_ram.v's
            pattern so level-held rd/wr only fires once per transaction. */
    reg cpu_state;       // 0=IDLE, 1=SETTLE
    reg cpu_ack_pulse;
    assign ack = cpu_ack_pulse;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            cpu_state       <= 1'b0;
            cpu_ack_pulse   <= 1'b0;
            rdata           <= 32'b0;
            cpu_buf_we      <= 1'b0;
            cpu_buf_wr_addr <= 9'b0;
            cpu_buf_wr_data <= 16'b0;
        end else begin
            cpu_ack_pulse <= 1'b0;
            cpu_buf_we    <= 1'b0;

            case (cpu_state)
                1'b0: if (rd || wr) begin
                    if (wr && is_fb_buf) begin
                        cpu_buf_we      <= 1'b1;
                        cpu_buf_wr_addr <= fb_buf_col;
                        if (wstrobe[1:0] == 2'b11)
                            cpu_buf_wr_data <= wdata[15: 0];
                        else if (wstrobe[3:2] == 2'b11)
                            cpu_buf_wr_data <= wdata[31:16];
                        else
                            cpu_buf_wr_data <= wdata[15: 0];
                    end

                    if (rd && ctrl_stat)
                        rdata <= {31'b0, busy_lat};
                    else
                        rdata <= 32'b0;

                    cpu_ack_pulse <= 1'b1;
                    cpu_state     <= 1'b1;
                end

                1'b1: cpu_state <= 1'b0;
            endcase
        end
    end

    /* ── LCD pixel output ──────────────────────────────────────────────── */
    always @(posedge clk) lcd_buf_rd_addr <= lcd_col[8:0];

    always @(posedge clk or negedge rst) begin
        if (!rst) lcd_pixel <= 16'h0000;
        else if (lcd_de) lcd_pixel <= lcd_buf_rd_data;
        else             lcd_pixel <= 16'h0000;
    end

endmodule

`default_nettype wire
