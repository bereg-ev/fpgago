#!/usr/bin/env bash
# setup.sh — Install FPGAgo project dependencies
#
# Usage:
#   ./setup.sh              Install base dependencies (enough for SDL2 games)
#   ./setup.sh base         Same as above
#   ./setup.sh sim          Base + HDL simulation (Verilator, iverilog, GTKWave)
#   ./setup.sh fpga         Sim  + FPGA synthesis  (Yosys, nextpnr, ecppack)
#   ./setup.sh full         FPGA + LLVM custom backend (CMake, Ninja, LLVM source)
#   ./setup.sh check        Check which tools are already installed
#
# Tiers build on each other:  base ⊂ sim ⊂ fpga ⊂ full

set -euo pipefail

TIER="${1:-base}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colors (disabled when piped) ────────────────────────────────────────────
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BOLD=''; RESET=''
fi

info()  { printf "${BOLD}==> %s${RESET}\n" "$*"; }
ok()    { printf "${GREEN} ✓  %s${RESET}\n" "$*"; }
warn()  { printf "${YELLOW} !  %s${RESET}\n" "$*"; }
fail()  { printf "${RED} ✗  %s${RESET}\n" "$*"; }

# ── OS detection ────────────────────────────────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Darwin)  echo "macos" ;;
        Linux)
            if   [ -f /etc/debian_version ];  then echo "debian"
            elif [ -f /etc/fedora-release ];   then echo "fedora"
            elif [ -f /etc/arch-release ];     then echo "arch"
            else echo "linux-unknown"; fi ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

OS="$(detect_os)"

# ── Tool check ──────────────────────────────────────────────────────────────
has() { command -v "$1" >/dev/null 2>&1; }

check_tool() {
    local cmd="$1" tier="$2" note="${3:-}"
    if has "$cmd"; then
        ok "$cmd  ($tier)  $(command -v "$cmd")"
    else
        fail "$cmd  ($tier)${note:+  — $note}"
    fi
}

do_check() {
    info "Checking installed tools..."
    echo ""

    printf "${BOLD}%-20s %-8s %s${RESET}\n" "TOOL" "TIER" "STATUS"
    echo "────────────────────────────────────────────"

    # base
    check_tool gcc        base
    check_tool make       base
    check_tool python3    base
    check_tool sdl2-config base "SDL2 development library"

    # sim
    check_tool verilator  sim
    check_tool iverilog   sim
    check_tool gtkwave    sim

    # fpga
    check_tool yosys      fpga
    check_tool nextpnr-ecp5 fpga
    check_tool ecppack    fpga

    # full (LLVM)
    check_tool cmake      full
    check_tool ninja      full  "or ninja-build"

    echo ""
    if [ -x "$HOME/llvm-risc2-build/bin/clang" ]; then
        ok "RISC2 Clang found at ~/llvm-risc2-build/bin/clang"
    else
        warn "RISC2 Clang not found at ~/llvm-risc2-build/bin/clang"
        warn "Build it with: ./setup.sh full"
    fi
}

# ── Package installation helpers ────────────────────────────────────────────

install_base() {
    info "Installing base dependencies (gcc, make, python3, SDL2)..."
    case "$OS" in
        macos)
            brew install gcc make python3 sdl2
            ;;
        debian)
            sudo apt-get update
            sudo apt-get install -y build-essential python3 libsdl2-dev
            ;;
        fedora)
            sudo dnf install -y gcc gcc-c++ make python3 SDL2-devel
            ;;
        arch)
            sudo pacman -S --needed gcc make python sdl2
            ;;
        windows)
            warn "Windows detected. Recommended: use WSL2 with Ubuntu, then re-run this script."
            warn "Alternatively, in MSYS2 run:"
            echo "  pacman -S mingw-w64-x86_64-gcc make python mingw-w64-x86_64-SDL2"
            ;;
        *)
            fail "Unsupported OS. Install manually: gcc, make, python3, SDL2 dev libraries."
            exit 1
            ;;
    esac
}

install_sim() {
    install_base
    echo ""
    info "Installing simulation tools (Verilator, iverilog, GTKWave)..."
    case "$OS" in
        macos)
            brew install verilator icarus-verilog
            if ! has gtkwave; then
                warn "GTKWave: 'brew install gtkwave' may not be available."
                warn "Download from: https://gtkwave.sourceforge.net/"
            fi
            ;;
        debian)
            sudo apt-get install -y verilator iverilog gtkwave
            ;;
        fedora)
            sudo dnf install -y verilator iverilog gtkwave
            ;;
        arch)
            sudo pacman -S --needed verilator iverilog gtkwave
            ;;
        windows)
            warn "For simulation tools on Windows, use OSS CAD Suite:"
            echo "  https://github.com/YosysHQ/oss-cad-suite-build/releases"
            echo "  Download, extract, and source the environment.sh script."
            ;;
    esac
}

install_fpga() {
    install_sim
    echo ""
    info "Installing FPGA synthesis tools (Yosys, nextpnr-ecp5, ecppack)..."
    case "$OS" in
        macos)
            brew install yosys nextpnr
            if ! has ecppack; then
                warn "ecppack is usually bundled with nextpnr or prjtrellis."
                brew install prjtrellis 2>/dev/null || \
                    warn "Install prjtrellis manually for ecppack."
            fi
            ;;
        debian)
            sudo apt-get install -y yosys nextpnr-ecp5 prjtrellis
            ;;
        fedora)
            sudo dnf install -y yosys nextpnr prjtrellis
            ;;
        arch)
            sudo pacman -S --needed yosys nextpnr-ecp5 prjtrellis
            ;;
        windows)
            warn "For FPGA tools on Windows, use OSS CAD Suite:"
            echo "  https://github.com/YosysHQ/oss-cad-suite-build/releases"
            ;;
    esac
}

install_full() {
    install_fpga
    echo ""
    info "Installing LLVM build prerequisites (CMake, Ninja)..."
    case "$OS" in
        macos)
            brew install cmake ninja
            ;;
        debian)
            sudo apt-get install -y cmake ninja-build
            ;;
        fedora)
            sudo dnf install -y cmake ninja-build
            ;;
        arch)
            sudo pacman -S --needed cmake ninja
            ;;
        windows)
            warn "Install CMake and Ninja via MSYS2:"
            echo "  pacman -S cmake ninja"
            ;;
    esac

    echo ""
    info "Building RISC2 LLVM/Clang backend..."
    echo ""
    echo "  This requires an LLVM source checkout (~2 GB download, ~30 min build)."
    echo ""
    echo "  Steps:"
    echo "    1. git clone --depth 1 https://github.com/llvm/llvm-project.git ~/llvm-project"
    echo "    2. bash $SCRIPT_DIR/arch/risc2/cpu/llvm-backend/setup-llvm.sh ~/llvm-project"
    echo "    3. cmake -S ~/llvm-project/llvm -B ~/llvm-risc2-build \\"
    echo "             -DLLVM_TARGETS_TO_BUILD='RISC2' \\"
    echo "             -DLLVM_ENABLE_PROJECTS='clang' \\"
    echo "             -DCMAKE_BUILD_TYPE=Release \\"
    echo "             -G Ninja"
    echo "    4. ninja -C ~/llvm-risc2-build clang llc"
    echo ""
    warn "This is not automated because it takes significant time and disk space."
    warn "Run the steps above manually when you're ready."
}

# ── Main ────────────────────────────────────────────────────────────────────

echo ""
echo "  FPGAgo Development Setup"
echo "  OS detected: $OS"
echo ""

case "$TIER" in
    base)  install_base ;;
    sim)   install_sim ;;
    fpga)  install_fpga ;;
    full)  install_full ;;
    check) do_check; exit 0 ;;
    *)
        echo "Usage: $0 [base|sim|fpga|full|check]"
        echo ""
        echo "Tiers:"
        echo "  base   gcc, make, python3, SDL2          (play games natively)"
        echo "  sim    + verilator, iverilog, gtkwave     (HDL simulation)"
        echo "  fpga   + yosys, nextpnr-ecp5, ecppack    (synthesize to FPGA)"
        echo "  full   + cmake, ninja, LLVM source        (build RISC2 C compiler)"
        echo "  check  show which tools are installed"
        exit 1
        ;;
esac

echo ""
info "Done! Verify with: ./setup.sh check"
echo ""
echo "Quick start:"
echo "  make run GAME=tic-tac-toe TARGET=sdl2"
echo ""
