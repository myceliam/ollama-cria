# ============================================================
#  install-startup-task.ps1  —  register start-stack.ps1 to run at logon
#
#  Run this ONCE, in an *elevated* PowerShell (Run as Administrator).
#  It creates a Scheduled Task that:
#    - fires ~1 min after you log in (lets Windows/Docker begin booting)
#    - runs start-stack.ps1, which then OWNS the wait for Docker (~6 min)
#    - has a small retry safety-net ONLY for hard failures
#
#  The design principle: the SCRIPT waits for Docker, not the scheduler.
#  Retries here are a belt-and-suspenders fallback, not the main mechanism.
# ============================================================
$ErrorActionPreference = 'Stop'

$taskName = 'OWUI-Stack-Startup'
$script   = 'E:\ai\ollama\start-stack.ps1'

if (-not (Test-Path $script)) { Write-Error "Not found: $script"; exit 1 }

# Action: run the startup script, bypassing execution policy, no visible window
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

# Trigger: at logon for the current user, delayed 1 minute
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = 'PT1M'   # ISO-8601: 1 minute

# Settings: allow on battery, don't auto-kill, retry 3x every 2 min if it
# exits non-zero (i.e. Docker truly never came up within the script's window)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 2)

# Run as the current user, in their interactive session (so it can reach
# the Ollama app + Docker Desktop GUI). Highest privileges for Docker.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description 'Brings the OpenWebUI/Ollama stack online at logon (waits for Docker, starts Ollama, docker compose up -d --build).' | Out-Null

Write-Host "[ok] Scheduled task '$taskName' registered." -ForegroundColor Green
Write-Host "     Test it now:  Start-ScheduledTask -TaskName '$taskName'" -ForegroundColor DarkGray
Write-Host "     Watch logs:   Get-Content E:\ai\ollama\logs\start-stack-*.log -Tail 40 -Wait" -ForegroundColor DarkGray
Write-Host "     Remove later: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false" -ForegroundColor DarkGray
