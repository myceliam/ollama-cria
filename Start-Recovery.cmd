@echo off
setlocal
title ollama-cria rebuild menu
rem Bootstrap 2 of 2 (README.md, Start here): opens the rebuild menu,
rem Start-Recovery.ps1, in PowerShell 7. Arguments pass through, for example
rem Start-Recovery.cmd -Step 2 or Start-Recovery.cmd -Status.
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
  echo.
  echo   PowerShell 7 is not installed yet.
  echo   Double-click Install-PowerShell7.cmd first: bootstrap 1 of 2. Then this file again.
  echo.
  pause
  exit /b 1
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Recovery.ps1" %*
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" (
  echo.
  echo   The menu stopped with exit code %CODE%. Read the lines above, then press a key to close.
  pause >nul
)
exit /b %CODE%
