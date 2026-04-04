`include "project.vh"

`define CMD_STEP        8'h53    // 'S'
`define CMD_CONTINUE    8'h43    // 'C'
`define CMD_PRINT       8'h50    // 'P'
`define CMD_RESET       8'h52    // 'R'

module debugger(
	input clk,
	input rst,

  input rxen_in,
  input [7:0] rxdata_in,
  output reg rxen_out,
  output reg [7:0] rxdata_out,

  output reg txen,
  output reg [7:0] txdata,

  input [127:0] cpuDbg,
  output clk_en,
  output reg cpu_rst_req,
  output led

);

  reg [23:0] cnt;
  reg [127:0] dbgOut;        // 16 bytes of UART debug
  reg [6:0] dstate;
  reg [7:0] lo, hi, stepCnt, resetCnt;
  reg tick;
  reg rxen_in0;
  reg dbg_mode;
  reg [7:0] init_dbg_mode;

  assign clk_en = dbg_mode ? (rxen_in != rxen_in0 && rxdata_in == `CMD_STEP) : 1'b1;
  assign led = dbg_mode;

  always @(posedge clk or negedge rst)
  if (!rst)
  begin
      {rxen_out, rxdata_out, rxen_in0, txdata, txen, cnt, tick, dbgOut, dstate, cpu_rst_req, dbg_mode, init_dbg_mode} <= 0;
      {dbg_mode, init_dbg_mode} <= 0;
  end else
  begin
    cnt <= cnt + 1;
    rxen_in0 <= rxen_in;

`ifdef SIMULATION
    if (cnt == 24 'h000060)
`else
    if (cnt == 24'h08000)   // 30000
`endif
    begin
      tick <= 1;
      cnt <= 0;
    end else
      tick <= 0;

      if (tick)
      begin
        if (dstate == 7'h00)
        begin
          if (init_dbg_mode != 7'h15)
            init_dbg_mode <= init_dbg_mode + 1;

          if (init_dbg_mode == 7'h14)
            dbg_mode <= 1'b0;
        end else
        begin
          if (dstate[6:0] == 7'b1000001)
          begin
            dstate <= 7'b1000010;
            txdata <= 8'h0d;
            txen <= ~txen;
          end
          else if (dstate[6:0] == 7'b1000010)
          begin
            dstate <= 0;
            txdata <= 8'h0a;
            txen <= ~txen;
          end else
          begin
            if (dstate[1:0] == 2'b00)
            begin
              txdata <= 8'h20;
              txen <= ~txen;
            end
            else if (dstate[1:0] == 2'b01)
            begin
              hi = dbgOut[127:124] > 4'h9 ? 8'h41 + dbgOut[127:124] - 4'ha : 8'h30 + dbgOut[127:124];
              lo = dbgOut[123:120] > 4'h9 ? 8'h41 + dbgOut[123:120] - 4'ha : 8'h30 + dbgOut[123:120];
            end
            else if (dstate[1:0] == 2'b10)
            begin
              txdata <= hi;
              txen <= ~txen;
            end
            else if (dstate[1:0] == 2'b11)
            begin
              txdata <= lo;
              txen <= ~txen;
              dbgOut <= {dbgOut[119:0], 8'h0};
            end

            dstate <= dstate + 1;
            end
          end
      end

      if (rxen_in != rxen_in0)
        begin
          if (rxdata_in == `CMD_STEP)
          begin
            dbg_mode <= 1;
            stepCnt <= stepCnt + 1;
            rxen_out <= ~rxen_out;
            rxdata_out <= rxdata_in;
          end
          else if (rxdata_in == `CMD_CONTINUE)
          begin
            dbg_mode <= 0;
          end
          else if (rxdata_in == `CMD_RESET)
          begin
            resetCnt <= resetCnt + 1;
            dbg_mode <= 1;
            cpu_rst_req <= 1;
          end
          else if (rxdata_in == `CMD_PRINT)
          begin
            dstate <= 5'h01;
//            dbgOut[127:0] <= {cpuDbg[127:32], resetCnt[7:0], stepCnt[7:0], init_dbg_mode[7:0], 6'b0, cpu_rst_req, dbg_mode};
            dbgOut[127:0] <= cpuDbg[127:0];
          end else
          begin
            rxen_out <= ~rxen_out;
            rxdata_out <= rxdata_in;
          end
        end else
          cpu_rst_req <= 0;
    end

endmodule
