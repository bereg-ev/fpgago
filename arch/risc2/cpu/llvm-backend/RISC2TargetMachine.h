//===-- RISC2TargetMachine.h - Define TargetMachine for RISC2 ------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2TARGETMACHINE_H
#define LLVM_LIB_TARGET_RISC2_RISC2TARGETMACHINE_H

#include "RISC2Subtarget.h"
#include "llvm/CodeGen/CodeGenTargetMachineImpl.h"
#include "llvm/CodeGen/TargetLoweringObjectFileImpl.h"
#include <optional>

namespace llvm {

class RISC2TargetMachine : public CodeGenTargetMachineImpl {
  std::unique_ptr<TargetLoweringObjectFile> TLOF;
  RISC2Subtarget Subtarget;

public:
  RISC2TargetMachine(const Target &T, const Triple &TT, StringRef CPU,
                     StringRef FS, const TargetOptions &Options,
                     std::optional<Reloc::Model> RM,
                     std::optional<CodeModel::Model> CM, CodeGenOptLevel OL,
                     bool JIT);

  ~RISC2TargetMachine() override;

  const RISC2Subtarget *getSubtargetImpl(const Function &) const override {
    return &Subtarget;
  }
  const RISC2Subtarget *getSubtargetImpl() const { return &Subtarget; }

  TargetPassConfig *createPassConfig(PassManagerBase &PM) override;

  TargetLoweringObjectFile *getObjFileLowering() const override {
    return TLOF.get();
  }
};

} // namespace llvm

#endif
