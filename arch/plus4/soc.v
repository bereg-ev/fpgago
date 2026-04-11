
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
    //  Clock enable — divide system clock for 7501/8501 CPU
    // ================================================================
    reg [5:0] clk_div;
    always @(posedge clk or negedge rst)
        if (!rst) clk_div <= 0;
        else      clk_div <= (clk_div == `CPU_CLOCK_DIV - 1) ? 6'd0 : clk_div + 1;

    wire cpu_rdy = (clk_div == 0);

    // ================================================================
    //  6502-compatible CPU (7501/8501)
    // ================================================================
    wire [15:0] cpu_ab;
    wire [7:0]  cpu_do;
    reg  [7:0]  cpu_di;
    wire        cpu_we;
    wire        ted_irq;

    cpu cpu0(
        .clk(clk), .reset(~rst),
        .AB(cpu_ab), .DI(cpu_di), .DO(cpu_do),
        .WE(cpu_we), .IRQ(ted_irq), .NMI(1'b0), .RDY(cpu_rdy)
    );

    wire cpu_write = cpu_we & cpu_rdy;

    // ================================================================
    //  Address decode
    // ================================================================
    wire rom_enabled;  // from TED ($FF3E/$FF3F)

    wire sel_ram     = 1'b1;  // RAM underlies everything

    // TED registers: $FD00-$FD3F and $FF00-$FF3F (64 bytes each)
    wire sel_ted_fd  = (cpu_ab[15:8] == 8'hFD) & (cpu_ab[7:6] == 2'b00);  // $FD00-$FD3F
    wire sel_ted_ff  = (cpu_ab[15:8] == 8'hFF) & (cpu_ab[7:6] == 2'b00);  // $FF00-$FF3F
    wire sel_ted     = sel_ted_fd | sel_ted_ff;

    // ROM banking: $FF3E/$FF3F (within TED range, handled by TED write logic)
    wire sel_bank    = sel_ted_ff & (cpu_ab[5:1] == 5'b11111);

    // ROMs (active when rom_enabled, except TED register windows)
    wire sel_basic   = rom_enabled & (cpu_ab[15:14] == 2'b10);            // $8000-$BFFF
    wire sel_kernal  = rom_enabled & (cpu_ab[15:14] == 2'b11) & !sel_ted; // $C000-$FFFF minus TED

    // ================================================================
    //  Main RAM — 64KB ($0000-$FFFF, underlies ROM/IO)
    // ================================================================
    reg [7:0] main_ram [0:65535];

`ifdef GAME_PRG
    reg [7:0] game_rom [0:65535];
    initial $readmemh("../roms/game.hex", game_rom);
`include "../roms/game_params.vh"

    reg        game_copying;
    reg        game_loaded;
    reg [15:0] game_copy_addr;
    wire       sel_gameload = sel_ted_ff & (cpu_ab[7:0] == 8'hF0);

    always @(posedge clk or negedge rst)
        if (!rst) begin
            game_copying   <= 0;
            game_loaded    <= 0;
            game_copy_addr <= {1'b0, GAME_START};
        end else begin
            if (cpu_write && sel_gameload && !game_loaded)
                game_copying <= 1;
            if (game_copying && !game_loaded) begin
                main_ram[game_copy_addr] <= game_rom[game_copy_addr];
                if (game_copy_addr == {1'b0, GAME_END}) begin
                    game_loaded  <= 1;
                    game_copying <= 0;
                end else
                    game_copy_addr <= game_copy_addr + 1;
            end
            if (cpu_write && sel_ram && !sel_ted)
                main_ram[cpu_ab] <= cpu_do;
        end
`else
    always @(posedge clk)
        if (cpu_write & sel_ram & !sel_ted)
            main_ram[cpu_ab] <= cpu_do;
`endif

    // Video read ports (registered, 1-cycle latency)
    wire [9:0] vid_screen_addr, vid_color_addr;
    reg  [7:0] vid_screen_data, vid_color_data;

    // Screen RAM at $0C00, Color RAM at $0800 (Plus/4 defaults)
    always @(posedge clk) begin
        vid_screen_data <= main_ram[{6'b000011, vid_screen_addr}];  // $0C00 + offset
        vid_color_data  <= main_ram[{6'b000010, vid_color_addr}];   // $0800 + offset
    end

    // ================================================================
    //  BASIC ROM — 16KB ($8000-$BFFF)
    // ================================================================
    reg [7:0] basic_rom [0:16383];
    initial $readmemh("../roms/basic.hex", basic_rom);

    // ================================================================
    //  KERNAL ROM — 16KB ($C000-$FFFF, I/O windows at $FD/$FF override)
    // ================================================================
    reg [7:0] kernal_rom [0:16383];
    initial $readmemh("../roms/kernal.hex", kernal_rom);

    // ================================================================
    //  Character ROM — 2KB (for TED video, not directly CPU-addressable)
    //  The c2lo-364.bin is 16KB but we only use the first 2KB.
    // ================================================================
    reg [7:0] char_rom [0:2047];
    initial $readmemh("../roms/chargen.hex", char_rom);

    wire [10:0] vid_char_addr;
    reg  [7:0]  vid_char_data;
    always @(posedge clk)
        vid_char_data <= char_rom[vid_char_addr];

    // ================================================================
    //  UART
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
    //  LCD timing generator
    // ================================================================
    wire [10:0] lcd_col, lcd_row;

    lcd_out lcd0(
        .clk(clk), .rst(rst),
        .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .row(lcd_row), .col(lcd_col)
    );

    // ================================================================
    //  TED chip
    // ================================================================
    wire [7:0] ted_dout;
    wire [15:0] vid_pixel;
    wire        vid_active;

    plus4_ted ted0(
        .clk(clk), .rst(rst),
        .addr(cpu_ab[5:0]),
        .din(cpu_do),
        .dout(ted_dout),
        .we(cpu_write & (sel_ted | sel_bank)),
        .rd(sel_ted),
        .cpu_clk_en(cpu_rdy),
        .row(lcd_row), .col(lcd_col),
        .screen_addr(vid_screen_addr),
        .screen_data(vid_screen_data),
        .color_addr(vid_color_addr),
        .color_data(vid_color_data),
        .char_addr(vid_char_addr),
        .char_data(vid_char_data),
        .pixel_out(vid_pixel),
        .pixel_active(vid_active),
        .uart_rx_data(rxdata),
        .uart_rx_valid(rxen != rxen0),
        .irq(ted_irq),
        .rom_enabled(rom_enabled),
        .lcd_vsync(lcd_vsync),
        .cursor_row(main_ram[16'h00CD][4:0]),
        .cursor_col(main_ram[16'h00CA][5:0])
    );

    // LCD output
    assign lcd_pwm = 1'b1;
    assign lcd_clk = clk;
    always @(posedge clk or negedge rst)
        if (!rst)
            lcd_data <= 0;
        else if (lcd_de)
            lcd_data <= vid_active ? vid_pixel : ted_color_border;

    // Border color from TED register $FF19
    wire [15:0] ted_color_border = 16'h0000;  // simplified: black border

    // ================================================================
    //  CPU data-in mux (registered, RDY-gated)
    // ================================================================
    reg [7:0] cpu_di_comb;
    always @* begin
        if (sel_ted)
            cpu_di_comb = ted_dout;
        else if (sel_basic)
            cpu_di_comb = basic_rom[cpu_ab[13:0]];
        else if (sel_kernal)
            cpu_di_comb = kernal_rom[cpu_ab[13:0]];
        else
            cpu_di_comb = main_ram[cpu_ab];
    end

    always @(posedge clk)
        if (cpu_rdy)
            cpu_di <= cpu_di_comb;

    // ================================================================
    //  Frame counter + debug
    // ================================================================
    reg [31:0] frame_count;
    always @(posedge clk or negedge rst)
        if (!rst) frame_count <= 0;
        else if (lcd_row == 0 && lcd_col == 0)
            frame_count <= frame_count + 1;

`ifdef SIMULATION
    reg [31:0] dbg_cycle;
    always @(posedge clk or negedge rst)
        if (!rst) begin
            dbg_cycle <= 0;
            txen <= 0; txdata <= 0; led1 <= 0; led2 <= 0;
        end else begin
            dbg_cycle <= dbg_cycle + 1;

            ;
        end
`else
    always @(posedge clk or negedge rst)
        if (!rst) begin
            txen <= 0; txdata <= 0; led1 <= 0; led2 <= 0;
        end
`endif

endmodule
