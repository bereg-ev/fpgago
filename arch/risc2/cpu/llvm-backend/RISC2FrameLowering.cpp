//===-- RISC2FrameLowering.cpp - RISC2 Frame Lowering --------------------===//
//
// Handles stack frame setup and teardown.
// R14 = SP (grows downward). No frame pointer (R14 is used directly).
// STORE has no displacement, so callee-save spills use address arithmetic.
//
#include "RISC2FrameLowering.h"
#include "RISC2InstrInfo.h"
#include "RISC2Subtarget.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/ADT/BitVector.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/RegisterScavenging.h"

using namespace llvm;

RISC2FrameLowering::RISC2FrameLowering(const RISC2Subtarget &STI)
    : TargetFrameLowering(TargetFrameLowering::StackGrowsDown,
                          Align(4),   // stack alignment: 4-byte (word)
                          0,          // local area offset
                          Align(4)),  // transit area alignment
      STI(STI) {}

// Helper: emit "SUB r14, r14, #n" (adjust SP)
static void emitSPAdjust(MachineBasicBlock &MBB,
                          MachineBasicBlock::iterator MBBI,
                          const DebugLoc &DL,
                          const RISC2InstrInfo &TII,
                          int Amount) {
  if (Amount == 0)
    return;
  // Amount should always fit in 20 bits for reasonable stack frames
  if (Amount > 0)
    BuildMI(MBB, MBBI, DL, TII.get(RISC2::SUB_RI), RISC2::R14)
        .addReg(RISC2::R14)
        .addImm(Amount);
  else
    BuildMI(MBB, MBBI, DL, TII.get(RISC2::ADD_RI), RISC2::R14)
        .addReg(RISC2::R14)
        .addImm(-Amount);
}

void RISC2FrameLowering::emitPrologue(MachineFunction &MF,
                                       MachineBasicBlock &MBB) const {
  MachineFrameInfo &MFI = MF.getFrameInfo();
  const RISC2InstrInfo &TII =
      *MF.getSubtarget<RISC2Subtarget>().getInstrInfo();

  MachineBasicBlock::iterator MBBI = MBB.begin();
  DebugLoc DL;

  uint64_t StackSize = MFI.getStackSize();
  if (StackSize == 0 && !MFI.hasCalls())
    return;

  // Allocate stack frame: SUB r14, r14, #StackSize
  emitSPAdjust(MBB, MBBI, DL, TII, (int)StackSize);
}

void RISC2FrameLowering::emitEpilogue(MachineFunction &MF,
                                       MachineBasicBlock &MBB) const {
  MachineFrameInfo &MFI = MF.getFrameInfo();
  const RISC2InstrInfo &TII =
      *MF.getSubtarget<RISC2Subtarget>().getInstrInfo();

  MachineBasicBlock::iterator MBBI = MBB.getLastNonDebugInstr();
  DebugLoc DL;
  if (MBBI != MBB.end())
    DL = MBBI->getDebugLoc();

  uint64_t StackSize = MFI.getStackSize();
  if (StackSize == 0 && !MFI.hasCalls())
    return;

  // Deallocate stack frame: ADD r14, r14, #StackSize
  emitSPAdjust(MBB, MBBI, DL, TII, -(int)StackSize);
}

MachineBasicBlock::iterator RISC2FrameLowering::eliminateCallFramePseudoInstr(
    MachineFunction &MF, MachineBasicBlock &MBB,
    MachineBasicBlock::iterator I) const {
  const RISC2InstrInfo &TII =
      *MF.getSubtarget<RISC2Subtarget>().getInstrInfo();

  if (!hasReservedCallFrame(MF)) {
    int64_t Amount = I->getOperand(0).getImm();
    if (Amount != 0) {
      if (I->getOpcode() == RISC2::ADJCALLSTACKDOWN)
        emitSPAdjust(MBB, I, I->getDebugLoc(), TII, (int)Amount);
      else
        emitSPAdjust(MBB, I, I->getDebugLoc(), TII, -(int)Amount);
    }
  }
  return MBB.erase(I);
}

void RISC2FrameLowering::determineCalleeSaves(MachineFunction &MF,
                                               BitVector &SavedRegs,
                                               RegScavenger *RS) const {
  TargetFrameLowering::determineCalleeSaves(MF, SavedRegs, RS);

  // R15 is the link register; CALL unconditionally overwrites it with the
  // callee's return address.  Any non-leaf function must therefore save R15
  // in the prologue and restore it in the epilogue so that RET can return to
  // the correct address.
  //
  // The CALL instruction's regmask marks R15 as "preserved" (so that LLVM's
  // PEI adds R15 liveins to every BB in leaf functions).  That causes the
  // implicit-def of R15 on CALL to be annotated "dead", which would normally
  // suppress PEI's save/restore.  We counteract that here by force-setting
  // R15 in SavedRegs whenever the function contains any call.
  if (MF.getFrameInfo().hasCalls())
    SavedRegs.set(RISC2::R15);
}

// spillCalleeSavedRegisters / restoreCalleeSavedRegisters:
// We rely on the default PEI mechanism (spillCalleeSavedRegister / restoreCalleeSavedRegister)
// which calls TII->storeRegToStackSlot / loadRegFromStackSlot.
// Those emit STORE32/LOAD32 with MO_FrameIndex operands, which eliminateFrameIndex
// later converts to proper SP+offset sequences — AFTER calculateFrameObjectOffsets
// has finalized the frame layout.
// A custom implementation that pre-computes offsets here would be wrong because
// PEI calls spillCalleeSavedRegisters BEFORE calculateFrameObjectOffsets.

void RISC2FrameLowering::processFunctionBeforeFrameFinalized(
    MachineFunction &MF, RegScavenger *RS) const {
  // Create an emergency spill slot so the register scavenger always has
  // somewhere to spill when all GPRs are live during frame-index elimination
  // (e.g. STORE32 to a non-zero stack offset needs a scratch register).
  if (RS) {
    int FI = MF.getFrameInfo().CreateStackObject(4, Align(4), false);
    RS->addScavengingFrameIndex(FI);
  }
}
