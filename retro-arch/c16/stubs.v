`timescale 1ns / 1ps

// Stub modules for components not available in Verilator simulation

module ps2receiver(
    input clk, input ps2_clk, input ps2_data,
    output reg rx_done, output reg [7:0] ps2scancode
);
    always @(posedge clk) begin rx_done <= 0; ps2scancode <= 0; end
endmodule

module sid8580(
    input reset, input clk32, input clk_1MHz,
    input cs, input we,
    input [4:0] addr, input [7:0] data_in, output [7:0] data_out,
    input extfilter_en, output [15:0] audio_data
);
    assign data_out = 8'hFF;
    assign audio_data = 16'h0000;
endmodule

module sid_top #(parameter g_num_voices = 3) (
    input reset, input clock, input start_iter,
    input wren, input [7:0] addr, input [7:0] wdata, output [7:0] rdata,
    input extfilter_en, output signed [17:0] sample_left
);
    assign rdata = 8'hFF;
    assign sample_left = 0;
endmodule
