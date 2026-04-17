// RISC2 Instruction Definitions
// Opcodes from risc2.vh:
//   NOP=0, LOAD=1, STORE=2, JMP=3, IMM=4, SLEEP=5, MOV=7
//   AND=8, OR=9, XOR=0xA, ADD=0xB, SUB=0xC, RCL=0xD, RCR=0xE, CMP=0xF

include "RISC2InstrFormats.td"

//===----------------------------------------------------------------------===//
// Custom RISC2 SDNodes
//===----------------------------------------------------------------------===//

def SDT_RISC2Call    : SDTypeProfile<0, 1, [SDTCisVT<0, iPTR>]>;
def SDT_RISC2CallSeqStart : SDCallSeqStart<[SDTCisVT<0, i32>, SDTCisVT<1, i32>]>;
def SDT_RISC2CallSeqEnd   : SDCallSeqEnd<[SDTCisVT<0, i32>, SDTCisVT<1, i32>]>;
def SDT_RISC2Ret     : SDTypeProfile<0, 0, []>;
def SDT_RISC2CmpBr   : SDTypeProfile<0, 4, [SDTCisVT<0, i32>, SDTCisVT<1, i32>,
                                             SDTCisVT<2, i32>, SDTCisVT<3, OtherVT>]>;
def SDT_RISC2Wrapper : SDTypeProfile<1, 1, [SDTCisSameAs<0, 1>, SDTCisPtrTy<0>]>;
def SDT_RISC2SelectCC : SDTypeProfile<1, 5, [SDTCisSameAs<0, 1>, SDTCisSameAs<1, 2>,
                                              SDTCisVT<3, i32>, SDTCisVT<4, i32>,
                                              SDTCisVT<5, OtherVT>]>;

def RISC2callseq_start : SDNode<"ISD::CALLSEQ_START", SDT_RISC2CallSeqStart,
                                [SDNPHasChain, SDNPOutGlue]>;
def RISC2callseq_end   : SDNode<"ISD::CALLSEQ_END",   SDT_RISC2CallSeqEnd,
                                [SDNPHasChain, SDNPOptInGlue, SDNPOutGlue]>;
def RISC2call    : SDNode<"RISC2ISD::CALL",    SDT_RISC2Call,
                          [SDNPHasChain, SDNPOutGlue, SDNPOptInGlue, SDNPVariadic]>;
def RISC2ret     : SDNode<"RISC2ISD::RET",     SDT_RISC2Ret,
                          [SDNPHasChain, SDNPOptInGlue, SDNPVariadic]>;
def RISC2cmpbr   : SDNode<"RISC2ISD::CMPBR",  SDT_RISC2CmpBr,
                          [SDNPHasChain]>;
def RISC2wrapper : SDNode<"RISC2ISD::WRAPPER", SDT_RISC2Wrapper>;
def RISC2selectcc: SDNode<"RISC2ISD::SELECT_CC", SDT_RISC2SelectCC>;

//===----------------------------------------------------------------------===//
// Operand definitions
//===----------------------------------------------------------------------===//

// 20-bit unsigned immediate (fits directly in instruction)
def uimm20 : Operand<i32> {
  let PrintMethod = "printUImm20Operand";
}

// MOV immediate/address: prints #hex for literals, @label for symbol refs
// Used by MOV_RI so the template has no '#' prefix
def mov_imm : Operand<i32> {
  let PrintMethod = "printMovImmAddr";
}

// 16-bit unsigned displacement (LOAD only)
def uimm16 : Operand<i32> {
  let PrintMethod = "printUImm16Operand";
}

// 12-bit immediate for IMM instruction
def uimm12 : Operand<i32> {
  let PrintMethod = "printUImm12Operand";
}

// Branch target (24-bit PC-relative offset)
def brtarget24 : Operand<OtherVT> {
  let PrintMethod = "printBranchTarget";
  let EncoderMethod = "getBranchTargetEncoding";
}

// 22-bit branch target for signed branches (JGE/JLT)
def brtarget22 : Operand<OtherVT> {
  let PrintMethod = "printBranchTarget";
  let EncoderMethod = "getBranchTargetEncoding";
}

// Call target
def calltarget : Operand<iPTR> {
  let PrintMethod = "printCallTarget";
  let EncoderMethod = "getCallTargetEncoding";
}

// Condition code operand
def ccop : Operand<i32> {
  let PrintMethod = "printCondCode";
}

// PatLeafs for immediate matching
def imm20_pat : PatLeaf<(imm), [{
  return isUInt<20>(N->getZExtValue());
}]>;

def imm16_pat : PatLeaf<(imm), [{
  return isUInt<16>(N->getZExtValue());
}]>;

//===----------------------------------------------------------------------===//
// NOP
//===----------------------------------------------------------------------===//

def NOP : RISC2Inst<0x0, (outs), (ins), "nop", []> {
  let hasSideEffects = 0;
  let mayLoad  = 0;
  let mayStore = 0;
}

//===----------------------------------------------------------------------===//
// IMM (loads upper 12 bits for next instruction's 32-bit immediate)
//===----------------------------------------------------------------------===//

def IMMInst : RISC2Inst<0x4, (outs), (ins uimm12:$upper12),
    "imm #$upper12", []> {
  bits<12> upper12;
  let Inst{26}   = 1;
  let Inst{11-0} = upper12;
  let hasSideEffects = 1;
}

//===----------------------------------------------------------------------===//
// LOAD instructions
// Format: load[.b/.w/.d] dst, (base+#disp)  OR  load dst, (#absaddr)
// [31:27]=1, [25:24]=width, [23:20]=dst, [19:16]=base, [15:0]=disp (zero-ext)
//===----------------------------------------------------------------------===//

// 32-bit load: load dst, (base+#disp16)
def LOAD32 : RISC2Inst<0x1,
    (outs GPR:$dst),
    (ins  GPR:$base, uimm16:$disp),
    "load $dst, ($base+#$disp)",
    [(set i32:$dst, (load (add GPR:$base, imm16_pat:$disp)))]> {
  bits<4>  dst;
  bits<4>  base;
  bits<16> disp;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b00;
  let Inst{23-20} = dst;
  let Inst{19-16} = base;
  let Inst{15-0}  = disp;
  let mayLoad = 1;
}

// 32-bit load with zero displacement (simplifies eliminateFrameIndex)
def LOAD32_base : RISC2Inst<0x1,
    (outs GPR:$dst),
    (ins  GPR:$base),
    "load $dst, ($base)",
    [(set i32:$dst, (load GPR:$base))]> {
  bits<4> dst;
  bits<4> base;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b00;
  let Inst{23-20} = dst;
  let Inst{19-16} = base;
  let Inst{15-0}  = 0;
  let mayLoad = 1;
}

// 8-bit load with displacement: load.b dst, (base+#disp16)
def LOAD8 : RISC2Inst<0x1,
    (outs GPR:$dst),
    (ins  GPR:$base, uimm16:$disp),
    "load.b $dst, ($base+#$disp)",
    [(set i32:$dst, (zextloadi8 (add GPR:$base, imm16_pat:$disp)))]> {
  bits<4>  dst;
  bits<4>  base;
  bits<16> disp;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b01;  // byte
  let Inst{23-20} = dst;
  let Inst{19-16} = base;
  let Inst{15-0}  = disp;
  let mayLoad = 1;
}

// 8-bit load, zero displacement: load.b dst, (base)
def LOAD8_base : RISC2Inst<0x1,
    (outs GPR:$dst),
    (ins  GPR:$base),
    "load.b $dst, ($base)",
    [(set i32:$dst, (zextloadi8 GPR:$base))]> {
  bits<4> dst;
  bits<4> base;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b01;
  let Inst{23-20} = dst;
  let Inst{19-16} = base;
  let Inst{15-0}  = 0;
  let mayLoad = 1;
}

// 16-bit load with displacement: load.w dst, (base+#disp16)
def LOAD16 : RISC2Inst<0x1,
    (outs GPR:$dst),
    (ins  GPR:$base, uimm16:$disp),
    "load.w $dst, ($base+#$disp)",
    [(set i32:$dst, (zextloadi16 (add GPR:$base, imm16_pat:$disp)))]> {
  bits<4>  dst;
  bits<4>  base;
  bits<16> disp;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b10;  // 16H (lower 16 bits at even word)
  let Inst{23-20} = dst;
  let Inst{19-16} = base;
  let Inst{15-0}  = disp;
  let mayLoad = 1;
}

// 16-bit load, zero displacement: load.w dst, (base)
def LOAD16_base : RISC2Inst<0x1,
    (outs GPR:$dst),
    (ins  GPR:$base),
    "load.w $dst, ($base)",
    [(set i32:$dst, (zextloadi16 GPR:$base))]> {
  bits<4> dst;
  bits<4> base;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b10;
  let Inst{23-20} = dst;
  let Inst{19-16} = base;
  let Inst{15-0}  = 0;
  let mayLoad = 1;
}

// extload (any-extend) patterns — reuse the zero-extending LOAD8/LOAD16
// hardware instructions since the upper bits don't matter for any-extend.
def : Pat<(extloadi8  (add GPR:$base, imm16_pat:$disp)), (LOAD8  GPR:$base, uimm16:$disp)>;
def : Pat<(extloadi8  GPR:$base),                         (LOAD8_base  GPR:$base)>;
def : Pat<(extloadi16 (add GPR:$base, imm16_pat:$disp)), (LOAD16 GPR:$base, uimm16:$disp)>;
def : Pat<(extloadi16 GPR:$base),                         (LOAD16_base GPR:$base)>;

//===----------------------------------------------------------------------===//
// STORE instructions
// NO displacement — address must be in a register
// gcasm syntax: store (addr_reg), val_reg  (operands swapped by gcasm)
// LLVM internal: STORE32 val, addr
// [31:27]=2, [25:24]=width, [23:20]=val(opA), [19:16]=addr(opB)
//===----------------------------------------------------------------------===//

def STORE32 : RISC2Inst<0x2,
    (outs),
    (ins GPR:$val, GPR:$addr),
    "store ($addr), $val",
    [(store GPR:$val, GPR:$addr)]> {
  bits<4> val;
  bits<4> addr;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b00;
  let Inst{23-20} = val;
  let Inst{19-16} = addr;
  let Inst{15-0}  = 0;
  let mayStore = 1;
}

def STORE8 : RISC2Inst<0x2,
    (outs),
    (ins GPR:$val, GPR:$addr),
    "store.b ($addr), $val",
    [(truncstorei8 GPR:$val, GPR:$addr)]> {
  bits<4> val;
  bits<4> addr;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b01;  // byte
  let Inst{23-20} = val;
  let Inst{19-16} = addr;
  let Inst{15-0}  = 0;
  let mayStore = 1;
}

def STORE16 : RISC2Inst<0x2,
    (outs),
    (ins GPR:$val, GPR:$addr),
    "store.w ($addr), $val",
    [(truncstorei16 GPR:$val, GPR:$addr)]> {
  bits<4> val;
  bits<4> addr;
  let Inst{26}    = 0;
  let Inst{25-24} = 0b10;  // 16H
  let Inst{23-20} = val;
  let Inst{19-16} = addr;
  let Inst{15-0}  = 0;
  let mayStore = 1;
}

//===----------------------------------------------------------------------===//
// ALU instructions (two-address: dst is also src1)
//===----------------------------------------------------------------------===//

// MOV reg, reg
def MOV_RR : RISC2Inst<0x7,
    (outs GPR:$dst),
    (ins  GPR:$src),
    "mov $dst, $src",
    []> {
  bits<4> dst;
  bits<4> src;
  let Inst{26}    = 0;
  let Inst{23-20} = dst;
  let Inst{19-16} = src;
  let Inst{15-0}  = 0;
}

// MOV reg, #imm20  (or @label for symbol addresses)
def MOV_RI : RISC2Inst<0x7,
    (outs GPR:$dst),
    (ins  mov_imm:$imm),
    "mov $dst, $imm",
    []> {
  bits<4>  dst;
  bits<20> imm;
  let Inst{26}    = 1;
  let Inst{23-20} = dst;
  let Inst{19-16} = imm{19-16};
  let Inst{15-0}  = imm{15-0};
}

// ADD
def ADD_RR : ALUInstRR<0xB, "add", add, 1>;
def ADD_RI : ALUInstRI<0xB, "add", add>;

// SUB
def SUB_RR : ALUInstRR<0xC, "sub", sub>;
def SUB_RI : ALUInstRI<0xC, "sub", sub>;

// AND
def AND_RR : ALUInstRR<0x8, "and", and, 1>;
def AND_RI : ALUInstRI<0x8, "and", and>;

// OR
def OR_RR : ALUInstRR<0x9, "or", or, 1>;
def OR_RI : ALUInstRI<0x9, "or", or>;

// XOR
def XOR_RR : ALUInstRR<0xA, "xor", xor, 1>;
def XOR_RI : ALUInstRI<0xA, "xor", xor>;

// CMP (sets flags, no destination register written)
def CMP_RR : RISC2Inst<0xF,
    (outs),
    (ins GPR:$src1, GPR:$src2),
    "cmp $src1, $src2",
    []> {
  bits<4> src1;
  bits<4> src2;
  let Inst{26}    = 0;
  let Inst{23-20} = src1;
  let Inst{19-16} = src2;
  let Inst{15-0}  = 0;
  let Defs = [FLAGS];
  let hasSideEffects = 1;
}

def CMP_RI : RISC2Inst<0xF,
    (outs),
    (ins GPR:$src1, uimm20:$imm),
    "cmp $src1, #$imm",
    []> {
  bits<4>  src1;
  bits<20> imm;
  let Inst{26}    = 1;
  let Inst{23-20} = src1;
  let Inst{19-16} = imm{19-16};
  let Inst{15-0}  = imm{15-0};
  let Defs = [FLAGS];
  let hasSideEffects = 1;
}

// RCL/RCR (single-bit shift through carry)
// These are used internally for shift expansion; not directly pattern-matched
def RCL_RR : ALUInstRR<0xD, "rcl", shl>;
def RCR_RI : RISC2Inst<0xE,
    (outs GPR:$dst),
    (ins  GPR:$src1),
    "rcr $dst, $src1",
    []> {
  bits<4> src1;
  let Inst{26}    = 0;
  let Inst{23-20} = src1;
  let Inst{19-16} = src1;
  let Inst{15-0}  = 0;
  let Constraints = "$dst = $src1";
  let Defs = [FLAGS];
}

//===----------------------------------------------------------------------===//
// Branch/Jump instructions
// [31:27]=3, [26:24]=condition encoding, [23:0]=PC-relative offset (signed)
// Relative to CURRENT instruction address (not PC+4)
//===----------------------------------------------------------------------===//

// Condition codes for JMP instructions (bits [26:24])
// 000=JNZ, 001=JZ, 010=JNC, 011=JC, 100=JMP, 111=CALL, 110=RET, 101=IRET

def JMP : RISC2Inst<0x3, (outs), (ins brtarget24:$target),
    "jmp $target",
    [(br bb:$target)]> {
  bits<24> target;
  let Inst{26-24} = 0b100;
  let Inst{23-0}  = target;
  let isBranch    = 1;
  let isTerminator = 1;
  let isBarrier   = 1;
}

def JNZ : RISC2Inst<0x3, (outs), (ins brtarget24:$target),
    "jnz $target", []> {
  bits<24> target;
  let Inst{26-24} = 0b000;
  let Inst{23-0}  = target;
  let isBranch    = 1;
  let isTerminator = 1;
  let Uses = [FLAGS];
}

def JZ : RISC2Inst<0x3, (outs), (ins brtarget24:$target),
    "jz $target", []> {
  bits<24> target;
  let Inst{26-24} = 0b001;
  let Inst{23-0}  = target;
  let isBranch    = 1;
  let isTerminator = 1;
  let Uses = [FLAGS];
}

def JNC : RISC2Inst<0x3, (outs), (ins brtarget24:$target),
    "jnc $target", []> {
  bits<24> target;
  let Inst{26-24} = 0b010;
  let Inst{23-0}  = target;
  let isBranch    = 1;
  let isTerminator = 1;
  let Uses = [FLAGS];
}

def JC : RISC2Inst<0x3, (outs), (ins brtarget24:$target),
    "jc $target", []> {
  bits<24> target;
  let Inst{26-24} = 0b011;
  let Inst{23-0}  = target;
  let isBranch    = 1;
  let isTerminator = 1;
  let Uses = [FLAGS];
}

// Signed branches: reuse IRET slot [26:24]=101 with [23]=1
// JGE: [22]=0, offset=[21:0]  — branch if N==V (signed >=)
// JLT: [22]=1, offset=[21:0]  — branch if N!=V (signed <)
def JGE : RISC2Inst<0x3, (outs), (ins brtarget22:$target),
    "jge $target", []> {
  bits<22> target;
  let Inst{26-24} = 0b101;
  let Inst{23}    = 1;
  let Inst{22}    = 0;
  let Inst{21-0}  = target;
  let isBranch    = 1;
  let isTerminator = 1;
  let Uses = [FLAGS];
}

def JLT : RISC2Inst<0x3, (outs), (ins brtarget22:$target),
    "jlt $target", []> {
  bits<22> target;
  let Inst{26-24} = 0b101;
  let Inst{23}    = 1;
  let Inst{22}    = 1;
  let Inst{21-0}  = target;
  let isBranch    = 1;
  let isTerminator = 1;
  let Uses = [FLAGS];
}

// CALL: hardwired saves return addr to R15
def CALL_target : RISC2Inst<0x3,
    (outs),
    (ins calltarget:$target, variable_ops),
    "call $target",
    []> {
  bits<24> target;
  let Inst{26-24} = 0b111;
  let Inst{23-0}  = target;
  let isCall      = 1;
  let Defs        = [R15, FLAGS];  // CALL writes R15; callee clobbers FLAGS
}

// CALL via register (indirect call)
def CALL_reg : RISC2Inst<0x3,
    (outs),
    (ins GPR:$addr, variable_ops),
    "call $addr",
    []> {
  bits<4> addr;
  let Inst{26-24} = 0b111;
  let Inst{19-16} = addr;
  let isCall      = 1;
  let Defs        = [R15, FLAGS];
}

// RET: jumps to R15
def RET : RISC2Inst<0x3, (outs), (ins variable_ops),
    "ret",
    [(RISC2ret)]> {
  let Inst{26-24} = 0b110;
  let Inst{23-0}  = 0;
  let isReturn    = 1;
  let isTerminator = 1;
  let isBarrier   = 1;
  let Uses        = [R15];
}

//===----------------------------------------------------------------------===//
// Pseudo instructions used during code generation
//===----------------------------------------------------------------------===//

// Spill/restore pseudos (expanded by FrameLowering)
let isCodeGenOnly = 1, Defs = [R14], Uses = [R14] in {
def ADJCALLSTACKDOWN : Pseudo<(outs), (ins i32imm:$amt1, i32imm:$amt2),
    "# ADJCALLSTACKDOWN $amt1",
    [(RISC2callseq_start timm:$amt1, timm:$amt2)]>;

def ADJCALLSTACKUP : Pseudo<(outs), (ins i32imm:$amt1, i32imm:$amt2),
    "# ADJCALLSTACKUP $amt1",
    [(RISC2callseq_end timm:$amt1, timm:$amt2)]>;
}

// SELECT_CC pseudo (expanded by emitInstrWithCustomInserter)
def SELECT_CC : Pseudo<(outs GPR:$dst),
    (ins GPR:$trueVal, GPR:$falseVal, i32imm:$cc, GPR:$lhs, GPR:$rhs),
    "# SELECT_CC", []> {
  let usesCustomInserter = 1;
}
