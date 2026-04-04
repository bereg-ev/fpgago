`include "project.vh"

module bootloader(
	input clk,
	input rst,

  input rxen_in,
  input [7:0] rxdata_in,
  output reg rxen_out,
  output reg [7:0] rxdata_out,

  output reg [9:0] bram_addr,
  output reg [17:0] bram_data,
  output reg bram_we,

  output reg cpu_rst_req
);

reg header1, header2, rxen_in1;

always @(posedge clk or negedge rst)
	if (!rst)
		{cpu_rst_req, header1, header2, rxen_in1, rxen_out, rxdata_out} <= 0;
	else
	begin
    rxen_in1 <= rxen_in;

    if (boot_done)
      cpu_rst_req <= 0;

    if (cpu_rst_req == 1'b0 && rxen_in1 != rxen_in)
    begin
      if (rxdata_in == 8'h00)
        {cpu_rst_req, header2, header1} <= {header2, header1, 1'b1};
      else
      begin
        {header1, header2} <= 0;
        rxen_out <= ~rxen_out;
        rxdata_out <= rxdata_in;
      end
    end

    if (cpu_rst_req == 1'b1)
      {header1, header2} <= 0;
  end

reg boot_done, st0, st1, st2, st3;
reg [1:0] bytes;

always @(posedge clk or negedge rst)
	if (!rst)
		{boot_done, bram_addr, bram_data, bram_we, st0, st1, st2} <= 0;
	else
  begin
    if (cpu_rst_req == 1'b0)
      {bram_addr, bram_we, bytes, boot_done, st0, st1, st2} <= 0;
    else
    begin
      if (rxen_in1 != rxen_in)
      begin
        bram_data[17:0] <= {bram_data[9:0], rxdata_in[7:0]};

        if (bytes == 2'b10)
        begin
          {st3, st2, st1, st0} <= 4'b0001;
          bytes <= 2'b00;
        end
        else
          bytes <= bytes + 1;
      end
      else
        {st3, st2, st1, st0} <= {st2, st1, st0, 1'b0};

      if (st1)
        bram_we <= 1;

      if (st2)
        bram_we <= 1'b0;

      if (st3)
      begin
        bram_addr <= bram_addr + 1;

`ifdef SIMULATION
        if (bram_addr == 10'h2)
`else
        if (bram_addr == 10'h3ff)
`endif
          boot_done <= 1;
      end
    end

  end

endmodule
