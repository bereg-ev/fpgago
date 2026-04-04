//===-- RISC2Subtarget.h - Define Subtarget for RISC2 --------------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2SUBTARGET_H
#define LLVM_LIB_TARGET_RISC2_RISC2SUBTARGET_H

#include "RISC2FrameLowering.h"
#include "RISC2ISelLowering.h"
#include "RISC2InstrInfo.h"
#include "RISC2RegisterInfo.h"
#include "llvm/CodeGen/SelectionDAGTargetInfo.h"
#include "llvm/CodeGen/TargetSubtargetInfo.h"
#include <string>

#define GET_SUBTARGETINFO_HEADER
#include "RISC2GenSubtargetInfo.inc"

namespace llvm {
class StringRef;
class RISC2TargetMachine;

class RISC2Subtarget : public RISC2GenSubtargetInfo {
  RISC2InstrInfo       InstrInfo;
  RISC2FrameLowering   FrameLowering;
  RISC2TargetLowering  TLInfo;
  RISC2RegisterInfo    RegInfo;
  SelectionDAGTargetInfo TSInfo;

public:
  RISC2Subtarget(const Triple &TT, StringRef CPU, StringRef FS,
                 const RISC2TargetMachine &TM);

  // Required subtarget interface
  void ParseSubtargetFeatures(StringRef CPU, StringRef TuneCPU, StringRef FS);

  const RISC2InstrInfo      *getInstrInfo()      const override { return &InstrInfo; }
  const RISC2FrameLowering  *getFrameLowering()  const override { return &FrameLowering; }
  const RISC2TargetLowering *getTargetLowering() const override { return &TLInfo; }
  const RISC2RegisterInfo   *getRegisterInfo()   const override { return &RegInfo; }
  const SelectionDAGTargetInfo *getSelectionDAGInfo() const override { return &TSInfo; }
};

} // namespace llvm

#endif
