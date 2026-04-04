//===-- RISC2MCInstLower.h - Lower MachineInstr to MCInst -------*- C++ -*-===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2MCINSTLOWER_H
#define LLVM_LIB_TARGET_RISC2_RISC2MCINSTLOWER_H

#include "llvm/Support/Compiler.h"

namespace llvm {
class AsmPrinter;
class MCContext;
class MCInst;
class MCOperand;
class MCSymbol;
class MachineInstr;
class MachineOperand;

class LLVM_LIBRARY_VISIBILITY RISC2MCInstLower {
  MCContext &Ctx;
  AsmPrinter &Printer;

public:
  RISC2MCInstLower(MCContext &CTX, AsmPrinter &AP) : Ctx(CTX), Printer(AP) {}
  void Lower(const MachineInstr *MI, MCInst &OutMI) const;

private:
  MCOperand lowerOperand(const MachineOperand &MO) const;
  MCSymbol *getSymbol(const MachineOperand &MO) const;
};
} // namespace llvm

#endif
