//===-- RISC2RegisterInfo.cpp - RISC2 Register Information ----------------===//
#include "RISC2RegisterInfo.h"
#include "RISC2.h"
#include "RISC2InstrInfo.h"
#include "RISC2Subtarget.h"
#include "RISC2TargetMachine.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/RegisterScavenging.h"
#include "llvm/CodeGen/TargetFrameLowering.h"
#include "llvm/Support/ErrorHandling.h"

using namespace llvm;

#define GET_REGINFO_TARGET_DESC
#include "RISC2GenRegisterInfo.inc"

RISC2RegisterInfo::RISC2RegisterInfo(unsigned HwMode)
    : RISC2GenRegisterInfo(RISC2::R15, /*DwarfFlavour=*/0,
                            /*EHFlavour=*/0, /*PC=*/0, HwMode) {}

const MCPhysReg *
RISC2RegisterInfo::getCalleeSavedRegs(const MachineFunction *MF) const {
  return CSR_RISC2_SaveList;
}

const uint32_t *
RISC2RegisterInfo::getCallPreservedMask(const MachineFunction &MF,
                                         CallingConv::ID CC) const {
  // Use the full callee-saved mask that includes R15 (link register).
  // Including R15 here tells LLVM's PEI that R15 is "preserved" across calls,
  // which causes PEI to add R15 as a live-in to every basic block in the
  // function — essential for leaf functions whose RET instruction uses R15
  // but where R15 is never written.
  //
  // For non-leaf functions, RISC2FrameLowering::determineCalleeSaves()
  // forcibly sets R15 in SavedRegs when hasCalls() is true, so PEI always
  // emits the R15 save/restore regardless of the "dead" def on CALL.
  return CSR_RISC2_RegMask;
}

BitVector RISC2RegisterInfo::getReservedRegs(const MachineFunction &MF) const {
  BitVector Reserved(getNumRegs());
  Reserved.set(RISC2::R7);   // R7 is scratch for frame-index elimination
  Reserved.set(RISC2::R14);  // SP is reserved
  return Reserved;
}

Register RISC2RegisterInfo::getFrameRegister(const MachineFunction &MF) const {
  return RISC2::R14;  // R14 is the stack pointer
}

bool RISC2RegisterInfo::eliminateFrameIndex(MachineBasicBlock::iterator II,
                                             int SPAdj, unsigned FIOperandNum,
                                             RegScavenger *RS) const {
  MachineInstr &MI      = *II;
  MachineFunction &MF   = *MI.getMF();
  MachineBasicBlock &MBB = *MI.getParent();
  DebugLoc DL           = MI.getDebugLoc();
  const RISC2Subtarget &STI =
      MF.getSubtarget<RISC2Subtarget>();
  const RISC2InstrInfo &TII = *STI.getInstrInfo();

  int FrameIndex = MI.getOperand(FIOperandNum).getIndex();

  // Compute the actual byte offset from SP
  int Offset = MF.getFrameInfo().getObjectOffset(FrameIndex)
             + MF.getFrameInfo().getStackSize()
             + SPAdj;

  // Also add any immediate displacement already in the operand
  if (FIOperandNum + 1 < MI.getNumOperands() &&
      MI.getOperand(FIOperandNum + 1).isImm())
    Offset += MI.getOperand(FIOperandNum + 1).getImm();

  Register SP = RISC2::R14;
  unsigned Opcode = MI.getOpcode();

  bool IsStore = (Opcode == RISC2::STORE32 || Opcode == RISC2::STORE8 ||
                  Opcode == RISC2::STORE16);
  bool IsLoad  = (Opcode == RISC2::LOAD32  || Opcode == RISC2::LOAD8  ||
                  Opcode == RISC2::LOAD16);

  // R7 is the dedicated scratch register for address computation.
  // (caller-saved, never appears in callee-save lists, safe to clobber)
  Register Scratch = RISC2::R7;

  // Helper: emit "scratch = SP + Offset" using 2-address MOV+ADD sequence.
  // We always use MOV_RR+ADD_RI to stay in 2-address form (gcasm only supports
  // the 2-address assembly syntax: "add dst, #imm" means dst = dst + imm).
  auto emitAddrInScratch = [&]() {
    // mov r7, r14
    BuildMI(MBB, II, DL, TII.get(RISC2::MOV_RR), Scratch).addReg(SP);
    if (isUInt<20>((uint64_t)Offset)) {
      // add r7, #Offset
      BuildMI(MBB, II, DL, TII.get(RISC2::ADD_RI), Scratch)
          .addReg(Scratch).addImm(Offset);
    } else {
      // Large offset: IMMInst sets upper 12 bits, ADD_RI handles lower 20 bits
      BuildMI(MBB, II, DL, TII.get(RISC2::IMMInst))
          .addImm((Offset >> 20) & 0xFFF);
      BuildMI(MBB, II, DL, TII.get(RISC2::ADD_RI), Scratch)
          .addReg(Scratch).addImm(Offset & 0xFFFFF);
    }
  };

  // Determine if this is a standalone address materialization (ADD_RI with FI).
  // ADD_RI is two-address: "add rX, #imm" means rX = rX + imm.  Changing the
  // source operand to R7 has NO effect on the assembly output because the asm
  // printer only emits the destination register.  Instead we must emit an
  // explicit MOV to copy the computed address into the destination register
  // and erase the original ADD_RI.
  bool IsStandaloneAddr = !IsLoad && !IsStore;

  if (IsStandaloneAddr) {
    // Standalone FI → materialise address in the destination register.
    Register DstReg = MI.getOperand(0).getReg();
    if (Offset == 0) {
      BuildMI(MBB, II, DL, TII.get(RISC2::MOV_RR), DstReg).addReg(SP);
    } else {
      // mov dst, SP ; add dst, #Offset
      BuildMI(MBB, II, DL, TII.get(RISC2::MOV_RR), DstReg).addReg(SP);
      if (isUInt<20>((uint64_t)Offset)) {
        BuildMI(MBB, II, DL, TII.get(RISC2::ADD_RI), DstReg)
            .addReg(DstReg).addImm(Offset);
      } else {
        BuildMI(MBB, II, DL, TII.get(RISC2::IMMInst))
            .addImm((Offset >> 20) & 0xFFF);
        BuildMI(MBB, II, DL, TII.get(RISC2::ADD_RI), DstReg)
            .addReg(DstReg).addImm(Offset & 0xFFFFF);
      }
    }
    MI.eraseFromParent();
    return false;
  }

  // LOAD / STORE cases.
  //
  // LOAD32 supports base+displacement: "load rDst, (r14+#offset)" — use it
  // directly instead of computing the address in R7.  This avoids emitting
  // the "mov r7,r14; add r7,#off" sequence that clobbers flags (the RISC2
  // ADD instruction updates Z/C, and these sequences land between CMP and
  // conditional branch instructions after register allocation).
  //
  // STORE does NOT support base+displacement in hardware (cpu_risc2.v uses
  // opb directly without adding displacement), so STOREs still go through
  // the scratch register.  The CPU R7 flag-neutral fix makes this safe.

  if (IsLoad && Opcode == RISC2::LOAD32) {
    // LOAD32 has base+displacement form: "load rDst, (rBase+#disp)"
    // Use it directly with SP as base and Offset as displacement.
    MI.getOperand(FIOperandNum).ChangeToRegister(SP, /*isDef=*/false);
    if (Offset == 0) {
      // Zero displacement → use LOAD32_base (no disp operand)
      MI.setDesc(TII.get(RISC2::LOAD32_base));
      if (FIOperandNum + 1 < MI.getNumOperands() &&
          MI.getOperand(FIOperandNum + 1).isImm())
        MI.removeOperand(FIOperandNum + 1);
    } else if (isUInt<16>((uint64_t)Offset)) {
      // Displacement fits in 16 bits → keep LOAD32, set displacement
      if (FIOperandNum + 1 < MI.getNumOperands() &&
          MI.getOperand(FIOperandNum + 1).isImm())
        MI.getOperand(FIOperandNum + 1).setImm(Offset);
    } else {
      // Large offset (>16 bits) — fall back to scratch register
      MI.getOperand(FIOperandNum).ChangeToRegister(Scratch, /*isDef=*/false);
      emitAddrInScratch();
      MI.setDesc(TII.get(RISC2::LOAD32_base));
      if (FIOperandNum + 1 < MI.getNumOperands() &&
          MI.getOperand(FIOperandNum + 1).isImm())
        MI.removeOperand(FIOperandNum + 1);
    }
  } else if (IsStore) {
    // STORE has no base+displacement in hardware — must use scratch register.
    if (Offset == 0) {
      MI.getOperand(FIOperandNum).ChangeToRegister(SP, /*isDef=*/false);
    } else {
      emitAddrInScratch();
      MI.getOperand(FIOperandNum).ChangeToRegister(Scratch, /*isDef=*/false);
    }
    if (FIOperandNum + 1 < MI.getNumOperands() &&
        MI.getOperand(FIOperandNum + 1).isImm())
      MI.removeOperand(FIOperandNum + 1);
  } else {
    // Other LOAD variants (LOAD8, LOAD16) — use scratch register for now
    if (Offset == 0) {
      MI.getOperand(FIOperandNum).ChangeToRegister(SP, /*isDef=*/false);
    } else {
      emitAddrInScratch();
      MI.getOperand(FIOperandNum).ChangeToRegister(Scratch, /*isDef=*/false);
    }
  }

  return false;
}
