@echo off
setlocal
title ollama-cria rebuild: install PowerShell 7
rem Bootstrap 1 of 2 (README.md, Start here): installs PowerShell 7 with
rem winget, at the version manifests/windows-apps.json records, so the menu
rem (Start-Recovery.cmd, bootstrap 2 of 2) can run. Safe to run again.
echo.
echo   ollama-cria rebuild, bootstrap 1 of 2: PowerShell 7
echo   ===================================================
echo.
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" (
  echo   PowerShell 7 is already installed. Nothing to do.
  goto :next
)
where winget >nul 2>nul
if errorlevel 1 (
  echo   PROBLEM: winget is not available yet.
  echo   Fix:     Microsoft Store, Library, Get updates. That updates App Installer,
  echo            which brings winget. Then run this file again.
  goto :end
)
echo   Installing PowerShell 7.6.6.0 with winget. Click Yes if Windows asks.
echo.
winget install --id Microsoft.PowerShell --exact --source winget --version 7.6.6.0 --accept-package-agreements --accept-source-agreements
if not exist "%PWSH%" (
  echo.
  echo   That version did not install. Trying the newest PowerShell 7 instead.
  echo.
  winget install --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements
)
if not exist "%PWSH%" (
  echo.
  echo   PROBLEM: PowerShell 7 is still not in "%ProgramFiles%\PowerShell\7".
  echo   Fix:     download the x64 .msi from https://aka.ms/powershell-release?tag=stable
  echo            and install it. Then double-click Start-Recovery.cmd.
  goto :end
)
:next
echo.
echo   Next: double-click Start-Recovery.cmd in this folder. That is bootstrap 2 of 2: the menu.
echo   Its step 1b starts with your motherboard's drivers (AMD's chipset driver, then ASUS's),
echo   before Windows Update.
:end
echo.
pause
