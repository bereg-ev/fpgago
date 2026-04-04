//===-- RISC2MCAsmInfo.h - RISC2 Asm Info --------------------------------===//
#ifndef LLVM_LIB_TARGET_RISC2_MCTARGETDESC_RISC2MCASMINFO_H
#define LLVM_LIB_TARGET_RISC2_MCTARGETDESC_RISC2MCASMINFO_H

#include "llvm/MC/MCAsmInfo.h"

namespace llvm {
class Triple;

class RISC2MCAsmInfo : public MCAsmInfo {
  virtual void anchor();

public:
  explicit RISC2MCAsmInfo(const Triple &TT);
};

} // namespace llvm

#endif
