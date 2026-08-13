`timescale 1ns / 1ps
// Plus/4 BASIC ROM — loads Plus/4 BASIC 3.5.
// Based on FPGATED basic_rom module.

module basic_rom(
    input wire clk,
    input wire [13:0] address_in,
    output wire [7:0] data_out,
    input wire [7:0] data_in,
    input wire wr,
    input wire cs
    );

(* ROM_STYLE="BLOCK" *)
reg [7:0] basic [0:16383];
reg [7:0] data;
reg cs_prev=1'b1;
wire enable;

always@(posedge clk) begin
    if (wr)
        basic[address_in] <= data_in;

    if(enable)
        data<=basic[address_in];
end

always@(posedge clk)
    cs_prev<=cs;

assign enable=~cs&cs_prev;     // cs falling edge detection
assign data_out=(~cs)?data:8'hff;

// See kernal_rom.v for why the two branches are mutually exclusive.
`ifdef ROMLESS
integer i;
initial for (i = 0; i < 16384; i = i + 1) basic[i] = 8'h00;
`else
initial begin
    $readmemh("../roms/basic.hex", basic);
end
`endif

endmodule
