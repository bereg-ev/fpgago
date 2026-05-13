/*
 * ddr3_test_top.v — FPGA top for the DDR3 bring-up test (HW v2 board).
 *
 * Clocking
 * --------
 * OSCG @ DIV=2  →  ~155 MHz on-chip oscillator
 *               →  EHXPLLL  →  CLKOP = clk_sys (≈51.67 MHz)
 *                            →  CLKOS = clk_ddr (same freq, 90° lead)
 *
 * The DDR3 controller runs at clk_sys; the PHY uses clk_ddr to launch DQ /
 * capture DQS at quadrature.  The two clocks are at the SAME frequency, so
 * for first-pass bring-up the design behaves as a single-clock-domain SoC
 * (every flop sees a pseudo-90° edge of the same period).  When you want
 * to push the DDR3 clock higher than the CPU clock, change CLKOP_DIV vs
 * CLKOS_DIV here and the controller's DDR_MHZ parameter in soc.v.
 *
 * NOTE: the PLL settings produce ~52 MHz, not exactly 50 MHz — it is a
 * starting point.  Recompute CLKI_DIV / CLKFB_DIV / CLKOP_DIV if you want
 * a different operating point.  VCO must stay in the 400–800 MHz range.
 *
 */

module ddr3_test_top(
    output wire        led1,
    output wire        led2,

    input  wire        rx,
    output wire        tx,

    /* DDR3 SDRAM */
    output wire        ddr3_ck_p,
    output wire        ddr3_cke,
    output wire        ddr3_reset_n,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_cs_n,
    output wire [ 2:0] ddr3_ba,
    output wire [12:0] ddr3_a,
    output wire        ddr3_odt,
    output wire [ 1:0] ddr3_dm,
    inout  wire [ 1:0] ddr3_dqs_p,
    inout  wire [15:0] ddr3_dq
);

/* ── On-chip oscillator ──────────────────────────────────────────────────── */
wire osc_clk;
defparam OSCI1.DIV = "2";
OSCG OSCI1 (.OSC(osc_clk));

/* ── PLL: 0° + 90° outputs from osc_clk ──────────────────────────────────── */
wire clk_sys;
wire clk_ddr;
wire pll_locked;

EHXPLLL #(
    .PLLRST_ENA      ("DISABLED"),
    .INTFB_WAKE      ("DISABLED"),
    .STDBY_ENABLE    ("DISABLED"),
    .DPHASE_SOURCE   ("DISABLED"),
    .OUTDIVIDER_MUXA ("DIVA"),
    .OUTDIVIDER_MUXB ("DIVB"),
    .CLKI_DIV        (1),
    .CLKFB_DIV       (4),
    .FEEDBK_PATH     ("CLKOP"),

    .CLKOP_ENABLE    ("ENABLED"),
    .CLKOP_DIV       (12),
    .CLKOP_CPHASE    (11),
    .CLKOP_FPHASE    (0),

    .CLKOS_ENABLE    ("ENABLED"),
    .CLKOS_DIV       (12),
    .CLKOS_CPHASE    (8),                /* 11 - 3 ≈ 90° lead vs CLKOP   */
    .CLKOS_FPHASE    (0)
) pll0 (
    .CLKI         (osc_clk),
    .CLKFB        (clk_sys),
    .CLKINTFB     (),
    .RST          (1'b0),
    .STDBY        (1'b0),
    .PHASESEL0    (1'b0), .PHASESEL1    (1'b0),
    .PHASEDIR     (1'b0), .PHASESTEP    (1'b0), .PHASELOADREG(1'b0),
    .PLLWAKESYNC  (1'b0),
    .ENCLKOP      (1'b1), .ENCLKOS      (1'b1),
    .ENCLKOS2     (1'b0), .ENCLKOS3     (1'b0),
    .CLKOP        (clk_sys),
    .CLKOS        (clk_ddr),
    .CLKOS2       (),
    .CLKOS3       (),
    .LOCK         (pll_locked)
);

/* ── Reset generation ────────────────────────────────────────────────────── */
reg [3:0] rst_cnt;
reg       rst;

initial begin
    rst_cnt = 4'h0;
    rst     = 1'b0;
end

always @(posedge clk_sys) begin
    if (!pll_locked) begin
        rst_cnt <= 4'h0;
        rst     <= 1'b0;
    end else if (rst_cnt != 4'hF) begin
        rst_cnt <= rst_cnt + 4'h1;
        rst     <= 1'b0;
    end else begin
        rst <= 1'b1;
    end
end

/* ── SoC instance ────────────────────────────────────────────────────────── */
ddr3_test_soc soc0(
    .clk_sys(clk_sys),
    .clk_ddr(clk_ddr),
    .rst    (rst),

    .led1(led1), .led2(led2),
    .rx  (rx),   .tx  (tx),

    .ddr3_ck_p   (ddr3_ck_p),
    .ddr3_cke    (ddr3_cke),
    .ddr3_reset_n(ddr3_reset_n),
    .ddr3_ras_n  (ddr3_ras_n),
    .ddr3_cas_n  (ddr3_cas_n),
    .ddr3_we_n   (ddr3_we_n),
    .ddr3_cs_n   (ddr3_cs_n),
    .ddr3_ba     (ddr3_ba),
    .ddr3_a      (ddr3_a),
    .ddr3_odt    (ddr3_odt),
    .ddr3_dm     (ddr3_dm),
    .ddr3_dqs_p  (ddr3_dqs_p),
    .ddr3_dq     (ddr3_dq)
);

endmodule
