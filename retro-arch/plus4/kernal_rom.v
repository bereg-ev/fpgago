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

// ROM content arrives one of two ways.  Baked at synthesis (default), or —
// under ROMLESS — pushed at runtime through the write port below, so the
// shipped bitstream carries no copyrighted bytes (bitstreams/README.md).
//
// The ROMLESS branch still needs an explicit power-up value: an EBR with no
// init bakes x into the netlist and miscompiles on silicon only.  The two
// branches are mutually exclusive on purpose — yosys drops a $readmemh that
// follows a for-loop clear, so they must never both run.
`ifdef ROMLESS
integer i;
initial for (i = 0; i < 16384; i = i + 1) kernal[i] = 8'h00;
`else
initial begin
    $readmemh("../roms/kernal.hex", kernal);
end
`endif

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
