//===-- RISC2RegisterInfo.h - RISC2 Register Info ------------------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2REGISTERINFO_H
#define LLVM_LIB_TARGET_RISC2_RISC2REGISTERINFO_H

#include "llvm/CodeGen/TargetRegisterInfo.h"

#define GET_REGINFO_HEADER
#include "RISC2GenRegisterInfo.inc"

namespace llvm {
class RISC2Subtarget;

class RISC2RegisterInfo : public RISC2GenRegisterInfo {
public:
  RISC2RegisterInfo(unsigned HwMode);

  const MCPhysReg *getCalleeSavedRegs(const MachineFunction *MF) const override;
  const uint32_t  *getCallPreservedMask(const MachineFunction &MF,
                                         CallingConv::ID CC) const override;

  BitVector getReservedRegs(const MachineFunction &MF) const override;

  bool eliminateFrameIndex(MachineBasicBlock::iterator MI, int SPAdj,
                           unsigned FIOperandNum,
                           RegScavenger *RS = nullptr) const override;

  Register getFrameRegister(const MachineFunction &MF) const override;

  bool requiresRegisterScavenging(const MachineFunction &MF) const override {
    return true;
  }
  bool requiresFrameIndexScavenging(const MachineFunction &MF) const override {
    return true;
  }
  bool trackLivenessAfterRegAlloc(const MachineFunction &MF) const override {
    return true;
  }
};

} // namespace llvm

#endif
