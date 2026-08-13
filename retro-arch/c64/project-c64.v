
`include "project.vh"

module fpga_gameconsole (
    output led1,
    output led2,

`ifdef HW_V2
    // 17.734475 MHz PAL crystal (X1 on the MCU sheet, ball B11) — 4x the
    // PAL colour subcarrier, the same master frequency a real PAL C64 uses.
    input clk_pal,

    // v2 board push buttons (active-low, internal pull-ups)
    input btn_up,
    input btn_down,
    input btn_left,
    input btn_right,
    input btn_a,
    input btn_b,
    input btn_c,
    input btn_d,

    // MCU⇄FPGA QSPI link (RP2350 is SPI master; see common/qspi_slave.v).
    // Present in BOTH the plain and the real-1541 builds — its balls
    // (A7/B7/A8/A9/A10/B10) are independent of the IEC CLK/ATN lines below,
    // so BIOS, fastload and volume keep working even while the drive runs.
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
    // Real-1541 IEC rides the *reclaimed sysCONFIG pins* (proven by the
    // config-pin spike, retro-arch/c64/spike/), so the QSPI link above is
    // untouched and BIOS/volume coexist with the drive:
    //   ATN  = N9 (CCLK)  — output-only via the USRMCLK primitive (no port)
    //   CLK  = N8 (config DI ball, PB15A) — bidirectional open-drain
    //   DATA = A9 = the qspi_sd3 pad above — DRIVE_MODE muxes its role
    // (MCU side: ATN=GPIO24, CLK=GPIO25, DATA=GPIO9 — see the board firmware)
    inout  iec_clk,
`endif
`ifdef FDRIVE
    // QSPI PSRAM (APS6404L) — the fabric 1541's DOS ROM + GCR tracks
    output psram_sclk,
    output psram_ce_n,
    inout  psram_sio0,
    inout  psram_sio1,
    inout  psram_sio2,
    inout  psram_sio3,
`elsif EASYFLASH
    // QSPI PSRAM (APS6404L) — the EasyFlash cart image (README.md)
    output psram_sclk,
    output psram_ce_n,
    inout  psram_sio0,
    inout  psram_sio1,
    inout  psram_sio2,
    inout  psram_sio3,
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

    // I2S audio (MS4344 DAC + speaker amp on the v2 board)
    output i2s_data,
    output i2s_mclk,
    output i2s_lrck,
    output i2s_bclk,
    output i2s_en
);

    wire clk;
    /* Explicit power-up values: without them yosys is free to assume
     * rst inits to 1 and const-folds the whole reset generator away,
     * deleting every sync reset in the SoC (the ecp5-rst-constfold
     * trap).  With INIT=0 the timed power-on-reset really pulses. */
    reg rst = 0;
    reg [15:0] lockCnt = 0;

`ifdef HW_V2
    // PAL-exact dot4x: the board's 17.734475 MHz crystal x 16/9 =
    // 31.527955 MHz.  The VIC-II is the clock master and divides this by
    // 32 to the true 0.985248 MHz phi — display refresh lands on the real
    // 50.125 Hz and SID pitch is exact (OSCG was nominally -1.7% with a
    // several-percent part spread on top).  PLL config from ecppll
    // --highres: PFD = 17.73 MHz, VCO = crystal x 32 = 567.503 MHz
    // (feedback on CLKOP), output = CLKOS = VCO/18.  LOCK is deliberately
    // left unconnected — it reads 0 on this board even when locked (the
    // ecp5-ehxplll-lock-untrusted rule); the timed reset below covers
    // lock time instead.
    wire clk_fb;
    wire psram_clk;     /* CLKOS2 = VCO/5 = 113.5006 MHz — psram_fast's
                         * fast domain (SCLK = half that, 56.75 MHz, right
                         * beside the 59.85 MHz point).  Only
                         * the FDRIVE build consumes it; otherwise pruned. */
    (* FREQUENCY_PIN_CLKI="17.734475" *)
    (* FREQUENCY_PIN_CLKOS="31.527955" *)
    (* FREQUENCY_PIN_CLKOS2="113.500638" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *)
    (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"), .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(32),
        .CLKOP_CPHASE(9), .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"), .CLKOS_DIV(18),
        .CLKOS_CPHASE(0), .CLKOS_FPHASE(0),
        .CLKOS2_ENABLE("ENABLED"), .CLKOS2_DIV(5),
        .CLKOS2_CPHASE(0), .CLKOS2_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(1)
    ) pll0 (
        .RST(1'b0), .STDBY(1'b0),
        .CLKI(clk_pal),
        .CLKOP(clk_fb), .CLKOS(clk), .CLKOS2(psram_clk),
        .CLKFB(clk_fb), .CLKINTFB(),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0),
        .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0),
        .LOCK()
    );
`else
    // v1 board has no PAL crystal: ECP5 OSCG 310 MHz / 10 = 31 MHz ≈ dot4x.
    defparam OSCI1.DIV = `MAIN_CLK_DIVIDER;
    OSCG OSCI1 (.OSC(clk));
`endif

    // Timed power-on reset: hold rst low for 65536 clk cycles (~2.1 ms at
    // 31.5 MHz) — long enough to cover PLL lock without trusting LOCK.
    always @(posedge clk)
    begin
        if (lockCnt != 16'hFFFF)
            lockCnt <= lockCnt + 1;
        else
            rst <= 1;
    end

    // Drive lcd_clk directly from the machine clock (= dot4x = LCD pixel
    // clock); the LCD stays genlocked to the VIC raster.
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
    // HIGH).  CLK/DATA read back the wired-AND pad level.
    wire iec_atn_out, iec_clk_out, iec_data_out;
    assign iec_clk  = iec_clk_out  ? 1'bz : 1'b0;
    wire iec_clk_in  = iec_clk;
    wire iec_data_in = qspi_sd3;

    // ATN is C64→drive only (matching CIA2 PA3); the MCU reads it and never
    // drives it.  N9/CCLK is not a fabric PIO — reach it through the USRMCLK
    // primitive (output enabled with USRMCLKTS=0).  Push-pull is fine here
    // since nothing else contends ATN.  iec_atn_out is the *bus level*
    // (1=released/HIGH, 0=asserted/LOW), which is exactly what the MCU wants.
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
    // Pad muxes MUST be written as the canonical single-level
    // `oe ? val : 1'bz` — yosys's tribuf pass only recognizes that shape.
    // The original nested ternaries (1'bz leaves inside both branches) were
    // silently folded into plain push-pull LUT outputs: the A9 pad fought
    // the drive's open-drain DATA pulls and iec_data_in read back the
    // FPGA's own driven value, so every real-1541 LOAD hung right after
    // SEARCHING FOR (bit 2607181432.0; found in the out.json netlist —
    // sims build soc.v, never these pad muxes).
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
        .rx(rx), .tx(tx),
        .led1(led1), .led2(led2),
        .joy(5'b11111),   // no physical joystick (active-low); board
                          // buttons drive joy port 2 via kbd_buttons
        .btn(btn_bus),
        .lcd_data(lcd_data), .lcd_de(lcd_de), .lcd_pwm(lcd_pwm),
        .lcd_vsync(lcd_vsync), .lcd_hsync(lcd_hsync),
`ifdef IEC1541
        // Real-1541: IEC lines on the reclaimed config pads above, AND the
        // live QSPI link on its own balls — both active at once.
        .iec_atn_out(iec_atn_out), .iec_clk_out(iec_clk_out),
        .iec_data_out(iec_data_out),
        .iec_clk_in(iec_clk_in), .iec_data_in(iec_data_in),
        .spi_sck(qspi_sck), .spi_ss(qspi_ss), .spi_sd_in(qspi_sd_in),
        .spi_sd_out(qspi_sd_out), .spi_sd_oe(qspi_sd_oe),
        .spi_req(qspi_req_w), .drive_1541(drive_1541),
`else
        // IEC stays unwired in the fastload/BIOS bitstream:
        // both bus inputs read released (HIGH).
        .iec_atn_out(), .iec_clk_out(), .iec_data_out(),
        .iec_clk_in(1'b1), .iec_data_in(1'b1),
  `ifdef HW_V2
        .spi_sck(qspi_sck), .spi_ss(qspi_ss), .spi_sd_in(qspi_sd_in),
        .spi_sd_out(qspi_sd_out), .spi_sd_oe(qspi_sd_oe),
        .spi_req(qspi_req_w), .drive_1541(drive_1541),
  `else
        // v1: link pins not wired; SS high keeps the slave deselected
        .spi_sck(1'b0), .spi_ss(1'b1), .spi_sd_in(4'hF),
        .spi_sd_out(), .spi_sd_oe(), .spi_req(), .drive_1541(),
  `endif
`endif
`ifdef FDRIVE
        .psram_clk(psram_clk),
        .psram_sclk(psram_sclk), .psram_ce_n(psram_ce_n),
        .psram_sio0(psram_sio0), .psram_sio1(psram_sio1),
        .psram_sio2(psram_sio2), .psram_sio3(psram_sio3),
`elsif EASYFLASH
        .psram_sclk(psram_sclk), .psram_ce_n(psram_ce_n),
        .psram_sio0(psram_sio0), .psram_sio1(psram_sio1),
        .psram_sio2(psram_sio2), .psram_sio3(psram_sio3),
`endif
        .audio_pcm(audio_pcm)
    );

    // SID PCM → MS4344 I2S DAC (MCLK/LRCK = 384, fs = clk/768 ≈ 40.4 kHz)
    i2s_pcm i2s0(
        .clk(clk), .rst(rst),
        .pcm(audio_pcm),
        .i2s_data(i2s_data), .i2s_mclk(i2s_mclk),
        .i2s_lrck(i2s_lrck), .i2s_bclk(i2s_bclk),
        .i2s_en(i2s_en)
    );

endmodule
