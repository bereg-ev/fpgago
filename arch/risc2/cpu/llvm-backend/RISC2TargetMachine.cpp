//===-- RISC2TargetMachine.cpp - Define TargetMachine for RISC2 ----------===//
#include "RISC2TargetMachine.h"
#include "RISC2.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "TargetInfo/RISC2TargetInfo.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/Passes.h"
#include "llvm/CodeGen/TargetPassConfig.h"
#include "llvm/CodeGen/TargetLoweringObjectFileImpl.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Transforms/Scalar.h"

using namespace llvm;

//===----------------------------------------------------------------------===//
// RISC2LinkRegLiveIn pass
//
// RISC2's RET instruction reads R15 (link register) as an implicit use.
// In leaf functions (no calls), R15 is never written — it holds the return
// address deposited by the caller's CALL instruction and is used directly
// by RET.  LLVM's LiveRangeCalc::findReachingDefs (debug build) requires
// that a physical-register use operand have the register marked as live-in
// to every block in its backward-walk worklist.  The entry block's live-in
// (added in LowerFormalArguments) only covers bb.0; blocks created by
// SELECT_CC / PHI lowering also need R15 in their live-in sets.
// This pass runs just before register allocation and ensures R15 is live-in
// to every basic block in the function.
//===----------------------------------------------------------------------===//
namespace {
struct RISC2LinkRegLiveInPass : public MachineFunctionPass {
  static char ID;
  RISC2LinkRegLiveInPass() : MachineFunctionPass(ID) {}

  StringRef getPassName() const override {
    return "RISC2 Link-Register Live-In Propagation";
  }

  bool runOnMachineFunction(MachineFunction &MF) override {
    bool Changed = false;
    for (MachineBasicBlock &MBB : MF) {
      if (!MBB.isLiveIn(RISC2::R15)) {
        MBB.addLiveIn(RISC2::R15);
        Changed = true;
      }
    }
    return Changed;
  }
};
char RISC2LinkRegLiveInPass::ID = 0;
} // anonymous namespace

FunctionPass *llvm::createRISC2LinkRegLiveInPass() {
  return new RISC2LinkRegLiveInPass();
}

extern "C" LLVM_EXTERNAL_VISIBILITY void LLVMInitializeRISC2Target() {
  RegisterTargetMachine<RISC2TargetMachine> X(getTheRISC2Target());
}

static StringRef computeDataLayout(const Triple &TT) {
  // e       = little-endian
  // (no m:) = MM_None mangling: DataLayout::getPrivateGlobalPrefix() returns ""
  //           rather than ".L" (ELF default).  The Mangler uses that prefix for
  //           private-linkage globals (switch lookup tables, string constants…).
  //           gcasm's tokeniser treats any token starting with '.' as a keyword
  //           or directive, so ".Lswitch.table.foo:" would fail.  With MM_None
  //           the label is "switch.table.foo:" — accepted as a plain identifier.
  //           MCAsmInfo::PrivateGlobalPrefix = "_L" still governs basic-block
  //           labels (_LBB0_1) which are created via MCContext, not the Mangler.
  // p:32:32 = 32-bit pointer, 32-bit aligned
  // i32:32  = i32 is 32-bit aligned
  // n32     = native integer width is 32 bits
  // S32     = stack is 32-bit aligned
  return "e-p:32:32-i32:32-i64:32-n32-S32";
}

static Reloc::Model getEffectiveRelocModel(std::optional<Reloc::Model> RM) {
  return RM.value_or(Reloc::Static);
}

RISC2TargetMachine::RISC2TargetMachine(const Target &T, const Triple &TT,
                                         StringRef CPU, StringRef FS,
                                         const TargetOptions &Options,
                                         std::optional<Reloc::Model> RM,
                                         std::optional<CodeModel::Model> CM,
                                         CodeGenOptLevel OL, bool JIT)
    : CodeGenTargetMachineImpl(T, computeDataLayout(TT), TT,
                        CPU.empty() ? "generic-risc2" : CPU, FS, Options,
                        getEffectiveRelocModel(RM),
                        getEffectiveCodeModel(CM, CodeModel::Small), OL),
      TLOF(std::make_unique<TargetLoweringObjectFileELF>()),
      Subtarget(TT, CPU.empty() ? "generic-risc2" : CPU, FS, *this) {
  initAsmInfo();
  // gcasm doesn't understand .addrsig — disable address significance tables.
  this->Options.EmitAddrsig = false;
}

RISC2TargetMachine::~RISC2TargetMachine() = default;

//===----------------------------------------------------------------------===//
// Pass configuration
//===----------------------------------------------------------------------===//

namespace {
class RISC2PassConfig : public TargetPassConfig {
public:
  RISC2PassConfig(RISC2TargetMachine &TM, PassManagerBase &PM)
      : TargetPassConfig(TM, PM) {}

  RISC2TargetMachine &getRISC2TargetMachine() const {
    return getTM<RISC2TargetMachine>();
  }

  bool addInstSelector() override;
  void addPreRegAlloc() override;
};
} // namespace

TargetPassConfig *RISC2TargetMachine::createPassConfig(PassManagerBase &PM) {
  return new RISC2PassConfig(*this, PM);
}

bool RISC2PassConfig::addInstSelector() {
  addPass(createRISC2ISelDag(getRISC2TargetMachine()));
  return false;
}

void RISC2PassConfig::addPreRegAlloc() {
  // Ensure R15 (link register) is marked live-in to every basic block before
  // register allocation runs.  This satisfies LLVM's debug-build assertion in
  // LiveRangeCalc::findReachingDefs which requires that physical registers
  // with implicit uses (e.g. RET's implicit $r15) be present in the live-in
  // sets of every block in the backward-walk worklist.
  addPass(createRISC2LinkRegLiveInPass());
}
