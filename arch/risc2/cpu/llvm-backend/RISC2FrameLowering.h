//===-- RISC2FrameLowering.h - Frame Lowering for RISC2 ------------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2FRAMELOWERING_H
#define LLVM_LIB_TARGET_RISC2_RISC2FRAMELOWERING_H

#include "llvm/CodeGen/TargetFrameLowering.h"

namespace llvm {
class RISC2Subtarget;

class RISC2FrameLowering : public TargetFrameLowering {
  const RISC2Subtarget &STI;

public:
  explicit RISC2FrameLowering(const RISC2Subtarget &STI);

  void emitPrologue(MachineFunction &MF, MachineBasicBlock &MBB) const override;
  void emitEpilogue(MachineFunction &MF, MachineBasicBlock &MBB) const override;

  bool hasFPImpl(const MachineFunction &MF) const override { return false; }

  MachineBasicBlock::iterator
  eliminateCallFramePseudoInstr(MachineFunction &MF, MachineBasicBlock &MBB,
                                MachineBasicBlock::iterator I) const override;

  // Force R15 (link register) into the callee-saved set for any function
  // that makes calls, because CALL unconditionally overwrites R15 with the
  // callee's return address.  Without this, PEI would skip saving R15 in
  // non-leaf functions (the CALL instruction marks its implicit-def of R15 as
  // "dead" because R15 is in the call-preserved mask).
  void determineCalleeSaves(MachineFunction &MF, BitVector &SavedRegs,
                             RegScavenger *RS = nullptr) const override;

  // Add an emergency spill slot so the register scavenger can always
  // find a place to spill when eliminating frame indices in STORE instructions.
  void processFunctionBeforeFrameFinalized(MachineFunction &MF,
                                            RegScavenger *RS) const override;
};

} // namespace llvm

#endif
