@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-local-api.ps1"
set "setup_result=%errorlevel%"
pause
exit /b %setup_result%
