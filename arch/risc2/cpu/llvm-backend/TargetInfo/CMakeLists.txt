add_llvm_component_library(LLVMRISC2Info
  RISC2TargetInfo.cpp

  LINK_COMPONENTS
    MC
    Support

  ADD_TO_COMPONENT
    RISC2
)
