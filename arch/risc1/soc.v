
`include "project.vh"

module soc(
    input clk,
    input rst,
    output led1,
    output reg led2,

    input rx,
    output tx,

    output i2s_en,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_mclk,
    output i2s_data,

    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output reg [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk
);

    // ---- CPU signals ----
    wire [9:0] instr_addr;
    wire [17:0] instr_data;
    wire [7:0] port_addr, port_data_out;
    reg  [7:0] port_data_in;
    wire port_rd, port_wr;
    wire [127:0] cpuDbg;

    // ---- Instruction ROM (1K x 18) ----
    dual_port_ram_1k_18 #(
`include "romL.vh"
    ) rom0(
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[9:0]), .din_a(18'b0), .dout_a(instr_data),
        .clk_b(clk), .we_b(1'b0),
        .addr_b(10'b0), .din_b(18'b0)
    );

    // ---- Debugger + UART ----
    reg  [7:0] txdata;
    reg  txen, rxrdy, rxen0, rxovf;
    wire txbusy, rxen;
    wire [7:0] rxdata;

`ifdef CPU_DEBUGGER
    wire rxenA;
    wire [7:0] rxdataA;
    wire [7:0] dbg_txdata;
    wire dbg_txen;
    wire cpu_clk_en;
    wire dbg_rst_req;
    wire dbg_led;

    uart uart0(
        .clk(clk), .rst(rst),
        .tx(tx), .rx(rx),
        .txdata(txdata), .txen(txen), .txbusy(txbusy),
        .rxdata(rxdataA), .rxen(rxenA)
    );

    debugger debug0(
        .clk(clk), .rst(rst),
        .rxen_in(rxenA), .rxdata_in(rxdataA),
        .rxen_out(rxen), .rxdata_out(rxdata),
        .txen(dbg_txen), .txdata(dbg_txdata),
        .cpuDbg(cpuDbg),
        .clk_en(cpu_clk_en),
        .cpu_rst_req(dbg_rst_req),
        .led(dbg_led)
    );

    wire cpu_rst = rst & (~dbg_rst_req);
`else
    uart uart0(
        .clk(clk), .rst(rst),
        .tx(tx), .rx(rx),
        .txdata(txdata), .txen(txen), .txbusy(txbusy),
        .rxdata(rxdata), .rxen(rxen)
    );

    wire cpu_rst = rst;
    wire cpu_clk_en = 1'b1;
    wire dbg_led = 1'b0;
    wire dbg_txen = 1'b0;
    wire [7:0] dbg_txdata = 8'b0;
`endif

    // ---- RISC1 CPU ----
    cpu_risc1 cpu0(
        .clk(clk), .clk_en(cpu_clk_en), .rst(cpu_rst),
        .instr_addr(instr_addr), .instr_data(instr_data),
        .port_addr(port_addr), .port_data_in(port_data_in), .port_data_out(port_data_out),
        .port_rd(port_rd), .port_wr(port_wr),
        .cpuDbg(cpuDbg)
    );

    // ---- LED output (debugger overrides led1 when in debug mode) ----
    reg sled1;
    assign led1 = dbg_led ? 1'b1 : sled1;

    // ---- LCD timing generator ----
    wire [10:0] lcd_col, lcd_row;

    lcd_out lcd0(
        .clk(clk), .rst(rst),
        .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .row(lcd_row), .col(lcd_col)
    );

    // ---- LCD character display ----
    reg  [23:0] lchar_addr;
    reg  [15:0] lchar_data;
    reg  lchar_we;
    wire [15:0] char_pixel_out;
    wire        char_active;

    lcd_char lcdc0(
        .clk(clk), .rst(rst),
        .ctrl_addr(lchar_addr), .ctrl_data(lchar_data), .ctrl_we(lchar_we),
        .row(lcd_row), .col(lcd_col),
        .char_pixel_out(char_pixel_out), .char_active(char_active)
    );

    // ---- Game RAM (mirror of text buffer, CPU-readable) ----
    // Port A: continuous read at txt_addr_reg (CPU reads via port 0x10)
    // Port B: write when CPU writes char via port 0x12/0x13
    reg  [9:0] txt_addr_reg;
    wire [17:0] game_dout_raw;
    wire [7:0]  game_dout = game_dout_raw[7:0];
    reg  game_we;
    reg  [9:0] game_wr_addr;
    reg  [7:0] game_wr_data;

    ram_1k_18 gameram(
        .clk_a(clk), .we_a(1'b0),
        .addr_a(txt_addr_reg), .din_a(18'b0), .dout_a(game_dout_raw),
        .clk_b(clk), .we_b(game_we),
        .addr_b(game_wr_addr), .din_b({10'b0, game_wr_data})
    );

    // ---- Timer (free-running 8-bit tick counter) ----
    reg [23:0] prescaler;
    reg [7:0]  tick;

    // ---- LFSR random number generator (16-bit, free-running) ----
    reg [15:0] lfsr;

    // ---- Audio synthesizer (3-channel, SID-style) ----
    wire audio_port_range = (port_addr[7:4] == 4'h4);     /* ports 0x40..0x4F */
    wire [7:0] audio_rdata;

    audio audio0(
        .clk(clk), .rst(rst),
        .reg_addr(port_addr[3:0]),
        .reg_wdata(port_data_out),
        .reg_we(port_wr && audio_port_range),
        .reg_rdata(audio_rdata),
        .i2s_data(i2s_data), .i2s_mclk(i2s_mclk),
        .i2s_lrck(i2s_lrck), .i2s_bclk(i2s_bclk),
        .audio_en(i2s_en)
    );

    // ---- LCD output mux ----
    assign lcd_pwm = 1'b1;
    assign lcd_clk = clk;
    always @(posedge clk or negedge rst)
    if (!rst)
        lcd_data <= 0;
    else if (lcd_de)
        lcd_data <= char_active ? char_pixel_out : 16'h0000;

    // ---- Hardware init: configure lcd_char after reset ----
    // Screen: 32 x 16 chars, centered on 480x272 LCD
    // X = 112, Y = 8, chnumx = 32, chnumy = 16, enabled
    reg [2:0] init_cnt;

    reg dbg_txen0;

    // ---- Main SoC logic ----
    always @(posedge clk or negedge rst)
    if (!rst) begin
        {sled1, led2, port_data_in, txdata, txen, rxen0, rxrdy, rxovf, dbg_txen0} <= 0;
        {lchar_addr, lchar_data, lchar_we} <= 0;
        {txt_addr_reg, game_we, game_wr_addr, game_wr_data} <= 0;
        {prescaler, tick} <= 0;
        lfsr <= 16'hACE1;
        init_cnt <= 0;
    end else begin
        rxen0   <= rxen;
        lchar_we <= 0;
        game_we  <= 0;
        dbg_txen0 <= dbg_txen;

        // Timer prescaler
        if (prescaler == `TIMER_PRESCALE) begin
            prescaler <= 0;
            tick <= tick + 1;
        end else
            prescaler <= prescaler + 1;

        // LFSR (x^16 + x^15 + x^13 + x^4 + 1)
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3]};

        // ---- LCD char hardware init (first 4 cycles after reset) ----
        if (init_cnt < 4) begin
            init_cnt <= init_cnt + 1;
            lchar_we <= 1;
            case (init_cnt)
                0: begin lchar_addr <= 24'h0C0000; lchar_data <= 16'd112;   end  // X = 112
                1: begin lchar_addr <= 24'h0C0001; lchar_data <= 16'd8;     end  // Y = 8
                2: begin lchar_addr <= 24'h0C0002; lchar_data <= 16'd32;    end  // chnumx = 32
                3: begin lchar_addr <= 24'h0C0003; lchar_data <= 16'h8010;  end  // enabled=1, chnumy=16
            endcase
        end else begin

            // ---- Port Write handling ----
            if (port_wr) begin
                case (port_addr)
                    8'h00: begin                                    // LED set
                        if (port_data_out[0]) sled1 <= 1;
                        if (port_data_out[1]) led2 <= 1;
                    end
                    8'h01: begin                                    // LED clear
                        if (port_data_out[0]) sled1 <= 0;
                        if (port_data_out[1]) led2 <= 0;
                    end
                    8'h10: txt_addr_reg[7:0]  <= port_data_out;    // text addr low
                    8'h11: txt_addr_reg[9:8]  <= port_data_out[1:0]; // text addr high
                    8'h12: begin                                    // write char + auto-increment
                        lchar_addr   <= {8'h0E, 6'b0, txt_addr_reg};
                        lchar_data   <= {8'h00, port_data_out};
                        lchar_we     <= 1;
                        game_wr_addr <= txt_addr_reg;
                        game_wr_data <= port_data_out;
                        game_we      <= 1;
                        txt_addr_reg <= txt_addr_reg + 1;
                    end
                    8'h13: begin                                    // write char (no auto-inc)
                        lchar_addr   <= {8'h0E, 6'b0, txt_addr_reg};
                        lchar_data   <= {8'h00, port_data_out};
                        lchar_we     <= 1;
                        game_wr_addr <= txt_addr_reg;
                        game_wr_data <= port_data_out;
                        game_we      <= 1;
                    end
                    8'h30: begin                                    // UART TX
                        txdata <= port_data_out;
                        txen   <= ~txen;
                    end
                endcase
            end
            else if (dbg_txen != dbg_txen0) begin               // Debugger TX
                txdata <= dbg_txdata;
                txen   <= ~txen;
            end

            // ---- UART RX edge detection ----
            if (rxen != rxen0) begin
                if (rxrdy) rxovf <= 1;
                rxrdy <= 1;
            end

            // ---- Port Read handling ----
            if (port_rd) begin
                case (port_addr)
                    8'h10: port_data_in <= game_dout;               // read char at txt_addr
                    8'h18: port_data_in <= tick;                    // timer tick
                    8'h1A: port_data_in <= lfsr[7:0];              // random number
                    8'h20: port_data_in <= {5'b0, txbusy, rxovf, rxrdy}; // UART status
                    8'h21: begin                                    // UART RX data
                        port_data_in <= rxdata;
                        rxrdy <= 0;
                    end
                    default:
                        if (audio_port_range)
                            port_data_in <= audio_rdata;            // audio status
                endcase
            end

        end
    end

endmodule
