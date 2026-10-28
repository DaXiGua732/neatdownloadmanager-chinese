@echo off
chcp 65001 >nul 2>&1
setlocal
set "PS_EXE=pwsh"
where pwsh >nul 2>&1 || set "PS_EXE=powershell"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0menu.ps1"
if errorlevel 1 (
  echo.
  echo Failed to start. Please make sure PowerShell is available.
  pause
)
endlocal
