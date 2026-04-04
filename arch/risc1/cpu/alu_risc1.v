
`include "./risc1.vh"

module alu_risc1(
    input [7:0] opa,
    input [7:0] opb,
    input [3:0] instr,
		input c,
    output reg [8:0] out
    );

always @(opa or opb or instr)
begin
  case (instr)
		`INSTR_MOV:	out = {1'b0, opb};
		`INSTR_AND:	out = {1'b0, opa & opb};
		`INSTR_OR:	out = {1'b0, opa | opb};
		`INSTR_XOR:	out = {1'b0, opa ^ opb};
		`INSTR_ADD:	out = {1'b0, opa} + {1'b0, opb};
		`INSTR_SUB:	out = {{1'b0, opa} - {1'b0, opb}};
		`INSTR_RCL:	out = {opb, 1'b0};
		`INSTR_RCR:	out = {1'b0, c, opb[7:1]};
		`INSTR_CMP:	out = {{1'b0, opa} - {1'b0, opb}};
		default: 	out = 0;
  endcase
end

endmodule
