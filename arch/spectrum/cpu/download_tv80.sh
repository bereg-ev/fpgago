#!/bin/bash
# download_tv80.sh — Download TV80 Z80 CPU core (LGPL licensed)
#
# TV80 by Guy Hutchison is a well-tested, synthesizable Z80 in Verilog.
# https://github.com/hutch31/tv80

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TV80_URL="https://github.com/hutch31/tv80/archive/refs/heads/master.zip"
TMPZIP="$(mktemp)"

echo ""
echo "  ================================================================"
echo "  TV80 Z80 CPU Core Download"
echo "  ================================================================"
echo ""
echo "  TV80 is an open-source Z80 CPU implementation in Verilog"
echo "  by Guy Hutchison, licensed under LGPL."
echo ""
echo "  Source: https://github.com/hutch31/tv80"
echo ""

echo "  Downloading..."
curl -sfL "$TV80_URL" -o "$TMPZIP" || {
    echo "  Error: download failed."
    rm -f "$TMPZIP"
    exit 1
}

echo "  Extracting..."
# Extract only the RTL source files we need
unzip -qo "$TMPZIP" \
    "tv80-master/rtl/core/tv80_alu.v" \
    "tv80-master/rtl/core/tv80_core.v" \
    "tv80-master/rtl/core/tv80_mcode.v" \
    "tv80-master/rtl/core/tv80_reg.v" \
    "tv80-master/rtl/core/tv80s.v" \
    -d "$SCRIPT_DIR"

# Move files to cpu/ directory
mv "$SCRIPT_DIR/tv80-master/rtl/core/"*.v "$SCRIPT_DIR/"
rm -rf "$SCRIPT_DIR/tv80-master"
rm -f "$TMPZIP"

echo "  Installed to $SCRIPT_DIR/"
ls -1 "$SCRIPT_DIR/"*.v
echo ""
echo "  Done!"
echo ""
