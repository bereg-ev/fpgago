//===-- RISC2MCAsmInfo.cpp - RISC2 Asm Properties -------------------------===//
#include "RISC2MCAsmInfo.h"
#include "llvm/MC/MCAsmInfo.h"
#include "llvm/TargetParser/Triple.h"

using namespace llvm;

void RISC2MCAsmInfo::anchor() {}

RISC2MCAsmInfo::RISC2MCAsmInfo(const Triple &TT) {
  // gcasm uses ';' for comments
  CommentString = ";";

  // Local label prefix — must NOT start with '.' because gcasm checks for
  // '.' before checking for ':' (label), so .Lxxx would fail as "unknown keyword"
  PrivateLabelPrefix  = "_L";

  // Data directives matching gcasm syntax
  Data8bitsDirective  = "\t.db ";
  Data16bitsDirective = nullptr;  // not supported directly; use .db pairs
  Data32bitsDirective = "\t.dd ";
  Data64bitsDirective = nullptr;

  // gcasm doesn't understand ELF metadata directives
  HasDotTypeDotSizeDirective = false;
  HasSingleParameterDotFile  = false;
  SupportsDebugInformation   = false;

  // Code alignment — gcasm has no alignment directives, suppress them
  HasFunctionAlignment  = false;
  AlignmentIsInBytes    = false;
  TextAlignFillValue    = 0;

  // Weak/global visibility not needed for flat ROM target
  WeakRefDirective = nullptr;
  GlobalDirective  = nullptr;

  // Separator between instructions on the same line
  SeparatorString = "\n";

  // Byte encoding is big-endian in the ROM image (see compile.c)
  IsLittleEndian = false;

  // Zero-length arrays
  ZeroDirective = "\t.db ";
}
