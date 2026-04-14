/*
 * soc.v — ZX Spectrum 48K System-on-Chip
 *
 * Memory map:
 *   $0000-$3FFF   16 KB ROM (Spectrum BASIC)
 *   $4000-$57FF   6144 bytes screen bitmap
 *   $5800-$5AFF   768 bytes colour attributes
 *   $5B00-$FFFF   RAM (general purpose)
 *
 * I/O: Port $FE (any even port)
 *   Write: border [2:0], MIC [3], speaker [4]
 *   Read:  keyboard [4:0], selected by A15-A8
 */

`include "project.vh"

module soc(
    input        clk,
    input        rst,

    input        rx,
    output       tx,

    output reg [15:0] lcd_data,
    output        lcd_de,
    output        lcd_vsync,
    output        lcd_hsync
);

/* ── Game NMI signal (directly before CPU for forward declaration) ──── */
`ifdef GAME_SNA
reg game_nmi_active;
wire game_nmi_n = ~game_nmi_active;
`else
wire game_nmi_n = 1'b1;
`endif

/* ── Z80 CPU (TV80) ───────────────────────────────────────────────────── */
/* TV80s runs at full system clock speed. For simulation this is fine;
 * for real FPGA, add a clock divider or use wait_n throttling. */
wire [15:0] cpu_addr;
wire  [7:0] cpu_data_out;
reg   [7:0] cpu_data_in;
wire        cpu_mreq_n, cpu_iorq_n, cpu_rd_n, cpu_wr_n;
wire        cpu_m1_n, cpu_rfsh_n;

tv80s cpu(
    .clk    (clk),
    .reset_n(rst),
    .wait_n (1'b1),
    .int_n  (cpu_int_n),
    .nmi_n  (game_nmi_n),
    .busrq_n(1'b1),
    .m1_n   (cpu_m1_n),
    .mreq_n (cpu_mreq_n),
    .iorq_n (cpu_iorq_n),
    .rd_n   (cpu_rd_n),
    .wr_n   (cpu_wr_n),
    .rfsh_n (cpu_rfsh_n),
    .halt_n (),
    .busak_n(),
    .A      (cpu_addr),
    .di     (cpu_data_in),
    .dout   (cpu_data_out)
);

/* ── ROM (16 KB) ───────────────────────────────────────────────────────── */
reg [7:0] rom [0:16383];
initial $readmemh("../roms/rom.hex", rom);

wire [7:0] rom_data = rom[cpu_addr[13:0]];

/* ── RAM (48 KB at $4000-$FFFF) ────────────────────────────────────────── */
reg [7:0] ram [0:49151];

integer init_i;
initial begin
    for (init_i = 0; init_i < 49152; init_i = init_i + 1)
        ram[init_i] = 8'h00;
    for (init_i = 16'h1800; init_i < 16'h1B00; init_i = init_i + 1)
        ram[init_i] = 8'h38;
end

wire [15:0] ram_offset = cpu_addr - 16'h4000;
wire [7:0]  ram_data   = ram[ram_offset];

`ifdef GAME_SNA
/* ── Game loader: shadow ROM + post-boot bulk copy ─────────────────────── */
/* Game data stored in shadow array. After ROM boot completes (S_POSN set),
 * the game is bulk-copied into RAM at hardware speed, then the CPU is
 * redirected to the game's entry point via a trampoline at $FF00. */
`include "../roms/game_params.vh"

reg [7:0] game_shadow [0:49151];
initial $readmemh("../roms/game.hex", game_shadow);

reg [2:0]  game_state;     // 0=wait_boot, 1=copying, 2=trampoline, 3=nmi, 4=done
reg [15:0] game_copy_addr;
reg [15:0] game_nmi_cnt;
wire [15:0] s_posn_val = {ram[16'h1C89], ram[16'h1C88]};

always @(posedge clk) begin
    if (!rst) begin
        game_state      <= 0;
        game_copy_addr  <= 0;
        game_nmi_active <= 0;
        game_nmi_cnt    <= 0;
    end else begin
        case (game_state)
            0: begin
                /* Normal CPU writes during boot */
                if (!cpu_mreq_n && !cpu_wr_n && cpu_addr >= 16'h4000)
                    ram[ram_offset] <= cpu_data_out;
                /* Wait for ROM boot to complete */
                if (s_posn_val == 16'h1821) begin
                    game_state     <= 1;
                    game_copy_addr <= 0;
                end
            end
            1: begin
                /* Bulk copy: 1 byte per clock, full 48K */
                ram[game_copy_addr] <= game_shadow[game_copy_addr];
                game_copy_addr <= game_copy_addr + 1;
                if (game_copy_addr == 16'hBFFF)
                    game_state <= 2;
            end
            2: begin
                /* Write trampoline at $FF00 and set NMIADD to point to it. */
                ram[16'hBF00] <= 8'hF3;          // $FF00: DI
                ram[16'hBF01] <= 8'hC3;          // $FF01: JP GAME_PC
                ram[16'hBF02] <= GAME_PC[7:0];   // $FF02: lo
                ram[16'hBF03] <= GAME_PC[15:8];  // $FF03: hi
                /* NMIADD at $5CB0 = RAM offset $1CB0 → point to $FF00 */
                ram[16'h1CB0] <= 8'h00;          // NMIADD lo = $00
                ram[16'h1CB1] <= 8'hFF;          // NMIADD hi = $FF
                game_state <= 3;
            end
            3: begin
                /* Trigger NMI pulse */
                game_nmi_active <= 1;
                game_nmi_cnt <= game_nmi_cnt + 1;
                if (game_nmi_cnt > 100) begin
                    game_nmi_active <= 0;
                    game_state <= 4;
                end
            end
            default: begin
                /* Game running — normal CPU writes */
                if (!cpu_mreq_n && !cpu_wr_n && cpu_addr >= 16'h4000)
                    ram[ram_offset] <= cpu_data_out;
            end
        endcase
    end
end
`else
always @(posedge clk) begin
    if (rst && !cpu_mreq_n && !cpu_wr_n && cpu_addr >= 16'h4000)
        ram[ram_offset] <= cpu_data_out;
end
`endif

/* ── LCD timing generator ──────────────────────────────────────────────── */
wire [10:0] lcd_col, lcd_row;

lcd_out lcd0(
    .clk(clk), .rst(rst),
    .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
    .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
    .row(lcd_row), .col(lcd_col)
);

/* ── Video generation ──────────────────────────────────────────────────── */
/* 256x192 Spectrum display centred in 480x272 LCD
 * Border: (480-256)/2 = 112 pixels each side, (272-192)/2 = 40 top/bottom
 *
 * Pipeline: addresses are calculated 1 clock ahead so that when we need
 * the pixel data at column N, the registered RAM output already has it.
 * lcd_col runs freely; we compute addresses from (lcd_col+1) and latch
 * bitmap/attr into registers. On the next clock, the registers hold the
 * data for the current pixel. */

localparam BORDER_H = 112;
localparam BORDER_V = 40;
localparam DISPLAY_W = 256;
localparam DISPLAY_H = 192;

/* Current pixel position (for output) */
wire in_display = (lcd_col >= BORDER_H) && (lcd_col < BORDER_H + DISPLAY_W) &&
                  (lcd_row >= BORDER_V) && (lcd_row < BORDER_V + DISPLAY_H);
wire [8:0] dx = lcd_col - BORDER_H;
wire [7:0] dy = lcd_row - BORDER_V;

/* Look-ahead position: 1 pixel ahead for pre-fetching */
wire [8:0] dx_next = lcd_col + 1 - BORDER_H;
wire       in_display_next = (lcd_col + 1 >= BORDER_H) && (lcd_col + 1 < BORDER_H + DISPLAY_W) &&
                             (lcd_row >= BORDER_V) && (lcd_row < BORDER_V + DISPLAY_H);

/* Spectrum bitmap address from look-ahead x, current y */
wire [12:0] bitmap_addr_next = {dy[7:6], dy[2:0], dy[5:3], dx_next[7:3]};
wire [12:0] attr_addr_next   = {3'b110, dy[7:3], dx_next[7:3]};

/* Video RAM read — pre-fetch at character boundaries (every 8 pixels) */
reg [7:0] vid_bitmap;
reg [7:0] vid_attr;

always @(posedge clk) begin
    /* Latch bitmap and attr at the start of each character (dx_next[2:0]==0).
     * The look-ahead means data is ready when we enter that character. */
    if (in_display_next && dx_next[2:0] == 3'd0) begin
        vid_bitmap <= ram[bitmap_addr_next];
        vid_attr   <= ram[attr_addr_next];
    end
end

/* Colour palette — combinational lookup */
reg [2:0] border_color = 3'b111;

reg [15:0] pal_out;
always @(*) begin
    case (pal_idx)
        4'h0: pal_out = 16'h0000;
        4'h1: pal_out = 16'h001A;
        4'h2: pal_out = 16'hD000;
        4'h3: pal_out = 16'hD01A;
        4'h4: pal_out = 16'h06A0;
        4'h5: pal_out = 16'h06BA;
        4'h6: pal_out = 16'hD6A0;
        4'h7: pal_out = 16'hD6BA;
        4'h8: pal_out = 16'h0000;
        4'h9: pal_out = 16'h001F;
        4'hA: pal_out = 16'hF800;
        4'hB: pal_out = 16'hF81F;
        4'hC: pal_out = 16'h07E0;
        4'hD: pal_out = 16'h07FF;
        4'hE: pal_out = 16'hFFE0;
        4'hF: pal_out = 16'hFFFF;
    endcase
end

/* Flash: toggle every 16 frames */
reg [4:0] flash_cnt;
wire flash_state = flash_cnt[4];

always @(posedge clk) begin
    if (!rst)
        flash_cnt <= 0;
    else if (lcd_row == 0 && lcd_col == 0)
        flash_cnt <= flash_cnt + 1;
end

/* Pixel colour computation */
wire [3:0] ink_idx   = {vid_attr[6], vid_attr[2:0]};
wire [3:0] paper_idx = {vid_attr[6], vid_attr[5:3]};
wire       pixel_bit = vid_bitmap[7 - dx[2:0]];
wire       flash_inv = vid_attr[7] & flash_state;
wire       use_ink   = pixel_bit ^ flash_inv;

/* Select palette index based on display position */
wire [3:0] border_idx = {1'b0, border_color};
wire [3:0] display_idx = use_ink ? ink_idx : paper_idx;
wire [3:0] pal_idx = in_display ? display_idx : border_idx;

always @(posedge clk) begin
    if (!rst)
        lcd_data <= 16'h0000;
    else if (lcd_de)
        lcd_data <= pal_out;
end

/* ── Keyboard ──────────────────────────────────────────────────────────── */
wire [7:0] uart_rx_data;
wire       uart_rx_valid;
wire [4:0] key_data;

spectrum_keyboard keyboard(
    .clk          (clk),
    .rst          (rst),
    .uart_rx_data (uart_rx_data),
    .uart_rx_valid(uart_rx_valid),
    .halfrow_sel  (cpu_addr[15:8]),
    .key_columns  (key_data)
);

/* ── UART ──────────────────────────────────────────────────────────────── */
uart uart_inst(
    .clk    (clk),
    .rst    (rst),
    .rx     (rx),
    .tx     (tx),
    .rxdata (uart_rx_data),
    .rxen   (uart_rx_valid),
    .txdata (8'h00),
    .txen   (1'b0),
    .txbusy ()
);

/* ── Port $FE ──────────────────────────────────────────────────────────── */
/* I/O access is valid when IORQ=0, M1=1 (not interrupt ack), and RD or WR active */
wire io_fe = !cpu_iorq_n && cpu_m1_n && !cpu_addr[0];

always @(posedge clk) begin
    if (!rst)
        border_color <= 3'b111;
    else if (io_fe && !cpu_wr_n)
        border_color <= cpu_data_out[2:0];
end

/* ── CPU data bus mux ──────────────────────────────────────────────────── */
always @(*) begin
    cpu_data_in = 8'hFF;
    if (!cpu_mreq_n && !cpu_rd_n) begin
        if (cpu_addr[15:14] == 2'b00)
            cpu_data_in = rom_data;
        else
            cpu_data_in = ram_data;
    end else if (!cpu_iorq_n && cpu_m1_n && !cpu_rd_n && !cpu_addr[0]) begin
        cpu_data_in = {3'b111, key_data};
    end
end

/* ── Interrupt: frame sync from lcd_out vsync ──────────────────────────── */
reg prev_vsync;
reg int_active;
wire cpu_int_n = ~int_active;

/* INT acknowledge: Z80 signals IORQ=0 + M1=0 during interrupt acknowledge cycle */
wire int_ack = !cpu_iorq_n && !cpu_m1_n;

always @(posedge clk) begin
    if (!rst) begin
        int_active <= 0;
        prev_vsync <= 1;
    end else begin
        prev_vsync <= lcd_vsync;

        /* Trigger INT on vsync falling edge */
        if (prev_vsync && !lcd_vsync)
            int_active <= 1;

        /* Release INT when CPU acknowledges it */
        if (int_ack)
            int_active <= 0;
    end
end

/* ── Debug: cursor tracking ─────────────────────────────────────────────── */
/* S_POSN at $5C88: col (33-col), $5C89: line (24-line)
 * After boot: should be something like (33,2) for the input line */
/* Debug: check both screen RAM and system variables */
endmodule
