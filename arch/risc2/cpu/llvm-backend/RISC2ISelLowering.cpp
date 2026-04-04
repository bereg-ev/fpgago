//===-- RISC2ISelLowering.cpp - RISC2 DAG Lowering Implementation ---------===//
#include "RISC2ISelLowering.h"
#include "RISC2.h"
#include "RISC2InstrInfo.h"
#include "RISC2Subtarget.h"
#include "RISC2TargetMachine.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/CodeGen/CallingConvLower.h"
#include "llvm/IR/RuntimeLibcalls.h"
#include "llvm/CodeGen/LibcallLoweringInfo.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/SelectionDAG.h"
#include "llvm/CodeGen/SelectionDAGNodes.h"
#include "llvm/CodeGen/TargetLoweringObjectFileImpl.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/DiagnosticInfo.h"
#include "llvm/IR/GlobalValue.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/MathExtras.h"

using namespace llvm;

#define GET_CALLINGCONV_IMPLEMENTATION
#include "RISC2GenCallingConv.inc"

RISC2TargetLowering::RISC2TargetLowering(const TargetMachine &TM,
                                           const RISC2Subtarget &STI)
    : TargetLowering(TM, STI), STI(STI) {

  addRegisterClass(MVT::i32, &RISC2::GPRRegClass);
  computeRegisterProperties(STI.getRegisterInfo());

  setStackPointerRegisterToSaveRestore(RISC2::R14);
  setMinFunctionAlignment(Align(4));
  setPrefFunctionAlignment(Align(4));

  // ---- Operations NOT supported in hardware → expand or custom-lower ----

  // No hardware multiply / divide — lower to libcalls (__mulsi3, __divsi3, ...)
  setOperationAction(ISD::MUL,       MVT::i32, Expand);
  setOperationAction(ISD::MULHS,     MVT::i32, Expand);
  setOperationAction(ISD::MULHU,     MVT::i32, Expand);
  setOperationAction(ISD::SDIV,      MVT::i32, Expand);
  setOperationAction(ISD::UDIV,      MVT::i32, Expand);
  setOperationAction(ISD::SREM,      MVT::i32, Expand);
  setOperationAction(ISD::UREM,      MVT::i32, Expand);
  setOperationAction(ISD::SMUL_LOHI, MVT::i32, Expand);
  setOperationAction(ISD::UMUL_LOHI, MVT::i32, Expand);
  // LLVM may combine SDIV+SREM into SDIVREM — expand that too
  setOperationAction(ISD::SDIVREM,   MVT::i32, Expand);
  setOperationAction(ISD::UDIVREM,   MVT::i32, Expand);

  // RCL/RCR are single-bit rotations through carry, not general shifts.
  // Multi-bit SHL/SRL/SRA are lowered to libcalls (__ashlsi3, __lshrsi3, __ashrsi3).
  setOperationAction(ISD::SHL,    MVT::i32, Custom);
  setOperationAction(ISD::SRL,    MVT::i32, Custom);
  setOperationAction(ISD::SRA,    MVT::i32, Custom);
  setOperationAction(ISD::ROTL,   MVT::i32, Expand);
  setOperationAction(ISD::ROTR,   MVT::i32, Expand);

  // Explicit libcall implementations (compiler-rt / libgcc naming).
  // RISC2Subtarget::initLibcallLoweringInfo() is not overridden, so all
  // impls default to RTLIB::Unsupported.  Register the standard ones here.
  setLibcallImpl(RTLIB::MUL_I32,  RTLIB::impl___mulsi3);
  setLibcallImpl(RTLIB::SDIV_I32, RTLIB::impl___divsi3);
  setLibcallImpl(RTLIB::UDIV_I32, RTLIB::impl___udivsi3);
  setLibcallImpl(RTLIB::SREM_I32, RTLIB::impl___modsi3);
  setLibcallImpl(RTLIB::UREM_I32, RTLIB::impl___umodsi3);
  setLibcallImpl(RTLIB::SHL_I32,  RTLIB::impl___ashlsi3);
  setLibcallImpl(RTLIB::SRL_I32,  RTLIB::impl___lshrsi3);
  setLibcallImpl(RTLIB::SRA_I32,  RTLIB::impl___ashrsi3);

  // No 64-bit integer operations
  setOperationAction(ISD::SHL_PARTS, MVT::i32, Expand);
  setOperationAction(ISD::SRL_PARTS, MVT::i32, Expand);
  setOperationAction(ISD::SRA_PARTS, MVT::i32, Expand);

  // No floating point
  setOperationAction(ISD::FADD,   MVT::f32, Expand);
  setOperationAction(ISD::FSUB,   MVT::f32, Expand);
  setOperationAction(ISD::FMUL,   MVT::f32, Expand);
  setOperationAction(ISD::FDIV,   MVT::f32, Expand);

  // Custom-lowered operations
  setOperationAction(ISD::GlobalAddress,    MVT::i32, Custom);
  setOperationAction(ISD::ExternalSymbol,   MVT::i32, Custom);
  setOperationAction(ISD::BR_CC,            MVT::i32, Custom);
  setOperationAction(ISD::SELECT_CC,        MVT::i32, Custom);
  setOperationAction(ISD::BRCOND,           MVT::Other, Expand);
  setOperationAction(ISD::SELECT,           MVT::i32, Expand);
  setOperationAction(ISD::SETCC,            MVT::i32, Expand);

  // Dynamic stack allocation not supported
  setOperationAction(ISD::DYNAMIC_STACKALLOC, MVT::i32, Expand);

  // Sign-extend loads: lower to zero-extend + shift
  setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i16, Expand);
  setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i8,  Expand);
  setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i1,  Expand);

  // Sub-word load extensions:
  //   ZEXTLOAD i8/i16 → Legal  (LOAD8/LOAD8_base, LOAD16/LOAD16_base patterns)
  //   SEXTLOAD i8/i16 → Expand (becomes zextload + sign_extend_inreg → shifts)
  //   EXTLOAD  i8/i16 → Expand (any-extend, converted to zextload by legalizer)
  for (MVT SubTy : {MVT::i8, MVT::i16}) {
    setLoadExtAction(ISD::ZEXTLOAD, MVT::i32, SubTy, Legal);
    setLoadExtAction(ISD::SEXTLOAD, MVT::i32, SubTy, Expand);
    setLoadExtAction(ISD::EXTLOAD,  MVT::i32, SubTy, Legal);
  }

  // Truncating stores: RISC2 has STORE8 and STORE16 instructions.
  setTruncStoreAction(MVT::i32, MVT::i8,  Legal);
  setTruncStoreAction(MVT::i32, MVT::i16, Legal);

  // Prevent LLVM from generating memset/memcpy/memmove library calls.
  // Our bare-metal runtime (runtime.s) does not provide these functions.
  // Setting MaxStores to a large value forces LLVM to always inline
  // memory operations as individual stores instead of calling library funcs.
  MaxStoresPerMemset     = 1024;
  MaxStoresPerMemsetOptSize = 1024;
  MaxStoresPerMemcpy     = 1024;
  MaxStoresPerMemcpyOptSize = 1024;
  MaxStoresPerMemmove    = 1024;
  MaxStoresPerMemmoveOptSize = 1024;

  // Varargs not supported in Phase 1
  setOperationAction(ISD::VASTART, MVT::Other, Expand);
  setOperationAction(ISD::VAARG,   MVT::Other, Expand);
  setOperationAction(ISD::VACOPY,  MVT::Other, Expand);
  setOperationAction(ISD::VAEND,   MVT::Other, Expand);

  // Disable address-based jump tables (RISC2 has no indirect-jump instruction).
  // SimplifyCFG may still emit value lookup tables (global constant arrays +
  // getelementptr + load) for switch statements — those work fine because they
  // only require a regular LOAD instruction, not an indirect branch.
  setMinimumJumpTableEntries(INT_MAX);

  // Condition codes
  setBooleanContents(ZeroOrOneBooleanContent);
  setBooleanVectorContents(ZeroOrNegativeOneBooleanContent);
}

const char *RISC2TargetLowering::getTargetNodeName(unsigned Opcode) const {
  switch ((RISC2ISD::NodeType)Opcode) {
  case RISC2ISD::CALL:      return "RISC2ISD::CALL";
  case RISC2ISD::RET:       return "RISC2ISD::RET";
  case RISC2ISD::WRAPPER:   return "RISC2ISD::WRAPPER";
  case RISC2ISD::CMPBR:     return "RISC2ISD::CMPBR";
  case RISC2ISD::SELECT_CC: return "RISC2ISD::SELECT_CC";
  default: return nullptr;
  }
}

//===----------------------------------------------------------------------===//
// Immediate materialization
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::materializeImm(const SDLoc &DL, uint32_t Val,
                                              SelectionDAG &DAG) const {
  // Small value: fits in MOV_RI (20 bits)
  if (isUInt<20>(Val))
    return DAG.getNode(ISD::Constant, DL, MVT::i32,
                       DAG.getConstant(Val, DL, MVT::i32));
  // Large value: wrapped in RISC2ISD::WRAPPER for later expansion
  return DAG.getNode(RISC2ISD::WRAPPER, DL, MVT::i32,
                     DAG.getConstant(Val, DL, MVT::i32));
}

//===----------------------------------------------------------------------===//
// LowerOperation dispatch
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::LowerOperation(SDValue Op,
                                             SelectionDAG &DAG) const {
  switch (Op.getOpcode()) {
  case ISD::GlobalAddress:  return lowerGlobalAddress(Op, DAG);
  case ISD::ExternalSymbol: return lowerGlobalAddress(Op, DAG);
  case ISD::BR_CC:          return lowerBR_CC(Op, DAG);
  case ISD::SELECT_CC:      return lowerSELECT_CC(Op, DAG);
  case ISD::SHL:
  case ISD::SRL:
  case ISD::SRA:            return lowerShift(Op, DAG);
  default:
    llvm_unreachable("Unhandled operation in LowerOperation");
  }
}

//===----------------------------------------------------------------------===//
// BSS layout: assign data RAM addresses to mutable globals
//===----------------------------------------------------------------------===//

void RISC2TargetLowering::computeBSSLayout(const Module &M) const {
  if (BSSComputed) return;
  BSSComputed = true;

  const DataLayout &DL = M.getDataLayout();
  uint64_t Addr = 0x010000; // data RAM base

  for (const GlobalVariable &GV : M.globals()) {
    if (GV.isDeclaration()) continue; // external — no allocation
    if (GV.isConstant()) continue;    // const → ROM

    uint64_t Size = DL.getTypeAllocSize(GV.getValueType()).getFixedValue();
    Align A = DL.getPreferredAlign(&GV);
    Addr = alignTo(Addr, A);
    BSSAddrs[&GV] = Addr;
    Addr += Size;
  }
  BSSNextAddr = Addr;
}

//===----------------------------------------------------------------------===//
// Global address lowering
// Produces RISC2ISD::WRAPPER which ISelDAGToDAG expands to IMM+MOV sequence
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::lowerGlobalAddress(SDValue Op,
                                                  SelectionDAG &DAG) const {
  SDLoc DL(Op);

  if (auto *GAN = dyn_cast<GlobalAddressSDNode>(Op)) {
    const GlobalValue *GV = GAN->getGlobal();

    // Mutable global variable → data RAM address (BSS)
    if (auto *GVar = dyn_cast<GlobalVariable>(GV)) {
      if (!GVar->isDeclaration() && !GVar->isConstant()) {
        computeBSSLayout(*GV->getParent());
        auto It = BSSAddrs.find(GVar);
        if (It != BSSAddrs.end()) {
          uint64_t Addr = It->second + (uint64_t)GAN->getOffset();
          return DAG.getNode(RISC2ISD::WRAPPER, DL, MVT::i32,
                             DAG.getConstant(Addr, DL, MVT::i32));
        }
      }
    }

    // Const global or function → ROM (symbol reference)
    SDValue GA = DAG.getTargetGlobalAddress(GAN->getGlobal(), DL, MVT::i32,
                                            GAN->getOffset());
    return DAG.getNode(RISC2ISD::WRAPPER, DL, MVT::i32, GA);
  }

  if (auto *ES = dyn_cast<ExternalSymbolSDNode>(Op))
    return DAG.getNode(RISC2ISD::WRAPPER, DL, MVT::i32,
                       DAG.getTargetExternalSymbol(ES->getSymbol(), MVT::i32));

  llvm_unreachable("Unexpected op in lowerGlobalAddress");
}

//===----------------------------------------------------------------------===//
// Condition code mapping
//===----------------------------------------------------------------------===//

RISC2CC::CondCode
RISC2TargetLowering::getCondCode(ISD::CondCode CC) const {
  // RISC2 CMP = opA - opB; flags set on result
  // Z=1 iff opA == opB; C=1 iff opA < opB (unsigned borrow)
  switch (CC) {
  case ISD::SETEQ:  return RISC2CC::COND_Z;   // equal → Z
  case ISD::SETNE:  return RISC2CC::COND_NZ;  // not equal → NZ
  case ISD::SETULT: return RISC2CC::COND_C;   // unsigned < → C (borrow)
  case ISD::SETUGE: return RISC2CC::COND_NC;  // unsigned >= → NC
  case ISD::SETLT:  return RISC2CC::COND_LT;  // signed < → N!=V
  case ISD::SETGE:  return RISC2CC::COND_GE;  // signed >= → N==V
  case ISD::SETUGT:
  case ISD::SETULE:
  case ISD::SETGT:
  case ISD::SETLE:
    // Handled by swapping operands in BR_CC/SELECT_CC:
    //   SETUGT a,b → swap → SETULT b,a → COND_C
    //   SETULE a,b → swap → SETUGE b,a → COND_NC
    //   SETGT  a,b → swap → SETLT  b,a → COND_LT
    //   SETLE  a,b → swap → SETGE  b,a → COND_GE
    return RISC2CC::COND_INVALID;
  default:
    return RISC2CC::COND_INVALID;
  }
}

//===----------------------------------------------------------------------===//
// BR_CC lowering → CMP + conditional branch
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::lowerBR_CC(SDValue Op, SelectionDAG &DAG) const {
  SDLoc DL(Op);
  SDValue Chain  = Op.getOperand(0);
  ISD::CondCode CC = cast<CondCodeSDNode>(Op.getOperand(1))->get();
  SDValue LHS    = Op.getOperand(2);
  SDValue RHS    = Op.getOperand(3);
  SDValue TrueBB = Op.getOperand(4);

  // Signed comparisons (SETLT, SETGE, SETGT, SETLE) are handled natively
  // by the RISC2 CPU's N and V flags via JGE/JLT instructions.
  // No bias or conversion needed — getCondCode() maps them directly.

  // Try to map condition code directly
  RISC2CC::CondCode RCC = getCondCode(CC);
  if (RCC == RISC2CC::COND_INVALID) {
    // Swap operands to get a supported condition
    std::swap(LHS, RHS);
    CC = ISD::getSetCCSwappedOperands(CC);
    RCC = getCondCode(CC);
  }
  if (RCC == RISC2CC::COND_INVALID)
    llvm_unreachable("Cannot lower BR_CC condition");

  return DAG.getNode(RISC2ISD::CMPBR, DL, MVT::Other,
                     Chain, LHS, RHS,
                     DAG.getConstant(RCC, DL, MVT::i32), TrueBB);
}

//===----------------------------------------------------------------------===//
// SELECT_CC lowering → branch sequence
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::lowerSELECT_CC(SDValue Op,
                                              SelectionDAG &DAG) const {
  SDLoc DL(Op);
  // ISD::SELECT_CC operands: (LHS, RHS, TrueVal, FalseVal, CC)
  ISD::CondCode CC = cast<CondCodeSDNode>(Op.getOperand(4))->get();
  SDValue LHS      = Op.getOperand(0);
  SDValue RHS      = Op.getOperand(1);
  SDValue TrueVal  = Op.getOperand(2);
  SDValue FalseVal = Op.getOperand(3);

  // Signed comparisons handled natively via N/V flags (same as lowerBR_CC).

  RISC2CC::CondCode RCC = getCondCode(CC);
  if (RCC == RISC2CC::COND_INVALID) {
    std::swap(LHS, RHS);
    CC = ISD::getSetCCSwappedOperands(CC);
    RCC = getCondCode(CC);
  }
  if (RCC == RISC2CC::COND_INVALID)
    llvm_unreachable("Cannot lower SELECT_CC condition");

  return DAG.getNode(RISC2ISD::SELECT_CC, DL, MVT::i32,
                     TrueVal, FalseVal, LHS, RHS,
                     DAG.getConstant(RCC, DL, MVT::i32));
}

//===----------------------------------------------------------------------===//
// Shift lowering (RCL/RCR are 1-bit; multi-bit shifts expanded to loop)
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::lowerShift(SDValue Op, SelectionDAG &DAG) const {
  // RISC2 has only 1-bit RCL/RCR (rotate through carry).
  // Multi-bit shifts fall back to compiler-rt libcalls, EXCEPT for left-shifts
  // by a small constant: SHL by N (1 ≤ N ≤ 5) is expanded inline as N
  // doublings via ADD r, r.  This avoids __ashlsi3 calls for the common
  // switch-table index computation (x << 2 = multiply by 4).
  SDLoc DL(Op);

  if (Op.getOpcode() == ISD::SHL) {
    if (auto *CN = dyn_cast<ConstantSDNode>(Op.getOperand(1))) {
      unsigned N = CN->getZExtValue();
      if (N == 0)
        return Op.getOperand(0);
      if (N <= 5) {
        // Expand: result = val << N  as  N × (result = result + result)
        SDValue R = Op.getOperand(0);
        for (unsigned i = 0; i < N; ++i)
          R = DAG.getNode(ISD::ADD, DL, MVT::i32, R, R);
        return R;
      }
    }
  }

  // All other shifts (variable amount, or constant > 5, or SRL/SRA):
  // lower to a compiler-rt libcall.
  RTLIB::Libcall LC;
  switch (Op.getOpcode()) {
  case ISD::SHL: LC = RTLIB::SHL_I32; break;
  case ISD::SRL: LC = RTLIB::SRL_I32; break;
  case ISD::SRA: LC = RTLIB::SRA_I32; break;
  default: llvm_unreachable("unexpected shift opcode in lowerShift");
  }
  TargetLowering::MakeLibCallOptions CallOptions;
  SDValue Ops[] = {Op.getOperand(0), Op.getOperand(1)};
  return makeLibCall(DAG, LC, Op.getValueType(), Ops, CallOptions, DL).first;
}

//===----------------------------------------------------------------------===//
// Formal arguments (function entry)
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::LowerFormalArguments(
    SDValue Chain, CallingConv::ID CallConv, bool IsVarArg,
    const SmallVectorImpl<ISD::InputArg> &Ins, const SDLoc &DL,
    SelectionDAG &DAG, SmallVectorImpl<SDValue> &InVals) const {

  MachineFunction &MF  = DAG.getMachineFunction();
  MachineRegisterInfo &MRI = MF.getRegInfo();

  // R15 is the link register: it always holds the return address on function
  // entry (placed there by the caller's CALL instruction). Mark it live-in so
  // the register allocator and liveness analysis know it has a valid value at
  // function entry, even in functions with complex control flow or many calls.
  MF.front().addLiveIn(RISC2::R15);

  SmallVector<CCValAssign, 16> ArgLocs;
  CCState CCInfo(CallConv, IsVarArg, MF, ArgLocs, *DAG.getContext());
  CCInfo.AnalyzeFormalArguments(Ins, CC_RISC2);

  for (auto &VA : ArgLocs) {
    if (VA.isRegLoc()) {
      // Argument passed in register
      EVT RegVT = VA.getLocVT();
      const TargetRegisterClass *RC = &RISC2::GPRRegClass;
      Register VReg = MRI.createVirtualRegister(RC);
      MRI.addLiveIn(VA.getLocReg(), VReg);
      SDValue ArgIn = DAG.getCopyFromReg(Chain, DL, VReg, RegVT);

      if (VA.getLocInfo() == CCValAssign::SExt)
        ArgIn = DAG.getNode(ISD::AssertSext, DL, RegVT, ArgIn,
                            DAG.getValueType(VA.getValVT()));
      else if (VA.getLocInfo() == CCValAssign::ZExt)
        ArgIn = DAG.getNode(ISD::AssertZext, DL, RegVT, ArgIn,
                            DAG.getValueType(VA.getValVT()));

      InVals.push_back(ArgIn);
    } else {
      // Argument passed on stack
      assert(VA.isMemLoc());
      unsigned Offset = VA.getLocMemOffset();
      EVT ValVT = VA.getValVT();
      int FI = MF.getFrameInfo().CreateFixedObject(4, Offset, true);
      SDValue FIPtr = DAG.getFrameIndex(FI, MVT::i32);
      SDValue Load = DAG.getLoad(ValVT, DL, Chain, FIPtr,
                                  MachinePointerInfo::getFixedStack(MF, FI));
      InVals.push_back(Load);
    }
  }

  return Chain;
}

//===----------------------------------------------------------------------===//
// Call lowering
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::LowerCall(CallLoweringInfo &CLI,
                                        SmallVectorImpl<SDValue> &InVals) const {
  SelectionDAG &DAG          = CLI.DAG;
  SDLoc &DL                  = CLI.DL;
  SmallVectorImpl<ISD::OutputArg> &Outs = CLI.Outs;
  SmallVectorImpl<SDValue>  &OutVals    = CLI.OutVals;
  SmallVectorImpl<ISD::InputArg> &Ins   = CLI.Ins;
  SDValue Chain              = CLI.Chain;
  SDValue Callee             = CLI.Callee;
  bool &IsTailCall           = CLI.IsTailCall;
  CallingConv::ID CallConv   = CLI.CallConv;
  bool IsVarArg              = CLI.IsVarArg;
  MachineFunction &MF        = DAG.getMachineFunction();

  IsTailCall = false;  // No tail calls in Phase 1

  // Analyze outgoing arguments
  SmallVector<CCValAssign, 16> ArgLocs;
  CCState CCInfo(CallConv, IsVarArg, MF, ArgLocs, *DAG.getContext());
  CCInfo.AnalyzeCallOperands(Outs, CC_RISC2);

  unsigned NumBytes = CCInfo.getStackSize();

  Chain = DAG.getCALLSEQ_START(Chain, NumBytes, 0, DL);

  SmallVector<std::pair<unsigned, SDValue>, 4> RegsToPass;
  SmallVector<SDValue, 8> MemOpChains;

  for (unsigned i = 0, e = ArgLocs.size(); i != e; ++i) {
    CCValAssign &VA = ArgLocs[i];
    SDValue Arg = OutVals[i];

    if (VA.isRegLoc()) {
      RegsToPass.push_back(std::make_pair(VA.getLocReg(), Arg));
    } else {
      assert(VA.isMemLoc());
      SDValue SpillSlot = DAG.getNode(ISD::ADD, DL, MVT::i32,
                                       DAG.getRegister(RISC2::R14, MVT::i32),
                                       DAG.getConstant(VA.getLocMemOffset(), DL, MVT::i32));
      MemOpChains.push_back(DAG.getStore(Chain, DL, Arg, SpillSlot,
                                          MachinePointerInfo()));
    }
  }

  if (!MemOpChains.empty())
    Chain = DAG.getNode(ISD::TokenFactor, DL, MVT::Other, MemOpChains);

  // Build a sequence of CopyToReg nodes, each with a glue edge
  SDValue Glue;
  for (auto &Reg : RegsToPass) {
    Chain = DAG.getCopyToReg(Chain, DL, Reg.first, Reg.second, Glue);
    Glue  = Chain.getValue(1);
  }

  // Wrap target in WRAPPER node if it's a global
  if (auto *G = dyn_cast<GlobalAddressSDNode>(Callee))
    Callee = DAG.getTargetGlobalAddress(G->getGlobal(), DL, MVT::i32,
                                         G->getOffset());
  else if (auto *ES = dyn_cast<ExternalSymbolSDNode>(Callee))
    Callee = DAG.getTargetExternalSymbol(ES->getSymbol(), MVT::i32);

  // Build call node
  SmallVector<SDValue, 8> Ops;
  Ops.push_back(Chain);
  Ops.push_back(Callee);
  for (auto &Reg : RegsToPass)
    Ops.push_back(DAG.getRegister(Reg.first, Reg.second.getValueType()));

  // Add register mask (R15 is clobbered by CALL, plus all caller-saved regs)
  const uint32_t *Mask =
      MF.getSubtarget<RISC2Subtarget>().getRegisterInfo()
          ->getCallPreservedMask(MF, CallConv);
  assert(Mask && "Missing call preserved mask");
  Ops.push_back(DAG.getRegisterMask(Mask));

  if (Glue.getNode())
    Ops.push_back(Glue);

  SDVTList NodeTys = DAG.getVTList(MVT::Other, MVT::Glue);
  Chain = DAG.getNode(RISC2ISD::CALL, DL, NodeTys, Ops);
  Glue  = Chain.getValue(1);

  Chain = DAG.getCALLSEQ_END(Chain, NumBytes, 0, Glue, DL);
  Glue  = Chain.getValue(1);

  // Handle return values
  SmallVector<CCValAssign, 4> RVLocs;
  CCState RetCCInfo(CallConv, IsVarArg, MF, RVLocs, *DAG.getContext());
  RetCCInfo.AnalyzeCallResult(Ins, RetCC_RISC2);

  for (auto &VA : RVLocs) {
    Chain = DAG.getCopyFromReg(Chain, DL, VA.getLocReg(), VA.getLocVT(), Glue)
                .getValue(1);
    Glue  = Chain.getValue(2);
    InVals.push_back(Chain.getValue(0));
  }

  return Chain;
}

//===----------------------------------------------------------------------===//
// Return lowering
//===----------------------------------------------------------------------===//

SDValue RISC2TargetLowering::LowerReturn(
    SDValue Chain, CallingConv::ID CallConv, bool IsVarArg,
    const SmallVectorImpl<ISD::OutputArg> &Outs,
    const SmallVectorImpl<SDValue> &OutVals, const SDLoc &DL,
    SelectionDAG &DAG) const {

  MachineFunction &MF = DAG.getMachineFunction();

  SmallVector<CCValAssign, 4> RVLocs;
  CCState CCInfo(CallConv, IsVarArg, MF, RVLocs, *DAG.getContext());
  CCInfo.AnalyzeReturn(Outs, RetCC_RISC2);

  SDValue Glue;
  SmallVector<SDValue, 4> RetOps(1, Chain);

  for (unsigned i = 0, e = RVLocs.size(); i != e; ++i) {
    CCValAssign &VA = RVLocs[i];
    assert(VA.isRegLoc() && "Can only return in registers!");

    Chain = DAG.getCopyToReg(Chain, DL, VA.getLocReg(), OutVals[i], Glue);
    Glue  = Chain.getValue(1);
    RetOps.push_back(DAG.getRegister(VA.getLocReg(), VA.getLocVT()));
  }

  RetOps[0] = Chain;  // Update chain
  if (Glue.getNode())
    RetOps.push_back(Glue);

  return DAG.getNode(RISC2ISD::RET, DL, MVT::Other, RetOps);
}

//===----------------------------------------------------------------------===//
// SELECT_CC pseudo expansion
//===----------------------------------------------------------------------===//
//
// MI operands: [0]=dst, [1]=trueVal, [2]=falseVal, [3]=cc, [4]=lhs, [5]=rhs
//
//   thisMBB:
//     CMP_RR lhs, rhs
//     Jcc(CC) trueBB
//   falseBB:
//     MOV_RR dst, falseVal
//     JMP sinkBB
//   trueBB:
//     MOV_RR dst, trueVal
//   sinkBB:  (rest of code)

MachineBasicBlock *RISC2TargetLowering::EmitInstrWithCustomInserter(
    MachineInstr &MI, MachineBasicBlock *BB) const {
  assert(MI.getOpcode() == RISC2::SELECT_CC && "Unexpected opcode");

  DebugLoc DL = MI.getDebugLoc();
  MachineFunction *MF = BB->getParent();
  const BasicBlock *LLVM_BB = BB->getBasicBlock();
  MachineFunction::iterator I = ++BB->getIterator();
  const RISC2InstrInfo &TII =
      *BB->getParent()->getSubtarget<RISC2Subtarget>().getInstrInfo();

  MachineBasicBlock *thisMBB = BB;
  MachineBasicBlock *falseBB = MF->CreateMachineBasicBlock(LLVM_BB);
  MachineBasicBlock *trueBB  = MF->CreateMachineBasicBlock(LLVM_BB);
  MachineBasicBlock *sinkBB  = MF->CreateMachineBasicBlock(LLVM_BB);
  MF->insert(I, falseBB);
  MF->insert(I, trueBB);
  MF->insert(I, sinkBB);

  // Move remainder of thisMBB into sinkBB and transfer successors
  sinkBB->splice(sinkBB->begin(), BB,
                 std::next(MachineBasicBlock::iterator(MI)), BB->end());
  sinkBB->transferSuccessorsAndUpdatePHIs(BB);

  Register DstReg   = MI.getOperand(0).getReg();
  Register TrueReg  = MI.getOperand(1).getReg();
  Register FalseReg = MI.getOperand(2).getReg();
  unsigned CC       = MI.getOperand(3).getImm();
  Register LHSReg   = MI.getOperand(4).getReg();
  Register RHSReg   = MI.getOperand(5).getReg();

  unsigned BrOpc;
  switch (CC) {
  case RISC2CC::COND_NZ: BrOpc = RISC2::JNZ; break;
  case RISC2CC::COND_Z:  BrOpc = RISC2::JZ;  break;
  case RISC2CC::COND_NC: BrOpc = RISC2::JNC; break;
  case RISC2CC::COND_C:  BrOpc = RISC2::JC;  break;
  case RISC2CC::COND_GE: BrOpc = RISC2::JGE; break;
  case RISC2CC::COND_LT: BrOpc = RISC2::JLT; break;
  default:               BrOpc = RISC2::JMP; break;
  }

  // Create new vregs to avoid defining DstReg in two places (SSA requirement)
  MachineRegisterInfo &MRI = MF->getRegInfo();
  const TargetRegisterClass *RC = MRI.getRegClass(DstReg);
  Register FalseResult = MRI.createVirtualRegister(RC);
  Register TrueResult  = MRI.createVirtualRegister(RC);

  // thisMBB: CMP + conditional branch to trueBB, fall through to falseBB
  thisMBB->addSuccessor(falseBB);
  thisMBB->addSuccessor(trueBB);
  BuildMI(*thisMBB, thisMBB->end(), DL, TII.get(RISC2::CMP_RR))
      .addReg(LHSReg).addReg(RHSReg);
  BuildMI(*thisMBB, thisMBB->end(), DL, TII.get(BrOpc)).addMBB(trueBB);

  // falseBB: FalseResult = MOV_RR falseVal; JMP sinkBB
  falseBB->addSuccessor(sinkBB);
  BuildMI(*falseBB, falseBB->end(), DL, TII.get(RISC2::MOV_RR), FalseResult)
      .addReg(FalseReg);
  BuildMI(*falseBB, falseBB->end(), DL, TII.get(RISC2::JMP)).addMBB(sinkBB);

  // trueBB: TrueResult = MOV_RR trueVal; fall through to sinkBB
  trueBB->addSuccessor(sinkBB);
  BuildMI(*trueBB, trueBB->end(), DL, TII.get(RISC2::MOV_RR), TrueResult)
      .addReg(TrueReg);

  // sinkBB: PHI merges TrueResult and FalseResult into DstReg
  BuildMI(*sinkBB, sinkBB->begin(), DL, TII.get(TargetOpcode::PHI), DstReg)
      .addReg(TrueResult).addMBB(trueBB)
      .addReg(FalseResult).addMBB(falseBB);

  MI.eraseFromParent();
  return sinkBB;
}
