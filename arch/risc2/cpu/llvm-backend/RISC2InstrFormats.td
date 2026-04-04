// RISC2 Instruction Encoding Format
//
// All instructions are 32-bit.
// [31:27] = opcode (5 bits)
// [26]    = reg/imm mode: 0=register, 1=immediate
// [25:24] = width: 00=32bit, 01=8bit, 10=16H, 11=16L  (for LOAD/STORE)
// [23:20] = opA (destination / first source register, 4 bits)
// [19:16] = opB register OR imm[19:16] (4 bits)
// [15:0]  = displacement (LOAD only) OR imm[15:0]

// Base instruction class
class RISC2Inst<bits<5> opcode, dag outs, dag ins,
               string asmstr, list<dag> pattern>
    : Instruction {
  field bits<32> Inst;

  let Namespace      = "RISC2";
  let Size           = 4;
  let OutOperandList = outs;
  let InOperandList  = ins;
  let AsmString      = asmstr;
  let Pattern        = pattern;

  // Default: no delay slot, no branch
  let isCodeGenOnly  = 0;

  let Inst{31-27} = opcode;
  let Inst{26}    = 0;     // register mode by default
  let Inst{25-24} = 0b00;  // 32-bit width by default
  let Inst{23-0}  = 0;
}

// Pseudo instruction (used internally, not emitted as hardware instruction)
class Pseudo<dag outs, dag ins, string asmstr, list<dag> pattern>
    : RISC2Inst<0, outs, ins, asmstr, pattern> {
  let isPseudo    = 1;
  let isCodeGenOnly = 1;
}

// --- ALU two-address register-register format ---
// opcode dst, src2   (dst is also implicit src1 = two-address)
// [26]=0, [23:20]=dst/src1, [19:16]=src2
class ALUInstRR<bits<5> op, string mnem, SDNode opnode,
               bit isComm = 0>
    : RISC2Inst<op,
        (outs GPR:$dst),
        (ins  GPR:$src1, GPR:$src2),
        !strconcat(mnem, " $dst, $src2"),
        [(set i32:$dst, (opnode i32:$src1, i32:$src2))]> {
  bits<4> src1;
  bits<4> src2;
  let Inst{26}    = 0;
  let Inst{23-20} = src1;
  let Inst{19-16} = src2;
  let Inst{15-0}  = 0;
  let isCommutable = isComm;
  // Two-address constraint: $dst tied to $src1
  let Constraints = "$dst = $src1";
}

// ALU two-address register-immediate format
// opcode dst, #imm20  (immediate fits in 20 bits)
// [26]=1, [23:20]=dst/src1, [19:16]=imm[19:16], [15:0]=imm[15:0]
class ALUInstRI<bits<5> op, string mnem, SDNode opnode>
    : RISC2Inst<op,
        (outs GPR:$dst),
        (ins  GPR:$src1, i32imm:$imm),
        !strconcat(mnem, " $dst, $imm"),
        [(set i32:$dst, (opnode i32:$src1, imm:$imm))]> {
  bits<4>  src1;
  bits<20> imm;
  let Inst{26}    = 1;
  let Inst{23-20} = src1;
  let Inst{19-16} = imm{19-16};
  let Inst{15-0}  = imm{15-0};
  let Constraints = "$dst = $src1";
}
