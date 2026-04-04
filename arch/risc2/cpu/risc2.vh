

`define		INSTR_NOP	    5'h0
`define		INSTR_LOAD	  5'h1
`define		INSTR_STORE	  5'h2
`define		INSTR_JMP	    5'h3
`define		INSTR_IMM	    5'h4
`define		INSTR_SLEEP   5'h5

`define		INSTR_MOV	    5'h7
`define		INSTR_AND	    5'h8
`define		INSTR_OR	    5'h9
`define		INSTR_XOR	    5'hA
`define		INSTR_ADD	    5'hB
`define		INSTR_SUB	    5'hC
`define		INSTR_RCL	    5'hD
`define		INSTR_RCR	    5'hE
`define		INSTR_CMP	    5'hF

`define STAGE_1_FETCH       3'h0
`define STAGE_2_DECODE      3'h1
`define STAGE_3_EXECUTE     3'h2
`define STAGE_4_MEMORY      3'h3
`define STAGE_5_WRITEBACK   3'h4
`define STAGE_6_IRQ         3'h5

// reg: reg0 .. reg15 (32 bites)
// stack: nincs, bazis relativ load / store, valamint call-nal regiszterbe irja a return address-t
// interrupt: flag-ek mentese, IRET-nel visszaallitasa

// [31:27] opcode, [26] reg/const, [25:24] 32 bit / 16H bit, / 16L bit, 8 bit,
//  [23:20] opA, [19:16] opB vagy const[19:16], [15:0] disp - vagy const[15:0]
//								0 = regA, regB
//								1 = regA, const

// JMP:  [26:24] = 000 (jnz), 001 (jz), 010 (jnc), 011 (jc),
//                100 (jmp), 111 (call), 110 (ret), 101 (iret)
//       [23:0] relative
//
// IMM: [11:0] imm, upper 12 bits