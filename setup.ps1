# setup.ps1 — Install FPGAgo project dependencies on Windows
#
# Usage (run from PowerShell):
#   .\setup.ps1              Install all dependencies and download LLVM source
#   .\setup.ps1 llvm         Build the RISC2 LLVM/Clang backend (needed for C games)
#   .\setup.ps1 check        Check which tools are already installed
#
# Prerequisites: PowerShell 5.1+ and internet access.
# This script will install MSYS2 (build tools) and OSS CAD Suite (FPGA tools).

param(
    [Parameter(Position=0)]
    [ValidateSet("install", "llvm", "check", "help")]
    [string]$Command = "install"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LlvmSrc = Join-Path $ScriptDir "llvm-project"
$LlvmBuild = Join-Path $ScriptDir "llvm-risc2-build"
$OssCadDir = Join-Path $ScriptDir "oss-cad-suite"
$Msys2Dir = "C:\msys64"

# ── Helpers ─────────────────────────────────────────────────────────────────

function Write-Info  { param($msg) Write-Host "==> $msg" -ForegroundColor White }
function Write-Ok    { param($msg) Write-Host " +  $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host " !  $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host " x  $msg" -ForegroundColor Red }

function Test-Command {
    param($Name)
    $null = Get-Command $Name -ErrorAction SilentlyContinue
    return $?
}

function Get-Msys2Bash {
    # Find MSYS2 bash in common locations
    $candidates = @(
        (Join-Path $Msys2Dir "usr\bin\bash.exe"),
        "C:\tools\msys64\usr\bin\bash.exe",
        "$env:USERPROFILE\msys64\usr\bin\bash.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Invoke-Msys2 {
    param([string]$Cmd)
    $bash = Get-Msys2Bash
    if (-not $bash) {
        Write-Fail "MSYS2 bash not found"
        exit 1
    }
    # Run in UCRT64 environment
    $env:MSYSTEM = "UCRT64"
    & $bash -lc $Cmd
    if ($LASTEXITCODE -ne 0) {
        throw "MSYS2 command failed: $Cmd"
    }
}

# ── Check ───────────────────────────────────────────────────────────────────

function Invoke-Check {
    # Build a combined PATH with MSYS2 and OSS CAD Suite for detection
    $extraPaths = @()
    if (Test-Path (Join-Path $Msys2Dir "ucrt64\bin")) {
        $extraPaths += Join-Path $Msys2Dir "ucrt64\bin"
        $extraPaths += Join-Path $Msys2Dir "usr\bin"
    }
    if (Test-Path (Join-Path $OssCadDir "bin")) {
        $extraPaths += Join-Path $OssCadDir "bin"
    }
    $savedPath = $env:PATH
    if ($extraPaths.Count -gt 0) {
        $env:PATH = ($extraPaths -join ";") + ";$env:PATH"
    }

    Write-Info "Checking installed tools..."
    Write-Host ""
    Write-Host ("{0,-20} {1}" -f "TOOL", "STATUS") -ForegroundColor White
    Write-Host ("=" * 50)

    $tools = @(
        @("gcc",           ""),
        @("make",          ""),
        @("python3",       "or python"),
        @("sdl2-config",   "SDL2 (via MSYS2 pkg-config)"),
        @("verilator",     ""),
        @("iverilog",      ""),
        @("gtkwave",       ""),
        @("yosys",         ""),
        @("nextpnr-ecp5",  ""),
        @("ecppack",       ""),
        @("cmake",         ""),
        @("ninja",         "")
    )
    foreach ($t in $tools) {
        $cmd = $t[0]; $note = $t[1]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            Write-Ok "$cmd  $($found.Source)"
        } else {
            $suffix = if ($note) { " -- $note" } else { "" }
            Write-Fail "$cmd$suffix"
        }
    }

    Write-Host ""

    Write-Info "MSYS2"
    if (Get-Msys2Bash) {
        Write-Ok "Found at $(Split-Path -Parent (Split-Path -Parent (Get-Msys2Bash)))"
    } else {
        Write-Fail "Not found (run setup.bat to install)"
    }

    Write-Info "OSS CAD Suite"
    if (Test-Path (Join-Path $OssCadDir "bin\nextpnr-ecp5.exe")) {
        Write-Ok "Installed at $OssCadDir"
    } else {
        Write-Fail "Not found (run setup.bat to install)"
    }

    Write-Info "LLVM source"
    if (Test-Path (Join-Path $LlvmSrc "llvm\CMakeLists.txt")) {
        Write-Ok "Found at $LlvmSrc"
    } else {
        Write-Fail "Not found (run setup.bat to download)"
    }

    Write-Info "RISC2 Clang"
    $clangPath = ""
    $configMk = Join-Path $ScriptDir ".config.mk"
    if (Test-Path $configMk) {
        $clangLine = Select-String -Path $configMk -Pattern "^CLANG" | Select-Object -First 1
        if ($clangLine) {
            $clangPath = ($clangLine -replace '.*=\s*','').ToString().Trim()
        }
    }
    $clangExe = Join-Path $LlvmBuild "bin\clang.exe"
    if ($clangPath -and (Test-Path $clangPath)) {
        Write-Ok "RISC2 Clang at $clangPath"
    } elseif (Test-Path $clangExe) {
        Write-Ok "RISC2 Clang at $clangExe"
    } else {
        Write-Warn "RISC2 Clang not built (run setup.bat llvm -- only needed for C games)"
    }

    $env:PATH = $savedPath
}

# ── Install MSYS2 ──────────────────────────────────────────────────────────

function Install-Msys2 {
    if (Get-Msys2Bash) {
        Write-Ok "MSYS2 already installed"
        return
    }

    Write-Info "Installing MSYS2..."

    # Try winget first
    if (Test-Command "winget") {
        Write-Info "Installing via winget..."
        winget install --id MSYS2.MSYS2 --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0 -and (Get-Msys2Bash)) {
            Write-Ok "MSYS2 installed via winget"
            return
        }
    }

    # Fall back to direct download
    Write-Info "Downloading MSYS2 installer..."
    $installerUrl = "https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe"
    $installer = Join-Path $env:TEMP "msys2-installer.exe"
    Invoke-WebRequest -Uri $installerUrl -OutFile $installer -UseBasicParsing
    Write-Info "Extracting MSYS2 to C:\..."
    & $installer -y -oC:\
    Remove-Item $installer -ErrorAction SilentlyContinue

    if (-not (Get-Msys2Bash)) {
        Write-Fail "MSYS2 installation failed. Install manually from https://www.msys2.org/"
        exit 1
    }
    Write-Ok "MSYS2 installed to $Msys2Dir"

    # Initialize package database
    Write-Info "Initializing MSYS2 package database..."
    Invoke-Msys2 "pacman -Syu --noconfirm"
}

function Install-Msys2Packages {
    Write-Info "Installing build tools via MSYS2 (UCRT64)..."
    $packages = @(
        "mingw-w64-ucrt-x86_64-gcc",
        "mingw-w64-ucrt-x86_64-make",
        "mingw-w64-ucrt-x86_64-python",
        "mingw-w64-ucrt-x86_64-SDL2",
        "mingw-w64-ucrt-x86_64-verilator",
        "mingw-w64-ucrt-x86_64-cmake",
        "mingw-w64-ucrt-x86_64-ninja",
        "make",
        "git",
        "patch"
    )
    $pkgList = $packages -join " "
    Invoke-Msys2 "pacman -S --noconfirm --needed $pkgList"
    Write-Ok "MSYS2 packages installed"
}

# ── Install OSS CAD Suite ──────────────────────────────────────────────────

function Install-OssCadSuite {
    if (Test-Path (Join-Path $OssCadDir "bin\nextpnr-ecp5.exe")) {
        Write-Ok "OSS CAD Suite already installed at $OssCadDir"
        return
    }

    Write-Info "Installing OSS CAD Suite (yosys, nextpnr-ecp5, ecppack, iverilog, gtkwave)..."

    # Get the latest Windows x64 release URL
    Write-Info "Fetching latest release info..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest" -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match "windows-x64.*\.exe$" } | Select-Object -First 1

    if (-not $asset) {
        Write-Fail "Could not find OSS CAD Suite Windows release"
        Write-Warn "Download manually from: https://github.com/YosysHQ/oss-cad-suite-build/releases"
        return
    }

    $exePath = Join-Path $env:TEMP $asset.name
    Write-Info "Downloading $($asset.browser_download_url) ..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exePath -UseBasicParsing

    Write-Info "Extracting to $OssCadDir ..."
    # The .exe is a self-extracting 7z archive
    & $exePath -y -o"$ScriptDir"
    Remove-Item $exePath -ErrorAction SilentlyContinue

    # Handle possible directory name mismatch
    if (-not (Test-Path $OssCadDir)) {
        $extracted = Get-ChildItem -Path $ScriptDir -Directory -Filter "oss-cad-suite*" | Select-Object -First 1
        if ($extracted -and $extracted.FullName -ne $OssCadDir) {
            Rename-Item $extracted.FullName $OssCadDir
        }
    }

    if (Test-Path (Join-Path $OssCadDir "bin\nextpnr-ecp5.exe")) {
        Write-Ok "OSS CAD Suite installed to $OssCadDir"
    } else {
        Write-Fail "OSS CAD Suite extraction may have failed. Check $ScriptDir for extracted files."
    }
}

# ── Write .config.mk ──────────────────────────────────────────────────────

function Write-ConfigMk {
    $lines = @("# Generated by setup.ps1 -- do not edit, do not commit")

    # MSYS2 UCRT64 bin path (for make to find gcc, etc.)
    $ucrt64Bin = Join-Path $Msys2Dir "ucrt64\bin"
    if (Test-Path $ucrt64Bin) {
        $msys2Bin = Join-Path $Msys2Dir "usr\bin"
        $lines += "export PATH := $($ucrt64Bin -replace '\\','/'):`$(PATH)"
        $lines += "export PATH := $($msys2Bin -replace '\\','/'):`$(PATH)"
    }

    $ossCadBin = Join-Path $OssCadDir "bin"
    if (Test-Path $ossCadBin) {
        $lines += "export PATH := $($ossCadBin -replace '\\','/'):`$(PATH)"
    }

    $clangExe = Join-Path $LlvmBuild "bin\clang.exe"
    if (Test-Path $clangExe) {
        $lines += "CLANG = $($clangExe -replace '\\','/')"
    }

    $configPath = Join-Path $ScriptDir ".config.mk"
    $lines -join "`n" | Set-Content -Path $configPath -NoNewline -Encoding UTF8
    Write-Ok "Config written to .config.mk"
}

# ── Install (main) ─────────────────────────────────────────────────────────

function Invoke-Install {
    Install-Msys2
    Install-Msys2Packages
    Write-Host ""
    Install-OssCadSuite

    Write-Host ""
    Write-Info "Downloading LLVM source (shallow clone, ~500 MB)..."
    if (Test-Path (Join-Path $LlvmSrc "llvm\CMakeLists.txt")) {
        Write-Ok "LLVM source already present at $LlvmSrc"
    } else {
        git clone --depth 1 https://github.com/llvm/llvm-project.git $LlvmSrc
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
        Write-Ok "LLVM source cloned to $LlvmSrc"
    }

    Write-Info "Patching LLVM with RISC2 backend..."
    $setupScript = Join-Path $ScriptDir "arch\risc2\cpu\llvm-backend\setup-llvm.sh"
    Invoke-Msys2 "bash '$($setupScript -replace '\\','/')' '$($LlvmSrc -replace '\\','/')'"

    Write-Host ""
    Write-ConfigMk

    Write-Host ""
    Write-Info "Done! Verify with: setup.bat check"
    Write-Host ""
    Write-Host "Quick start (assembly games -- no LLVM build needed):"
    Write-Host "  .\make run GAME=char-snake ARCH=risc1 TARGET=verilator"
    Write-Host ""
    Write-Host "For C games (gomoku, chess, labyrinth, ...), build LLVM first:"
    Write-Host "  setup.bat llvm"
    Write-Host ""
}

# ── Build LLVM ─────────────────────────────────────────────────────────────

function Invoke-LlvmBuild {
    if (-not (Test-Path (Join-Path $LlvmSrc "llvm\CMakeLists.txt"))) {
        Write-Fail "LLVM source not found at $LlvmSrc"
        Write-Fail "Run setup.bat first to download it."
        exit 1
    }

    Write-Info "Building RISC2 LLVM/Clang (this will take a while)..."

    # Use MSYS2 cmake and ninja
    $ucrt64Bin = Join-Path $Msys2Dir "ucrt64\bin"
    $env:PATH = "$ucrt64Bin;$env:PATH"

    $cmakeArgs = @(
        "-S", (Join-Path $LlvmSrc "llvm"),
        "-B", $LlvmBuild,
        "-DLLVM_TARGETS_TO_BUILD=RISC2",
        "-DLLVM_ENABLE_PROJECTS=clang",
        "-DCMAKE_BUILD_TYPE=Release",
        "-G", "Ninja"
    )
    cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

    ninja -C $LlvmBuild clang llc
    if ($LASTEXITCODE -ne 0) { throw "ninja build failed" }

    Write-ConfigMk

    Write-Host ""
    Write-Ok "RISC2 Clang built at $(Join-Path $LlvmBuild 'bin\clang.exe')"
    Write-Host ""
    Write-Host "Test it:"
    Write-Host "  .\make run GAME=tic-tac-toe ARCH=risc2 TARGET=verilator"
}

# ── Main ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  FPGAgo Development Setup (Windows)"
Write-Host ""

switch ($Command) {
    "install" { Invoke-Install }
    "llvm"    { Invoke-LlvmBuild }
    "check"   { Invoke-Check }
    "help" {
        Write-Host "Usage: setup.bat [install|llvm|check]"
        Write-Host ""
        Write-Host "  install   Install all dependencies and download LLVM source (default)"
        Write-Host "  llvm      Build the RISC2 LLVM/Clang backend (needed for C games)"
        Write-Host "  check     Show which tools are installed"
    }
}
