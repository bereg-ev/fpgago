// RISC2 Calling Convention
//
// Arguments:  R0-R3 (first 4 int args), remaining on stack
// Return:     R0 (and R1 for i64, not yet supported)
// Callee-saved: R8-R13, R14(SP)
// Caller-saved: R0-R7, R15(LR clobbered by CALL)

// Return value convention
def RetCC_RISC2 : CallingConv<[
  CCIfType<[i1, i8, i16], CCPromoteToType<i32>>,
  CCIfType<[i32], CCAssignToReg<[R0, R1, R2, R3]>>,
  CCIfType<[i32], CCAssignToStack<4, 4>>
]>;

// Argument passing convention
def CC_RISC2 : CallingConv<[
  CCIfType<[i1, i8, i16], CCPromoteToType<i32>>,
  CCIfType<[i32], CCAssignToReg<[R0, R1, R2, R3]>>,
  CCIfType<[i32], CCAssignToStack<4, 4>>
]>;

// R8-R13: callee-saved GP registers
// R14: stack pointer — managed by FrameLowering, NOT here
// R15: link register — clobbered by CALL, saved by non-leaf functions
def CSR_RISC2 : CalleeSavedRegs<(add R8, R9, R10, R11, R12, R13, R15)>;

// Call-preserved mask used in CALL instruction regmask operands.
// R15 is intentionally excluded: the CALL instruction itself writes R15
// (with the return address for the callee), so from the CALLER's perspective
// R15 is clobbered at every call site.  PEI uses CSR_RISC2 (which includes
// R15) to emit the single function-entry save / function-exit restore.
def CSR_RISC2_Call : CalleeSavedRegs<(add R8, R9, R10, R11, R12, R13)>;
