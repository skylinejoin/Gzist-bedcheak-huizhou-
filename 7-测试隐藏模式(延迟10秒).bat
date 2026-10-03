@echo off
cd /d "%~dp0"
echo [Hidden-mode test: 10s delay, then run sign-in flow]
echo Switch to your game / fullscreen video NOW and watch for interruption.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "test-hidden.ps1"
echo.
pause
