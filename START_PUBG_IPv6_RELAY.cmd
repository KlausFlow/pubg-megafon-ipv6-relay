@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

fltmc >nul 2>&1 || (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

taskkill /F /IM winws.exe >nul 2>&1
title PUBG MegaFon Russian-first hybrid v12 - CLOSE WINDOW TO STOP AND CLEAN
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PUBG-IPv6-Relay.ps1"

echo.
echo Relay stopped. Automatic cleanup is running.
pause
