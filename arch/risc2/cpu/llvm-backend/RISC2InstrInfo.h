//===-- RISC2InstrInfo.h - RISC2 Instruction Information -----------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2INSTRINFO_H
#define LLVM_LIB_TARGET_RISC2_RISC2INSTRINFO_H

#include "RISC2RegisterInfo.h"
#include "llvm/CodeGen/MachineInstr.h"
#include "llvm/CodeGen/TargetInstrInfo.h"

#define GET_INSTRINFO_HEADER
#include "RISC2GenInstrInfo.inc"

namespace llvm {
class RISC2Subtarget;

class RISC2InstrInfo : public RISC2GenInstrInfo {
  const RISC2RegisterInfo RI;
  const RISC2Subtarget &STI;

public:
  explicit RISC2InstrInfo(const RISC2Subtarget &STI);

  const RISC2RegisterInfo &getRegisterInfo() const { return RI; }

  void copyPhysReg(MachineBasicBlock &MBB, MachineBasicBlock::iterator I,
                   const DebugLoc &DL, Register DestReg, Register SrcReg,
                   bool KillSrc, bool RenamableDest = false,
                   bool RenamableSrc = false) const override;

  void storeRegToStackSlot(MachineBasicBlock &MBB,
                            MachineBasicBlock::iterator MBBI, Register SrcReg,
                            bool isKill, int FrameIndex,
                            const TargetRegisterClass *RC,
                            Register VReg,
                            MachineInstr::MIFlag Flags =
                                MachineInstr::NoFlags) const override;

  void loadRegFromStackSlot(MachineBasicBlock &MBB,
                             MachineBasicBlock::iterator MBBI, Register DestReg,
                             int FrameIndex, const TargetRegisterClass *RC,
                             Register VReg, unsigned SubReg = 0,
                             MachineInstr::MIFlag Flags =
                                 MachineInstr::NoFlags) const override;

};

} // namespace llvm

#endif
