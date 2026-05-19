/*
 * project-riscv-darkrv-video.v — FPGA toplevel for the riscv-darkrv SoC.
 *
 * Built for HW=v2 (ECP5, single APS6404L QSPI PSRAM, 480×272 LCD).
 *
 * What this toplevel does:
 *   - Generates the system clock from ECP5 OSCG (~19 MHz at /16).
 *   - Holds reset for a few cycles after power-up.
 *   - Instantiates soc.v (DarkRISCV + ROM + RAM + BRAM framebuffer).
 *   - Bridges soc's UART byte interface to a real peripheral/uart.v module
 *     wired to the FPGA's tx/rx pins.
 *   - Drives the LCD by instantiating peripheral/lcd_out.v for the timing
 *     and reading pixels out of soc's framebuffer BRAM via fb_rd_addr.
 *   - Passes PSRAM pins straight through from soc to the physical chip.
 *
 * Not yet wired (left as stubs):
 *   - I2S audio (i2s_*), debugger, bootloader code-upload.
 */
`default_nettype none
`include "project.vh"

module fpga_gameconsole (
    output wire led1,                 // onboard LEDs (status)
    output wire led2,

    output wire tx,                   // UART to host
    input  wire rx,

    output wire i2s_en,               // tied off — audio not wired up yet
    output wire i2s_bclk,
    output wire i2s_lrck,
    output wire i2s_mclk,
    output wire i2s_data,

    output wire        lcd_hsync,
    output wire        lcd_vsync,
    output wire        lcd_de,
    output wire [15:0] lcd_data,
    output wire        lcd_pwm,
    output wire        lcd_clk,

    // PSRAM (HW=v2 chip — APS6404L)
    output wire        psram_sclk,
    output wire        psram_ce_n,
    inout  wire        psram_sio0,
    inout  wire        psram_sio1,
    inout  wire        psram_sio2,
    inout  wire        psram_sio3
);

    // ── Internal oscillator → sys clock ─────────────────────────────────
    wire clk;
    defparam OSCI1.DIV = `MAIN_CLK_DIVIDER;
    OSCG OSCI1 (.OSC(clk));

    // ── Reset generator: hold rst low for the first few clocks ─────────
    reg [2:0] lockCnt = 0;
    reg       rst     = 0;
    always @(posedge clk) begin
        if (lockCnt != 3'b111) begin
            lockCnt <= lockCnt + 3'b001;
            rst     <= 1'b0;
        end else begin
            rst <= 1'b1;
        end
    end

    // ── SoC ─────────────────────────────────────────────────────────────
    wire [7:0] soc_tx_data;
    wire       soc_tx_pulse;
    wire [7:0] soc_rx_data;
    wire       soc_rx_valid;
    wire       soc_frame_ready;
    wire       soc_fb_dummy;

    wire [17:0] fb_rd_addr_dummy = 18'b0;       // sim-peek path; unused on FPGA
    wire [31:0] fb_rd_data_dummy;
    wire [10:0] lcd_row, lcd_col;
    wire        lcd_de_raw, lcd_hs, lcd_vs;
    wire [15:0] lcd_pixel_from_soc;

    soc soc0 (
        .clk               (clk),
        .rst               (rst),
        .uart_tx_data      (soc_tx_data),
        .uart_tx_pulse     (soc_tx_pulse),
        .uart_rx_data      (soc_rx_data),
        .uart_rx_valid     (soc_rx_valid),
        .frame_ready_pulse (soc_frame_ready),
        .fb_rd_addr        (fb_rd_addr_dummy),
        .fb_rd_data        (fb_rd_data_dummy),
        .lcd_row_in        (lcd_row),
        .lcd_col_in        (lcd_col),
        .lcd_de_in         (lcd_de_raw),
        .lcd_pixel_out     (lcd_pixel_from_soc),
        .psram_sclk        (psram_sclk),
        .psram_ce_n        (psram_ce_n),
        .psram_sio0        (psram_sio0),
        .psram_sio1        (psram_sio1),
        .psram_sio2        (psram_sio2),
        .psram_sio3        (psram_sio3),
        .fb_dummy_out      (soc_fb_dummy)
    );

    // ── Real UART bridge ────────────────────────────────────────────────
    // peripheral/uart.v expects:
    //   txen   = 1-cycle pulse to start a TX byte
    //   txdata = byte to send
    //   rxen   = TOGGLE each time a byte is received (rising-edge detect → pulse)
    //   rxdata = latest received byte
    wire        u_txbusy;
    wire        u_rxen;
    wire [7:0]  u_rxdata;
    reg         u_rxen_prev;
    wire        u_rxen_pulse = u_rxen ^ u_rxen_prev;  // 1-cycle when rxen toggles

    always @(posedge clk or negedge rst)
        if (!rst) u_rxen_prev <= 1'b0;
        else      u_rxen_prev <= u_rxen;

    uart uart0 (
        .clk    (clk),
        .rst    (rst),
        .txen   (soc_tx_pulse),
        .txdata (soc_tx_data),
        .tx     (tx),
        .rx     (rx),
        .rxen   (u_rxen),
        .rxdata (u_rxdata),
        .txbusy (u_txbusy)
    );

    assign soc_rx_data  = u_rxdata;
    assign soc_rx_valid = u_rxen_pulse;

    // ── LCD timing ──────────────────────────────────────────────────────
    // lcd_row/col/de_raw are wired into soc.v's fb_psram, which streams
    // RGB565 pixels back via lcd_pixel_from_soc.  Sync signals are
    // registered once so they line up with the BRAM-side fetch latency.
    lcd_out lcd0 (
        .clk       (clk),
        .rst       (rst),
        .ctrl_addr (3'h0),
        .ctrl_data (11'h0),
        .ctrl_we   (1'b0),
        .lcd_hsync (lcd_hs),
        .lcd_vsync (lcd_vs),
        .lcd_de    (lcd_de_raw),
        .row       (lcd_row),
        .col       (lcd_col)
    );

    reg lcd_hs_r, lcd_vs_r, lcd_de_r;
    always @(posedge clk) begin
        lcd_hs_r <= lcd_hs;
        lcd_vs_r <= lcd_vs;
        lcd_de_r <= lcd_de_raw;
    end
    assign lcd_hsync = lcd_hs_r;
    assign lcd_vsync = lcd_vs_r;
    assign lcd_de    = lcd_de_r;
    assign lcd_data  = lcd_pixel_from_soc;

    assign lcd_clk = clk;
    assign lcd_pwm = 1'b1;    // backlight always-on for first bring-up

    // ── Status LEDs ─────────────────────────────────────────────────────
    // led1 = blink at the frame rate, led2 = blink at UART activity.
    reg led1_reg = 1'b0;
    reg led2_reg = 1'b0;
    always @(posedge clk) begin
        if (soc_frame_ready) led1_reg <= ~led1_reg;
        if (soc_tx_pulse)    led2_reg <= ~led2_reg;
    end
    assign led1 = led1_reg;
    assign led2 = led2_reg;

    // ── Unused outputs tied off ─────────────────────────────────────────
    assign i2s_en   = 1'b0;
    assign i2s_bclk = 1'b0;
    assign i2s_lrck = 1'b0;
    assign i2s_mclk = 1'b0;
    assign i2s_data = 1'b0;

endmodule

`default_nettype wire
