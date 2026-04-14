`timescale 1ns / 1ps
// Verilog replacement for gen_ram.vhd (generic dual-port RAM)

module gen_ram #(
    parameter dWidth = 8,
    parameter aWidth = 10
)(
    input clk,
    input we,
    input [aWidth-1:0] addr,
    input [dWidth-1:0] d,
    output reg [dWidth-1:0] q
);

reg [dWidth-1:0] mem [0:(1<<aWidth)-1];

always @(posedge clk) begin
    if (we)
        mem[addr] <= d;
    q <= mem[addr];
end

endmodule
