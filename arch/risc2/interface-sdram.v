
// dummy reads for refreshing??????

module interface_sdram(
  input clk,
  input rst,

  input [7:0] base_addr,
  input [7:0] port_addr,
  input [7:0] port_data_out,
  input port_wr,
  output reg [7:0] out_st,
  output reg [7:0] out_lo,
  output reg [7:0] out_hi,

  output sd_clk,
  output sd_cke,
  output sd_cs,
  output sd_ras,
  output sd_cas,
  output sd_we,
  output [12:0] sd_a,
  inout  [15:0] sd_d,
  output [1:0] sd_ba,
  output sd_ldqm,
  output sd_udqm,
  output dbg1,
  output dbg2
);

  wire [15:0] bram_di, bram_do;
  wire bram_we;
  wire [9:0] bram_w_addr, bram_r_addr;
  reg start_read, start_write, start_init;
  wire [7:0] dbg;

  /* dummy1/dummy2: extra 2-bit slices from ram1 dout_a that are not used.
   * Declared here so Verilator does not error on undeclared identifiers. */
  wire [1:0] dummy1, dummy2;

  /* sd_clk must be driven — drive it from the system clock.
   * (Required for Verilator; on real hardware this pin comes from the PLL.) */
  assign sd_clk = clk;

  reg if_we;
  reg [9:0] if_addr;
  reg [15:0] if_w_data;
  wire [17:0] if_r_data;

  assign dbg1 = if_addr[0]; // if_r_data[0]; //bram_di[0];
  assign dbg2 = if_r_data[0];

  sdram sdram0(.clk(clk), .rst(rst),
    .bram_di(bram_di), .bram_do(bram_do), .bram_we(bram_we),
    .w_addr(bram_w_addr), .r_addr(bram_r_addr),
    .start_init(start_init), .start_read(start_read), .start_write(start_write),
    .dbg(dbg),

    .r_col(10'b0), .r_stop(10'h03f), .w_col(10'b0), .w_addr_start(10'b0), .w_stop(10'h3ff),
    .fill_en(1'b0), .fill_const(16'b0),

    .sd_cke(sd_cke), .sd_cs(sd_cs), .sd_ras(sd_ras), .sd_cas(sd_cas), .sd_we(sd_we),
    .sd_a(sd_a), .sd_d(sd_d), .sd_ba(sd_ba), .sd_ldqm(sd_ldqm), .sd_udqm(sd_udqm),
    .write_pending()
    );

  ram_1k_18 ram0(
//  dual_port_ram_1k_18 ram0(
    .clk_a(clk), .we_a(bram_we), .addr_a(bram_r_addr), .din_a({2'b0, bram_di}), //.dout_a(instr_data[17:0])
    .clk_b(clk), .we_b(1'b0), .addr_b(if_addr), .din_b(18'b0), .dout_b(if_r_data)
  );

  ram_1k_18 ram1(
//  dual_port_ram_1k_18 ram1(
    .clk_a(clk), .we_a(1'b0), .addr_a(bram_w_addr), .din_a(18'b0), .dout_a({dummy1, dummy2, bram_do}),
    .clk_b(clk), .we_b(if_we), .addr_b(if_addr), .din_b({2'b0, if_w_data}) //.dout_a(bram_do),
  );

  always @(posedge clk or negedge rst)
  if (!rst)
  begin
    {out_st, out_lo, out_hi, if_we, if_addr, if_w_data} <= 0;
    {start_init, start_read, start_write} <= 0;
  end else
  begin
    {out_hi, out_lo, out_st} <= {if_r_data[15:0], dbg};

    if (port_wr && port_addr == base_addr)              //
    begin
      if (port_data_out[0])
        start_init <= ~start_init;

	    if (port_data_out[1])
        start_read <= ~start_read;

	    if (port_data_out[2])
        start_write <= ~start_write;

	    if (port_data_out[3])
        if_addr <= 0;

	    if (port_data_out[4])
        if_addr <= if_addr + 1;

	    if (port_data_out[5])
        if_we <= 1'b1;
    end else
      if_we <= 1'b0;

    if (port_wr && port_addr == {base_addr[7:2], 2'b01})              //
      if_w_data[7:0] = port_data_out;

    if (port_wr && port_addr == {base_addr[7:2], 2'b10})              //
      if_w_data[15:8] = port_data_out;

  end

endmodule