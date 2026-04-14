`timescale 1ns / 1ps
`include "project.vh"

module soc(
    input clk,
    input rst,
    output reg led1,
    output reg led2,
    input rx,
    output tx,
    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output reg [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk
);

    // ================================================================
    //  FPGATED — cycle-exact TED chip
    // ================================================================
    wire [15:0] ted_addr_out;
    wire [7:0]  ted_data_out;
    wire        ted_cpuclk, ted_cpuenable;
    wire [6:0]  ted_color;
    wire        ted_csync, ted_irq, ted_ba;
    wire        ted_mux, ted_ras, ted_cas;
    wire        ted_cs0, ted_cs1, ted_aec;
    wire        ted_hsync, ted_vsync;
    wire        ted_data_oe;
    wire        ted_snd;
    wire signed [15:0] ted_digi_sound;
    wire        ted_burst, ted_even;
    wire        ted_pal;

    // ================================================================
    //  6502 CPU
    // ================================================================
    wire [15:0] cpu_ab;
    wire [7:0]  cpu_do;
    reg  [7:0]  cpu_di;
    wire        cpu_we;

    cpu cpu0(
        .clk(clk), .reset(~rst),
        .AB(cpu_ab), .DI(cpu_di), .DO(cpu_do),
        .WE(cpu_we), .IRQ(ted_irq), .NMI(1'b0),
        .RDY(ted_cpuenable)
    );

    // ================================================================
    //  Memory: 64KB RAM + 16KB BASIC ROM + 16KB KERNAL ROM
    // ================================================================
    reg [7:0] main_ram [0:65535];
    reg [7:0] basic_rom [0:16383];
    reg [7:0] kernal_rom [0:16383];

    initial $readmemh("../roms/basic.hex", basic_rom);
    initial $readmemh("../roms/kernal.hex", kernal_rom);

`ifdef GAME_PRG
    reg [7:0] game_rom [0:65535];
    initial $readmemh("../roms/game.hex", game_rom);
`include "../roms/game_params.vh"
    reg        game_copying, game_loaded;
    reg [15:0] game_copy_addr;
    wire       sel_gameload = (ted_addr_out == 16'hFD3D);
`endif

    // Bus address: CPU drives during CPU cycles (aec=1), TED during DMA (aec=0)
    wire [15:0] bus_addr = ted_aec ? cpu_ab : ted_addr_out;

    // Memory read at a given address, with ROM/RAM banking from TED cs signals
    function [7:0] mem_read;
        input [15:0] addr;
        input cs0_n, cs1_n;   // active-low chip selects
        begin
            if (!cs0_n)
                mem_read = basic_rom[addr[13:0]];
            else if (!cs1_n)
                mem_read = kernal_rom[addr[13:0]];
            else if (addr[15])
                // Fallback for early boot when cs signals haven't initialized:
                // $8000-$BFFF → BASIC, $C000-$FFFF → KERNAL
                mem_read = addr[14] ? kernal_rom[addr[13:0]] : basic_rom[addr[13:0]];
            else
                mem_read = main_ram[addr];
        end
    endfunction

    // CPU data-in: ALWAYS reads from cpu_ab (never from DMA addresses).
    // Registered and gated by cpuenable to break JMP1 combinational loop
    // (same fix as PET: AB depends on DIMUX depends on DI depends on AB).
    wire [7:0] cpu_mem = mem_read(cpu_ab, ted_cs0, ted_cs1);
    wire [7:0] cpu_di_comb = ted_data_oe ? ted_data_out : cpu_mem;
    always @(posedge clk)
        if (ted_cpuenable)
            cpu_di <= cpu_di_comb;

    // DMA data: use tedaddress directly with 0 latency.
    // The combinational loop (tedaddress → mem → data_in → charpointer → tedaddress)
    // converges because memory is deterministic (same address → same data).
    /* verilator lint_off UNOPTFLAT */
    wire [7:0] dma_mem = mem_read(ted0.tedaddress, ted_cs0, ted_cs1);
    /* verilator lint_on UNOPTFLAT */

    // Data bus to TED: use addr_out_reg (stable within cycle, no aec glitches)
    // for all reads.  Only switch to cpu_do during CPU writes.
    // FPGATED uses data_in combinationally (charpointer during badline2),
    // so the bus MUST be stable — addr_out_reg only changes at cycle_end.
    // Use cpuenable (not aec) for write detection — aec glitches cause
    // cpu_do to leak onto the bus during DMA when CPU is frozen in write state.
    wire [7:0] data_bus = (ted_cpuenable && cpu_we) ? cpu_do
                                                    : mem_read(ted0.addr_out_reg, ted_cs0, ted_cs1);

    // RAM writes: CPU writes when AEC=1 (CPU owns bus) and WE=1
    // Game loader also writes during copy phase
    always @(posedge clk) begin
`ifdef GAME_PRG
        if (!rst) begin
            game_copying <= 0; game_loaded <= 0; game_copy_addr <= GAME_START;
        end else begin
            if (ted_cpuenable && cpu_we && sel_gameload && !game_loaded)
                game_copying <= 1;
            if (game_copying && !game_loaded) begin
                main_ram[game_copy_addr] <= game_rom[game_copy_addr];
                if (game_copy_addr == GAME_END) begin
                    game_loaded <= 1; game_copying <= 0;
                end else
                    game_copy_addr <= game_copy_addr + 1;
            end
        end
`endif
        // Write RAM: addresses below $8000 are always RAM.
        // Above $8000: write if both cs0 and cs1 are high (RAM mode, not ROM).
        if (ted_cpuenable && cpu_we) begin
            if (!cpu_ab[15] || (ted_cs0 && ted_cs1))
                main_ram[cpu_ab] <= cpu_do;
        end
    end

    // ================================================================
    //  UART (keyboard input)
    // ================================================================
    reg  [7:0] txdata;
    reg  txen;
    wire txbusy;
    wire [7:0] rxdata;
    wire rxen;
    reg  rxen0;

    uart uart0(
        .clk(clk), .rst(rst),
        .tx(tx), .rx(rx),
        .txdata(txdata), .txen(txen), .txbusy(txbusy),
        .rxdata(rxdata), .rxen(rxen)
    );

    always @(posedge clk or negedge rst)
        if (!rst) rxen0 <= 0;
        else      rxen0 <= rxen;

    // ================================================================
    //  Keyboard matrix (UART → 8x8 matrix → TED k input)
    // ================================================================
    reg [7:0] key_matrix [0:7];
    reg [17:0] key_timer;
    reg [7:0] kbd_row_latch;  // active keyboard row from TED

    integer i;

    // TED writes to $FD30 for keyboard row select.
    // We detect this when TED addresses $FD30 during a CPU write.
    always @(posedge clk or negedge rst)
        if (!rst) begin
            kbd_row_latch <= 8'hFF;
            for (i = 0; i < 8; i = i + 1) key_matrix[i] <= 8'h00;
            key_timer <= 0;
        end else begin
            // Capture keyboard row select: CPU writes to $FD30
            if (ted_aec && cpu_we && ted_cpuenable && cpu_ab == 16'hFD30)
                kbd_row_latch <= cpu_do;

            // Also capture from TED keylatch write ($FF08)
            if (ted_aec && cpu_we && ted_cpuenable &&
                (cpu_ab[15:8] == 8'hFF) && (cpu_ab[5:0] == 6'h08))
                kbd_row_latch <= cpu_do;

            // Key auto-release
            if (key_timer > 0) begin
                key_timer <= key_timer - 1;
                if (key_timer == 1)
                    for (i = 0; i < 8; i = i + 1) key_matrix[i] <= 8'h00;
            end

            // UART key input
            if (rxen != rxen0 && kbd_map_valid) begin
                for (i = 0; i < 8; i = i + 1) key_matrix[i] <= 8'h00;
                key_matrix[kbd_map_row][kbd_map_col] <= 1'b1;
                key_timer <= 18'd80000;
            end
        end

    // Scan keyboard matrix based on row latch
    reg [7:0] kbd_scan;
    always @* begin
        kbd_scan = 8'hFF;
        for (i = 0; i < 8; i = i + 1)
            if (!kbd_row_latch[i])
                kbd_scan = kbd_scan & ~key_matrix[i];
    end

    // ASCII → Plus/4 matrix (from KERNAL ROM table at $E026)
    reg [2:0] kbd_map_row, kbd_map_col;
    reg       kbd_map_valid;
    always @* begin
        kbd_map_valid = 1; kbd_map_row = 0; kbd_map_col = 0;
        case (rxdata)
            8'h61: begin kbd_map_row=1; kbd_map_col=2; end  // a
            8'h62: begin kbd_map_row=3; kbd_map_col=4; end  // b
            8'h63: begin kbd_map_row=2; kbd_map_col=4; end  // c
            8'h64: begin kbd_map_row=2; kbd_map_col=2; end  // d
            8'h65: begin kbd_map_row=1; kbd_map_col=6; end  // e
            8'h66: begin kbd_map_row=2; kbd_map_col=5; end  // f
            8'h67: begin kbd_map_row=3; kbd_map_col=2; end  // g
            8'h68: begin kbd_map_row=3; kbd_map_col=5; end  // h
            8'h69: begin kbd_map_row=4; kbd_map_col=1; end  // i
            8'h6A: begin kbd_map_row=4; kbd_map_col=2; end  // j
            8'h6B: begin kbd_map_row=4; kbd_map_col=5; end  // k
            8'h6C: begin kbd_map_row=5; kbd_map_col=2; end  // l
            8'h6D: begin kbd_map_row=4; kbd_map_col=4; end  // m
            8'h6E: begin kbd_map_row=4; kbd_map_col=7; end  // n
            8'h6F: begin kbd_map_row=4; kbd_map_col=6; end  // o
            8'h70: begin kbd_map_row=5; kbd_map_col=1; end  // p
            8'h71: begin kbd_map_row=7; kbd_map_col=6; end  // q
            8'h72: begin kbd_map_row=2; kbd_map_col=1; end  // r
            8'h73: begin kbd_map_row=1; kbd_map_col=5; end  // s
            8'h74: begin kbd_map_row=2; kbd_map_col=6; end  // t
            8'h75: begin kbd_map_row=3; kbd_map_col=6; end  // u
            8'h76: begin kbd_map_row=3; kbd_map_col=7; end  // v
            8'h77: begin kbd_map_row=1; kbd_map_col=1; end  // w
            8'h78: begin kbd_map_row=2; kbd_map_col=7; end  // x
            8'h79: begin kbd_map_row=3; kbd_map_col=1; end  // y
            8'h7A: begin kbd_map_row=1; kbd_map_col=4; end  // z
            8'h30: begin kbd_map_row=4; kbd_map_col=3; end  // 0
            8'h31: begin kbd_map_row=7; kbd_map_col=0; end  // 1
            8'h32: begin kbd_map_row=7; kbd_map_col=3; end  // 2
            8'h33: begin kbd_map_row=1; kbd_map_col=0; end  // 3
            8'h34: begin kbd_map_row=1; kbd_map_col=3; end  // 4
            8'h35: begin kbd_map_row=2; kbd_map_col=0; end  // 5
            8'h36: begin kbd_map_row=2; kbd_map_col=3; end  // 6
            8'h37: begin kbd_map_row=3; kbd_map_col=0; end  // 7
            8'h38: begin kbd_map_row=3; kbd_map_col=3; end  // 8
            8'h39: begin kbd_map_row=4; kbd_map_col=0; end  // 9
            8'h0D: begin kbd_map_row=0; kbd_map_col=1; end  // RETURN
            8'h20: begin kbd_map_row=7; kbd_map_col=4; end  // SPACE
            8'h08: begin kbd_map_row=0; kbd_map_col=0; end  // DEL
            8'h7F: begin kbd_map_row=0; kbd_map_col=0; end  // DEL
            8'h2A: begin kbd_map_row=6; kbd_map_col=1; end  // *
            8'h2B: begin kbd_map_row=6; kbd_map_col=6; end  // +
            8'h2C: begin kbd_map_row=5; kbd_map_col=7; end  // ,
            8'h2D: begin kbd_map_row=5; kbd_map_col=6; end  // -
            8'h2E: begin kbd_map_row=5; kbd_map_col=4; end  // .
            8'h2F: begin kbd_map_row=6; kbd_map_col=7; end  // /
            8'h3A: begin kbd_map_row=5; kbd_map_col=5; end  // :
            8'h3B: begin kbd_map_row=6; kbd_map_col=2; end  // ;
            8'h3D: begin kbd_map_row=6; kbd_map_col=5; end  // =
            8'h40: begin kbd_map_row=0; kbd_map_col=7; end  // @
            default: kbd_map_valid = 0;
        endcase
    end

    // ================================================================
    //  TED instantiation
    // ================================================================
    ted ted0(
        .clk(clk),
        .addr_in(cpu_ab),
        .addr_out(ted_addr_out),
        .data_in(data_bus),
        .data_out(ted_data_out),
        .rw(ted_cpuenable ? ~cpu_we : 1'b1),  // Only signal write during CPU enable; frozen WE leaks corrupt regs
        .cpuclk(ted_cpuclk),
        .color(ted_color),
        .csync(ted_csync),
        .irq(ted_irq),
        .ba(ted_ba),
        .mux(ted_mux),
        .ras(ted_ras),
        .cas(ted_cas),
        .cs0(ted_cs0),
        .cs1(ted_cs1),
        .aec(ted_aec),
        .snd(ted_snd),
        .digi_sound(ted_digi_sound),
        .k(kbd_scan),
        .cpuenable(ted_cpuenable),
        .pal(ted_pal),
        .hsync(ted_hsync),
        .vsync(ted_vsync),
        .burst(ted_burst),
        .even(ted_even),
        .data_oe(ted_data_oe)
    );

    // ================================================================
    //  Video: TED 7-bit color → RGB565 → framebuffer → LCD
    // ================================================================

    // TED color (7 bits: luma[6:4] + chroma[3:0]) → RGB565
    // TED 7-bit color → RGB565 lookup
    // color[6:4] = luminance (0-7), color[3:0] = chrominance (0-15)
    // Same palette function as plus4_ted.v
    function [15:0] ted_rgb565;
        input [6:0] c;
        reg [2:0] luma;
        reg [3:0] chroma;
        reg [7:0] y, r, g, b;
        reg signed [8:0] rs, gs, bs;
        begin
            luma = c[6:4]; chroma = c[3:0];
            case (luma)
                3'd0: y=8'd0;   3'd1: y=8'd30;  3'd2: y=8'd55;  3'd3: y=8'd85;
                3'd4: y=8'd115; 3'd5: y=8'd150; 3'd6: y=8'd190; 3'd7: y=8'd235;
            endcase
            if (chroma <= 4'd1) begin
                r = (chroma==0) ? 8'd0 : y; g = r; b = r;
            end else begin
                case (chroma)
                    4'd2:  begin rs=9'd80;  gs=-9'd40; bs=-9'd50; end
                    4'd3:  begin rs=-9'd60; gs=9'd30;  bs=9'd40;  end
                    4'd4:  begin rs=9'd50;  gs=-9'd50; bs=9'd70;  end
                    4'd5:  begin rs=-9'd50; gs=9'd50;  bs=-9'd50; end
                    4'd6:  begin rs=-9'd30; gs=-9'd30; bs=9'd90;  end
                    4'd7:  begin rs=9'd40;  gs=9'd40;  bs=-9'd70; end
                    4'd8:  begin rs=9'd70;  gs=-9'd10; bs=-9'd60; end
                    4'd9:  begin rs=9'd50;  gs=-9'd10; bs=-9'd50; end
                    4'd10: begin rs=-9'd10; gs=9'd50;  bs=-9'd50; end
                    4'd11: begin rs=9'd60;  gs=-9'd40; bs=9'd10;  end
                    4'd12: begin rs=-9'd50; gs=9'd30;  bs=9'd10;  end
                    4'd13: begin rs=-9'd20; gs=-9'd10; bs=9'd60;  end
                    4'd14: begin rs=9'd20;  gs=-9'd20; bs=9'd80;  end
                    4'd15: begin rs=-9'd30; gs=9'd50;  bs=-9'd30; end
                    default: begin rs=0; gs=0; bs=0; end
                endcase
                r = ({1'b0,y}+rs > 255) ? 8'd255 : ({1'b0,y}+rs < 0) ? 8'd0 : y+rs[7:0];
                g = ({1'b0,y}+gs > 255) ? 8'd255 : ({1'b0,y}+gs < 0) ? 8'd0 : y+gs[7:0];
                b = ({1'b0,y}+bs > 255) ? 8'd255 : ({1'b0,y}+bs < 0) ? 8'd0 : y+bs[7:0];
            end
            ted_rgb565 = {r[7:3], g[7:2], b[7:3]};
        end
    endfunction

    // Framebuffer: capture TED output into a full-frame buffer, display via LCD.
    // TED PAL: 456 pixels/line × 312 lines. Pixel clock = system_clk / 4.
    // LCD: 480×272.

    // Single framebuffer (512×312 × 16-bit).
    reg [15:0] framebuf [0:512*312-1];

    reg [8:0] prev_hcounter;
    wire pixel_tick = (ted0.hcounter != prev_hcounter);
    wire [17:0] fb_wr_addr = {ted0.videoline, ted0.hcounter};

    always @(posedge clk or negedge rst)
        if (!rst) begin
            prev_hcounter <= 0;
        end else begin
            prev_hcounter <= ted0.hcounter;

            if (pixel_tick && ted0.hcounter < 456 && ted0.videoline < 312)
                framebuf[fb_wr_addr] <= ted_rgb565(ted_color);
        end

    // LCD output
    wire [10:0] lcd_col, lcd_row;

    lcd_out lcd0(
        .clk(clk), .rst(rst),
        .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .row(lcd_row), .col(lcd_col)
    );

    assign lcd_pwm = 1'b1;
    assign lcd_clk = clk;

    // Map LCD (480×272) to TED framebuffer (456×312)
    // Center horizontally: LCD col 0-479 → TED col 0-455 (scale ~0.95, just crop edges)
    // Vertically: LCD row 0-271 → TED row 20-291 (skip top 20 lines of border)
    wire [8:0] fb_x = lcd_col[8:0];
    wire [8:0] fb_y = lcd_row[8:0] + 9'd20;
    wire in_fb = (fb_x < 456) && (fb_y < 312);

    always @(posedge clk or negedge rst)
        if (!rst)
            lcd_data <= 0;
        else if (lcd_de)
            lcd_data <= in_fb ? framebuf[{fb_y, fb_x}] : 16'h0000;

    // ================================================================
    //  Debug + misc
    // ================================================================
    reg [31:0] frame_count;
    reg ted_vsync_prev;
    always @(posedge clk or negedge rst)
        if (!rst) begin frame_count <= 0; ted_vsync_prev <= 1; end
        else begin
            ted_vsync_prev <= ted_vsync;
            if (!ted_vsync && ted_vsync_prev) frame_count <= frame_count + 1;
        end

`ifdef SIMULATION
    reg [31:0] dbg_cycle;
    always @(posedge clk or negedge rst)
        if (!rst) begin
            dbg_cycle <= 0; txen <= 0; txdata <= 0; led1 <= 0; led2 <= 0;
        end else begin
            dbg_cycle <= dbg_cycle + 1;
            // Track vsync edges and frame count
            if (!ted_vsync && ted_vsync_prev)
                $display("cyc=%0d VSYNC_FALL fc=%0d", dbg_cycle, frame_count);
            if (ted_vsync && !ted_vsync_prev && dbg_cycle < 5000000)
                $display("cyc=%0d VSYNC_RISE", dbg_cycle);
            // DEBUG: Watch 16 pixels at hcounter=100-115, videoline=50 across frames 5-8
            // Search for "COMMODORE" pattern ($03 $0F $0D $0D $0F) in RAM
            // Check every 1KB boundary
            if (frame_count == 100 && !ted_vsync && ted_vsync_prev) begin
                for (i = 0; i < 64; i = i + 1) begin
                    if (main_ram[{i[5:0], 10'd0}] == 8'h03 &&
                        main_ram[{i[5:0], 10'd1}] == 8'h0F &&
                        main_ram[{i[5:0], 10'd2}] == 8'h0D)
                        $display("FOUND at $%04x: %02x %02x %02x %02x",
                            {i[5:0], 10'd0},
                            main_ram[{i[5:0], 10'd0}], main_ram[{i[5:0], 10'd1}],
                            main_ram[{i[5:0], 10'd2}], main_ram[{i[5:0], 10'd3}]);
                end
            end
        end
`else
    always @(posedge clk or negedge rst)
        if (!rst) begin
            txen <= 0; txdata <= 0; led1 <= 0; led2 <= 0;
        end
`endif

endmodule
