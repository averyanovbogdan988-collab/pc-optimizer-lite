@echo off
chcp 65001 >nul
title Wi-Fi Doctor - pc-optimizer-lite

rem Nuzhny prava administratora - inache perezapuskaem sebya s UAC.
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath %~f0 -Verb RunAs"
    exit /b
)

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Wifi-Doctor.ps1" -Menu

echo.
pause
