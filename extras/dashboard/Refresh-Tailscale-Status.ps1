# ============================================================================
#  Refresh-Tailscale-Status.ps1
#
#  WHY THIS EXISTS
#  ---------------
#  The dashboard container wants `tailscale status --json` so it can trust the
#  Tailscale daemon's own view of which peers are up, instead of guessing from
#  ICMP. On a LINUX host that works via the bind-mounted socket:
#      /var/run/tailscale/tailscaled.sock
#  On WINDOWS it cannot: tailscaled listens on a named pipe
#      \\.\pipe\ProtectedPrefix\Administrators\Tailscale\tailscaled
#  Docker Desktop cannot map a named pipe onto a Linux socket path, so the
#  compose mount silently produces an empty DIRECTORY and every
#  `tailscale status` call inside the container exits 1.
#
#  Result before this fix: the dashboard was ping-only, and any single dropped
#  ICMP packet showed a peer as Offline. Sleepy phones flapped constantly.
#
#  THIS SCRIPT writes the daemon's JSON into the container's mounted data dir.
#  monitor.py reads it as a fallback whenever the socket is unavailable.
#
#  INSTALL (run once, elevated):
#      pwsh -File .\Refresh-Tailscale-Status.ps1 -Install
#
#  Runs every minute; monitor.py treats the file as stale after 180s.
# ============================================================================
[CmdletBinding()]
param(
    [string]$OutFile  = 'E:\ai\ag-startuip\cline-dashboard\data\tailscale-status.json',
    [string]$TaskName = 'Tailscale-Status-Feed',
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$tailscale = 'C:\Program Files\Tailscale\tailscale.exe'

# ---------------------------------------------------------------------------
# -Install: register the scheduled task, then exit
# ---------------------------------------------------------------------------
if ($Install) {
    $me = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $me)

    # Every 1 minute, indefinitely, starting at boot and at logon.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger @($trigger, $repeat) -Settings $settings `
        -RunLevel Highest -Force | Out-Null

    Write-Host "[ok] Scheduled task '$TaskName' registered (every 1 min)." -ForegroundColor Green
    Write-Host "     Writes: $OutFile" -ForegroundColor DarkGray
    Start-ScheduledTask -TaskName $TaskName
    return
}

# ---------------------------------------------------------------------------
# Normal run: capture status -> temp -> atomic move
# ---------------------------------------------------------------------------
if (-not (Test-Path $tailscale)) {
    Write-Error "tailscale.exe not found at $tailscale"
    exit 1
}

$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$json = & $tailscale status --json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $json) {
    Write-Error "tailscale status failed (exit $LASTEXITCODE)"
    exit 1
}

# Validate before publishing - never leave a truncated file for the container.
try { $null = $json | ConvertFrom-Json } catch { Write-Error "invalid JSON from tailscale"; exit 1 }

# Atomic replace so monitor.py never reads a half-written file.
$tmp = "$OutFile.tmp"
[System.IO.File]::WriteAllText($tmp, ($json -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
Move-Item $tmp $OutFile -Force
