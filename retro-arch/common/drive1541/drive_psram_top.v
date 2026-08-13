/*
 * drive_psram_top.v — phase-3 verification top: drive_1541 + drive_psram +
 * the behavioural PSRAM engine, with the STRETCHABLE PHI generator that the
 * soc will replicate.
 *
 * The divider ticks every PHI_DIV clks; when drive_psram raises `stall`
 * (a ROM fetch has not landed for the ending cycle) the tick is HELD until
 * it clears — the whole drive stretches that one cycle.  Fastloader code
 * runs from drive RAM and never stalls (see drive_psram.v).
 *
 * `push_mode` holds the DRIVE in reset while the TB (later: the MCU)
 * streams the DOS ROM + GCR tracks through the push port — the EasyFlash
 * loader convention.  Arlet's AB sits in the stack page under reset, so
 * the ROM path stays quiet and pushes flow at full rate.
 */

`default_nettype none

module drive_psram_top #(
    parameter PHI_DIV = 32
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        push_mode,

    input  wire        iec_atn,
    input  wire        iec_clk_in,
    input  wire        iec_data_in,
    output wire        iec_clk_pull,
    output wire        iec_data_pull,

    input  wire        push_we,
    input  wire [21:0] push_addr,
    input  wire [7:0]  push_data,
    output wire        push_busy,

    input  wire        disk_writable,
    output wire [23:0] stall_clks,        /* clks of real phi stretch */
    output wire        dbg_motor,
    output wire        dbg_led,
    output wire [6:0]  dbg_halftrack,
    output wire [15:0] dbg_cpu_ab
);

/* ── stretchable phi ──────────────────────────────────────────────────── */
wire stall;
reg  [5:0] div = 6'd0;
reg  tick = 1'b0;
reg  [23:0] stall_r = 24'd0;              /* clks the tick was actually HELD */
assign stall_clks = stall_r;

always @(posedge clk) begin
    tick <= 1'b0;
    if (rst) begin
        div <= 6'd0;
        stall_r <= 24'd0;
    end else if (div >= PHI_DIV - 1) begin
        if (!stall) begin                 /* hold the tick until ROM lands */
            tick <= 1'b1;
            div  <= 6'd0;
        end else
            stall_r <= stall_r + 24'd1;
    end else
        div <= div + 6'd1;
end

/* ── drive + backend + engine ─────────────────────────────────────────── */
wire [13:0] rom_addr;
wire        rom_sel;
wire [7:0]  rom_data;
wire [21:0] gcr_addr;
wire [7:0]  gcr_data;

wire [23:0] ps_addr;
wire        ps_rd, ps_wr, ps_byte;
wire [3:0]  ps_words;
wire [31:0] ps_wdata, ps_rdata;
wire        ps_rdy, ps_busy;

drive_1541 drive(
    .clk(clk), .rst(rst || push_mode), .tick(tick),
    .iec_atn(iec_atn), .iec_clk_in(iec_clk_in), .iec_data_in(iec_data_in),
    .iec_clk_pull(iec_clk_pull), .iec_data_pull(iec_data_pull),
    .rom_addr(rom_addr), .rom_sel(rom_sel), .rom_data(rom_data),
    .gcr_addr(gcr_addr), .gcr_data(gcr_data),
    .disk_writable(disk_writable),
    .dbg_motor(dbg_motor), .dbg_led(dbg_led),
    .dbg_halftrack(dbg_halftrack), .dbg_cpu_ab(dbg_cpu_ab),
    .dbg_ram85()
);

drive_psram backend(
    .clk(clk), .rst(rst), .gcr_flush(rst || push_mode),
    .rom_addr(rom_addr), .rom_sel(rom_sel), .rom_data(rom_data),
    .gcr_addr(gcr_addr), .gcr_data(gcr_data),
    .stall(stall),
    .push_we(push_we), .push_addr(push_addr), .push_data(push_data),
    .push_busy(push_busy),
    .ps_addr(ps_addr), .ps_rd(ps_rd), .ps_wr(ps_wr),
    .ps_byte(ps_byte), .ps_words(ps_words), .ps_wdata(ps_wdata),
    .ps_rdata(ps_rdata), .ps_rdy(ps_rdy), .ps_busy(ps_busy)
);

`ifdef USE_REAL_PSRAM
/* the board engine + pin-level chip — the soc's exact memory stack */
wire p_sclk, p_ce_n, p_sio0, p_sio1, p_sio2, p_sio3;
psram engine(
    .clk(clk), .rst(~rst),
    .cmd_addr(ps_addr), .cmd_rd(ps_rd), .cmd_wr(ps_wr),
    .cmd_byte(ps_byte), .cmd_words(ps_words), .cmd_wdata(ps_wdata),
    .rdata(ps_rdata), .rdy(ps_rdy),
    .word_rdy(), .word_idx(), .busy(ps_busy),
    .psram_sclk(p_sclk), .psram_ce_n(p_ce_n),
    .psram_sio0(p_sio0), .psram_sio1(p_sio1),
    .psram_sio2(p_sio2), .psram_sio3(p_sio3),
    .raw_en(1'b0), .raw_sclk(1'b0), .raw_ce_n(1'b1),
    .raw_oe(1'b0), .raw_sio(4'b0), .raw_sio_in()
);
psram_chip_model chip0(
    .psram_sclk(p_sclk), .psram_ce_n(p_ce_n),
    .psram_sio0(p_sio0), .psram_sio1(p_sio1),
    .psram_sio2(p_sio2), .psram_sio3(p_sio3)
);
`else
psram_cmd_behav engine(
    .clk(clk),
    .cmd_addr(ps_addr), .cmd_rd(ps_rd), .cmd_wr(ps_wr),
    .cmd_byte(ps_byte), .cmd_words(ps_words), .cmd_wdata(ps_wdata),
    .rdata(ps_rdata), .rdy(ps_rdy), .busy(ps_busy)
);
`endif

endmodule
