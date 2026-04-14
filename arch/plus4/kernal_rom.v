`timescale 1ns / 1ps
// Plus/4 Kernal ROM — loads Plus/4 kernal (PAL).
// Based on FPGATED kernal_rom module.

module kernal_rom #(parameter MODE_PAL=1) (
    input wire clk,
    input wire [13:0] address_in,
    output wire [7:0] data_out,
    input wire [7:0] data_in,
    input wire wr,
    input wire cs
    );

(* ROM_STYLE="BLOCK" *)
reg [7:0] kernal [0:16383];
reg [7:0] data;
reg cs_prev=1'b1;
wire enable;

initial begin
    $readmemh("../roms/kernal.hex", kernal);
end

always@(posedge clk) begin
    if (wr)
        kernal[address_in] <= data_in;

    if(enable)
        data<=kernal[address_in];
end

always@(posedge clk)
    cs_prev<=cs;

assign enable=~cs&cs_prev;     // cs falling edge detection
assign data_out=(~cs)?data:8'hff;

endmodule
