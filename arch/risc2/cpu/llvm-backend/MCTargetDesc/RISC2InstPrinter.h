//===-- RISC2InstPrinter.h - Convert RISC2 MCInst to assembly syntax -----===//
#ifndef LLVM_LIB_TARGET_RISC2_RISC2INSTPRINTER_H
#define LLVM_LIB_TARGET_RISC2_RISC2INSTPRINTER_H

#include "llvm/MC/MCInstPrinter.h"

namespace llvm {
class MCOperand;
class Triple;

class RISC2InstPrinter : public MCInstPrinter {
public:
  RISC2InstPrinter(const MCAsmInfo &MAI, const MCInstrInfo &MII,
                   const MCRegisterInfo &MRI)
      : MCInstPrinter(MAI, MII, MRI) {}

  void printInst(const MCInst *MI, uint64_t Address, StringRef Annot,
                 const MCSubtargetInfo &STI, raw_ostream &O) override;

  void printRegName(raw_ostream &OS, MCRegister Reg) override;

  // Called by TableGen-generated printInstruction (no STI in LLVM 22)
  void printOperand(const MCInst *MI, unsigned OpNo, raw_ostream &O);

  // Custom print methods (no STI — TableGen 22 generates 3-arg calls)
  void printUImm20Operand(const MCInst *MI, unsigned OpNo, raw_ostream &O);
  void printUImm16Operand(const MCInst *MI, unsigned OpNo, raw_ostream &O);
  void printUImm12Operand(const MCInst *MI, unsigned OpNo, raw_ostream &O);
  void printMovImmAddr(const MCInst *MI, unsigned OpNo, raw_ostream &O);
  void printBranchTarget(const MCInst *MI, unsigned OpNo, raw_ostream &O);
  void printCallTarget(const MCInst *MI, unsigned OpNo, raw_ostream &O);
  void printCondCode(const MCInst *MI, unsigned OpNo, raw_ostream &O);

  // TableGen-generated (LLVM 22: no STI, no Address in printInstruction)
  std::pair<const char *, uint64_t> getMnemonic(const MCInst &MI) const override;
  void printInstruction(const MCInst *MI, uint64_t Address, raw_ostream &O);
  bool printAliasInstr(const MCInst *MI, uint64_t Address, raw_ostream &OS);
  void printCustomAliasOperand(const MCInst *MI, uint64_t Address,
                               unsigned OpIdx, unsigned PrintMethodIdx,
                               raw_ostream &O);
  static const char *getRegisterName(MCRegister Reg);
};

MCInstPrinter *createRISC2InstPrinter(const Triple &T, unsigned SyntaxVariant,
                                       const MCAsmInfo &MAI,
                                       const MCInstrInfo &MII,
                                       const MCRegisterInfo &MRI);

} // namespace llvm

#endif
