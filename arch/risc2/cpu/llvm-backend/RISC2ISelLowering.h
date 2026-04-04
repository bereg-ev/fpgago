//===-- RISC2ISelLowering.h - RISC2 DAG Lowering Interface ---------------===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2ISELLOWERING_H
#define LLVM_LIB_TARGET_RISC2_RISC2ISELLOWERING_H

#include "RISC2.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/CodeGen/TargetLowering.h"

namespace llvm {
class GlobalVariable;
class RISC2Subtarget;
class RISC2TargetMachine;

namespace RISC2ISD {
enum NodeType : unsigned {
  FIRST_NUMBER = ISD::BUILTIN_OP_END,
  CALL,       // function call; chain + callee + args → chain + glue
  RET,        // return; chain + (optional value in R0) → chain
  WRAPPER,    // wraps a GlobalAddress/ExternalSymbol for 2-instr materialization
  CMPBR,      // CMP + conditional branch (chain, lhs, rhs, cc, trueBB, falseBB)
  SELECT_CC,  // select on condition: (trueV, falseV, lhs, rhs, cc)
};
} // namespace RISC2ISD

class RISC2TargetLowering : public TargetLowering {
  const RISC2Subtarget &STI;

public:
  explicit RISC2TargetLowering(const TargetMachine &TM,
                                const RISC2Subtarget &STI);

  const char *getTargetNodeName(unsigned Opcode) const override;

  SDValue LowerOperation(SDValue Op, SelectionDAG &DAG) const override;

  SDValue LowerFormalArguments(SDValue Chain, CallingConv::ID CallConv,
                                bool IsVarArg,
                                const SmallVectorImpl<ISD::InputArg> &Ins,
                                const SDLoc &DL, SelectionDAG &DAG,
                                SmallVectorImpl<SDValue> &InVals) const override;

  SDValue LowerCall(CallLoweringInfo &CLI,
                    SmallVectorImpl<SDValue> &InVals) const override;

  SDValue LowerReturn(SDValue Chain, CallingConv::ID CallConv, bool IsVarArg,
                      const SmallVectorImpl<ISD::OutputArg> &Outs,
                      const SmallVectorImpl<SDValue> &OutVals, const SDLoc &DL,
                      SelectionDAG &DAG) const override;

  MachineBasicBlock *
  EmitInstrWithCustomInserter(MachineInstr &MI,
                               MachineBasicBlock *BB) const override;

private:
  SDValue lowerGlobalAddress(SDValue Op, SelectionDAG &DAG) const;
  SDValue lowerBR_CC(SDValue Op, SelectionDAG &DAG) const;
  SDValue lowerSELECT_CC(SDValue Op, SelectionDAG &DAG) const;
  SDValue lowerShift(SDValue Op, SelectionDAG &DAG) const;

  // Materialize a 32-bit constant into a register
  SDValue materializeImm(const SDLoc &DL, uint32_t Val, SelectionDAG &DAG) const;

  // Map ISD condition code to RISC2 condition code
  RISC2CC::CondCode getCondCode(ISD::CondCode CC) const;

  // BSS layout: mutable globals are assigned data RAM addresses.
  // Computed lazily on first use; mutable because lowerGlobalAddress is const.
  mutable DenseMap<const GlobalVariable*, uint64_t> BSSAddrs;
  mutable uint64_t BSSNextAddr = 0;
  mutable bool BSSComputed = false;
  void computeBSSLayout(const Module &M) const;
};

} // namespace llvm

#endif
