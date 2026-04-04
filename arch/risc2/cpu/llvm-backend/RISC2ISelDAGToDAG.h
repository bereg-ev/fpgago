//===-- RISC2ISelDAGToDAG.h - RISC2 DAG Instruction Selector -------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2ISELDAGTODAG_H
#define LLVM_LIB_TARGET_RISC2_RISC2ISELDAGTODAG_H

#include "RISC2Subtarget.h"
#include "RISC2TargetMachine.h"
#include "llvm/CodeGen/SelectionDAGISel.h"

namespace llvm {

// The core instruction selector — not a pass itself in LLVM 22.
class RISC2DAGToDAGISel : public SelectionDAGISel {
  const RISC2Subtarget *Subtarget = nullptr;

public:
  RISC2DAGToDAGISel() = delete;
  explicit RISC2DAGToDAGISel(RISC2TargetMachine &TM)
      : SelectionDAGISel(TM) {}

  bool runOnMachineFunction(MachineFunction &MF) override {
    Subtarget = &MF.getSubtarget<RISC2Subtarget>();
    return SelectionDAGISel::runOnMachineFunction(MF);
  }

  void Select(SDNode *N) override;

  bool SelectAddrRegImm(SDValue Addr, SDValue &Base, SDValue &Offset);

// TableGen-generated
#include "RISC2GenDAGISel.inc"
};

// Legacy MachineFunction pass wrapper (required by LLVM 22 pass pipeline).
class RISC2DAGToDAGISelLegacy : public SelectionDAGISelLegacy {
public:
  static char ID;
  explicit RISC2DAGToDAGISelLegacy(RISC2TargetMachine &TM)
      : SelectionDAGISelLegacy(ID, std::make_unique<RISC2DAGToDAGISel>(TM)) {}
};

FunctionPass *createRISC2ISelDag(RISC2TargetMachine &TM);

} // namespace llvm

#endif
