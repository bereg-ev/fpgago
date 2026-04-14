/*
 * soc.v — Commodore 64 System-on-Chip (initial text-mode version)
 *
 * This is a simplified C64 SoC for initial bring-up. It uses:
 *   - 6510 CPU (6502 + I/O port) from PET core + wrapper
 *   - CIA 6526 x2 (MiSTer) for keyboard and timers
 *   - 64 KB RAM + ROMs with PLA-style banking
 *   - Character ROM for text display
 *   - Simple text-mode video (40x25 chars, no VIC-II yet)
 *
 * The full VIC-II Kawari integration requires careful clock domain
 * handling (dot clock, color clock, phi2) and will be added once
 * basic boot is verified.
 *
 * Memory map (default bank: LORAM=1, HIRAM=1, CHAREN=1):
 *   $0000-$0001  6510 I/O port (DDR, Port)
 *   $0002-$9FFF  RAM
 *   $A000-$BFFF  BASIC ROM
 *   $C000-$CFFF  RAM
 *   $D000-$D3FF  VIC-II (stub: returns $00)
 *   $D400-$D7FF  SID (stub: returns $00)
 *   $D800-$DBFF  Color RAM
 *   $DC00-$DCFF  CIA1 (keyboard, joystick)
 *   $DD00-$DDFF  CIA2 (serial, NMI)
 *   $E000-$FFFF  KERNAL ROM
 */

`include "project.vh"

module soc(
    input        clk,
    input        rst,
    input        rx,
    output       tx,
    output reg [15:0] lcd_data,
    output       lcd_de,
    output       lcd_vsync,
    output       lcd_hsync
);

/* Gate IRQs until the CPU has had time to execute SEI.
 * Count phi2 cycles (not system clocks) for proper timing. */
reg [7:0] irq_gate_cnt;
wire irq_gated = (irq_gate_cnt < 8'd200);  // ~200 CPU cycles
wire cpu_irq = irq_gated ? 1'b0 : ~cia1_irq_n;
wire cpu_nmi = irq_gated ? 1'b0 : ~cia2_irq_n;

always @(posedge clk) begin
    if (!rst) irq_gate_cnt <= 0;
    else if (irq_gated && phi2_p) irq_gate_cnt <= irq_gate_cnt + 1;
end

/* ── Clock divider: ~1 MHz CPU and CIA clock ───────────────────────────── */
/* Same approach as the PET: RDY pulses at ~1 MHz.
 * phi2_p and phi2_n are derived from the same divider. */
reg [4:0] clk_div;
reg phi2_half;  // toggles every 25 clocks: 0=phi2_n phase, 1=phi2_p phase
wire cpu_rdy = phi2_p;  // CPU advances on phi2 positive edge only

/* Latch WE and DO — the 6502 only asserts these for the RDY=1 clock.
 * The CIA needs them stable at phi2_n (25 clocks later). */
reg cpu_we_latched;
reg [7:0] cpu_do_latched;
reg [15:0] cpu_addr_latched;
always @(posedge clk) begin
    if (!rst) begin
        cpu_we_latched   <= 0;
        cpu_do_latched   <= 8'h00;
        cpu_addr_latched <= 16'h0000;
    end else if (phi2_p) begin
        cpu_we_latched   <= cpu_we;
        cpu_do_latched   <= cpu_data_out;
        cpu_addr_latched <= cpu_addr;
    end
end
wire phi2_n  = (clk_div == 0) && !phi2_half;    // negative edge FIRST: CIA register access
wire phi2_p  = (clk_div == 0) &&  phi2_half;   // positive edge SECOND: CPU advance + timer count

always @(posedge clk) begin
    if (!rst) begin
        clk_div <= 0;
        phi2_half <= 0;
    end else if (clk_div == 5'd4) begin  // 50 MHz / 5 / 2 = 5 MHz phi2
        clk_div <= 0;
        phi2_half <= ~phi2_half;
    end else begin
        clk_div <= clk_div + 1;
    end
end

/* ── 6510 CPU ──────────────────────────────────────────────────────────── */
wire [15:0] cpu_addr;
wire  [7:0] cpu_data_out;
reg   [7:0] cpu_data_in;
wire        cpu_we;
wire  [5:0] cpu_port;     // I/O port bits [5:0]
wire  [7:0] cpu_ddr;      // DDR register (for reads to $0000)
wire  [7:0] cpu_port_read; // Port register (for reads to $0001)
wire        cia1_irq_n, cia2_irq_n;

cpu_6510 cpu(
    .clk    (clk),
    .reset  (!rst),       // 6502 uses active-high reset
    .DI     (cpu_data_in),
    .DO     (cpu_data_out),
    .AB     (cpu_addr),
    .WE     (cpu_we),
    .IRQ    (cpu_irq),
    .NMI    (cpu_nmi),
    .RDY    (cpu_rdy),
    .port_out(cpu_port),
    .port_ddr_out(cpu_ddr),
    .port_read_out(cpu_port_read)
);

/* ── Memory banking (PLA simplified) ──────────────────────────────────── */
wire loram  = cpu_port[0];   // 1 = BASIC ROM visible at $A000
wire hiram  = cpu_port[1];   // 1 = KERNAL ROM visible at $E000
wire charen = cpu_port[2];   // 1 = I/O visible at $D000, 0 = Char ROM

/* Address decode from LIVE cpu_addr (for combinational read mux) */
wire sel_basic  = loram && hiram && (cpu_addr >= 16'hA000) && (cpu_addr <= 16'hBFFF);
wire sel_kernal = hiram && (cpu_addr >= 16'hE000);
wire sel_io     = charen && (cpu_addr >= 16'hD000) && (cpu_addr <= 16'hDFFF);
wire sel_charrom = !charen && (cpu_addr >= 16'hD000) && (cpu_addr <= 16'hDFFF);

wire sel_vic    = sel_io && (cpu_addr[11:8] == 4'h0 || cpu_addr[11:8] == 4'h1 ||
                             cpu_addr[11:8] == 4'h2 || cpu_addr[11:8] == 4'h3);
wire sel_sid    = sel_io && (cpu_addr[11:8] == 4'h4 || cpu_addr[11:8] == 4'h5 ||
                             cpu_addr[11:8] == 4'h6 || cpu_addr[11:8] == 4'h7);
wire sel_color  = sel_io && (cpu_addr[11:8] >= 4'h8 && cpu_addr[11:8] <= 4'hB);
wire sel_cia1   = sel_io && (cpu_addr[11:8] == 4'hC);
wire sel_cia2   = sel_io && (cpu_addr[11:8] == 4'hD);

/* LATCHED address decode (for writes at phi2_n, 25 clocks after phi2_p) */
wire lat_io     = charen && (cpu_addr_latched >= 16'hD000) && (cpu_addr_latched <= 16'hDFFF);
wire lat_vic    = lat_io && (cpu_addr_latched[11:8] <= 4'h3);
wire lat_color  = lat_io && (cpu_addr_latched[11:8] >= 4'h8) && (cpu_addr_latched[11:8] <= 4'hB);
wire lat_cia1   = lat_io && (cpu_addr_latched[11:8] == 4'hC);
wire lat_cia2   = lat_io && (cpu_addr_latched[11:8] == 4'hD);
wire lat_basic  = loram && hiram && (cpu_addr_latched >= 16'hA000) && (cpu_addr_latched <= 16'hBFFF);
wire lat_kernal = hiram && (cpu_addr_latched >= 16'hE000);
wire lat_charrom = !charen && (cpu_addr_latched >= 16'hD000) && (cpu_addr_latched <= 16'hDFFF);

/* ── RAM (64 KB) ──────────────────────────────────────────────────────── */
reg [7:0] ram [0:65535];
initial begin : ram_init
    integer i;
    for (i = 0; i < 65536; i = i + 1) ram[i] = 8'h00;
`ifdef GAME_PRG
    $readmemh("../roms/game.hex", ram);
`endif
end

always @(posedge clk) begin
    if (rst && cpu_we_latched && phi2_n && !lat_basic && !lat_kernal && !lat_io && !lat_charrom)
        ram[cpu_addr_latched] <= cpu_do_latched;
end

/* ── ROMs ──────────────────────────────────────────────────────────────── */
reg [7:0] basic_rom [0:8191];
reg [7:0] kernal_rom [0:8191];
reg [7:0] char_rom [0:4095];

initial $readmemh("../roms/basic.hex", basic_rom);
initial $readmemh("../roms/kernal.hex", kernal_rom);
initial $readmemh("../roms/chargen.hex", char_rom);

/* ── Color RAM (1K x 4 bits) ──────────────────────────────────────────── */
reg [3:0] color_ram [0:1023];
initial begin : color_init
    integer i;
    for (i = 0; i < 1024; i = i + 1) color_ram[i] = 4'hE; // light blue
end

always @(posedge clk) begin
    if (rst && cpu_we_latched && phi2_n && lat_color)
        color_ram[cpu_addr_latched[9:0]] <= cpu_do_latched[3:0];
end

/* ── CIA1 (keyboard, joystick, IRQ) ───────────────────────────────────── */
wire [7:0] cia1_data_out;
wire [7:0] cia1_pa_out, cia1_pb_out;
wire [7:0] cia1_pa_oe, cia1_pb_oe;

// Keyboard matrix — at 1 MHz, CIA PA output is in sync with CPU
wire [7:0] key_row_select = cia1_pa_out | ~cia1_pa_oe;
wire [7:0] key_col_result;

mos6526 cia1(
    .mode   (1'b0),
    .clk    (clk),
    .phi2_p (phi2_p),
    .phi2_n (phi2_n),
    .res_n  (rst),
    .cs_n   (~lat_cia1),
    .rw     (~cpu_we_latched),
    .rs     (cpu_addr_latched[3:0]),
    .db_in  (cpu_do_latched),
    .db_out (cia1_data_out),
    .pa_in  (8'hFF),
    .pa_out (cia1_pa_out),
    .pa_oe  (cia1_pa_oe),
    .pb_in  (key_col_result),
    .pb_out (cia1_pb_out),
    .pb_oe  (),
    .flag_n (1'b1),
    .pc_n   (),
    .tod    (tod_clk),
    .sp_in  (1'b1),
    .sp_out (),
    .cnt_in (1'b1),
    .cnt_out(),
    .irq_n  (cia1_irq_n)
);

/* ── CIA2 (serial, NMI) ───────────────────────────────────────────────── */
wire [7:0] cia2_data_out;

mos6526 cia2(
    .mode   (1'b0),
    .clk    (clk),
    .phi2_p (phi2_p),
    .phi2_n (phi2_n),
    .res_n  (rst),
    .cs_n   (~lat_cia2),
    .rw     (~cpu_we_latched),
    .rs     (cpu_addr_latched[3:0]),
    .db_in  (cpu_do_latched),
    .db_out (cia2_data_out),
    .pa_in  (8'hFF),
    .pa_out (),
    .pa_oe  (),
    .pb_in  (8'hFF),
    .pb_out (),
    .pb_oe  (),
    .flag_n (1'b1),
    .pc_n   (),
    .tod    (tod_clk),
    .sp_in  (1'b1),
    .sp_out (),
    .cnt_in (1'b1),
    .cnt_out(),
    .irq_n  (cia2_irq_n)
);

/* ── TOD clock (~60 Hz from LCD vsync) ─────────────────────────────────── */
reg tod_clk;
reg prev_lcd_vsync;
always @(posedge clk) begin
    if (!rst) begin
        tod_clk <= 0;
        prev_lcd_vsync <= 1;
    end else begin
        prev_lcd_vsync <= lcd_vsync;
        if (prev_lcd_vsync && !lcd_vsync)
            tod_clk <= ~tod_clk;
    end
end

/* ── Keyboard (UART bridge) ────────────────────────────────────────────── */
wire [7:0] uart_rx_data;
wire       uart_rx_valid;

c64_keyboard kbd(
    .clk         (clk),
    .rst         (rst),
    .uart_rx_data(uart_rx_data),
    .uart_rx_valid(uart_rx_valid),
    .row_select  (key_row_select),
    .col_result  (key_col_result)
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

/* ── CPU data bus mux ──────────────────────────────────────────────────── */
/* The mux is combinational, but we register the output on phi2_n
 * (halfway between two CPU cycles). The CPU presents the address on
 * phi2_p, the mux settles during the ~25 clocks until phi2_n, and the
 * registered value is stable for the next phi2_p when the CPU reads DI. */
reg [7:0] data_mux;
always @(*) begin
    data_mux = ram[cpu_addr];

    if (cpu_addr == 16'h0000)
        data_mux = cpu_ddr;
    else if (cpu_addr == 16'h0001)
        data_mux = cpu_port_read;
    else if (sel_basic)
        data_mux = basic_rom[cpu_addr[12:0]];
    else if (sel_kernal)
        data_mux = kernal_rom[cpu_addr[12:0]];
    else if (sel_charrom)
        data_mux = char_rom[cpu_addr[11:0]];
    else if (sel_vic)
        data_mux = 8'h00;
    else if (sel_sid)
        data_mux = 8'h00;
    else if (sel_color)
        data_mux = {4'hF, color_ram[cpu_addr[9:0]]};
    else if (sel_cia1 && cpu_addr[3:0] == 4'h1)
        data_mux = key_col_result;
    else if (sel_cia1)
        data_mux = cia1_data_out;
    else if (sel_cia2)
        data_mux = cia2_data_out;
end

/* PET-style registered bus: only update when RDY is high.
 * CPU presents address when RDY=1, data_mux settles combinationally,
 * cpu_data_in latches it. On the next RDY=1 cycle (25 clocks later),
 * the CPU reads the latched value — which is data for the address it
 * presented on the PREVIOUS RDY=1 cycle. */
always @(posedge clk)
    if (cpu_rdy)
        cpu_data_in <= data_mux;

/* ── LCD timing ────────────────────────────────────────────────────────── */
wire [10:0] lcd_col, lcd_row;

lcd_out lcd0(
    .clk(clk), .rst(rst),
    .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
    .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
    .row(lcd_row), .col(lcd_col)
);

/* ── Simple text-mode display (40x25, C64 character ROM) ───────────────── */
/* Renders the screen RAM ($0400-$07E7) using the character ROM.
 * 320x200 display centred in 480x272 LCD. */

localparam BORDER_H = 80;   // (480-320)/2
localparam BORDER_V = 36;   // (272-200)/2
localparam DISPLAY_W = 320;
localparam DISPLAY_H = 200;

wire in_display = (lcd_col >= BORDER_H) && (lcd_col < BORDER_H + DISPLAY_W) &&
                  (lcd_row >= BORDER_V) && (lcd_row < BORDER_V + DISPLAY_H);

wire [8:0] dx = lcd_col - BORDER_H;
wire [7:0] dy = lcd_row - BORDER_V;

// Screen RAM at $0400, character column = dx/8, row = dy/8
wire [5:0] char_col = dx / 8;   // 0-39
wire [4:0] char_row = dy[7:3];  // 0-24
wire [9:0] screen_addr = char_row * 40 + char_col;

// Pre-fetch screen byte and char ROM (1 pixel ahead)
wire [8:0] dx_next = lcd_col + 1 - BORDER_H;
wire       in_next = (lcd_col + 1 >= BORDER_H) && (lcd_col + 1 < BORDER_H + DISPLAY_W) &&
                     (lcd_row >= BORDER_V) && (lcd_row < BORDER_V + DISPLAY_H);
wire [5:0] next_col = dx_next / 8;
wire [4:0] next_row = dy[7:3];
wire [9:0] next_screen_addr = next_row * 40 + next_col;

reg [7:0] vid_char;
reg [7:0] vid_pixels;
reg [3:0] vid_color;

reg [7:0] vid_shiftreg;

always @(posedge clk) begin
    if (in_next && dx_next[2:0] == 3'd0) begin
        vid_char  <= ram[16'h0400 + next_screen_addr];
        vid_color <= color_ram[next_screen_addr];
    end
    /* Load shift register 2 clocks after char load (vid_char settled) */
    if (in_next && dx_next[2:0] == 3'd2)
        vid_shiftreg <= char_rom[{vid_char, dy[2:0]}];
    else
        vid_shiftreg <= {vid_shiftreg[6:0], 1'b0};  // shift left each clock
end

/* ── C64 colour palette (16 colours in RGB565) ─────────────────────────── */
reg [15:0] c64_pal;
always @(*) begin
    case (vid_color)
        4'h0: c64_pal = 16'h0000;  // black
        4'h1: c64_pal = 16'hFFFF;  // white
        4'h2: c64_pal = 16'hA104;  // red
        4'h3: c64_pal = 16'h5EFB;  // cyan
        4'h4: c64_pal = 16'hA1D7;  // purple
        4'h5: c64_pal = 16'h4547;  // green
        4'h6: c64_pal = 16'h2015;  // blue
        4'h7: c64_pal = 16'hDF40;  // yellow
        4'h8: c64_pal = 16'hA345;  // orange
        4'h9: c64_pal = 16'h6262;  // brown
        4'hA: c64_pal = 16'hD34A;  // light red
        4'hB: c64_pal = 16'h4228;  // dark grey
        4'hC: c64_pal = 16'h7BCF;  // grey
        4'hD: c64_pal = 16'h8F0C;  // light green
        4'hE: c64_pal = 16'h5C1E;  // light blue
        4'hF: c64_pal = 16'hB596;  // light grey
    endcase
end

/* Background color from VIC-II register $D021 — default $06 (blue) */
reg [3:0] bg_color = 4'h6;
reg [3:0] border_color_reg = 4'hE;  // light blue

/* Border color palette lookup */
reg [15:0] border_pal;
always @(*) begin
    case (border_color_reg)
        4'h0: border_pal = 16'h0000;
        4'h1: border_pal = 16'hFFFF;
        4'h2: border_pal = 16'hA104;
        4'h3: border_pal = 16'h5EFB;
        4'h4: border_pal = 16'hA1D7;
        4'h5: border_pal = 16'h4547;
        4'h6: border_pal = 16'h2015;
        4'h7: border_pal = 16'hDF40;
        4'h8: border_pal = 16'hA345;
        4'h9: border_pal = 16'h6262;
        4'hA: border_pal = 16'hD34A;
        4'hB: border_pal = 16'h4228;
        4'hC: border_pal = 16'h7BCF;
        4'hD: border_pal = 16'h8F0C;
        4'hE: border_pal = 16'h5C1E;
        4'hF: border_pal = 16'hB596;
    endcase
end

reg [15:0] bg_pal;
always @(*) begin
    case (bg_color)
        4'h0: bg_pal = 16'h0000;
        4'h1: bg_pal = 16'hFFFF;
        4'h2: bg_pal = 16'hA104;
        4'h3: bg_pal = 16'h5EFB;
        4'h4: bg_pal = 16'hA1D7;
        4'h5: bg_pal = 16'h4547;
        4'h6: bg_pal = 16'h2015;
        4'h7: bg_pal = 16'hDF40;
        4'h8: bg_pal = 16'hA345;
        4'h9: bg_pal = 16'h6262;
        4'hA: bg_pal = 16'hD34A;
        4'hB: bg_pal = 16'h4228;
        4'hC: bg_pal = 16'h7BCF;
        4'hD: bg_pal = 16'h8F0C;
        4'hE: bg_pal = 16'h5C1E;
        4'hF: bg_pal = 16'hB596;
    endcase
end

/* Handle VIC-II register writes (minimal: border and background only) */
always @(posedge clk) begin
    if (!rst) begin
        bg_color <= 4'h6;
        border_color_reg <= 4'hE;
    end else if (cpu_we_latched && phi2_n && lat_vic) begin
        if (cpu_addr_latched[5:0] == 6'h20) border_color_reg <= cpu_do_latched[3:0];
        if (cpu_addr_latched[5:0] == 6'h21) bg_color <= cpu_do_latched[3:0];
    end
end

/* Pixel output — MSB of shift register */
wire pixel_bit = vid_shiftreg[7];

always @(posedge clk) begin
    if (!rst)
        lcd_data <= 16'h0000;
    else if (lcd_de) begin
        if (in_display)
            lcd_data <= pixel_bit ? c64_pal : bg_pal;
        else
            lcd_data <= border_pal;
    end
end

/* Count CIA1 IRQs to see if timer ever fires */
/* Debug: show what PB the CIA returns when CPU reads $DC01 */
assign dbg_addr = cpu_addr;
endmodule
