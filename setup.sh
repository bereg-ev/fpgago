#!/usr/bin/env bash
# setup.sh — Install FPGAgo project dependencies
#
# Usage:
#   ./setup.sh          Install all dependencies and download LLVM source
#   ./setup.sh llvm     Build the RISC2 LLVM/Clang backend (needed for C games)
#   ./setup.sh check    Check which tools are already installed

set -euo pipefail

CMD="${1:-install}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LLVM_SRC="$SCRIPT_DIR/llvm-project"
LLVM_BUILD="$SCRIPT_DIR/llvm-risc2-build"

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
    local cmd="$1" note="${2:-}"
    if has "$cmd"; then
        ok "$cmd  $(command -v "$cmd")"
    else
        fail "$cmd${note:+  — $note}"
    fi
}

do_check() {
    info "Checking installed tools..."
    echo ""

    printf "${BOLD}%-20s %s${RESET}\n" "TOOL" "STATUS"
    echo "────────────────────────────────────────────"

    check_tool gcc
    check_tool make
    check_tool python3
    check_tool sdl2-config    "SDL2 development library"
    check_tool verilator
    check_tool iverilog
    check_tool gtkwave
    check_tool yosys
    check_tool nextpnr-ecp5
    check_tool ecppack
    check_tool cmake
    check_tool ninja          "or ninja-build"

    echo ""
    info "LLVM source"
    if [ -f "$LLVM_SRC/llvm/CMakeLists.txt" ]; then
        ok "LLVM source found at $LLVM_SRC"
    else
        fail "LLVM source not found (run ./setup.sh to download)"
    fi

    info "RISC2 Clang"
    if [ -f "$SCRIPT_DIR/.config.mk" ]; then
        local clang_path
        clang_path=$(grep '^CLANG' "$SCRIPT_DIR/.config.mk" | sed 's/.*= *//')
        if [ -x "$clang_path" ]; then
            ok "RISC2 Clang at $clang_path"
        else
            fail "RISC2 Clang configured in .config.mk but not found at $clang_path"
        fi
    elif [ -x "$LLVM_BUILD/bin/clang" ]; then
        ok "RISC2 Clang at $LLVM_BUILD/bin/clang (no .config.mk yet — run ./setup.sh llvm)"
    else
        warn "RISC2 Clang not built (run ./setup.sh llvm — only needed for C games)"
    fi
}

# ── Install all system dependencies + download LLVM source ─────────────────

do_install() {
    info "Installing system packages..."
    case "$OS" in
        macos)
            brew install gcc make python3 sdl2 \
                         verilator icarus-verilog \
                         yosys nextpnr prjtrellis \
                         cmake ninja
            if ! has gtkwave; then
                warn "GTKWave: 'brew install gtkwave' may not be available."
                warn "Download from: https://gtkwave.sourceforge.net/"
            fi
            ;;
        debian)
            sudo apt-get update
            sudo apt-get install -y \
                build-essential python3 libsdl2-dev \
                verilator iverilog gtkwave \
                yosys nextpnr-ecp5 prjtrellis \
                cmake ninja-build
            ;;
        fedora)
            sudo dnf install -y \
                gcc gcc-c++ make python3 SDL2-devel \
                verilator iverilog gtkwave \
                yosys nextpnr prjtrellis \
                cmake ninja-build
            ;;
        arch)
            sudo pacman -S --needed \
                gcc make python sdl2 \
                verilator iverilog gtkwave \
                yosys nextpnr-ecp5 prjtrellis \
                cmake ninja
            ;;
        windows)
            warn "Windows detected. Recommended: use WSL2 with Ubuntu, then re-run this script."
            warn "Alternatively, in MSYS2:"
            echo "  pacman -S mingw-w64-x86_64-gcc make python mingw-w64-x86_64-SDL2"
            warn "For FPGA/simulation tools, use OSS CAD Suite:"
            echo "  https://github.com/YosysHQ/oss-cad-suite-build/releases"
            ;;
        *)
            fail "Unsupported OS. Install manually: gcc, make, python3, SDL2, verilator,"
            fail "  iverilog, gtkwave, yosys, nextpnr-ecp5, ecppack, cmake, ninja"
            exit 1
            ;;
    esac

    echo ""
    info "Downloading LLVM source (shallow clone, ~500 MB)..."
    if [ -f "$LLVM_SRC/llvm/CMakeLists.txt" ]; then
        ok "LLVM source already present at $LLVM_SRC"
    else
        git clone --depth 1 https://github.com/llvm/llvm-project.git "$LLVM_SRC"
        ok "LLVM source cloned to $LLVM_SRC"
    fi

    info "Patching LLVM with RISC2 backend..."
    bash "$SCRIPT_DIR/arch/risc2/cpu/llvm-backend/setup-llvm.sh" "$LLVM_SRC"

    echo ""
    info "Done! Verify with: ./setup.sh check"
    echo ""
    echo "Quick start (assembly games — no LLVM build needed):"
    echo "  make run GAME=char-snake ARCH=risc1 TARGET=verilator"
    echo ""
    echo "For C games (gomoku, chess, labyrinth, ...), build LLVM first:"
    echo "  ./setup.sh llvm"
    echo ""
}

# ── Build LLVM with RISC2 backend ──────────────────────────────────────────

do_llvm() {
    if [ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]; then
        fail "LLVM source not found at $LLVM_SRC"
        fail "Run ./setup.sh first to download it."
        exit 1
    fi

    info "Building RISC2 LLVM/Clang (this will take a while)..."
    cmake -S "$LLVM_SRC/llvm" -B "$LLVM_BUILD" \
          -DLLVM_TARGETS_TO_BUILD="RISC2" \
          -DLLVM_ENABLE_PROJECTS="clang" \
          -DCMAKE_BUILD_TYPE=Release \
          -G Ninja

    ninja -C "$LLVM_BUILD" clang llc

    # Write config so the build system finds clang automatically
    cat > "$SCRIPT_DIR/.config.mk" <<EOF
# Generated by setup.sh llvm — do not edit, do not commit
CLANG = $LLVM_BUILD/bin/clang
EOF

    echo ""
    ok "RISC2 Clang built at $LLVM_BUILD/bin/clang"
    ok "Config written to .config.mk"
    echo ""
    echo "Test it:"
    echo "  make run GAME=tic-tac-toe TARGET=sdl2"
}

# ── Main ────────────────────────────────────────────────────────────────────

echo ""
echo "  FPGAgo Development Setup"
echo "  OS detected: $OS"
echo ""

case "$CMD" in
    install) do_install ;;
    llvm)    do_llvm ;;
    check)   do_check ;;
    *)
        echo "Usage: $0 [install|llvm|check]"
        echo ""
        echo "  install   Install all dependencies and download LLVM source (default)"
        echo "  llvm      Build the RISC2 LLVM/Clang backend (needed for C games)"
        echo "  check     Show which tools are installed"
        exit 1
        ;;
esac
