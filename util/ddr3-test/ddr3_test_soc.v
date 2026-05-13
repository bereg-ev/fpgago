/*
 * ddr3_test_soc.v — Stripped-down RISC2 SoC for DDR3 bring-up.
 *
 * No LCD, no audio, no PSRAM, no SDRAM, no icache, no dcache.  The CPU
 * runs straight out of a 32 KB boot ROM with a 16 KB data scratch BRAM
 * and a single peripheral (ddr3_iface) that owns the AXI master toward
 * the DDR3 controller.  All blocks share `clk_sys`.  `clk_ddr` is the
 * 90°-shifted clock the DDR3 PHY needs for DQS strobe / DQ launch — at
 * first it is just clk_sys (no PLL) so the design works in simulation
 * with a single domain; on hardware the top-level provides the shift.
 */

`include "project.vh"

module ddr3_test_soc(
    input  wire        clk_sys,
    input  wire        clk_ddr,
    input  wire        rst,

    output wire        led1,
    output wire        led2,

    input  wire        rx,
    output wire        tx,

    /* DDR3 pins (see project-risc2-video-hw2.lpf for sites). */
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

/* ── CPU bus ─────────────────────────────────────────────────────────────── */
wire [23:0] instr_addr;
wire [31:0] instr_data;

/* Boot-ROM read has 1-cycle BRAM latency; gate instr_valid LOW the cycle
 * instr_addr changes so the CPU doesn't latch stale instr_data, and HIGH
 * once instr_addr_d1 catches up.  No icache => no other latency to add. */
reg [23:0] instr_addr_d1;
always @(posedge clk_sys or negedge rst) begin
    if (!rst) instr_addr_d1 <= 24'hfffffc;
    else      instr_addr_d1 <= instr_addr;
end
wire instr_valid = (instr_addr == instr_addr_d1);

wire [23:0] data_addr;
reg  [31:0] data_in_value;
reg         data_in_valid;
wire        data_rd, data_wr;
wire [31:0] data_out_value;
wire [ 3:0] data_out_strobe;
wire [127:0] cpuDbg;

reg sled1, sled2;
assign led1 = sled1;
assign led2 = sled2;

/* ── Boot ROM (32 KB = 8 banks × 1 KB-words × 2 halves) ──────────────────── */
wire [17:0] romL_iout [0:7], romH_iout [0:7];
wire [17:0] romL_dout [0:7], romH_dout [0:7];
wire [31:0] rom_out_value;

dual_port_ram_1k_18 #(
`include "romL.vh"
) romL0 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[0]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[0]));
dual_port_ram_1k_18 #(
`include "romH.vh"
) romH0 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[0]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[0]));

dual_port_ram_1k_18 #(
`include "romL2.vh"
) romL1 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[1]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[1]));
dual_port_ram_1k_18 #(
`include "romH2.vh"
) romH1 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[1]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[1]));

dual_port_ram_1k_18 #(
`include "romL3.vh"
) romL2 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[2]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[2]));
dual_port_ram_1k_18 #(
`include "romH3.vh"
) romH2 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[2]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[2]));

dual_port_ram_1k_18 #(
`include "romL4.vh"
) romL3 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[3]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[3]));
dual_port_ram_1k_18 #(
`include "romH4.vh"
) romH3 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[3]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[3]));

dual_port_ram_1k_18 #(
`include "romL5.vh"
) romL4 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[4]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[4]));
dual_port_ram_1k_18 #(
`include "romH5.vh"
) romH4 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[4]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[4]));

dual_port_ram_1k_18 #(
`include "romL6.vh"
) romL5 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[5]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[5]));
dual_port_ram_1k_18 #(
`include "romH6.vh"
) romH5 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[5]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[5]));

dual_port_ram_1k_18 #(
`include "romL7.vh"
) romL6 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[6]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[6]));
dual_port_ram_1k_18 #(
`include "romH7.vh"
) romH6 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[6]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[6]));

dual_port_ram_1k_18 #(
`include "romL8.vh"
) romL7 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL_iout[7]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romL_dout[7]));
dual_port_ram_1k_18 #(
`include "romH8.vh"
) romH7 (.clk_a(clk_sys), .we_a(1'b0), .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH_iout[7]),
         .clk_b(clk_sys), .we_b(1'b0), .addr_b(data_addr [11:2]), .din_b(18'b0), .dout_b(romH_dout[7]));

reg [2:0] rom_ibank, rom_dbank;
always @(posedge clk_sys) begin
    rom_ibank <= instr_addr[14:12];
    rom_dbank <= data_addr [14:12];
end

assign instr_data    = {romH_iout[rom_ibank][15:0], romL_iout[rom_ibank][15:0]};
assign rom_out_value = {romH_dout[rom_dbank][15:0], romL_dout[rom_dbank][15:0]};

/* ── Data BRAM (16 KB = 4 lanes × 4K × byte) ─────────────────────────────── */
wire [9:0] dummy_b0, dummy_b1, dummy_b2, dummy_b3;
wire [31:0] dataram_out;
wire dataram_wr = data_wr & (data_addr[23:16] == `MEM_BRAM_PFX8);

ram_4k_18 dataram_b0 (
    .clk_a(clk_sys), .we_a(1'b0),
    .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b0, dataram_out[ 7: 0]}),
    .clk_b(clk_sys), .we_b(dataram_wr & data_out_strobe[0]),
    .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[ 7: 0]})
);
ram_4k_18 dataram_b1 (
    .clk_a(clk_sys), .we_a(1'b0),
    .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b1, dataram_out[15: 8]}),
    .clk_b(clk_sys), .we_b(dataram_wr & data_out_strobe[1]),
    .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[15: 8]})
);
ram_4k_18 dataram_b2 (
    .clk_a(clk_sys), .we_a(1'b0),
    .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b2, dataram_out[23:16]}),
    .clk_b(clk_sys), .we_b(dataram_wr & data_out_strobe[2]),
    .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[23:16]})
);
ram_4k_18 dataram_b3 (
    .clk_a(clk_sys), .we_a(1'b0),
    .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b3, dataram_out[31:24]}),
    .clk_b(clk_sys), .we_b(dataram_wr & data_out_strobe[3]),
    .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[31:24]})
);

/* ── UART ────────────────────────────────────────────────────────────────── */
reg [7:0] txdata;
reg       txen, rxrdy, rxen0, rxovf;
wire      txbusy, rxen;
wire [7:0] rxdata;

uart uart0(
    .clk(clk_sys), .rst(rst),
    .tx(tx), .rx(rx),
    .txdata(txdata), .txen(txen), .txbusy(txbusy),
    .rxdata(rxdata), .rxen(rxen)
);

/* ── DDR3 test peripheral ────────────────────────────────────────────────── */
wire [31:0] ddr3_iface_rdata;

wire        m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
wire [31:0] m_awaddr,  m_wdata,  m_araddr;
wire [ 7:0] m_awlen,   m_arlen;
wire [ 1:0] m_awburst, m_arburst;
wire [ 3:0] m_awid,    m_arid, m_wstrb;
wire        m_wlast;

wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid, m_rlast;
wire [ 1:0] m_bresp,   m_rresp;
wire [ 3:0] m_bid,     m_rid;
wire [31:0] m_rdata;

wire ddr3_range = (data_addr[23:8] == `MEM_DDR3_PFX16);

ddr3_iface ddr3_iface0(
    .clk(clk_sys), .rst(rst),

    .data_addr (data_addr),
    .data_wdata(data_out_value),
    .data_wstrb(data_out_strobe),
    .data_we   (data_wr & ddr3_range),
    .data_re   (data_rd & ddr3_range),
    .data_rdata(ddr3_iface_rdata),

    .m_awvalid(m_awvalid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
    .m_awburst(m_awburst), .m_awid(m_awid), .m_awready(m_awready),

    .m_wvalid(m_wvalid), .m_wdata(m_wdata), .m_wstrb(m_wstrb),
    .m_wlast(m_wlast), .m_wready(m_wready),

    .m_bvalid(m_bvalid), .m_bresp(m_bresp), .m_bid(m_bid), .m_bready(m_bready),

    .m_arvalid(m_arvalid), .m_araddr(m_araddr), .m_arlen(m_arlen),
    .m_arburst(m_arburst), .m_arid(m_arid), .m_arready(m_arready),

    .m_rvalid(m_rvalid), .m_rdata(m_rdata), .m_rresp(m_rresp),
    .m_rlast(m_rlast), .m_rid(m_rid), .m_rready(m_rready)
);

/* ── DDR3 controller ──────────────────────────────────────────────────────
 *
 * SIMULATION: skip the controller and PHY, hook a behavioural AXI memory
 * directly to the master.  See sim/ddr3_axi_sim.v.
 *
 * Synthesis: full ddr3_axi → DFI sequencer → ECP5 DFI PHY chain. */

`ifdef SIMULATION
ddr3_axi_sim ddr3_sim0(
    .clk_i(clk_sys), .rst_i(~rst),

    .inport_awvalid_i(m_awvalid), .inport_awaddr_i(m_awaddr),
    .inport_awid_i   (m_awid),    .inport_awlen_i (m_awlen),
    .inport_awburst_i(m_awburst), .inport_awready_o(m_awready),

    .inport_wvalid_i (m_wvalid),  .inport_wdata_i (m_wdata),
    .inport_wstrb_i  (m_wstrb),   .inport_wlast_i (m_wlast),
    .inport_wready_o (m_wready),

    .inport_bvalid_o (m_bvalid),  .inport_bresp_o (m_bresp),
    .inport_bid_o    (m_bid),     .inport_bready_i(m_bready),

    .inport_arvalid_i(m_arvalid), .inport_araddr_i(m_araddr),
    .inport_arid_i   (m_arid),    .inport_arlen_i (m_arlen),
    .inport_arburst_i(m_arburst), .inport_arready_o(m_arready),

    .inport_rvalid_o (m_rvalid),  .inport_rdata_o (m_rdata),
    .inport_rresp_o  (m_rresp),   .inport_rlast_o (m_rlast),
    .inport_rid_o    (m_rid),     .inport_rready_i(m_rready)
);

/* Drive synth-only outputs to safe constants in simulation. */
assign ddr3_ck_p     = 1'b0;
assign ddr3_cke      = 1'b0;
assign ddr3_reset_n  = 1'b1;
assign ddr3_ras_n    = 1'b1;
assign ddr3_cas_n    = 1'b1;
assign ddr3_we_n     = 1'b1;
assign ddr3_cs_n     = 1'b1;
assign ddr3_ba       = 3'b0;
assign ddr3_a        = 13'b0;
assign ddr3_odt      = 1'b0;
assign ddr3_dm       = 2'b0;
assign ddr3_dqs_p    = 2'bzz;
assign ddr3_dq       = 16'bz;

`else
/* ── Synthesis: real DDR3 controller + PHY ───────────────────────────────── */

wire [14:0] dfi_address_w;
wire [ 2:0] dfi_bank_w;
wire        dfi_cas_n_w, dfi_cke_w, dfi_cs_n_w, dfi_odt_w;
wire        dfi_ras_n_w, dfi_reset_n_w, dfi_we_n_w;
wire [31:0] dfi_wrdata_w, dfi_rddata_w;
wire        dfi_wrdata_en_w, dfi_rddata_en_w, dfi_rddata_valid_w;
wire [ 3:0] dfi_wrdata_mask_w;
wire [ 1:0] dfi_rddata_dnv_w;

ddr3_axi #(
    .DDR_WRITE_LATENCY(3),
    .DDR_READ_LATENCY (3),
    .DDR_MHZ          (50)
) ddr3_axi0 (
    .clk_i(clk_sys), .rst_i(~rst),

    .inport_awvalid_i(m_awvalid), .inport_awaddr_i(m_awaddr),
    .inport_awid_i   (m_awid),    .inport_awlen_i (m_awlen),
    .inport_awburst_i(m_awburst), .inport_awready_o(m_awready),

    .inport_wvalid_i (m_wvalid),  .inport_wdata_i (m_wdata),
    .inport_wstrb_i  (m_wstrb),   .inport_wlast_i (m_wlast),
    .inport_wready_o (m_wready),

    .inport_bvalid_o (m_bvalid),  .inport_bresp_o (m_bresp),
    .inport_bid_o    (m_bid),     .inport_bready_i(m_bready),

    .inport_arvalid_i(m_arvalid), .inport_araddr_i(m_araddr),
    .inport_arid_i   (m_arid),    .inport_arlen_i (m_arlen),
    .inport_arburst_i(m_arburst), .inport_arready_o(m_arready),

    .inport_rvalid_o (m_rvalid),  .inport_rdata_o (m_rdata),
    .inport_rresp_o  (m_rresp),   .inport_rlast_o (m_rlast),
    .inport_rid_o    (m_rid),     .inport_rready_i(m_rready),

    .dfi_address_o    (dfi_address_w),
    .dfi_bank_o       (dfi_bank_w),
    .dfi_cas_n_o      (dfi_cas_n_w),
    .dfi_cke_o        (dfi_cke_w),
    .dfi_cs_n_o       (dfi_cs_n_w),
    .dfi_odt_o        (dfi_odt_w),
    .dfi_ras_n_o      (dfi_ras_n_w),
    .dfi_reset_n_o    (dfi_reset_n_w),
    .dfi_we_n_o       (dfi_we_n_w),
    .dfi_wrdata_o     (dfi_wrdata_w),
    .dfi_wrdata_en_o  (dfi_wrdata_en_w),
    .dfi_wrdata_mask_o(dfi_wrdata_mask_w),
    .dfi_rddata_en_o  (dfi_rddata_en_w),
    .dfi_rddata_i     (dfi_rddata_w),
    .dfi_rddata_valid_i(dfi_rddata_valid_w),
    .dfi_rddata_dnv_i (dfi_rddata_dnv_w)
);

wire [14:0] phy_addr_w;

ddr3_dfi_phy phy0 (
    .clk_i(clk_sys), .clk_ddr_i(clk_ddr), .rst_i(~rst),
    .cfg_valid_i(1'b0), .cfg_i(32'b0),

    .dfi_address_i    (dfi_address_w),
    .dfi_bank_i       (dfi_bank_w),
    .dfi_cas_n_i      (dfi_cas_n_w),
    .dfi_cke_i        (dfi_cke_w),
    .dfi_cs_n_i       (dfi_cs_n_w),
    .dfi_odt_i        (dfi_odt_w),
    .dfi_ras_n_i      (dfi_ras_n_w),
    .dfi_reset_n_i    (dfi_reset_n_w),
    .dfi_we_n_i       (dfi_we_n_w),
    .dfi_wrdata_i     (dfi_wrdata_w),
    .dfi_wrdata_en_i  (dfi_wrdata_en_w),
    .dfi_wrdata_mask_i(dfi_wrdata_mask_w),
    .dfi_rddata_en_i  (dfi_rddata_en_w),
    .dfi_rddata_o     (dfi_rddata_w),
    .dfi_rddata_valid_o(dfi_rddata_valid_w),
    .dfi_rddata_dnv_o (dfi_rddata_dnv_w),

    .ddr3_ck_p_o   (ddr3_ck_p),
    .ddr3_cke_o    (ddr3_cke),
    .ddr3_reset_n_o(ddr3_reset_n),
    .ddr3_ras_n_o  (ddr3_ras_n),
    .ddr3_cas_n_o  (ddr3_cas_n),
    .ddr3_we_n_o   (ddr3_we_n),
    .ddr3_cs_n_o   (ddr3_cs_n),
    .ddr3_ba_o     (ddr3_ba),
    .ddr3_addr_o   (phy_addr_w),
    .ddr3_odt_o    (ddr3_odt),
    .ddr3_dm_o     (ddr3_dm),
    .ddr3_dqs_p_io (ddr3_dqs_p),
    .ddr3_dq_io    (ddr3_dq)
);

/* The chip has 13 row bits (A0..A12); the PHY drives 15. */
assign ddr3_a = phy_addr_w[12:0];

`endif

/* ── CPU ─────────────────────────────────────────────────────────────────── */
cpu_risc2 cpu0(
    .clk(clk_sys), .clk_en(1'b1), .rst(rst),

    .instr_addr(instr_addr), .instr_value(instr_data), .instr_valid(instr_valid),
    .data_addr (data_addr),  .data_in_value(data_in_value), .data_in_valid(data_in_valid),
    .data_rd(data_rd),
    .data_out_value(data_out_value), .data_wr(data_wr),
    .data_out_strobe(data_out_strobe),
    .data_out_rdy(1'b1),
    .irq(1'b0), .irq_num(3'h0), .irq_ack(),
    .cpuDbg(cpuDbg)
);

/* ── Read-data mux + UART/SYS register handlers ──────────────────────────── *
 *
 * data_in_valid follows the existing arch/risc2 convention: drive 0 on the
 * cycle of data_rd for any region whose read result lags by one cycle
 * (BRAM ROM, scratch BRAM, *and* the DDR3 peripheral, since ddr3_iface
 * registers its rdata).  Valid pops back high one cycle later when data_rd2
 * is asserted, by which time data_in_value has been latched. */
reg data_rd2;
reg ddr3_range_d;
always @(posedge clk_sys or negedge rst) begin
    if (!rst) begin
        sled1 <= 0; sled2 <= 0;
        txdata <= 0; txen <= 0;
        rxen0 <= 0; rxrdy <= 0; rxovf <= 0;
        data_in_value <= 0; data_in_valid <= 0;
        data_rd2 <= 0; ddr3_range_d <= 0;
    end else begin
        rxen0        <= rxen;
        data_rd2     <= data_rd;
        ddr3_range_d <= ddr3_range;

        data_in_valid <= (data_rd && (data_addr[23:15] == 9'b0
                                       || data_addr[23:16] == `MEM_BRAM_PFX8
                                       || ddr3_range))
                        ? 1'b0 : 1'b1;

        if (data_rd2 && data_addr[23:15] == 9'b0)
            data_in_value <= rom_out_value;

        if (data_rd2 && data_addr[23:16] == `MEM_BRAM_PFX8)
            data_in_value <= dataram_out;

        if (data_rd2 && ddr3_range_d)
            data_in_value <= ddr3_iface_rdata;

        if (data_wr && data_addr == `ADDR_SYS_LED_SET) begin
            if (data_out_value[0]) sled1 <= 1;
            if (data_out_value[1]) sled2 <= 1;
        end
        if (data_wr && data_addr == `ADDR_SYS_LED_CLR) begin
            if (data_out_value[0]) sled1 <= 0;
            if (data_out_value[1]) sled2 <= 0;
        end

        if (data_rd && data_addr == `ADDR_UART_STATUS)
            data_in_value <= {5'b10000, txbusy, rxovf, rxrdy};

        if (data_wr && data_addr == `ADDR_UART_TX) begin
            txdata <= data_out_value[7:0];
            txen   <= ~txen;
        end

        if (data_rd && data_addr == `ADDR_UART_RX) begin
            data_in_value <= {24'b0, rxdata};
            rxrdy <= 0;
        end else if (rxen != rxen0) begin
            if (rxrdy) rxovf <= 1;
            rxrdy <= 1;
        end
    end
end

endmodule
