`timescale 1ns / 1ps
`include "project.vh"

module soc(
    input clk,
    input rst,
    output reg led1,
    output reg led2,
    input rx,
    output wire tx,
    input [4:0] joy,  // active-low joystick: up,down,left,right,fire
    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output reg [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk
);

    // ================================================================
    //  C16 core
    // ================================================================
    wire c16_hsync, c16_vsync, c16_csync, c16_hblank, c16_vblank;
    wire [3:0] c16_r, c16_g, c16_b;
    wire c16_ras, c16_cas, c16_rw;
    wire [7:0] c16_a, c16_dout;
    wire c16_tick8;
    wire c16_cs0, c16_cs1;
    wire [3:0] c16_rom_sel;
    wire [13:0] c16_rom_addr;
    wire c16_pal;
    wire [5:0] c16_audio_pcm;

    // RAM interface: reconstruct 16-bit address from multiplexed 8-bit A bus.
    // Latch low byte while RAS is HIGH (mux=1 guaranteed), use high byte at CAS.
    reg [7:0] ram_row;
    wire [15:0] ram_addr = {c16_a, ram_row};
    reg [7:0] ram_dout;

    reg [7:0] ram [0:16383];  // C16 has 16KB RAM

`ifdef GAME_PRG
    // Game ROM shadow: loaded from game.hex, copied to RAM on trigger
    reg [7:0] game_rom [0:65535];
    reg game_copy_pending;
    `include "../roms/game_params.vh"
    initial $readmemh("../roms/game.hex", game_rom);
`endif

    wire [13:0] ram_addr14 = ram_addr[13:0];  // 16KB address space

    always @(posedge clk) begin
        if (c16_ras) ram_row <= c16_a;   // latch low byte while RAS high (mux=1)
        if (!c16_cas && !c16_rw)         // write on CAS when RW=0
            ram[ram_addr14] <= c16_dout;
        ram_dout <= ram[ram_addr14];      // always read

`ifdef GAME_PRG
        // Trigger: detect CPU write to $FD3D via reconstructed address
        // (CAS doesn't go low for I/O addresses, so check address bus directly)
        // During mux=0 (CAS phase): A = high byte, ram_row = low byte
        if (!c16_rw && !c16_core.mux && {c16_a, ram_row} == 16'hFD3D)
            game_copy_pending <= 1;
        if (game_copy_pending) begin
            game_copy_pending <= 0;
            for (integer i = GAME_START; i <= GAME_END; i = i + 1)
                ram[i[13:0]] <= game_rom[i];
        end
`endif
    end

    // Data input to C16: just RAM data. ROMs are internal to the C16 module.
    wire [7:0] din_mux = ram_dout;

    C16 c16_core(
        .CLK28(clk),
        .RESET(~rst),
        .WAIT(1'b0),
        .HSYNC(c16_hsync),
        .VSYNC(c16_vsync),
        .CSYNC(c16_csync),
        .HBLANK(c16_hblank),
        .VBLANK(c16_vblank),
        .RED(c16_r),
        .GREEN(c16_g),
        .BLUE(c16_b),
        .RAS(c16_ras),
        .CAS(c16_cas),
        .RW(c16_rw),
        .A(c16_a),
        .DIN(din_mux),
        .DOUT(c16_dout),
        .CS0(c16_cs0),
        .CS1(c16_cs1),
        .ROM_SEL(c16_rom_sel),
        .ROM_ADDR(c16_rom_addr),
        .JOY0(joy),
        .JOY1(5'b11111),
        .PS2DAT(1'b1),
        .PS2CLK(1'b1),
        .IEC_DATAIN(1'b1),
        .IEC_CLKIN(1'b1),
        .CASS_READ(1'b1),
        .CASS_SENSE(1'b1),
        .SID_TYPE(2'b00),
        .AUDIO_PCM(c16_audio_pcm),
        .dl_addr(14'd0),
        .dl_data(8'd0),
        .kernal_dl_write(1'b0),
        .basic_dl_write(1'b0),
        .PAL(c16_pal),
        .RS232_RX(1'b1),  // idle; keyboard uses separate UART
        .RS232_TX(),      // disconnected; tx driven by uart_kb echo
        .RS232_DCD(1'b1),
        .RS232_DSR(1'b1),
        .sim_key_strobe(key_strobe),
        .sim_key_scancode(key_scancode),
        .TICK8(c16_tick8)
    );

    // ================================================================
    //  Video
    // ================================================================
    wire [15:0] c16_rgb565 = {c16_r, c16_r[3], c16_g, c16_g[3:2], c16_b, c16_b[3]};
    assign lcd_pwm = 1'b1;
    assign lcd_clk = clk;

`ifdef SIMULATION
    // Simulation: capture into framebuffer, read back via lcd_out timing
    reg [15:0] framebuf [0:512*312-1];
    reg [8:0] fb_x, fb_y;
    reg c16_hsync_prev, c16_vsync_prev;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            fb_x <= 0; fb_y <= 0;
            c16_hsync_prev <= 1; c16_vsync_prev <= 1;
        end else begin
            c16_hsync_prev <= c16_hsync;
            c16_vsync_prev <= c16_vsync;
            if (!c16_hblank && !c16_vblank && c16_tick8) begin
                if (fb_x < 400 && fb_y < 312)
                    framebuf[{fb_y, fb_x}] <= c16_rgb565;
                fb_x <= fb_x + 1;
            end
            if (c16_hblank && !c16_hsync_prev && c16_hsync) begin
                fb_x <= 0;
                fb_y <= fb_y + 1;
            end
            if (!c16_vsync && c16_vsync_prev)
                fb_y <= 0;
        end

    wire [10:0] lcd_col, lcd_row;
    lcd_out lcd0(
        .clk(clk), .rst(rst),
        .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .row(lcd_row), .col(lcd_col)
    );
    wire [8:0] fb_rx = lcd_col[8:0] - 9'd52;
    wire [8:0] fb_ry = lcd_row[8:0] + 9'd20;
    wire in_fb = (fb_rx < 400) && (fb_ry < 312);
    always @(posedge clk or negedge rst)
        if (!rst) lcd_data <= 0;
        else if (lcd_de) lcd_data <= in_fb ? framebuf[{fb_ry, fb_rx}] : 16'h0000;

`else
    // FPGA: line buffer with LCD timing locked to TED sync.
    // One DP16KD BRAM (1024x16, ping-pong halves).
    // TED writes at tick8 rate; LCD reads back twice per TED line (line doubling).
    // LCD hsync/vsync derived from TED sync → no rolling.
    reg [15:0] lbram [0:1023];
    reg [15:0] lbram_rd;
    reg lb_half;
    reg [8:0] lb_wr_x;
    reg fpga_hs_prev, fpga_vs_prev;

    // Write port: TED fills line buffer
    always @(posedge clk)
        if (!c16_hblank && !c16_vblank && c16_tick8 && lb_wr_x < 400)
            lbram[{lb_half, lb_wr_x}] <= c16_rgb565;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            lb_wr_x <= 0; lb_half <= 0; fpga_hs_prev <= 1; fpga_vs_prev <= 1;
        end else begin
            fpga_hs_prev <= c16_hsync;
            fpga_vs_prev <= c16_vsync;
            if (!c16_hblank && !c16_vblank && c16_tick8)
                lb_wr_x <= lb_wr_x + 1;
            if (!fpga_hs_prev && c16_hsync) begin
                lb_wr_x <= 0;
                lb_half <= ~lb_half;
            end
        end

    // LCD timing generator locked to TED.
    // One LCD line per TED line (1824 clocks). 480 active pixels + blanking.
    // Vertical: 272 active lines, frame locked to TED vsync.
    localparam LCD_HTOTAL = 1824;
    localparam LCD_HACTIVE = 480;
    localparam LCD_HFP = 20;   // front porch
    localparam LCD_HPW = 40;   // hsync pulse width

    reg [10:0] lh_cnt;         // LCD horizontal counter (0..1823)
    reg [8:0] lv_cnt;          // LCD vertical line counter
    reg [8:0] ted_line;        // TED line counter (for vertical crop)
    reg lcd_hs_r, lcd_vs_r, lcd_de_r;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            lh_cnt <= 0; lv_cnt <= 0; ted_line <= 0;
            lcd_hs_r <= 1; lcd_vs_r <= 1; lcd_de_r <= 0;
        end else begin
            // Horizontal counter: free-run, reset on TED hsync
            if (!fpga_hs_prev && c16_hsync)
                lh_cnt <= 0;
            else if (lh_cnt == LCD_HTOTAL - 1)
                lh_cnt <= 0;
            else
                lh_cnt <= lh_cnt + 1;

            // TED line counter for vertical cropping
            if (!fpga_hs_prev && c16_hsync)
                ted_line <= ted_line + 1;
            if (!c16_vsync && fpga_vs_prev)
                ted_line <= 0;

            // LCD vertical counter: increment every 2nd LCD line (= each TED line)
            if (!fpga_hs_prev && c16_hsync)
                lv_cnt <= lv_cnt + 1;
            if (!c16_vsync && fpga_vs_prev)
                lv_cnt <= 0;

            // LCD signals
            lcd_de_r <= (lh_cnt < LCD_HACTIVE) && (ted_line >= 20) && (ted_line < 292);
            lcd_hs_r <= !((lh_cnt >= LCD_HACTIVE + LCD_HFP) &&
                          (lh_cnt < LCD_HACTIVE + LCD_HFP + LCD_HPW));
            lcd_vs_r <= c16_vsync;
        end

    assign lcd_hsync = lcd_hs_r;
    assign lcd_vsync = lcd_vs_r;
    assign lcd_de    = lcd_de_r;

    // Read port: map LCD column to line buffer, centered
    wire [8:0] rd_x = lh_cnt[8:0] - 9'd52;
    always @(posedge clk)
        lbram_rd <= lbram[{~lb_half, rd_x}];

    always @(posedge clk or negedge rst)
        if (!rst) lcd_data <= 0;
        else lcd_data <= lcd_de_r ? ((rd_x < 400) ? lbram_rd : 16'h0000) : 16'h0000;
`endif

    // ================================================================
    //  Keyboard: UART ASCII → PS/2 scan codes for c16_keymatrix
    // ================================================================
    wire uart_rx_raw;
    wire [7:0] uart_rx_data;
    wire uart_kb_tx;
    reg [7:0] echo_data;
    reg echo_en;
    uart uart_kb(
        .clk(clk), .rst(rst),
        .rx(rx), .rxdata(uart_rx_data), .rxen(uart_rx_raw),
        .txdata(echo_data), .txen(echo_en), .tx(uart_kb_tx), .txbusy()
    );
    // Detect any rxen toggle (rxen XORs on each received byte)
    reg uart_rx_prev;
    always @(posedge clk) uart_rx_prev <= uart_rx_raw;
    wire uart_rx_valid = uart_rx_raw ^ uart_rx_prev;

    // Echo received byte back via UART TX (debug — remove when keyboard works)
    assign tx = uart_kb_tx;
    always @(posedge clk or negedge rst)
        if (!rst) echo_en <= 0;
        else if (uart_rx_valid) begin
            echo_data <= uart_rx_data;
            echo_en <= ~echo_en;
        end

    // Pending register: hold UART byte until state machine is ready
    reg [7:0] pend_char;
    reg pend_valid;
    always @(posedge clk or negedge rst)
        if (!rst) begin pend_char <= 0; pend_valid <= 0; end
        else if (uart_rx_valid) begin pend_char <= uart_rx_data; pend_valid <= 1; end
        else pend_valid <= 0;

    // Pending char's PS/2 code (re-decode from pend_char)
    // NOTE: Use explicit 8-bit hex values, NOT string literals like "a".
    // Yosys may widen string literals beyond 8 bits, causing case mismatches.
    // Use uart_rx_data directly (not pend_char) so the lookup is valid
    // on the same clock that uart_rx_valid fires.
    reg [7:0] pend_ps2;
    reg pend_shift;
    always @* begin
        pend_ps2 = 8'h00;
        pend_shift = 0;
        case (uart_rx_data | 8'h20)
            8'h61: pend_ps2 = 8'h1C;  // a
            8'h62: pend_ps2 = 8'h32;  // b
            8'h63: pend_ps2 = 8'h21;  // c
            8'h64: pend_ps2 = 8'h23;  // d
            8'h65: pend_ps2 = 8'h24;  // e
            8'h66: pend_ps2 = 8'h2B;  // f
            8'h67: pend_ps2 = 8'h34;  // g
            8'h68: pend_ps2 = 8'h33;  // h
            8'h69: pend_ps2 = 8'h43;  // i
            8'h6A: pend_ps2 = 8'h3B;  // j
            8'h6B: pend_ps2 = 8'h42;  // k
            8'h6C: pend_ps2 = 8'h4B;  // l
            8'h6D: pend_ps2 = 8'h3A;  // m
            8'h6E: pend_ps2 = 8'h31;  // n
            8'h6F: pend_ps2 = 8'h44;  // o
            8'h70: pend_ps2 = 8'h4D;  // p
            8'h71: pend_ps2 = 8'h15;  // q
            8'h72: pend_ps2 = 8'h2D;  // r
            8'h73: pend_ps2 = 8'h1B;  // s
            8'h74: pend_ps2 = 8'h2C;  // t
            8'h75: pend_ps2 = 8'h3C;  // u
            8'h76: pend_ps2 = 8'h2A;  // v
            8'h77: pend_ps2 = 8'h1D;  // w
            8'h78: pend_ps2 = 8'h22;  // x
            8'h79: pend_ps2 = 8'h35;  // y
            8'h7A: pend_ps2 = 8'h1A;  // z
            default: begin
                case (uart_rx_data)
                    8'h30: pend_ps2 = 8'h45;  // 0
                    8'h31: pend_ps2 = 8'h16;  // 1
                    8'h32: pend_ps2 = 8'h1E;  // 2
                    8'h33: pend_ps2 = 8'h26;  // 3
                    8'h34: pend_ps2 = 8'h25;  // 4
                    8'h35: pend_ps2 = 8'h2E;  // 5
                    8'h36: pend_ps2 = 8'h36;  // 6
                    8'h37: pend_ps2 = 8'h3D;  // 7
                    8'h38: pend_ps2 = 8'h3E;  // 8
                    8'h39: pend_ps2 = 8'h46;  // 9
                    8'h0D: pend_ps2 = 8'h5A;  // RETURN
                    8'h20: pend_ps2 = 8'h29;  // SPACE
                    8'h08: pend_ps2 = 8'h66;  // BACKSPACE
                    8'h7F: pend_ps2 = 8'h66;  // DEL
                    8'h2C: pend_ps2 = 8'h41;  // ,
                    8'h2E: pend_ps2 = 8'h49;  // .
                    8'h2D: pend_ps2 = 8'h4E;  // -
                    8'h2B: pend_ps2 = 8'h55;  // +
                    8'h2F: pend_ps2 = 8'h4A;  // /
                    8'h2A: pend_ps2 = 8'h5B;  // *
                    8'h3A: pend_ps2 = 8'h4C;  // :
                    8'h3B: pend_ps2 = 8'h52;  // ;
                    8'h3D: pend_ps2 = 8'h5D;  // =
                    8'h40: pend_ps2 = 8'h54;  // @
                    8'h22: begin pend_ps2 = 8'h1E; pend_shift = 1; end  // " = shift+2
                    default: pend_ps2 = 8'h00;
                endcase
            end
        endcase
    end

    // Key press state machine: make code → wait → F0 → break code
    // Simple counter approach (no case statement — avoids yosys optimization issues)
    reg [19:0] key_counter;
    reg [7:0] key_code;
    reg key_strobe;
    reg [7:0] key_scancode;

    localparam KEY_IDLE     = 0;
    localparam KEY_HOLD     = 1;       // after make, count down
    localparam KEY_BREAK_F0 = 700001;  // send F0
    localparam KEY_BREAK_GAP = 700002; // small gap
    localparam KEY_BREAK_CODE = 705002; // send break code
    localparam KEY_DONE    = 705003;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            key_counter <= 0;
            key_code <= 0;
            key_strobe <= 0;
            key_scancode <= 0;
        end else begin
            key_strobe <= 0;

            if (key_counter == KEY_IDLE) begin
                // Idle: wait for UART byte
                if (uart_rx_valid && pend_ps2 != 8'h00) begin
                    key_code <= pend_ps2;
                    key_scancode <= pend_ps2;
                    key_strobe <= 1;
                    key_counter <= KEY_HOLD;
                end
            end else if (key_counter == KEY_BREAK_F0) begin
                // Send F0 break prefix
                key_scancode <= 8'hF0;
                key_strobe <= 1;
                key_counter <= key_counter + 1;
            end else if (key_counter == KEY_BREAK_CODE) begin
                // Send break code
                key_scancode <= key_code;
                key_strobe <= 1;
                key_counter <= key_counter + 1;
            end else if (key_counter >= KEY_DONE) begin
                // Done, back to idle
                key_counter <= KEY_IDLE;
            end else begin
                // Counting
                key_counter <= key_counter + 1;
            end
        end

    // ================================================================
    //  Misc
    // ================================================================
`ifdef SIMULATION
    reg [31:0] dbg_cycle;
    reg c16_vs_prev;
    reg [31:0] frame_count;
    always @(posedge clk or negedge rst)
        if (!rst) begin
            led1 <= 0; led2 <= 0; dbg_cycle <= 0;
            c16_vs_prev <= 1; frame_count <= 0;
        end else begin
            dbg_cycle <= dbg_cycle + 1;
            c16_vs_prev <= c16_vsync;
            if (!c16_vsync && c16_vs_prev)
                frame_count <= frame_count + 1;
            // Dump framebuffer pixels for first "M" (chars 3-4) and second "M" (chars 5-6)
            // in "COMMODORE": C=1, O=2, M=3, M=4, O=5, D=6...
            // Each char ~8 pixels. Line 1 starts at fb_y ~offset.
            if (dbg_cycle == 25000000) begin
                // Find text: dump rows 0,5,10,15,20,25 — first 100 pixels as binary (dark=1, light=0)
                // Find first dark pixel and dump its context
            end
        end
`else
    // FPGA debug: led1=UART rx, led2=key_strobe (now same as uart_rx_valid)
    always @(posedge clk or negedge rst)
        if (!rst) begin led1 <= 0; led2 <= 0; end
        else begin
            if (uart_rx_valid) led1 <= ~led1;
            if (key_strobe)    led2 <= ~led2;
        end
`endif

endmodule
