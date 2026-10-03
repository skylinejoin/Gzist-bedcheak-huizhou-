@echo off
cd /d "%~dp0"
echo [Stop ALL scheduled tasks of this project]
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "stop-all-tasks.ps1"
echo.
pause
