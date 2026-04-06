@echo off
:: make.bat — Run GNU make via MSYS2 UCRT64 environment
:: Usage: make.bat [targets...] (same syntax as make)
set "MSYSTEM=UCRT64"
set "PATH=C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%"
make %*
