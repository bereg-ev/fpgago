add_llvm_component_library(LLVMRISC2Desc
  RISC2InstPrinter.cpp
  RISC2MCAsmInfo.cpp
  RISC2MCTargetDesc.cpp

  LINK_COMPONENTS
    MC
    MCDisassembler
    Support
    RISC2Info

  ADD_TO_COMPONENT
    RISC2
)

add_dependencies(LLVMRISC2Desc RISC2CommonTableGen)
