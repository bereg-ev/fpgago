@echo off
:: make.bat — Run GNU make via MSYS2 UCRT64 environment
:: Usage: make.bat [targets...] (same syntax as make)
set "MSYSTEM=UCRT64"
C:\msys64\usr\bin\bash.exe -lc "cd '%cd:\=/%' && make %*"
