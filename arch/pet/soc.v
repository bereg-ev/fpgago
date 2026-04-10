
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
    //  Clock enable — divide system clock down to ~1 MHz for 6502
    // ================================================================
    reg [5:0] clk_div;
    always @(posedge clk or negedge rst)
        if (!rst)
            clk_div <= 0;
        else
            clk_div <= (clk_div == `CPU_CLOCK_DIV - 1) ? 6'd0 : clk_div + 1;

    wire cpu_rdy = (clk_div == 0);

    // ================================================================
    //  6502 CPU
    // ================================================================
    wire [15:0] cpu_ab;
    wire [7:0]  cpu_do;
    reg  [7:0]  cpu_di;
    wire        cpu_we;

    wire        via_irq;
    wire        pia1_irq;
    wire        cpu_irq = via_irq | pia1_irq;

    cpu cpu0(
        .clk(clk),
        .reset(~rst),           // Arlet 6502: active-high reset
        .AB(cpu_ab),
        .DI(cpu_di),
        .DO(cpu_do),
        .WE(cpu_we),
        .IRQ(cpu_irq),
        .NMI(1'b0),
        .RDY(cpu_rdy)
    );

    wire cpu_write = cpu_we & cpu_rdy;

    // ================================================================
    //  Address decode
    // ================================================================
    wire sel_ram    = (cpu_ab[15] == 1'b0);                         // $0000-$7FFF
    wire sel_screen = (cpu_ab[15:10] == 6'b100000);                 // $8000-$83FF
    wire sel_io     = (cpu_ab[15:8] == 8'hE8);                     // $E800-$E8FF
    wire sel_basic  = (cpu_ab[15:13] == 3'b110);                   // $C000-$DFFF
    wire sel_kernal = (cpu_ab[15:12] == 4'hF)                      // $F000-$FFFF
                    | (cpu_ab[15:11] == 5'b11100 && !sel_io);      // $E000-$E7FF, $E900-$EFFF

    // I/O sub-decode ($E8xx)
    wire sel_crtc   = sel_io & (cpu_ab[7:4] == 4'h0);             // $E800-$E80F
    wire sel_pia1   = sel_io & (cpu_ab[7:4] == 4'h1);             // $E810-$E81F
    wire sel_pia2   = sel_io & (cpu_ab[7:4] == 4'h2);             // $E820-$E82F
    wire sel_via    = sel_io & (cpu_ab[7:4] == 4'h4);             // $E840-$E84F

    // ================================================================
    //  Main RAM — 32KB ($0000-$7FFF)
    // ================================================================
    reg [7:0] main_ram [0:32767];

    always @(posedge clk)
        if (cpu_write & sel_ram)
            main_ram[cpu_ab[14:0]] <= cpu_do;

    // ================================================================
    //  Screen RAM — 1KB ($8000-$83FF), dual-read: CPU + video
    // ================================================================
    reg [7:0] screen_ram [0:1023];

    always @(posedge clk)
        if (cpu_write & sel_screen)
            screen_ram[cpu_ab[9:0]] <= cpu_do;

    // Video port: registered read (1-cycle latency)
    wire [9:0] vid_screen_addr;
    reg  [7:0] vid_screen_data;
    always @(posedge clk)
        vid_screen_data <= screen_ram[vid_screen_addr];

    // ================================================================
    //  BASIC ROM — 8KB ($C000-$DFFF)
    // ================================================================
    reg [7:0] basic_rom [0:8191];
    initial $readmemh("../roms/basic.hex", basic_rom);

    // ================================================================
    //  KERNAL ROM — 8KB ($E000-$FFFF, I/O window at $E800 overrides)
    // ================================================================
    reg [7:0] kernal_rom [0:8191];
    initial $readmemh("../roms/kernal.hex", kernal_rom);

    // ================================================================
    //  Character ROM — 2KB (for video, not CPU-addressable)
    // ================================================================
    reg [7:0] char_rom [0:2047];
    initial $readmemh("../roms/chargen.hex", char_rom);

    // Video port: registered read (1-cycle latency)
    wire [10:0] vid_char_addr;
    reg  [7:0]  vid_char_data;
    always @(posedge clk)
        vid_char_data <= char_rom[vid_char_addr];

    // ================================================================
    //  UART (keyboard input / debug output)
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
    //  PET video output
    // ================================================================
    wire [15:0] vid_pixel;
    wire        vid_active;

    pet_video vid0(
        .clk(clk), .rst(rst),
        .row(lcd_row), .col(lcd_col),
        .screen_addr(vid_screen_addr),
        .screen_data(vid_screen_data),
        .char_addr(vid_char_addr),
        .char_data(vid_char_data),
        .pixel_out(vid_pixel),
        .pixel_active(vid_active)
    );

    // LCD output mux
    assign lcd_pwm = 1'b1;
    assign lcd_clk = clk;
    always @(posedge clk or negedge rst)
        if (!rst)
            lcd_data <= 0;
        else if (lcd_de)
            lcd_data <= vid_active ? vid_pixel : 16'h0000;

    // ================================================================
    //  PET keyboard (PIA1 — UART-to-matrix bridge)
    // ================================================================
    wire [7:0] pia1_data_out;

    pet_keyboard kbd0(
        .clk(clk), .rst(rst),
        .addr(cpu_ab[3:0]),
        .din(cpu_do),
        .dout(pia1_data_out),
        .we(cpu_write & sel_pia1),
        .rd(sel_pia1),
        .uart_rx_data(rxdata),
        .uart_rx_valid(rxen != rxen0),
        .cb1(lcd_vsync),       // vertical retrace → PIA1 CB1 (60 Hz IRQ)
        .irq(pia1_irq)
    );

    // Latch UART RX edge
    always @(posedge clk or negedge rst)
        if (!rst) rxen0 <= 0;
        else       rxen0 <= rxen;

    // ================================================================
    //  PIA2 stub — returns safe defaults
    // ================================================================
    reg [7:0] pia2_pa, pia2_pb, pia2_cra, pia2_crb;
    wire [7:0] pia2_data_out;

    always @(posedge clk or negedge rst)
        if (!rst) begin
            pia2_pa  <= 8'hFF;
            pia2_pb  <= 8'hFF;
            pia2_cra <= 8'h00;
            pia2_crb <= 8'h00;
        end else if (cpu_write & sel_pia2) begin
            case (cpu_ab[1:0])
                2'd0: pia2_pa  <= cpu_do;
                2'd1: pia2_cra <= cpu_do;
                2'd2: pia2_pb  <= cpu_do;
                2'd3: pia2_crb <= cpu_do;
            endcase
        end

    assign pia2_data_out = (cpu_ab[1:0] == 2'd0) ? pia2_pa  :
                           (cpu_ab[1:0] == 2'd1) ? pia2_cra :
                           (cpu_ab[1:0] == 2'd2) ? pia2_pb  :
                                                   pia2_crb;

    // ================================================================
    //  CRTC stub — accept writes, return 0 on reads
    // ================================================================
    reg [7:0] crtc_regs [0:15];
    reg [3:0] crtc_addr_reg;

    always @(posedge clk or negedge rst)
        if (!rst)
            crtc_addr_reg <= 0;
        else if (cpu_write & sel_crtc) begin
            if (cpu_ab[0] == 0)
                crtc_addr_reg <= cpu_do[3:0];  // address register
            else
                crtc_regs[crtc_addr_reg] <= cpu_do;  // data register
        end

    wire [7:0] crtc_data_out = (cpu_ab[0] == 0) ? {4'h0, crtc_addr_reg}
                                                 : crtc_regs[crtc_addr_reg];

    // ================================================================
    //  VIA (6522) — Timer 1 for jiffy clock IRQ
    // ================================================================
    wire [7:0] via_data_out;

    pet_via via0(
        .clk(clk), .rst(rst),
        .addr(cpu_ab[3:0]),
        .din(cpu_do),
        .dout(via_data_out),
        .we(cpu_write & sel_via),
        .rd(sel_via),
        .irq(via_irq),
        .cpu_clk_en(cpu_rdy)
    );

    // ================================================================
    //  CPU data-in mux — REGISTERED (synchronous memory interface)
    //
    //  The Arlet 6502 expects synchronous memory: data arrives one
    //  cycle after the address is presented.  With RDY alternating
    //  1/0, the CPU presents an address on an RDY=1 cycle, the
    //  registered read responds on the next cycle (RDY=0), and the
    //  CPU reads DIMUX on the following RDY=1 cycle.
    //
    //  A combinational read would create a feedback loop in states
    //  like JMP1 where AB depends on DIMUX which depends on DI.
    // ================================================================
    reg [7:0] cpu_di_comb;
    always @* begin
        casex ({sel_io, sel_basic, sel_kernal, sel_screen, sel_ram})
            5'b1xxxx:  // I/O ($E800-$E8FF)
                case (1'b1)
                    sel_crtc: cpu_di_comb = crtc_data_out;
                    sel_pia1: cpu_di_comb = pia1_data_out;
                    sel_pia2: cpu_di_comb = pia2_data_out;
                    sel_via:  cpu_di_comb = via_data_out;
                    default:  cpu_di_comb = 8'hFF;
                endcase
            5'b01xxx: cpu_di_comb = basic_rom[cpu_ab[12:0]];
            5'b001xx: cpu_di_comb = kernal_rom[cpu_ab[12:0]];
            5'b0001x: cpu_di_comb = screen_ram[cpu_ab[9:0]];
            5'b00001: cpu_di_comb = main_ram[cpu_ab[14:0]];
            default:  cpu_di_comb = 8'hFF;
        endcase
    end

    // Register the read — only update on CPU clock cycles (when RDY=1)
    // so the value stays stable during RDY=0 dead cycles and the CPU
    // sees data from the previous RDY=1 address, as synchronous BRAM does.
    always @(posedge clk)
        if (cpu_rdy)
            cpu_di <= cpu_di_comb;

    // ================================================================
    //  Debug: UART TX output of CPU PC (optional)
    // ================================================================
`ifdef SIMULATION
    reg [31:0] dbg_cycle;
    reg [31:0] frame_count;
    always @(posedge clk or negedge rst)
        if (!rst) begin
            dbg_cycle <= 0;
            frame_count <= 0;
            txen <= 0;
            txdata <= 0;
            led1 <= 0;
            led2 <= 0;
        end else begin
            dbg_cycle <= dbg_cycle + 1;

            // Count frames
            if (lcd_row == 0 && lcd_col == 0)
                frame_count <= frame_count + 1;
        end
`else
    always @(posedge clk or negedge rst)
        if (!rst) begin
            txen <= 0;
            txdata <= 0;
            led1 <= 0;
            led2 <= 0;
        end
`endif

endmodule
