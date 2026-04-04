//===-- RISC2.h - RISC2 target forward declarations ----------------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2_H
#define LLVM_LIB_TARGET_RISC2_RISC2_H

#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/Target/TargetMachine.h"

namespace llvm {
class FunctionPass;
class RISC2TargetMachine;
class PassRegistry;

// Condition codes (map to JMP[26:24] encoding)
namespace RISC2CC {
enum CondCode {
  COND_NZ = 0,  // JNZ: jump if not zero (Z==0)
  COND_Z  = 1,  // JZ:  jump if zero     (Z==1)
  COND_NC = 2,  // JNC: jump if no carry  (C==0)
  COND_C  = 3,  // JC:  jump if carry     (C==1)
  COND_AL = 4,  // JMP: unconditional
  COND_GE = 5,  // JGE: signed >= (N==V)
  COND_LT = 6,  // JLT: signed <  (N!=V)
  COND_INVALID = -1
};
} // namespace RISC2CC

FunctionPass *createRISC2ISelDag(RISC2TargetMachine &TM);
void initializeRISC2DAGToDAGISelLegacyPass(PassRegistry &);

// Propagates R15 (link register) as live-in to every basic block so that
// LiveRangeCalc does not complain about the implicit use in RET.
FunctionPass *createRISC2LinkRegLiveInPass();

} // namespace llvm

#endif
