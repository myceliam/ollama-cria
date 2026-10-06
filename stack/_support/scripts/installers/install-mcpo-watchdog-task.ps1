# ============================================================
#  install-mcpo-watchdog-task.ps1
#  Registers mcpo-watchdog.ps1 to run every 5 minutes.
#
#  Run ONCE in an *elevated* PowerShell (Run as Administrator) so the
#  task can drive Docker. Mirrors install-startup-task.ps1 conventions.
#
#  Remove later:
#    Unregister-ScheduledTask -TaskName 'OWUI-mcpo-Watchdog' -Confirm:$false
# ============================================================
$ErrorActionPreference = 'Stop'

$taskName = 'OWUI-mcpo-Watchdog'
$script   = 'E:\ai\ollama\mcpo-watchdog.ps1'

if (-not (Test-Path $script)) { Write-Error "Not found: $script"; exit 1 }

# Run under PowerShell 7 (pwsh) — the watchdog uses -SkipHttpErrorCheck,
# which does NOT exist in Windows PowerShell 5.1. You have pwsh 7.6.
$shell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $shell) { Write-Error 'pwsh.exe not found on PATH. Install PowerShell 7 or edit this script to handle 5.1.'; exit 1 }

# Route through run-hidden.vbs rather than calling pwsh directly.
#
# Why: pwsh.exe is a CONSOLE application. Task Scheduler allocates a conhost.exe
# before PowerShell ever parses -WindowStyle Hidden, so a black window flashes on
# every tick. Confirmed 2026-08-01 by watching process creation - each run made a
# pwsh.exe parented to svchost.exe with its own conhost.exe alongside. LogonType
# is irrelevant; an Interactive task did it too.
#
# wscript.exe is a WINDOWS-subsystem binary, so WshShell.Run(cmd, 0, False)
# starts pwsh hidden from the outset and no console is ever created.
#
# Trade-off: the shim returns immediately, so this task's Last Result is always
# 0. mcpo-watchdog.log is the real health signal.
$shim = 'E:\ai\ollama\run-hidden.vbs'
if (Test-Path $shim) {
    $wscript = Join-Path ([Environment]::GetFolderPath('System')) 'wscript.exe'
    $action  = New-ScheduledTaskAction -Execute $wscript -Argument "`"$shim`" `"$script`""
} else {
    Write-Warning "run-hidden.vbs missing at $shim - falling back to direct pwsh (console will flash every 5 min)."
    $action = New-ScheduledTaskAction -Execute $shell `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
}

# Repeat every 5 minutes. Anchor a one-off trigger to "now" with a 5-min
# repetition interval for ~10 years (reliable across Windows builds;
# [TimeSpan]::MaxValue throws on some systems).
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew    # a run waiting out the ~210s recovery blocks the next tick

# Run as the current user with highest privileges (needed for Docker).
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description 'Auto-heals a wedged mcpo session (500 "MCP session is not available") by restarting mcpo-core. Probes every 5 min.' | Out-Null

Write-Host "[ok] Scheduled task '$taskName' registered (every 5 min)." -ForegroundColor Green
Write-Host "     Test it now:  Start-ScheduledTask -TaskName '$taskName'" -ForegroundColor DarkGray
Write-Host "     Watch log:    Get-Content E:\ai\ollama\logs\mcpo-watchdog.log -Tail 30 -Wait" -ForegroundColor DarkGray
Write-Host "     Remove later: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false" -ForegroundColor DarkGray

# ---- Alternative: plain schtasks (rock-solid, any context) ----
#  schtasks /Create /TN "OWUI-mcpo-Watchdog" /SC MINUTE /MO 5 /F ^
#    /TR "pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File E:\ai\ollama\mcpo-watchdog.ps1"
