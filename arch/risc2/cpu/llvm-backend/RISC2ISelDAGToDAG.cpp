//===-- RISC2ISelDAGToDAG.cpp - RISC2 DAG Instruction Selector -----------===//
#include "RISC2ISelDAGToDAG.h"
#include "RISC2.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/SelectionDAG.h"
#include "llvm/CodeGen/SelectionDAGNodes.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"

#define DEBUG_TYPE "risc2-isel"
#define PASS_NAME "RISC2 DAG->DAG Pattern Instruction Selection"

using namespace llvm;

char RISC2DAGToDAGISelLegacy::ID = 0;

INITIALIZE_PASS(RISC2DAGToDAGISelLegacy, DEBUG_TYPE, PASS_NAME, false, false)

FunctionPass *llvm::createRISC2ISelDag(RISC2TargetMachine &TM) {
  return new RISC2DAGToDAGISelLegacy(TM);
}

// Select base+imm addressing: if Addr = base + constant fits in 16 bits
bool RISC2DAGToDAGISel::SelectAddrRegImm(SDValue Addr, SDValue &Base,
                                           SDValue &Offset) {
  SDLoc DL(Addr);

  if (auto *FI = dyn_cast<FrameIndexSDNode>(Addr)) {
    Base   = CurDAG->getTargetFrameIndex(FI->getIndex(), MVT::i32);
    Offset = CurDAG->getTargetConstant(0, DL, MVT::i32);
    return true;
  }

  if (Addr.getOpcode() == ISD::ADD) {
    if (auto *CN = dyn_cast<ConstantSDNode>(Addr.getOperand(1))) {
      uint64_t Val = CN->getZExtValue();
      if (isUInt<16>(Val)) {
        Base   = Addr.getOperand(0);
        Offset = CurDAG->getTargetConstant(Val, DL, MVT::i32);
        return true;
      }
    }
  }

  // Fall back: base = Addr, offset = 0
  Base   = Addr;
  Offset = CurDAG->getTargetConstant(0, DL, MVT::i32);
  return true;
}

void RISC2DAGToDAGISel::Select(SDNode *N) {
  SDLoc DL(N);

  if (N->isMachineOpcode()) {
    N->setNodeId(-1);
    return;
  }

  switch (N->getOpcode()) {

  case RISC2ISD::WRAPPER: {
    // Materialize a 32-bit address/constant:
    // If the wrapped value is a TargetGlobalAddress or TargetExternalSymbol,
    // emit IMMInst(upper12) + MOV_RI(lower20).
    SDValue Inner = N->getOperand(0);
    MVT VT = N->getSimpleValueType(0);

    if (auto *GA = dyn_cast<GlobalAddressSDNode>(Inner)) {
      // Load base address with zero offset (@label) so the InstPrinter emits
      // "@symbol" syntax that gcasm accepts.  If there is a non-zero byte
      // offset (e.g. accessing the Nth element of a global array at a
      // compile-time-constant index), emit a separate ADD_RI instruction
      // instead of folding it into the MOV as "symbol+N" which gcasm cannot
      // parse.
      int64_t Offset = GA->getOffset();
      SDNode *Mov = CurDAG->getMachineNode(RISC2::MOV_RI, DL, VT,
                                            CurDAG->getTargetGlobalAddress(
                                                GA->getGlobal(), DL, VT, 0));
      if (Offset == 0) {
        ReplaceNode(N, Mov);
      } else {
        SDNode *Add = CurDAG->getMachineNode(
            RISC2::ADD_RI, DL, VT,
            SDValue(Mov, 0),
            CurDAG->getTargetConstant((uint64_t)Offset, DL, MVT::i32));
        ReplaceNode(N, Add);
      }
      return;
    }
    if (auto *ES = dyn_cast<ExternalSymbolSDNode>(Inner)) {
      SDNode *Mov = CurDAG->getMachineNode(RISC2::MOV_RI, DL, VT,
                                            CurDAG->getTargetExternalSymbol(
                                                ES->getSymbol(), VT));
      ReplaceNode(N, Mov);
      return;
    }
    // Constant value — emit MOV_RI with the full 32-bit value.
    // The AsmPrinter's emitIMMPrefixIfNeeded will automatically emit an
    // "imm #upper12" prefix when the value exceeds 20 bits, so no separate
    // IMMInst SDNode is needed here (a free-floating IMMInst with no data
    // uses can be reordered away from MOV_RI by the scheduler).
    if (auto *CN = dyn_cast<ConstantSDNode>(Inner)) {
      uint32_t Val = CN->getZExtValue();
      SDNode *MovN = CurDAG->getMachineNode(
          RISC2::MOV_RI, DL, VT,
          CurDAG->getTargetConstant(Val, DL, MVT::i32));
      ReplaceNode(N, MovN);
      return;
    }
    break;
  }

  case RISC2ISD::SELECT_CC: {
    // Emit the SELECT_CC pseudo machine instruction.
    // Operand order in RISC2ISD::SELECT_CC: TrueVal, FalseVal, LHS, RHS, CC
    // Pseudo (ins): trueVal, falseVal, cc, lhs, rhs
    SDValue Ops[] = {
        N->getOperand(0),  // trueVal
        N->getOperand(1),  // falseVal
        CurDAG->getTargetConstant(
            cast<ConstantSDNode>(N->getOperand(4))->getZExtValue(), DL, MVT::i32), // cc
        N->getOperand(2),  // lhs
        N->getOperand(3),  // rhs
    };
    SDNode *Sel = CurDAG->getMachineNode(RISC2::SELECT_CC, DL,
                                          N->getValueType(0), Ops);
    ReplaceNode(N, Sel);
    return;
  }

  case RISC2ISD::CALL: {
    // Call lowering: the callee is either a target address or register.
    // CALL_target/CALL_reg use variable_ops, so we pass:
    //   [Callee, Register(arg0), ..., RegisterMask, Chain, Glue?]
    SDValue Chain  = N->getOperand(0);
    SDValue Callee = N->getOperand(1);

    SmallVector<SDValue, 8> Ops;
    Ops.push_back(Callee);

    // Operands 2..N-1 are: Register(arg)*, RegisterMask, maybe Glue at end
    unsigned LastOp = N->getNumOperands() - 1;
    bool HasGlue = N->getOperand(LastOp).getValueType() == MVT::Glue;
    unsigned End = HasGlue ? LastOp : N->getNumOperands();
    for (unsigned i = 2; i < End; ++i)
      Ops.push_back(N->getOperand(i));

    Ops.push_back(Chain);
    if (HasGlue)
      Ops.push_back(N->getOperand(LastOp));

    SDNode *Call;
    if (isa<GlobalAddressSDNode>(Callee) ||
        isa<ExternalSymbolSDNode>(Callee)) {
      Call = CurDAG->getMachineNode(RISC2::CALL_target, DL,
                                     MVT::Other, MVT::Glue, Ops);
    } else {
      Call = CurDAG->getMachineNode(RISC2::CALL_reg, DL,
                                     MVT::Other, MVT::Glue, Ops);
    }
    ReplaceNode(N, Call);
    return;
  }

  case RISC2ISD::CMPBR: {
    // CMP lhs, rhs + conditional branch
    SDValue Chain  = N->getOperand(0);
    SDValue LHS    = N->getOperand(1);
    SDValue RHS    = N->getOperand(2);
    SDValue CCVal  = N->getOperand(3);
    SDValue TrueBB = N->getOperand(4);

    unsigned CC = cast<ConstantSDNode>(CCVal)->getZExtValue();

    // Emit CMP
    SDNode *Cmp;
    if (auto *CN = dyn_cast<ConstantSDNode>(RHS)) {
      Cmp = CurDAG->getMachineNode(
          RISC2::CMP_RI, DL, MVT::Glue,
          LHS, CurDAG->getTargetConstant(CN->getZExtValue(), DL, MVT::i32));
    } else {
      Cmp = CurDAG->getMachineNode(RISC2::CMP_RR, DL, MVT::Glue, LHS, RHS);
    }
    SDValue CmpGlue = SDValue(Cmp, 0);

    // Emit conditional branch
    unsigned BranchOpc;
    switch (CC) {
    case RISC2CC::COND_NZ: BranchOpc = RISC2::JNZ; break;
    case RISC2CC::COND_Z:  BranchOpc = RISC2::JZ;  break;
    case RISC2CC::COND_NC: BranchOpc = RISC2::JNC; break;
    case RISC2CC::COND_C:  BranchOpc = RISC2::JC;  break;
    case RISC2CC::COND_GE: BranchOpc = RISC2::JGE; break;
    case RISC2CC::COND_LT: BranchOpc = RISC2::JLT; break;
    default: BranchOpc = RISC2::JMP; break;
    }
    // Chain must come before CmpGlue: LLVM's BuildSchedUnits "scan up"
    // code only checks the LAST operand for glue, so glue must be last.
    SDNode *Br = CurDAG->getMachineNode(BranchOpc, DL, MVT::Other,
                                         TrueBB, Chain, CmpGlue);
    ReplaceNode(N, Br);
    return;
  }

  case ISD::FrameIndex: {
    // Standalone frame index: compute stack slot address into a register.
    // Emit LOAD32_base as a placeholder that eliminateFrameIndex can fix.
    // This is the "address of a local variable" pattern (e.g. int *p = &a).
    // We emit: ADD_RI dst, TFI, #0 where TFI is a TargetFrameIndex operand.
    // eliminateFrameIndex sees the FI at operand[1] of ADD_RI and replaces it
    // with R14, setting operand[2] to the actual offset.
    // NOTE: dst must be a NEW virtual register (not R14), so the 3-address
    // emission is handled by the MachineNode infrastructure correctly.
    int FI = cast<FrameIndexSDNode>(N)->getIndex();
    SDValue TFI = CurDAG->getTargetFrameIndex(FI, MVT::i32);
    SDValue Imm0 = CurDAG->getTargetConstant(0, DL, MVT::i32);
    // ADD_RI dst, TFI, #0 — eliminateFrameIndex converts TFI → R14 + offset
    SDNode *Add = CurDAG->getMachineNode(RISC2::ADD_RI, DL, MVT::i32, TFI, Imm0);
    ReplaceNode(N, Add);
    return;
  }

  case ISD::LOAD: {
    // Handle load from a frame index (generated by -O0 alloca).
    LoadSDNode *LD = cast<LoadSDNode>(N);
    if (LD->isIndexed() || LD->getExtensionType() != ISD::NON_EXTLOAD) break;
    SDValue Addr = LD->getBasePtr();
    if (auto *FI = dyn_cast<FrameIndexSDNode>(Addr)) {
      SDValue TFI = CurDAG->getTargetFrameIndex(FI->getIndex(), MVT::i32);
      // Emit LOAD32 dst, TFI, #0 — eliminateFrameIndex fixes up TFI later.
      SDNode *Load = CurDAG->getMachineNode(
          RISC2::LOAD32, DL, MVT::i32, MVT::Other,
          TFI,
          CurDAG->getTargetConstant(0, DL, MVT::i32),
          LD->getChain());
      ReplaceNode(N, Load);
      return;
    }
    break;
  }

  case ISD::STORE: {
    // Handle store to a frame index (generated by -O0 alloca).
    StoreSDNode *ST = cast<StoreSDNode>(N);
    if (ST->isIndexed() || ST->isTruncatingStore()) break;
    SDValue Addr = ST->getBasePtr();
    if (auto *FI = dyn_cast<FrameIndexSDNode>(Addr)) {
      SDValue TFI = CurDAG->getTargetFrameIndex(FI->getIndex(), MVT::i32);
      // Emit STORE32 val, TFI — eliminateFrameIndex replaces TFI with R14
      // (offset=0) or emits ADD_RI R7,R14,#offset + STORE32 val,R7 (offset>0).
      SDNode *Store = CurDAG->getMachineNode(
          RISC2::STORE32, DL, MVT::Other,
          ST->getValue(), TFI, ST->getChain());
      ReplaceNode(N, Store);
      return;
    }
    break;
  }

  case ISD::Constant: {
    // Materialize any 32-bit constant via MOV_RI.
    // For values that exceed 20 bits the AsmPrinter automatically emits an
    // "imm #upper12" prefix immediately before the MOV_RI instruction, so no
    // separate IMMInst node is needed here (and would be unsafe: a free-floating
    // IMMInst SDNode with no data uses can be reordered by the scheduler away
    // from MOV_RI, producing the wrong value).
    uint32_t Val = cast<ConstantSDNode>(N)->getZExtValue();
    MVT VT = N->getSimpleValueType(0);
    SDNode *Mov = CurDAG->getMachineNode(
        RISC2::MOV_RI, DL, VT,
        CurDAG->getTargetConstant(Val, DL, MVT::i32));
    ReplaceNode(N, Mov);
    return;
  }

  default:
    break;
  }

  // Fall through to TableGen-generated instruction selection
  SelectCode(N);
}
