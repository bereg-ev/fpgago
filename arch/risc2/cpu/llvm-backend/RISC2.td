// RISC2 Target Description

include "llvm/Target/Target.td"

include "RISC2RegisterInfo.td"
include "RISC2Schedule.td"
include "RISC2InstrInfo.td"
include "RISC2CallingConv.td"

//===----------------------------------------------------------------------===//
// Subtarget features (none for now - single variant)
//===----------------------------------------------------------------------===//

def : ProcessorModel<"generic-risc2", RISC2SchedModel, []>;

// Map ptr_rc pseudo-instructions to GPR (pointer-sized = 32-bit = GPR)
defm : RemapAllTargetPseudoPointerOperands<GPR>;

//===----------------------------------------------------------------------===//
// Target declaration
//===----------------------------------------------------------------------===//

def RISC2InstrInfo : InstrInfo;

def RISC2AsmWriter : AsmWriter {
  string AsmWriterClassName = "InstPrinter";
  int Variant = 0;
}

def RISC2 : Target {
  let InstructionSet = RISC2InstrInfo;
  let AssemblyWriters = [RISC2AsmWriter];
}
