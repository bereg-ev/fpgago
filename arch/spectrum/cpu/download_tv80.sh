#!/bin/bash
# download_tv80.sh — Download TV80 Z80 CPU core (LGPL licensed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if already downloaded
if [ -f "$SCRIPT_DIR/tv80s.v" ]; then
    echo "  TV80 Z80 core already installed at $SCRIPT_DIR/"
    exit 0
fi

echo ""
echo "  ================================================================"
echo "  TV80 Z80 CPU Core Download"
echo "  ================================================================"
echo ""
echo "  TV80 is an open-source Z80 CPU implementation in Verilog"
echo "  by Guy Hutchison, licensed under LGPL."
echo "  Source: https://github.com/hutch31/tv80"
echo ""

TMPZIP="$(mktemp)"
echo "  Downloading..."
curl -sfL "https://github.com/hutch31/tv80/archive/refs/heads/master.zip" -o "$TMPZIP" || {
    echo "  Error: download failed."
    rm -f "$TMPZIP"
    exit 1
}

echo "  Extracting..."
unzip -qo "$TMPZIP" \
    "tv80-master/rtl/core/tv80_alu.v" \
    "tv80-master/rtl/core/tv80_core.v" \
    "tv80-master/rtl/core/tv80_mcode.v" \
    "tv80-master/rtl/core/tv80_reg.v" \
    "tv80-master/rtl/core/tv80s.v" \
    -d "$SCRIPT_DIR"

mv "$SCRIPT_DIR/tv80-master/rtl/core/"*.v "$SCRIPT_DIR/"
rm -rf "$SCRIPT_DIR/tv80-master"
rm -f "$TMPZIP"

echo "  Installed to $SCRIPT_DIR/"
ls -1 "$SCRIPT_DIR/"*.v
echo ""
echo "  Done!"
echo ""
