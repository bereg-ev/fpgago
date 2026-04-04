//===-- RISC2MCTargetDesc.cpp - RISC2 Target Descriptions -----------------===//
#include "RISC2MCTargetDesc.h"
#include "RISC2InstPrinter.h"
#include "RISC2MCAsmInfo.h"
#include "TargetInfo/RISC2TargetInfo.h"
#include "llvm/MC/MCDwarf.h"
#include "llvm/MC/MCInstrInfo.h"
#include "llvm/MC/MCRegisterInfo.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/ErrorHandling.h"

#define GET_INSTRINFO_MC_DESC
#define ENABLE_INSTR_PREDICATE_VERIFIER
#include "RISC2GenInstrInfo.inc"

#define GET_SUBTARGETINFO_MC_DESC
#include "RISC2GenSubtargetInfo.inc"

#define GET_REGINFO_MC_DESC
#include "RISC2GenRegisterInfo.inc"

using namespace llvm;

static MCInstrInfo *createRISC2MCInstrInfo() {
  MCInstrInfo *X = new MCInstrInfo();
  InitRISC2MCInstrInfo(X);
  return X;
}

static MCRegisterInfo *createRISC2MCRegisterInfo(const Triple &TT) {
  MCRegisterInfo *X = new MCRegisterInfo();
  InitRISC2MCRegisterInfo(X, RISC2::R15);  // R15 is return address register
  return X;
}

static MCSubtargetInfo *
createRISC2MCSubtargetInfo(const Triple &TT, StringRef CPU, StringRef FS) {
  if (CPU.empty())
    CPU = "generic-risc2";
  return createRISC2MCSubtargetInfoImpl(TT, CPU, /*TuneCPU*/ CPU, FS);
}

static MCAsmInfo *createRISC2MCAsmInfo(const MCRegisterInfo &MRI,
                                        const Triple &TT,
                                        const MCTargetOptions &Options) {
  return new RISC2MCAsmInfo(TT);
}

static MCInstPrinter *createRISC2MCInstPrinter(const Triple &T,
                                                unsigned SyntaxVariant,
                                                const MCAsmInfo &MAI,
                                                const MCInstrInfo &MII,
                                                const MCRegisterInfo &MRI) {
  return createRISC2InstPrinter(T, SyntaxVariant, MAI, MII, MRI);
}

extern "C" LLVM_EXTERNAL_VISIBILITY void LLVMInitializeRISC2TargetMC() {
  Target &T = getTheRISC2Target();

  // Register the MC asm info
  RegisterMCAsmInfoFn X(T, createRISC2MCAsmInfo);

  // Register the MC instruction info
  TargetRegistry::RegisterMCInstrInfo(T, createRISC2MCInstrInfo);

  // Register the MC register info
  TargetRegistry::RegisterMCRegInfo(T, createRISC2MCRegisterInfo);

  // Register the MC subtarget info
  TargetRegistry::RegisterMCSubtargetInfo(T, createRISC2MCSubtargetInfo);

  // Register the MCInstPrinter
  TargetRegistry::RegisterMCInstPrinter(T, createRISC2MCInstPrinter);
}
