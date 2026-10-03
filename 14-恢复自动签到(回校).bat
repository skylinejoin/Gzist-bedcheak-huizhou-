@echo OFF
cd /d "%~dp0"
echo [RESUME: re-enable automatic sign-in]
echo Make sure you are back in the dorm before enabling this.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "holiday-mode.ps1" -On
echo.
pause
