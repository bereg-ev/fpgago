//===-- RISC2TargetInfo.cpp - RISC2 Target Registration ------------------===//
#include "RISC2TargetInfo.h"
#include "llvm/MC/TargetRegistry.h"

using namespace llvm;

Target &llvm::getTheRISC2Target() {
  static Target TheRISC2Target;
  return TheRISC2Target;
}

extern "C" LLVM_EXTERNAL_VISIBILITY void LLVMInitializeRISC2TargetInfo() {
  RegisterTarget<Triple::risc2, /*HasJIT=*/false> X(
      getTheRISC2Target(), "risc2", "RISC2 (custom FPGA CPU)", "RISC2");
}
