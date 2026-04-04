//===-- RISC2InstrInfo.cpp - RISC2 Instruction Information ----------------===//
#include "RISC2InstrInfo.h"
#include "RISC2Subtarget.h"
#include "MCTargetDesc/RISC2MCTargetDesc.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/Support/ErrorHandling.h"

#define GET_INSTRINFO_CTOR_DTOR
#include "RISC2GenInstrInfo.inc"

using namespace llvm;

RISC2InstrInfo::RISC2InstrInfo(const RISC2Subtarget &STI)
    : RISC2GenInstrInfo(STI, *STI.getRegisterInfo(),
                        RISC2::ADJCALLSTACKDOWN, RISC2::ADJCALLSTACKUP),
      RI(STI.getHwMode()),
      STI(STI) {}

void RISC2InstrInfo::copyPhysReg(MachineBasicBlock &MBB,
                                  MachineBasicBlock::iterator I,
                                  const DebugLoc &DL, Register DestReg,
                                  Register SrcReg, bool KillSrc,
                                  bool RenamableDest,
                                  bool RenamableSrc) const {
  // MOV dst, src
  BuildMI(MBB, I, DL, get(RISC2::MOV_RR), DestReg)
      .addReg(SrcReg, getKillRegState(KillSrc));
}

void RISC2InstrInfo::storeRegToStackSlot(MachineBasicBlock &MBB,
                                          MachineBasicBlock::iterator MBBI,
                                          Register SrcReg, bool isKill,
                                          int FrameIndex,
                                          const TargetRegisterClass *RC,
                                          Register VReg,
                                          MachineInstr::MIFlag Flags) const {
  DebugLoc DL;
  if (MBBI != MBB.end())
    DL = MBBI->getDebugLoc();

  MachineFunction &MF = *MBB.getParent();
  const TargetRegisterInfo *TRI = MF.getSubtarget().getRegisterInfo();
  MachineMemOperand *MMO = MF.getMachineMemOperand(
      MachinePointerInfo::getFixedStack(MF, FrameIndex),
      MachineMemOperand::MOStore,
      TRI->getSpillSize(*RC), TRI->getSpillAlign(*RC));

  BuildMI(MBB, MBBI, DL, get(RISC2::STORE32))
      .addReg(SrcReg, getKillRegState(isKill))
      .addFrameIndex(FrameIndex)
      .addImm(0)
      .addMemOperand(MMO);
}

void RISC2InstrInfo::loadRegFromStackSlot(MachineBasicBlock &MBB,
                                           MachineBasicBlock::iterator MBBI,
                                           Register DestReg, int FrameIndex,
                                           const TargetRegisterClass *RC,
                                           Register VReg, unsigned SubReg,
                                           MachineInstr::MIFlag Flags) const {
  DebugLoc DL;
  if (MBBI != MBB.end())
    DL = MBBI->getDebugLoc();

  MachineFunction &MF = *MBB.getParent();
  const TargetRegisterInfo *TRI = MF.getSubtarget().getRegisterInfo();
  MachineMemOperand *MMO = MF.getMachineMemOperand(
      MachinePointerInfo::getFixedStack(MF, FrameIndex),
      MachineMemOperand::MOLoad,
      TRI->getSpillSize(*RC), TRI->getSpillAlign(*RC));

  BuildMI(MBB, MBBI, DL, get(RISC2::LOAD32), DestReg)
      .addFrameIndex(FrameIndex)
      .addImm(0)
      .addMemOperand(MMO);
}

