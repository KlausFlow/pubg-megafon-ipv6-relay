@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

fltmc >nul 2>&1 || (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PUBG-IPv6-Relay-Cleanup.ps1" -RelayPid 0 -Root "%~dp0" -StopRelay

echo Relay stopped and PUBG hosts entries removed.
pause
