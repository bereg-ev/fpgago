//===-- RISC2Subtarget.cpp - RISC2 Subtarget Information -----------------===//
#include "RISC2Subtarget.h"
#include "RISC2TargetMachine.h"

#define DEBUG_TYPE "risc2-subtarget"

using namespace llvm;

#define GET_SUBTARGETINFO_TARGET_DESC
#define GET_SUBTARGETINFO_CTOR
#include "RISC2GenSubtargetInfo.inc"

RISC2Subtarget::RISC2Subtarget(const Triple &TT, StringRef CPU, StringRef FS,
                                 const RISC2TargetMachine &TM)
    : RISC2GenSubtargetInfo(TT, CPU, /*TuneCPU=*/CPU, FS),
      InstrInfo(*this),
      FrameLowering(*this),
      TLInfo(TM, *this),
      RegInfo(getHwMode()) {
}
