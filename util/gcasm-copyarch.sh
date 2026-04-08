#!/bin/bash
# gcasm-copyarch.sh — Register a copied architecture in gcasm
#
# Usage: gcasm-copyarch.sh <dst-name> <base-isa> <src-name>
#
# Extracts the mnemonic array and cpu_t entry for <src-name> (or <base-isa>
# if <src-name> is a built-in), creates renamed copies, and appends them
# to util/gcasm/user_archs.inc.

set -euo pipefail

DST="$1"
BASE="$2"
SRC="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH_C="$SCRIPT_DIR/gcasm/arch.c"
USER_MN="$SCRIPT_DIR/gcasm/user_mnemonics.inc"
USER_CPU="$SCRIPT_DIR/gcasm/user_archs.inc"

# C identifier: replace dashes with underscores
dst_id=$(echo "$DST" | tr '-' '_')
src_id=$(echo "$SRC" | tr '-' '_')
base_id=$(echo "$BASE" | tr '-' '_')

# Already registered?
if grep -q "\"$DST\"" "$USER_CPU" 2>/dev/null; then
    echo "  $DST already registered in gcasm"
    exit 0
fi

# Find the mnemonic array source.
# If SRC is a built-in (risc1/risc2), it's in arch.c.
# If SRC is a user arch, its mnemonics are in user_mnemonics.inc.
if grep -q "mnemonic_t ${src_id}_mnemonics" "$ARCH_C" 2>/dev/null; then
    MN_SOURCE="$ARCH_C"
elif grep -q "mnemonic_t ${src_id}_mnemonics" "$USER_MN" 2>/dev/null; then
    MN_SOURCE="$USER_MN"
else
    # SRC might be a built-in referenced by base_isa name
    if grep -q "mnemonic_t ${base_id}_mnemonics" "$ARCH_C" 2>/dev/null; then
        MN_SOURCE="$ARCH_C"
        src_id="$base_id"
    else
        echo "Error: cannot find ${src_id}_mnemonics in arch.c or user_mnemonics.inc"
        exit 1
    fi
fi

# Extract mnemonic array: from "mnemonic_t NAME_mnemonics[]" to "};"
mn_block=$(sed -n "/^mnemonic_t ${src_id}_mnemonics/,/^};/p" "$MN_SOURCE")

# Extract cpu_t entry: from the line containing "SRC", "base_isa" to "},"
# For built-ins, search arch.c. For user arches, search user_archs.inc.
if grep -q "\"$SRC\", \"$BASE\"" "$ARCH_C" 2>/dev/null; then
    cpu_block=$(sed -n "/\"$SRC\", \"$BASE\"/,/},/p" "$ARCH_C")
elif grep -q "\"$SRC\", \"$BASE\"" "$USER_CPU" 2>/dev/null; then
    cpu_block=$(sed -n "/\"$SRC\", \"$BASE\"/,/},/p" "$USER_CPU")
else
    echo "Error: cannot find cpu_t entry for '$SRC' (base '$BASE')"
    exit 1
fi

# Rename mnemonic array: src_id_mnemonics -> dst_id_mnemonics
new_mn=$(echo "$mn_block" | sed "s/${src_id}_mnemonics/${dst_id}_mnemonics/g")

# Rename cpu_t entry: name, and mnemonic reference
new_cpu=$(echo "$cpu_block" \
    | sed "1s/\"$SRC\"/\"$DST\"/" \
    | sed "s/${src_id}_mnemonics/${dst_id}_mnemonics/g")

# Append mnemonics to user_mnemonics.inc, cpu_t to user_archs.inc
{ echo ""; echo "$new_mn"; } >> "$USER_MN"
{ echo ""; echo "$new_cpu"; } >> "$USER_CPU"

echo "  Registered $DST in gcasm (mnemonics: ${dst_id}_mnemonics)"
