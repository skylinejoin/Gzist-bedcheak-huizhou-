@echo off
cd /d "%~dp0"
set GZIST_ALLOW_VISIBLE=1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "daily-signin2.ps1"
echo.
pause
