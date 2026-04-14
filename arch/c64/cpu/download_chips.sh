#!/bin/bash
# download_chips.sh — Download open-source C64 chip implementations
#
# Sources:
#   VIC-II: vicii-kawari by Randy Rossi (GPL)
#   SID:    MiSTer C64 SID (GPL)
#   CIA:    MiSTer C64 6526 (GPL)
#   CPU:    6502 already in repo (PET), wrapped as 6510 here

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH_DIR="$(dirname "$SCRIPT_DIR")"
TMPDIR="$(mktemp -d)"

echo ""
echo "  ================================================================"
echo "  Commodore 64 Chip Download"
echo "  ================================================================"
echo ""

# ── VIC-II Kawari ──────────────────────────────────────────────────────
echo "  Downloading VIC-II Kawari..."
VIC_DIR="$ARCH_DIR/vic"
curl -sfL "https://github.com/randyrossi/vicii-kawari/archive/refs/heads/main.zip" -o "$TMPDIR/vicii.zip" || {
    echo "  Error: VIC-II download failed."; exit 1
}
unzip -qo "$TMPDIR/vicii.zip" -d "$TMPDIR"
# Copy core HDL files (not platform-specific)
mkdir -p "$VIC_DIR"
for f in vicii.v border.v bus_access.v colorreg.v comp_sync.v cycles.v divide.v \
         equalization.v lightpen.v lumareg.v matrix.v pixel_sequencer.v \
         raster.v registers.v serration.v sinewave.v sprites.v \
         testpattern.v videoram.v common.vh registers_no_eeprom.vh; do
    cp "$TMPDIR/vicii-kawari-main/hdl/$f" "$VIC_DIR/" 2>/dev/null || true
done
# Also copy the simulator top
cp "$TMPDIR/vicii-kawari-main/hdl/simulator/top.v" "$VIC_DIR/vic_sim_top.v" 2>/dev/null || true
echo "    VIC-II: $(ls "$VIC_DIR"/*.v "$VIC_DIR"/*.vh 2>/dev/null | wc -l | tr -d ' ') files"

# ── SID from MiSTer C64 ───────────────────────────────────────────────
echo "  Downloading SID + CIA from MiSTer C64..."
SID_DIR="$ARCH_DIR/sid"
curl -sfL "https://github.com/MiSTer-devel/C64_MiSTer/archive/refs/heads/master.zip" -o "$TMPDIR/c64mister.zip" || {
    echo "  Error: MiSTer C64 download failed."; exit 1
}
unzip -qo "$TMPDIR/c64mister.zip" -d "$TMPDIR"
# SID files
mkdir -p "$SID_DIR"
cp "$TMPDIR/C64_MiSTer-master/rtl/sid/"*.sv "$SID_DIR/" 2>/dev/null || true
cp "$TMPDIR/C64_MiSTer-master/rtl/sid/"*.v "$SID_DIR/" 2>/dev/null || true
echo "    SID: $(ls "$SID_DIR"/*.sv "$SID_DIR"/*.v 2>/dev/null | wc -l | tr -d ' ') files"

# CIA
cp "$TMPDIR/C64_MiSTer-master/rtl/mos6526.v" "$ARCH_DIR/cpu/" 2>/dev/null || true
echo "    CIA: mos6526.v"

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "  Done! C64 chip sources installed:"
echo "    VIC-II: arch/c64/vic/"
echo "    SID:    arch/c64/sid/"
echo "    CIA:    arch/c64/cpu/mos6526.v"
echo "    CPU:    6502 from arch/pet/cpu/ (wrapped as 6510)"
echo ""
