
`include "project.vh"

module fpga_gameconsole (
    output led1,
    output led2,

`ifdef HW_V2
    // v2 board push buttons (active-low, external pull-ups)
    input btn_up,
    input btn_down,
    input btn_left,
    input btn_right,
    input btn_a,
    input btn_b,
    input btn_c,
    input btn_d,

    // MCU⇄FPGA link (RP2350 is SPI master; see common/qspi_slave.v).
    // Data lanes are bidirectional since the LINK_CFG multi-lane upshift:
    //   SD0 = A7   (1-lane: MOSI)      SD2 = A8  (REQ while SS high)
    //   SD1 = B7   (1-lane: MISO)      SD3 = A9  (IEC DATA in drive mode)
    input  qspi_sck,
    input  qspi_ss,
    inout  qspi_sd0,
    inout  qspi_sd1,
    inout  qspi_sd2,
    inout  qspi_sd3,

`ifdef IEC1541
    // Real-1541 IEC rides the *reclaimed sysCONFIG pins* so the QSPI link above
    // is untouched and BIOS/volume coexist with the drive:
    //   ATN  = N9 (CCLK)  — output-only via the USRMCLK primitive (no port)
    //   CLK  = N8 (config DI ball)  — bidirectional open-drain
    //   DATA = A9 = the qspi_sd3 pad above — DRIVE_MODE muxes its role
    // (MCU side: ATN=GPIO24, CLK=GPIO25, DATA=GPIO9 — see the board firmware)
    inout  iec_clk,
`endif
`endif

    output tx,
    input rx,

    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk,

    // I2S audio (MS4344 DAC, same balls on the v1 board)
    output i2s_data,
    output i2s_mclk,
    output i2s_lrck,
    output i2s_bclk,
    output i2s_en
);

    wire clk;
    reg rst;
    reg [2:0] lockCnt;

    // ECP5 OSCG: 310 MHz / 11 ≈ 28.18 MHz (same TED clock as C16)
    defparam OSCI1.DIV = `MAIN_CLK_DIVIDER;
    OSCG OSCI1 (.OSC(clk));

    always @(posedge clk)
    begin
        lockCnt <= lockCnt + 1;

        if (lockCnt == 3'b111)
            rst <= 1;
    end

    // Drive lcd_clk directly from OSCG
    assign lcd_clk = clk;

`ifdef HW_V2
    // The v2 d-pad net names are rotated 180° vs the in-hand orientation
    // (SW11 net BTN-UP is the physical DOWN button, SW13 net BTN-RIGHT is
    // physical LEFT — verified on the board 2026-07-10), so swap both axes.
    wire [7:0] btn_bus = {btn_d, btn_c, btn_b, btn_a,
                          btn_left, btn_right, btn_up, btn_down};
`else
    wire [7:0] btn_bus = 8'hFF;   // v1: no push buttons
`endif

    wire signed [15:0] audio_pcm;

`ifdef IEC1541
    // Open-drain IEC drivers: CLK on the reclaimed config pad N8; DATA on
    // the shared qspi_sd3/A9 pad (muxed by drive_1541 below): pull the line
    // LOW when *_out==0, else release (Hi-Z; the board's 10k pull-up gives
    // HIGH).  ATN is machine→drive only, driven push-pull via the USRMCLK
    // primitive (N9/CCLK is not a fabric PIO).
    wire iec_atn_out, iec_clk_out, iec_data_out;
    assign iec_clk  = iec_clk_out  ? 1'bz : 1'b0;
    wire iec_clk_in  = iec_clk;
    wire iec_data_in = qspi_sd3;
    USRMCLK usrmclk_atn (
        .USRMCLKI (iec_atn_out),
        .USRMCLKTS(1'b0)
    );
`endif

`ifdef HW_V2
    // ── QSPI data-lane pads ────────────────────────────────────────────────
    // The slave only drives per its per-lane output enables (1-lane legacy:
    // SD1/MISO whenever selected; multi-lane: the response phase).  SD2
    // doubles as the REQ line while SS is high (the MCU samples REQ between
    // frames only).  SD3/A9 doubles as IEC DATA in drive mode (open-drain).
    wire [3:0] qspi_sd_out, qspi_sd_oe;
    wire qspi_req_w;
    wire drive_1541;
    assign qspi_sd0 = qspi_sd_oe[0] ? qspi_sd_out[0] : 1'bz;
    assign qspi_sd1 = qspi_sd_oe[1] ? qspi_sd_out[1] : 1'bz;
    // Pad muxes MUST be the canonical single-level `oe ? val : 1'bz` —
    // yosys tribuf only recognizes that shape; the nested ternaries here
    // were folded into plain push-pull outputs (real-1541 DATA dead, see
    // the c64 top for the full story).
    wire sd2_oe  = qspi_ss | qspi_sd_oe[2];
    wire sd2_out = qspi_ss ? qspi_req_w : qspi_sd_out[2];
    assign qspi_sd2 = sd2_oe ? sd2_out : 1'bz;
  `ifdef IEC1541
    wire sd3_oe  = drive_1541 ? ~iec_data_out : qspi_sd_oe[3];
    wire sd3_out = drive_1541 ? 1'b0          : qspi_sd_out[3];
    assign qspi_sd3 = sd3_oe ? sd3_out : 1'bz;
  `else
    assign qspi_sd3 = qspi_sd_oe[3] ? qspi_sd_out[3] : 1'bz;
  `endif
    wire [3:0] qspi_sd_in = {qspi_sd3, qspi_sd2, qspi_sd1, qspi_sd0};
`endif

    soc soc0(
        .clk(clk), .rst(rst),
        .led1(led1), .led2(led2),
        .tx(tx), .rx(rx),
        .joy(5'b11111),  // no joystick on FPGA (active-low)
        .btn(btn_bus),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .lcd_data(lcd_data), .lcd_pwm(lcd_pwm), .lcd_clk(),
`ifdef HW_V2
        .spi_sck(qspi_sck), .spi_ss(qspi_ss), .spi_sd_in(qspi_sd_in),
        .spi_sd_out(qspi_sd_out), .spi_sd_oe(qspi_sd_oe),
        .spi_req(qspi_req_w), .drive_1541(drive_1541),
`else
        // v1: link pins not wired; SS high keeps the slave deselected
        .spi_sck(1'b0), .spi_ss(1'b1), .spi_sd_in(4'hF),
        .spi_sd_out(), .spi_sd_oe(), .spi_req(), .drive_1541(),
`endif
        .audio_pcm(audio_pcm)
`ifdef IEC1541
        // Real-1541: IEC lines on the reclaimed config pads above, alongside
        // the live QSPI link on its own balls — both active at once.
        , .iec_atn_out(iec_atn_out), .iec_clk_out(iec_clk_out),
        .iec_data_out(iec_data_out),
        .iec_clk_in(iec_clk_in), .iec_data_in(iec_data_in)
`endif
    );

    // TED PCM → MS4344 I2S DAC (MCLK/LRCK = 384, fs = clk/768 ≈ 36.7 kHz)
    i2s_pcm i2s0(
        .clk(clk), .rst(rst),
        .pcm(audio_pcm),
        .i2s_data(i2s_data), .i2s_mclk(i2s_mclk),
        .i2s_lrck(i2s_lrck), .i2s_bclk(i2s_bclk),
        .i2s_en(i2s_en)
    );

    initial begin
        lockCnt <= 0;
`ifdef SIMULATION
        rst <= 0;
`endif
    end

endmodule
