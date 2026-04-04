//===-- RISC2AsmPrinter.cpp - RISC2 LLVM Assembly Printer ----------------===//
#include "RISC2.h"
#include "RISC2MCInstLower.h"
#include "RISC2TargetMachine.h"
#include "TargetInfo/RISC2TargetInfo.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/CodeGen/AsmPrinter.h"
#include "llvm/CodeGen/MachineInstr.h"
#include "llvm/CodeGen/MachineModuleInfoImpls.h"
#include "llvm/CodeGen/TargetLoweringObjectFileImpl.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/MCContext.h"
#include "llvm/MC/MCExpr.h"
#include "llvm/MC/MCAsmInfo.h"
#include "llvm/MC/MCInst.h"
#include "llvm/MC/MCStreamer.h"
#include "llvm/MC/MCSymbol.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/raw_ostream.h"

// Note: opcode enum (RISC2::MOV_RI etc.) comes from MCTargetDesc/RISC2MCTargetDesc.h
// which is already included above and contains #define GET_INSTRINFO_ENUM +
// #include "RISC2GenInstrInfo.inc".

using namespace llvm;

#define DEBUG_TYPE "asm-printer"

namespace {
class RISC2AsmPrinter : public AsmPrinter {
public:
  explicit RISC2AsmPrinter(TargetMachine &TM,
                            std::unique_ptr<MCStreamer> Streamer)
      : AsmPrinter(TM, std::move(Streamer)) {}

  StringRef getPassName() const override { return "RISC2 Assembly Printer"; }

  // Rename private globals whose IR names start with '.' to '_L' prefix.
  // gcasm's tokeniser treats any token starting with '.' as a directive;
  // LLVM names string literals @.str, @.str.1, etc. so they must be fixed
  // before MCSymbols are created.  This runs before any runOnFunction call.
  bool doInitialization(Module &M) override;

  void emitInstruction(const MachineInstr *MI) override;

  // Suppress ELF/metadata directives not understood by gcasm
  void emitFunctionEntryLabel() override;
  void emitFunctionBodyStart() override {}
  void emitFunctionBodyEnd() override {}
  void emitStartOfAsmFile(Module &) override {}
  void emitEndOfAsmFile(Module &) override {}
  // Suppress .global directives (gcasm doesn't understand them)
  void emitLinkage(const GlobalValue *GV, MCSymbol *GVSym) const override {}
  // Emit global variables without alignment directives
  void emitGlobalVariable(const GlobalVariable *GV) override;
};
} // end anonymous namespace

bool RISC2AsmPrinter::doInitialization(Module &M) {
  // gcasm tokenises any token starting with '.' as a keyword/directive, so
  // labels like ".str:" or ".str.1:" are rejected.  LLVM names anonymous
  // string-literal globals @.str, @.str.1, etc.  Rename them here — before
  // any MCSymbol is created — by replacing the leading '.' with "_L".
  // All IR references use the GlobalValue*, so renaming is automatically
  // reflected in every use site (MOV_RI @.str → MOV_RI @_Lstr, etc.).
  for (GlobalVariable &GV : M.globals()) {
    StringRef N = GV.getName();
    if (!N.empty() && N[0] == '.') {
      SmallString<64> NewName("_L");
      NewName += N.drop_front(1);  // drop the leading '.'
      GV.setName(NewName);
    }
  }
  return AsmPrinter::doInitialization(M);
}

void RISC2AsmPrinter::emitFunctionEntryLabel() {
  // Emit just "label:" without ELF .type/.size directives
  OutStreamer->emitLabel(CurrentFnSym);
}

// Recursively emit a constant as a flat sequence of 32-bit words.
// This avoids emitZeros() / ZeroDirective (".db N") which gcasm mis-parses
// as a single byte of value N rather than N zero bytes.
static void emitConstWords(MCStreamer &S, const DataLayout &DL,
                            const Constant *C) {
  Type *Ty = C->getType();

  // Scalar integer (including zero)
  if (const auto *CI = dyn_cast<ConstantInt>(C)) {
    S.emitIntValue(CI->getZExtValue(),
                   (unsigned)DL.getTypeStoreSize(Ty).getFixedValue());
    return;
  }
  // Dense uniform-type array/vector (ConstantDataArray / ConstantDataVector)
  if (const auto *CDS = dyn_cast<ConstantDataSequential>(C)) {
    unsigned ElemSize =
        (unsigned)DL.getTypeStoreSize(CDS->getElementType()).getFixedValue();
    for (unsigned i = 0, n = CDS->getNumElements(); i < n; ++i)
      S.emitIntValue(CDS->getElementAsInteger(i), ElemSize);
    return;
  }
  // General aggregate (ConstantArray, ConstantStruct): recurse into operands
  if (isa<ConstantAggregate>(C)) {
    for (unsigned i = 0, n = C->getNumOperands(); i < n; ++i)
      emitConstWords(S, DL, cast<Constant>(C->getOperand(i)));
    return;
  }
  // Null pointer: zero word
  if (isa<ConstantPointerNull>(C)) {
    S.emitIntValue(0, 4);
    return;
  }
  // Undef: zero-fill
  if (isa<UndefValue>(C)) {
    uint64_t Size = DL.getTypeAllocSize(Ty).getFixedValue();
    for (uint64_t i = 0; i < Size; ++i) S.emitIntValue(0, 1);
    return;
  }
  // ConstantAggregateZero (zeroinitializer for any type): zero-fill
  if (isa<ConstantAggregateZero>(C)) {
    uint64_t Size = DL.getTypeAllocSize(Ty).getFixedValue();
    for (uint64_t i = 0; i < Size; ++i) S.emitIntValue(0, 1);
    return;
  }
  // GlobalValue pointer (e.g. pointer table entry like @switch.table entries):
  // emit its absolute address as a 32-bit word.  Symbol is looked up from the
  // MCContext directly because AsmPrinter::getSymbol() is not accessible here;
  // the name is already in the MCContext from TM.getSymbol() calls elsewhere.
  if (const auto *GV = dyn_cast<GlobalValue>(C)) {
    // The GlobalValue name was already fixed by doInitialization (no leading '.').
    MCSymbol *Sym = S.getContext().getOrCreateSymbol(GV->getName());
    const MCExpr *Expr = MCSymbolRefExpr::create(Sym, S.getContext());
    S.emitValue(Expr, 4);
    return;
  }
  // ConstantExpr (e.g. GEP / bitcast / inttoptr of a global): strip casts
  // and emit the underlying global's address.
  if (const auto *CE = dyn_cast<ConstantExpr>(C)) {
    // Recursively handle the first operand (the base pointer) for casts/GEPs.
    if (CE->getOpcode() == Instruction::BitCast ||
        CE->getOpcode() == Instruction::GetElementPtr ||
        CE->getOpcode() == Instruction::IntToPtr ||
        CE->getOpcode() == Instruction::PtrToInt) {
      emitConstWords(S, DL, CE->getOperand(0));
      return;
    }
  }
  // Fallback: zero-fill unknown constant types
  uint64_t Size = DL.getTypeAllocSize(Ty).getFixedValue();
  for (uint64_t i = 0; i < Size / 4; ++i) S.emitIntValue(0, 4);
  for (uint64_t i = (Size / 4) * 4; i < Size; ++i) S.emitIntValue(0, 1);
}

void RISC2AsmPrinter::emitGlobalVariable(const GlobalVariable *GV) {
  if (!GV->hasInitializer())
    return; // External — no data to emit

  // Mutable globals live in data RAM (addresses assigned at ISel time by
  // RISC2TargetLowering::computeBSSLayout).  Don't emit their data into ROM.
  if (!GV->isConstant())
    return;

  MCSymbol *GVSym = getSymbol(GV);
  GVSym->redefineIfPossible();

  // Emit just the label and data; no alignment, no .type/.size directives.
  // Use emitConstWords instead of emitGlobalConstant to avoid the ZeroDirective
  // (".db N") which gcasm interprets as one byte of value N, not N zero bytes.
  OutStreamer->emitLabel(GVSym);
  const DataLayout &DL = GV->getDataLayout();
  emitConstWords(*OutStreamer, DL, GV->getInitializer());
}

// Emit an IMM prefix instruction if the MCInst is an RI instruction whose
// immediate value exceeds 20 bits.  The IMM instruction in RISC2 loads the
// upper 12 bits into an internal register that is consumed by the very next
// instruction's 20-bit immediate field to form a full 32-bit value.
// We emit both instructions in sequence from a single MachineInstr so the
// scheduler never separates them.
static bool emitIMMPrefixIfNeeded(MCStreamer &Streamer,
                                   MCInst &Inst,
                                   const MCSubtargetInfo &STI) {
  // Only RI-mode instructions use the IMM prefix mechanism.
  unsigned Opc = Inst.getOpcode();
  bool isRI = (Opc == RISC2::MOV_RI  || Opc == RISC2::ADD_RI ||
               Opc == RISC2::SUB_RI  || Opc == RISC2::AND_RI ||
               Opc == RISC2::OR_RI   || Opc == RISC2::XOR_RI ||
               Opc == RISC2::CMP_RI);
  if (!isRI)
    return false;

  // Find the (sole) immediate operand.
  for (unsigned i = 0, e = Inst.getNumOperands(); i < e; ++i) {
    const MCOperand &Op = Inst.getOperand(i);
    if (!Op.isImm())
      continue;

    uint32_t Val   = (uint32_t)Op.getImm();
    uint32_t Upper = (Val >> 20) & 0xFFF;
    if (Upper == 0)
      return false;  // Fits in 20 bits — no prefix needed.

    // Emit  imm #upper12
    MCInst IMMInst;
    IMMInst.setOpcode(RISC2::IMMInst);
    IMMInst.addOperand(MCOperand::createImm(Upper));
    Streamer.emitInstruction(IMMInst, STI);

    // Patch the original instruction to carry only the lower 20 bits.
    Inst.getOperand(i).setImm(Val & 0xFFFFF);
    return true;
  }
  return false;
}

void RISC2AsmPrinter::emitInstruction(const MachineInstr *MI) {
  RISC2MCInstLower MCInstLowering(OutContext, *this);
  MCInst TmpInst;
  MCInstLowering.Lower(MI, TmpInst);
  // If the instruction carries a >20-bit immediate, emit the IMM prefix first
  // then emit the patched instruction (with only the lower 20 bits).
  emitIMMPrefixIfNeeded(*OutStreamer, TmpInst, getSubtargetInfo());
  OutStreamer->emitInstruction(TmpInst, getSubtargetInfo());
}

// Force instantiation of the template
extern "C" LLVM_EXTERNAL_VISIBILITY void LLVMInitializeRISC2AsmPrinter() {
  RegisterAsmPrinter<RISC2AsmPrinter> X(getTheRISC2Target());
}
