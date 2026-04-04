add_llvm_component_group(RISC2)

set(LLVM_TARGET_DEFINITIONS RISC2.td)

tablegen(LLVM RISC2GenRegisterInfo.inc     -gen-register-info)
tablegen(LLVM RISC2GenInstrInfo.inc        -gen-instr-info)
tablegen(LLVM RISC2GenCallingConv.inc      -gen-callingconv)
tablegen(LLVM RISC2GenDAGISel.inc          -gen-dag-isel)
tablegen(LLVM RISC2GenSubtargetInfo.inc    -gen-subtarget)
tablegen(LLVM RISC2GenAsmWriter.inc        -gen-asm-writer)

add_public_tablegen_target(RISC2CommonTableGen)

add_llvm_target(RISC2CodeGen
  RISC2AsmPrinter.cpp
  RISC2MCInstLower.cpp
  RISC2FrameLowering.cpp
  RISC2ISelDAGToDAG.cpp
  RISC2ISelLowering.cpp
  RISC2InstrInfo.cpp
  RISC2RegisterInfo.cpp
  RISC2Subtarget.cpp
  RISC2TargetMachine.cpp

  LINK_COMPONENTS
    Analysis
    AsmPrinter
    CodeGen
    CodeGenTypes
    Core
    MC
    RISC2Desc
    RISC2Info
    SelectionDAG
    Support
    Target
    TargetParser
    TransformUtils

  ADD_TO_COMPONENT
    RISC2
)

add_subdirectory(MCTargetDesc)
add_subdirectory(TargetInfo)
