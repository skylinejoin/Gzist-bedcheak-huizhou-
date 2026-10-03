@echo off
cd /d "%~dp0"
echo [HOLIDAY MODE: disable automatic sign-in]
echo Leaving school? This stops the daily task so no false location check-in is recorded.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "holiday-mode.ps1" -Off
echo.
pause
