#!/usr/bin/env bash
# setup-llvm.sh - Integrate RISC2 backend into an LLVM source checkout
#
# Usage:  bash setup-llvm.sh <path-to-llvm-project>
# Example: bash setup-llvm.sh ~/llvm-project
#
# After running this script:
#   cmake -S <llvm-project>/llvm -B <build-dir> \
#         -DLLVM_TARGETS_TO_BUILD="RISC2" \
#         -DLLVM_ENABLE_PROJECTS="clang" \
#         -DCMAKE_BUILD_TYPE=Debug \
#         -G Ninja
#   ninja -C <build-dir> clang llc

set -e

LLVM_SRC="${1:?Usage: $0 <path-to-llvm-project>}"
BACKEND_SRC="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$BACKEND_SRC/patches"

echo "RISC2 backend source: $BACKEND_SRC"
echo "LLVM source tree:     $LLVM_SRC"
echo ""

# ── 1. Verify LLVM source ──────────────────────────────────────────────────
if [ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]; then
  echo "ERROR: $LLVM_SRC does not look like an llvm-project checkout."
  echo "       Expected to find llvm/CMakeLists.txt inside it."
  exit 1
fi

LLVM_VER=$(grep 'set(LLVM_VERSION_MAJOR' "$LLVM_SRC/llvm/CMakeLists.txt" | \
           grep -o '[0-9]*' | head -1)
echo "Detected LLVM major version: $LLVM_VER"

# ── 2. Symlink backend into LLVM Target directory ──────────────────────────
DEST="$LLVM_SRC/llvm/lib/Target/RISC2"
if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
  echo "ERROR: $DEST exists and is not a symlink. Remove it first."
  exit 1
fi
ln -snf "$BACKEND_SRC" "$DEST"
echo "Linked: $DEST -> $BACKEND_SRC"

# ── 3. Apply the combined tree patch ──────────────────────────────────────
# tree_modifications.patch covers all changes outside llvm-backend/:
#   - llvm/CMakeLists.txt               add RISC2 to LLVM_ALL_TARGETS
#   - llvm/include/.../Triple.h         add risc2 to ArchType enum
#   - llvm/lib/TargetParser/Triple.cpp  name/parse/format/endian/pointer tables
#   - clang/lib/Basic/CMakeLists.txt    add Targets/RISC2.cpp
#   - clang/lib/Basic/Targets.cpp       add risc2 case in AllocateTarget
#   - clang/lib/Basic/Targets/RISC2.h   new file (clang TargetInfo)
#   - clang/lib/Basic/Targets/RISC2.cpp new file (macro definitions)

PATCH="$PATCHES_DIR/tree_modifications.patch"
if [ ! -f "$PATCH" ]; then
  echo "ERROR: $PATCH not found."
  exit 1
fi

echo "Applying $PATCH ..."
cd "$LLVM_SRC"
if grep -q 'risc2' llvm/include/llvm/TargetParser/Triple.h 2>/dev/null; then
  echo "Patch already applied (Triple.h already contains 'risc2')."
else
  patch -p1 < "$PATCH"
  echo "Patch applied."
fi

# ── 4. Summary ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " RISC2 backend integration complete!"
echo ""
echo " Build commands:"
echo "   cmake -S $LLVM_SRC/llvm -B ~/llvm-risc2-build \\"
echo "         -DLLVM_TARGETS_TO_BUILD='RISC2' \\"
echo "         -DLLVM_ENABLE_PROJECTS='clang' \\"
echo "         -DCMAKE_BUILD_TYPE=Debug \\"
echo "         -G Ninja"
echo "   ninja -C ~/llvm-risc2-build clang llc"
echo ""
echo " Then test:"
echo '   ~/llvm-risc2-build/bin/clang --target=risc2 -S test.c -o test.asm'
echo '   gcasm -crisc2 test.asm'
echo "═══════════════════════════════════════════════════════════════"
