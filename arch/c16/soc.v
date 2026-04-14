`timescale 1ns / 1ps
`include "project.vh"

module soc(
    input clk,
    input rst,
    output reg led1,
    output reg led2,
    input rx,
    output tx,
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

    reg [7:0] ram [0:65535];

`ifdef GAME_PRG
    // Game ROM shadow: loaded from game.hex, copied to RAM on trigger
    reg [7:0] game_rom [0:65535];
    reg game_copy_pending;
    `include "../roms/game_params.vh"
    initial $readmemh("../roms/game.hex", game_rom);
`endif

    always @(posedge clk) begin
        if (c16_ras) ram_row <= c16_a;   // latch low byte while RAS high (mux=1)
        if (!c16_cas && !c16_rw)         // write on CAS when RW=0
            ram[ram_addr] <= c16_dout;
        ram_dout <= ram[ram_addr];        // always read

`ifdef GAME_PRG
        // Trigger: detect CPU write to $FD3D via reconstructed address
        // (CAS doesn't go low for I/O addresses, so check address bus directly)
        // During mux=0 (CAS phase): A = high byte, ram_row = low byte
        if (!c16_rw && !c16_core.mux && {c16_a, ram_row} == 16'hFD3D)
            game_copy_pending <= 1;
        if (game_copy_pending) begin
            game_copy_pending <= 0;
            for (integer i = GAME_START; i <= GAME_END; i = i + 1)
                ram[i] <= game_rom[i];
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
        .RS232_TX(tx),
        .RS232_DCD(1'b1),
        .RS232_DSR(1'b1),
        .sim_key_strobe(key_strobe),
        .sim_key_scancode(key_scancode),
        .TICK8(c16_tick8)
    );

    // ================================================================
    //  Video: C16 RGB444 → framebuffer → LCD
    // ================================================================
    // Capture framebuffer at the TED's pixel clock (tick8, exactly 1 sample/pixel).
    reg [15:0] framebuf [0:512*312-1];
    reg [8:0] fb_x, fb_y;
    reg c16_hsync_prev, c16_vsync_prev;
    wire [15:0] c16_rgb565 = {c16_r, c16_r[3], c16_g, c16_g[3:2], c16_b, c16_b[3]};

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

    // LCD output (480x272)
    wire [10:0] lcd_col, lcd_row;
    lcd_out lcd0(
        .clk(clk), .rst(rst),
        .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .row(lcd_row), .col(lcd_col)
    );
    assign lcd_pwm = 1'b1;
    assign lcd_clk = clk;

    // Display framebuffer 1:1 centered (480 LCD - ~375 content = ~52px each side)
    wire [8:0] fb_rx = lcd_col[8:0] - 9'd52;
    wire [8:0] fb_ry = lcd_row[8:0] + 9'd20;
    wire in_fb = (fb_rx < 400) && (fb_ry < 312);

    always @(posedge clk or negedge rst)
        if (!rst)
            lcd_data <= 0;
        else if (lcd_de)
            lcd_data <= in_fb ? framebuf[{fb_ry, fb_rx}] : 16'h0000;

    // ================================================================
    //  Keyboard: UART ASCII → PS/2 scan codes for c16_keymatrix
    // ================================================================
    wire uart_rx_raw;
    wire [7:0] uart_rx_data;
    uart uart_kb(
        .clk(clk), .rst(rst),
        .rx(rx), .rxdata(uart_rx_data), .rxen(uart_rx_raw),
        .txdata(8'd0), .txen(1'b0), .tx(), .txbusy()
    );
    // Detect any rxen toggle (rxen XORs on each received byte)
    reg uart_rx_prev;
    always @(posedge clk) uart_rx_prev <= uart_rx_raw;
    wire uart_rx_valid = uart_rx_raw ^ uart_rx_prev;

    // Pending register: hold UART byte until state machine is ready
    reg [7:0] pend_char;
    reg pend_valid;
    always @(posedge clk or negedge rst)
        if (!rst) begin pend_char <= 0; pend_valid <= 0; end
        else if (uart_rx_valid) begin pend_char <= uart_rx_data; pend_valid <= 1; end
        else if (pend_valid && key_state == 0) pend_valid <= 0;

    // Pending char's PS/2 code (re-decode from pend_char)
    reg [7:0] pend_ps2;
    reg pend_shift;
    always @* begin
        pend_shift = 0;
        case (pend_char)
            8'h22: pend_shift = 1;  // " needs shift+2 on C16
            default: pend_shift = 0;
        endcase
        case (pend_char | 8'h20)
            "a": pend_ps2 = 8'h1C; "b": pend_ps2 = 8'h32; "c": pend_ps2 = 8'h21;
            "d": pend_ps2 = 8'h23; "e": pend_ps2 = 8'h24; "f": pend_ps2 = 8'h2B;
            "g": pend_ps2 = 8'h34; "h": pend_ps2 = 8'h33; "i": pend_ps2 = 8'h43;
            "j": pend_ps2 = 8'h3B; "k": pend_ps2 = 8'h42; "l": pend_ps2 = 8'h4B;
            "m": pend_ps2 = 8'h3A; "n": pend_ps2 = 8'h31; "o": pend_ps2 = 8'h44;
            "p": pend_ps2 = 8'h4D; "q": pend_ps2 = 8'h15; "r": pend_ps2 = 8'h2D;
            "s": pend_ps2 = 8'h1B; "t": pend_ps2 = 8'h2C; "u": pend_ps2 = 8'h3C;
            "v": pend_ps2 = 8'h2A; "w": pend_ps2 = 8'h1D; "x": pend_ps2 = 8'h22;
            "y": pend_ps2 = 8'h35; "z": pend_ps2 = 8'h1A;
            default: begin
                case (pend_char)
                    "0": pend_ps2 = 8'h45; "1": pend_ps2 = 8'h16; "2": pend_ps2 = 8'h1E;
                    "3": pend_ps2 = 8'h26; "4": pend_ps2 = 8'h25; "5": pend_ps2 = 8'h2E;
                    "6": pend_ps2 = 8'h36; "7": pend_ps2 = 8'h3D; "8": pend_ps2 = 8'h3E;
                    "9": pend_ps2 = 8'h46;
                    8'h0D: pend_ps2 = 8'h5A;
                    " ":  pend_ps2 = 8'h29;
                    8'h08, 8'h7F: pend_ps2 = 8'h66;
                    ",": pend_ps2 = 8'h41; ".": pend_ps2 = 8'h49;
                    "-": pend_ps2 = 8'h4E; "+": pend_ps2 = 8'h55;
                    "/": pend_ps2 = 8'h4A; "*": pend_ps2 = 8'h5B;
                    ":": pend_ps2 = 8'h4C; ";": pend_ps2 = 8'h52;
                    "=": pend_ps2 = 8'h5D; "@": pend_ps2 = 8'h54;
                    8'h22: pend_ps2 = 8'h1E;  // " = shift+2
                    default: pend_ps2 = 8'h00;
                endcase
            end
        endcase
    end

    // State machine: send make code, wait, send break (F0 + code)
    reg key_strobe;
    reg [7:0] key_scancode;
    reg [2:0] key_state;
    reg [19:0] key_timer;
    reg [7:0] key_saved_code;
    reg key_saved_shift;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            key_strobe <= 0; key_scancode <= 0;
            key_state <= 0; key_timer <= 0;
            key_saved_code <= 0; key_saved_shift <= 0;
        end else begin
            key_strobe <= 0;
            case (key_state)
                0: if (pend_valid && pend_ps2 != 0) begin
                    key_saved_code <= pend_ps2;
                    key_saved_shift <= pend_shift;
                    if (pend_shift) begin
                        key_scancode <= 8'h12; // SHIFT make
                        key_strobe <= 1;
                        key_state <= 1;
                        key_timer <= 20'd5000;
                    end else begin
                        key_scancode <= pend_ps2; // key make
                        key_strobe <= 1;
                        key_state <= 3;
                        key_timer <= 20'd700000; // hold ~25ms
                    end
                end
                1: begin // wait then send key make
                    if (key_timer == 0) begin
                        key_scancode <= key_saved_code;
                        key_strobe <= 1;
                        key_state <= 3;
                        key_timer <= 20'd500000;
                    end else key_timer <= key_timer - 1;
                end
                3: begin // wait then send F0 (break prefix)
                    if (key_timer == 0) begin
                        key_scancode <= 8'hF0;
                        key_strobe <= 1;
                        key_state <= 4;
                        key_timer <= 20'd5000;
                    end else key_timer <= key_timer - 1;
                end
                4: begin // wait then send key break code
                    if (key_timer == 0) begin
                        key_scancode <= key_saved_code;
                        key_strobe <= 1;
                        if (key_saved_shift)
                            key_state <= 5;
                        else
                            key_state <= 7;
                        key_timer <= 20'd5000;
                    end else key_timer <= key_timer - 1;
                end
                5: begin // send F0 for shift release
                    if (key_timer == 0) begin
                        key_scancode <= 8'hF0;
                        key_strobe <= 1;
                        key_state <= 6;
                        key_timer <= 20'd5000;
                    end else key_timer <= key_timer - 1;
                end
                6: begin // send shift break code
                    if (key_timer == 0) begin
                        key_scancode <= 8'h12;
                        key_strobe <= 1;
                        key_state <= 7;
                        key_timer <= 20'd100000;
                    end else key_timer <= key_timer - 1;
                end
                7: begin // cooldown
                    if (key_timer == 0)
                        key_state <= 0;
                    else key_timer <= key_timer - 1;
                end
            endcase
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
    always @(posedge clk or negedge rst)
        if (!rst) begin led1 <= 0; led2 <= 0; end
`endif

endmodule
