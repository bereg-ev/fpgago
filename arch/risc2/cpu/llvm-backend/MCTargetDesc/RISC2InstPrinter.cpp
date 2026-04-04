//===-- RISC2InstPrinter.cpp - Convert RISC2 MCInst to assembly ----------===//
//
// Emits gcasm-compatible assembly text.
// Key format rules (from arch.c and 1.asm):
//   - Registers: r0..r15 (lowercase, no % prefix)
//   - Immediates: #hexvalue (no 0x prefix, lowercase hex)
//   - Symbol addresses: @label
//   - STORE: "store (addr_reg), val_reg"  (gcasm swaps internally)
//   - LOAD+disp: "load dst, (base+#disp)"
//   - LOAD abs: "load dst, (#absaddr)"
//   - Branch targets: label names
//
#include "RISC2InstPrinter.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/MC/MCAsmInfo.h"
#include "llvm/MC/MCExpr.h"
#include "llvm/MC/MCInst.h"
#include "llvm/MC/MCRegisterInfo.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/MC/MCSymbol.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Triple.h"

using namespace llvm;

#define PRINT_ALIAS_INSTR
#include "RISC2GenAsmWriter.inc"

MCInstPrinter *llvm::createRISC2InstPrinter(const Triple &T,
                                              unsigned SyntaxVariant,
                                              const MCAsmInfo &MAI,
                                              const MCInstrInfo &MII,
                                              const MCRegisterInfo &MRI) {
  return new RISC2InstPrinter(MAI, MII, MRI);
}

void RISC2InstPrinter::printRegName(raw_ostream &O, MCRegister Reg) {
  O << getRegisterName(Reg);
}

void RISC2InstPrinter::printInst(const MCInst *MI, uint64_t Address,
                                  StringRef Annot, const MCSubtargetInfo &STI,
                                  raw_ostream &O) {
  printInstruction(MI, Address, O);
  printAnnotation(O, Annot);
}

void RISC2InstPrinter::printOperand(const MCInst *MI, unsigned OpNo,
                                     raw_ostream &O) {
  const MCOperand &Op = MI->getOperand(OpNo);

  if (Op.isReg()) {
    printRegName(O, Op.getReg());
    return;
  }

  if (Op.isImm()) {
    // gcasm expects #hexvalue (no 0x prefix)
    O << '#';
    O.write_hex((uint32_t)Op.getImm());
    return;
  }

  if (Op.isExpr()) {
    const MCExpr *Expr = Op.getExpr();
    if (const MCSymbolRefExpr *SRE = dyn_cast<MCSymbolRefExpr>(Expr)) {
      // Use @label syntax for symbol references (gcasm address-of)
      O << '@' << SRE->getSymbol().getName();
    } else {
      MAI.printExpr(O, *Expr);
    }
    return;
  }

  llvm_unreachable("Unknown operand type");
}

// These methods print only the hex value (no '#') because the '#' is in the
// instruction template string (e.g., "mov $dst, #$imm").
void RISC2InstPrinter::printUImm20Operand(const MCInst *MI, unsigned OpNo,
                                           raw_ostream &O) {
  const MCOperand &Op = MI->getOperand(OpNo);
  if (Op.isImm())
    O.write_hex((uint32_t)Op.getImm());
  else
    printOperand(MI, OpNo, O);
}

void RISC2InstPrinter::printUImm16Operand(const MCInst *MI, unsigned OpNo,
                                           raw_ostream &O) {
  const MCOperand &Op = MI->getOperand(OpNo);
  if (Op.isImm())
    O.write_hex((uint32_t)Op.getImm());
  else
    printOperand(MI, OpNo, O);
}

void RISC2InstPrinter::printUImm12Operand(const MCInst *MI, unsigned OpNo,
                                           raw_ostream &O) {
  const MCOperand &Op = MI->getOperand(OpNo);
  if (Op.isImm())
    O.write_hex((uint32_t)Op.getImm());
  else
    printOperand(MI, OpNo, O);
}

// MOV_RI immediate/address: prints #hex for literals, @label for symbol refs
void RISC2InstPrinter::printMovImmAddr(const MCInst *MI, unsigned OpNo,
                                        raw_ostream &O) {
  const MCOperand &Op = MI->getOperand(OpNo);
  if (Op.isImm()) {
    O << '#';
    O.write_hex((uint32_t)Op.getImm());
  } else if (Op.isExpr()) {
    const MCExpr *Expr = Op.getExpr();
    if (const MCSymbolRefExpr *SRE = dyn_cast<MCSymbolRefExpr>(Expr))
      O << '@' << SRE->getSymbol().getName();
    else
      MAI.printExpr(O, *Expr);
  } else {
    printOperand(MI, OpNo, O);
  }
}

void RISC2InstPrinter::printBranchTarget(const MCInst *MI, unsigned OpNo,
                                          raw_ostream &O) {
  const MCOperand &Op = MI->getOperand(OpNo);
  if (Op.isExpr()) {
    MAI.printExpr(O, *Op.getExpr());
  } else if (Op.isImm()) {
    // Signed offset — printed as decimal for readability
    O << Op.getImm();
  }
}

void RISC2InstPrinter::printCallTarget(const MCInst *MI, unsigned OpNo,
                                        raw_ostream &O) {
  const MCOperand &Op = MI->getOperand(OpNo);
  if (Op.isExpr()) {
    if (const MCSymbolRefExpr *SRE = dyn_cast<MCSymbolRefExpr>(Op.getExpr()))
      O << SRE->getSymbol().getName();
    else
      MAI.printExpr(O, *Op.getExpr());
  } else if (Op.isReg()) {
    printRegName(O, Op.getReg());
  }
}

void RISC2InstPrinter::printCondCode(const MCInst *MI, unsigned OpNo,
                                      raw_ostream &O) {
  // Condition codes are embedded in the opcode; this is a no-op operand printer
}
