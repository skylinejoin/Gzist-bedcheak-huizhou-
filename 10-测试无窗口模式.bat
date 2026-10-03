@echo off
cd /d "%~dp0"
echo [Test headless / no-window mode - NO window will appear]
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "_ov\headless-probe.ps1"
echo.
pause
