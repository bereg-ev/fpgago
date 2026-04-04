//===-- RISC2MCTargetDesc.h - RISC2 Target Descriptions ------------------===//
#ifndef LLVM_LIB_TARGET_RISC2_MCTARGETDESC_RISC2MCTARGETDESC_H
#define LLVM_LIB_TARGET_RISC2_MCTARGETDESC_RISC2MCTARGETDESC_H

#include "llvm/Support/DataTypes.h"
#include <memory>

namespace llvm {
class MCAsmBackend;
class MCCodeEmitter;
class MCContext;
class MCInstrInfo;
class MCObjectTargetWriter;
class MCRegisterInfo;
class MCSubtargetInfo;
class MCTargetOptions;
class Target;

MCCodeEmitter *createRISC2MCCodeEmitter(const MCInstrInfo &MCII,
                                         MCContext &Ctx);
MCAsmBackend *createRISC2AsmBackend(const Target &T,
                                     const MCSubtargetInfo &STI,
                                     const MCRegisterInfo &MRI,
                                     const MCTargetOptions &Options);
std::unique_ptr<MCObjectTargetWriter> createRISC2ELFObjectWriter(uint8_t OSABI);

} // namespace llvm

// Defines symbolic names for RISC2 registers.
#define GET_REGINFO_ENUM
#include "RISC2GenRegisterInfo.inc"

// Defines symbolic names for RISC2 instructions.
#define GET_INSTRINFO_ENUM
#include "RISC2GenInstrInfo.inc"

// Defines symbolic names for RISC2 subtargets.
#define GET_SUBTARGETINFO_ENUM
#include "RISC2GenSubtargetInfo.inc"

#endif
