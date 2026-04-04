//===-- RISC2MCInstLower.cpp - Convert RISC2 MachineInstr to MCInst -------===//
//
// Lowers MachineInstr to MCInst for text assembly output.
//
#include "RISC2MCInstLower.h"
#include "llvm/CodeGen/AsmPrinter.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineInstr.h"
#include "llvm/MC/MCContext.h"
#include "llvm/MC/MCExpr.h"
#include "llvm/MC/MCInst.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

MCSymbol *RISC2MCInstLower::getSymbol(const MachineOperand &MO) const {
  switch (MO.getType()) {
  case MachineOperand::MO_GlobalAddress:
    return Printer.getSymbol(MO.getGlobal());
  case MachineOperand::MO_ExternalSymbol:
    return Printer.GetExternalSymbolSymbol(MO.getSymbolName());
  case MachineOperand::MO_BlockAddress:
    return Printer.GetBlockAddressSymbol(MO.getBlockAddress());
  default:
    llvm_unreachable("getSymbol: unexpected operand type");
  }
}

MCOperand RISC2MCInstLower::lowerOperand(const MachineOperand &MO) const {
  switch (MO.getType()) {
  case MachineOperand::MO_Register:
    return MCOperand::createReg(MO.getReg());

  case MachineOperand::MO_Immediate:
    return MCOperand::createImm(MO.getImm());

  case MachineOperand::MO_MachineBasicBlock:
    return MCOperand::createExpr(
        MCSymbolRefExpr::create(MO.getMBB()->getSymbol(), Ctx));

  case MachineOperand::MO_GlobalAddress:
  case MachineOperand::MO_ExternalSymbol:
  case MachineOperand::MO_BlockAddress: {
    MCSymbol *Sym = getSymbol(MO);
    const MCExpr *Expr = MCSymbolRefExpr::create(Sym, Ctx);
    if (MO.getOffset())
      Expr = MCBinaryExpr::createAdd(
          Expr, MCConstantExpr::create(MO.getOffset(), Ctx), Ctx);
    return MCOperand::createExpr(Expr);
  }

  case MachineOperand::MO_RegisterMask:
    return MCOperand(); // invalid / skip

  default:
    MO.getParent()->print(errs());
    llvm_unreachable("unknown operand type");
  }
}

void RISC2MCInstLower::Lower(const MachineInstr *MI, MCInst &OutMI) const {
  OutMI.setOpcode(MI->getOpcode());
  for (const MachineOperand &MO : MI->operands()) {
    // Skip implicit register operands and register masks
    if (MO.isReg() && MO.isImplicit())
      continue;
    if (MO.isRegMask())
      continue;
    MCOperand MCOp = lowerOperand(MO);
    if (MCOp.isValid())
      OutMI.addOperand(MCOp);
  }
}
