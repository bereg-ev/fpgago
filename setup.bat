@echo off
:: setup.bat — Wrapper to run setup.ps1 without execution policy issues
:: Usage: setup.bat [install|llvm|check]
powershell -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
