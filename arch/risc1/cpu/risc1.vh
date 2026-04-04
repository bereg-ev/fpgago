

`define		INSTR_NOP	    4'h0
`define		INSTR_OUT	    4'h1
`define		INSTR_IN	    4'h2
`define		INSTR_JMP	    4'h3

`define		INSTR_MOV	    4'h7
`define		INSTR_AND	    4'h8
`define		INSTR_OR	    4'h9
`define		INSTR_XOR	    4'hA
`define		INSTR_ADD	    4'hB
`define		INSTR_SUB	    4'hC
`define		INSTR_RCL	    4'hD
`define		INSTR_RCR	    4'hE
`define		INSTR_CMP	    4'hF

`define STAGE_1_FETCH       3'h0
`define STAGE_2_DECODE      3'h1
`define STAGE_3_EXECUTE     3'h2
`define STAGE_4_WRITEBACK   3'h3

// reg: reg0 .. reg15 (8 bites)
// stack: 8 elemu hw stack

// [17:14] opcode, [13] reg/const, [12:9] opA, [8] reserved,     [3:0] opB reg  VAGY  [7:0] const
//								0 = regA, regB
//								1 = regA, const

// JMP:  [13:11] = 000 (jnz), 001 (jz), 010 (jnc), 011 (jc),
//                100 (jmp), 111 (call), 110 (ret)
//       [10]: sign bit, [9:0] relative
