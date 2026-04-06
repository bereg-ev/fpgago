@echo off
:: make.bat — Run GNU make via MSYS2 UCRT64 environment
:: Usage: make.bat [targets...] (same syntax as make)
C:\msys64\usr\bin\bash.exe -lc "cd '%cd:\=/%' && make %*"
