#Requires -Version 7.0
<#
    Watch-PcHealth.ps1 - PC-side ntfy watcher for the OWUI / Ollama box.
    Created 2026-09-11. Stripped down and extended 2026-10-03 (see AI-CHANGELOG.csv).
    Runs every 15 minutes via the OWUI-ntfy-PcHealth scheduled task.

    COVERS (2026-10-03 bare-bones set, chosen by Liam)
      pc-alert
        1  Windows Update pending reboot                       (re-nag 24h)
        2  Disk critical  < 40 GB free                         (re-nag 12h, p5)
           Disk warning   < 75 GB free                         (re-nag 48h, p3 - low priority)
        3  GPU sustained heat (6 samples / 60 s, all >= 80 C)  (re-nag 2h)
        4  VRAM still held long after the last chat            (re-nag 6h)
        5  Unexpected shutdown since last scan                 (event-driven)
        8  Physical disk health / SMART                        (re-nag 12h)
        9  SSH connection attempts on this PC                  (event-driven, batched per run)
       10  Windows CRITICAL updates waiting to install         [daily, alerts when the KB list changes]
      pc-info
        6  winget app update digest                            [daily]
       11  Open WebUI update available                         [daily, once per new release]

      CPU runaway heat and VPS reachability need 10-second sampling, so they
      live in Watch-Fast.ps1, not here.

    REMOVED 2026-10-03: Docker/Ollama update notices, output-folder growth,
    three-hour focus nudge. Originals in _support\backups\config\pre-ntfy-stripdown-20261003\.

    DESIGN
      Transition-only. Every condition alerts once when it goes bad and once when
      it clears. -Repeat re-nags on the few that genuinely deserve it.
      Nothing here throws: a watcher that dies is worse than a missed alert.
      Timestamps from the state file go through ConvertTo-NtfyDate - NEVER
      [datetime]::TryParse (that was the en-GB day/month bug).
#>

[CmdletBinding()]
param([switch]$ForceDaily, [switch]$TestMode)

Import-Module "$PSScriptRoot\NtfyCore.psm1" -Force

$state = Get-NtfyState
$today = (Get-Date).ToString("yyyy-MM-dd")

function Test-DailyDue {
    param([string]$Key)
    if ($ForceDaily) { return $true }
    $k = "daily.$Key"
    if ($state.ContainsKey($k) -and [string]$state[$k] -eq $today) { return $false }
    return $true
}
function Set-DailyDone { param([string]$Key) $state["daily.$Key"] = $today }

Write-NtfyLog "=== Watch-PcHealth run ==="

# ------------------------------------------------- 1. Windows Update reboot
try {
    $pending = $false
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $pending = $true }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")  { $pending = $true }
    $pfro = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfro) { $pending = $true }

    $up = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Send-NtfyTransition -Key "win.reboot" -IsBad $pending -State $state -Repeat 24 -Priority 3 -Tags @("arrows_counterclockwise") `
        -BadTitle "Windows wants a reboot" `
        -BadMessage ("Updates are staged and waiting.`nUptime {0}d {1}h. Reboot when the stack is idle - start-stack.ps1 brings it back." -f $up.Days, $up.Hours) `
        -OkTitle "Reboot done" -OkMessage "No pending Windows Update reboot any more."
} catch { Write-NtfyLog -Level WARN "reboot check failed: $($_.Exception.Message)" }

# ------------------------------------------------------- 2. Disk thresholds
try {
    foreach ($d in @("C","D","E","G")) {
        $drv = Get-PSDrive -Name $d -ErrorAction SilentlyContinue
        if (-not $drv -or $null -eq $drv.Free) { continue }
        $freeGB = [math]::Round($drv.Free / 1GB, 1)
        $totGB  = [math]::Round(($drv.Free + $drv.Used) / 1GB, 1)

        Send-NtfyTransition -Key "disk.$d.crit" -IsBad ($freeGB -lt 40) -State $state -Repeat 12 -Priority 5 -Tags @("rotating_light","floppy_disk") `
            -BadTitle "$($d): critically low disk" `
            -BadMessage ("{0} GB free of {1} GB. Things will start failing to write." -f $freeGB, $totGB) `
            -OkTitle "$($d): disk recovered" -OkMessage ("Back to {0} GB free." -f $freeGB)

        Send-NtfyTransition -Key "disk.$d.warn" -IsBad (($freeGB -lt 75) -and ($freeGB -ge 40)) -State $state -Repeat 48 -Priority 3 -Tags @("warning","floppy_disk") `
            -BadTitle "$($d): disk getting low" `
            -BadMessage ("{0} GB free of {1} GB." -f $freeGB, $totGB) `
            -OkTitle "" -OkMessage ""
    }
} catch { Write-NtfyLog -Level WARN "disk check failed: $($_.Exception.Message)" }

# --------------------------------------------------------- 3. GPU sustained heat
#  Sample six times across a minute. One hot reading is a workload; six is a problem.
try {
    $temps = @()
    for ($i = 0; $i -lt 6; $i++) {
        $t = (nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>$null | Select-Object -First 1)
        if ($t) { $temps += [int]($t.ToString().Trim()) }
        if ($i -lt 5) { Start-Sleep -Seconds 10 }
    }
    if ($temps.Count -ge 4) {
        $hot = (($temps | Where-Object { $_ -ge 80 }).Count -eq $temps.Count)
        $max = ($temps | Measure-Object -Maximum).Maximum
        $min = ($temps | Measure-Object -Minimum).Minimum
        Send-NtfyTransition -Key "gpu.hot" -IsBad $hot -State $state -Repeat 2 -Priority 5 -Tags @("fire") `
            -BadTitle "GPU running hot" `
            -BadMessage ("Sustained {0} C across a minute (peak {1} C). If you are not running anything, something is stuck." -f $min, $max) `
            -OkTitle "GPU cooled down" -OkMessage ("Back to {0} C." -f $temps[-1])
    }
} catch { Write-NtfyLog -Level WARN "gpu temp check failed: $($_.Exception.Message)" }

# ------------------------------------- 4. VRAM held long after the last chat
try {
    $apps = nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader 2>$null
    $ollamaMB = 0
    foreach ($line in $apps) {
        if ($line -match "ollama" -and $line -match "(\d+)\s*MiB") { $ollamaMB += [int]$Matches[1] }
    }
    $lastChatMins = $null
    try {
        $py = "import sqlite3,time" + [char]10 + "r=sqlite3.connect('/app/backend/data/webui.db').execute('select max(updated_at) from chat').fetchone()[0]" + [char]10 + "print(int((time.time()-r)/60) if r else -1)"
        $out = $py | docker exec -i open-webui python - 2>$null
        if ($out) { $lastChatMins = [int]($out.ToString().Trim()) }
    } catch { }

    $stuck = ($ollamaMB -gt 1024 -and $null -ne $lastChatMins -and $lastChatMins -gt 30)
    Send-NtfyTransition -Key "gpu.vram.stuck" -IsBad $stuck -State $state -Repeat 6 -Priority 4 -Tags @("brain","warning") `
        -BadTitle "Ollama still holding VRAM" `
        -BadMessage ("{0} MB held, but the last chat was {1} minutes ago. KEEP_ALIVE=0 says it should have released. Usually a wedged model or a dead CUDA context - try owuihelp freevram." -f $ollamaMB, $lastChatMins) `
        -OkTitle "VRAM released" -OkMessage "Ollama has let go of the GPU again."
} catch { Write-NtfyLog -Level WARN "vram check failed: $($_.Exception.Message)" }

# ------------------------------------------------------ 5. Unexpected shutdown
try {
    $since = (Get-Date).AddMinutes(-20)
    if ($state.ContainsKey("lastRebootScan")) {
        $parsed = ConvertTo-NtfyDate $state["lastRebootScan"]
        # Never look back further than 2 days, even if the state is odd.
        if ($parsed -gt (Get-Date).AddDays(-2)) { $since = $parsed }
    }
    $scanStart = Get-Date
    $events = Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 6008, 41; StartTime = $since } -ErrorAction SilentlyContinue
    if ($events) {
        $newest = $events | Sort-Object TimeCreated -Descending | Select-Object -First 1
        Send-Ntfy -Title "Unexpected shutdown detected" `
                  -Message ("Event {0} at {1:HH:mm on ddd dd MMM}.`nThe PC did not shut down cleanly - power, crash, or a forced update." -f $newest.Id, $newest.TimeCreated) `
                  -Topic pc-alert -Priority 4 -Tags @("electric_plug","warning") | Out-Null
    }
    $state["lastRebootScan"] = $scanStart.ToString("o")
} catch { Write-NtfyLog -Level WARN "reboot event scan failed: $($_.Exception.Message)" }

# ------------------------------------------------------- 8. Physical disk health
try {
    $sick = Get-PhysicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.HealthStatus -ne "Healthy" -or $_.OperationalStatus -notin @("OK","Online") }
    if ($sick) {
        $names = ($sick | ForEach-Object { "{0} ({1}/{2})" -f $_.FriendlyName, $_.HealthStatus, $_.OperationalStatus }) -join "; "
        Send-NtfyTransition -Key "disk.smart" -IsBad $true -State $state -Repeat 12 -Priority 5 -Tags @("rotating_light","floppy_disk") `
            -BadTitle "Drive health warning" -BadMessage ("Windows is unhappy with: {0}.`nBack up before doing anything else." -f $names)
    } else {
        Send-NtfyTransition -Key "disk.smart" -IsBad $false -State $state `
            -OkTitle "Drive health recovered" -OkMessage "All physical disks report Healthy again."
    }
} catch { Write-NtfyLog -Level WARN "smart check failed: $($_.Exception.Message)" }

# ------------------------------------------------- 9. SSH connection attempts
#  sshd logs every connection to OpenSSH/Operational. This PC probes its own
#  port 22 every 15 s (a health check from its own tailnet IP), so every
#  address belonging to THIS machine is ignored - otherwise ~5,700 events/day.
#  Anything else - failed, invalid user, accepted, or a bare pre-auth
#  connection - is batched into ONE message per 15-minute run.
try {
    $selfIPs = @("127.0.0.1", "::1") + @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
    $since = (Get-Date).AddMinutes(-20)
    if ($state.ContainsKey("lastSshScan")) {
        $parsed = ConvertTo-NtfyDate $state["lastSshScan"]
        if ($parsed -gt (Get-Date).AddDays(-1)) { $since = $parsed }
    }
    $scanStart = Get-Date
    $ev = Get-WinEvent -FilterHashtable @{ LogName = "OpenSSH/Operational"; StartTime = $since } -ErrorAction SilentlyContinue

    $hits = @()
    foreach ($e in $ev) {
        $m = $e.Message
        if ($m -notmatch "from (\S+) port|by (?:authenticating user \S+ |invalid user \S+ )?(\S+) port") { continue }
        $ip = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        if ($selfIPs -contains $ip) { continue }
        $kind = "connection"
        if     ($m -match "Accepted (\S+) for (\S+)")                                { $kind = "ACCEPTED login ($($Matches[2]), $($Matches[1]))" }
        elseif ($m -match "Failed \S+ for (invalid user )?(\S+)")                     { $kind = "failed login ($($Matches[2]))" }
        elseif ($m -match "Invalid user (\S+)")                                       { $kind = "invalid user ($($Matches[1]))" }
        elseif ($m -match "maximum authentication attempts|Too many authentication")   { $kind = "too many auth attempts" }
        $hits += [pscustomobject]@{ IP = $ip; Kind = $kind; Time = $e.TimeCreated }
    }

    if ($hits.Count -gt 0) {
        $accepted = @($hits | Where-Object { $_.Kind -like "ACCEPTED*" })
        $failed   = @($hits | Where-Object { $_.Kind -match "failed|invalid|too many" })
        $lines = $hits | Group-Object IP, Kind | Sort-Object Count -Descending | Select-Object -First 8 |
                 ForEach-Object { "- {0} x{1}: {2}" -f $_.Group[0].IP, $_.Count, $_.Group[0].Kind }
        $prio  = if ($failed.Count -gt 0) { 4 } elseif ($accepted.Count -gt 0) { 3 } else { 3 }
        $title = if ($failed.Count -gt 0) { "SSH: $($failed.Count) failed login attempt(s)" }
                 elseif ($accepted.Count -gt 0) { "SSH: login accepted" }
                 else { "SSH: $($hits.Count) connection attempt(s)" }
        Send-Ntfy -Title $title `
                  -Message ("Since {0:HH:mm}:`n{1}`n`nIf that was not you, check: Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 50" -f $since, ($lines -join "`n")) `
                  -Topic pc-alert -Priority $prio -Tags @("key","warning") | Out-Null
    }
    $state["lastSshScan"] = $scanStart.ToString("o")
} catch { Write-NtfyLog -Level WARN "ssh scan failed: $($_.Exception.Message)" }

# ============================== DAILY SECTIONS ==============================

# ------------------------------------------------------- 6. winget digest
#  Ollama and Docker Desktop are held by blocking pins on purpose; they are
#  left out of the digest entirely (their separate alerts were dropped 2026-10-03).
if ((Get-Date).Hour -ge 9 -and (Test-DailyDue "winget")) {
    try {
        $held = @("Ollama.Ollama", "Docker.DockerDesktop")
        $raw  = (winget upgrade --include-unknown --accept-source-agreements 2>$null | Out-String) -split "`r?`n"

        $others  = @()
        $inTable = $false
        foreach ($r in $raw) {
            if ($r -match "^-{5,}") { $inTable = $true; continue }
            if (-not $inTable -or -not $r.Trim()) { continue }
            if ($r -match "upgrades available" -or $r -match "^\d+ ") { continue }
            $isHeld = $false
            foreach ($h in $held) { if ($r -match [regex]::Escape($h)) { $isHeld = $true } }
            if (-not $isHeld) { $others += $r.Trim() }
        }

        if ($others.Count -gt 0) {
            $plural = if ($others.Count -eq 1) { "" } else { "s" }
            $list = ($others | Select-Object -First 12 | ForEach-Object { "- " + ($_ -replace "\s{2,}", "  ") }) -join "`n"
            Send-Ntfy -Title ("{0} app update{1} available" -f $others.Count, $plural) `
                      -Message ("{0}`n`nRun: owuihelp winget-upgrade-all" -f $list) `
                      -Topic pc-info -Priority 2 -Tags @("package") | Out-Null
        }
        Set-DailyDone "winget"
    } catch { Write-NtfyLog -Level WARN "winget check failed: $($_.Exception.Message)" }
}

# ------------------------------------------- 10. Windows CRITICAL updates
#  Uses the Windows Update Agent COM API (works without elevation for a search).
#  MsrcSeverity is Microsoft's own rating; only "Critical" counts here.
#  Alerts when the set of pending critical KBs CHANGES, re-nags every 72h,
#  and sends an all-clear when the list empties.
if ((Get-Date).Hour -ge 9 -and (Test-DailyDue "winupdate")) {
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $result   = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $crit = @()
        foreach ($u in $result.Updates) {
            if ($u.MsrcSeverity -eq "Critical") {
                $kb = if ($u.KBArticleIDs.Count) { "KB" + $u.KBArticleIDs.Item(0) } else { "" }
                $crit += [pscustomobject]@{ KB = $kb; Title = $u.Title }
            }
        }
        $sig = (($crit | ForEach-Object { $_.KB } | Sort-Object) -join ",")
        $prevSig = if ($state.ContainsKey("winupdate.sig")) { [string]$state["winupdate.sig"] } else { "" }

        if ($crit.Count -gt 0 -and $sig -ne $prevSig) {
            # list changed: force a fresh alert by clearing the transition state first
            $state.Remove("win.critupd") | Out-Null
        }
        $list = ($crit | Select-Object -First 8 | ForEach-Object { "- " + $_.Title }) -join "`n"
        Send-NtfyTransition -Key "win.critupd" -IsBad ($crit.Count -gt 0) -State $state -Repeat 72 -Priority 4 -Tags @("shield","warning") `
            -BadTitle ("{0} critical Windows update{1} waiting" -f $crit.Count, $(if ($crit.Count -eq 1) { "" } else { "s" })) `
            -BadMessage ("{0}`n`nSettings > Windows Update > Download & install." -f $list) `
            -OkTitle "Critical Windows updates installed" -OkMessage "Nothing rated Critical is waiting any more."
        $state["winupdate.sig"] = $sig
        Set-DailyDone "winupdate"
    } catch { Write-NtfyLog -Level WARN "windows update check failed: $($_.Exception.Message)" }
}

# ------------------------------------------------- 11. Open WebUI update
#  open-webui runs a floating :latest tag, so a new release does NOT arrive by
#  itself - see image-pin-policy: owuihelp pull-latest, then recreate.
#  One message per new release tag; never repeats for the same tag.
if ((Get-Date).Hour -ge 9 -and (Test-DailyDue "owuiver")) {
    try {
        $running = (Invoke-RestMethod "http://127.0.0.1:3000/api/version" -TimeoutSec 10).version
        $latest  = ((Invoke-RestMethod "https://api.github.com/repos/open-webui/open-webui/releases/latest" -TimeoutSec 15).tag_name) -replace "^v", ""
        $told    = if ($state.ContainsKey("owui.notifiedTag")) { [string]$state["owui.notifiedTag"] } else { "" }
        if ($running -and $latest -and ([version]$latest -gt [version]$running) -and $latest -ne $told) {
            Send-Ntfy -Title "Open WebUI $latest is out" `
                      -Message ("You are on {0}. Release notes: github.com/open-webui/open-webui/releases`n`nUpdate: owuihelp pull-latest, then recreate open-webui." -f $running) `
                      -Topic pc-info -Priority 2 -Tags @("arrow_up","package") `
                      -Click "https://github.com/open-webui/open-webui/releases/tag/v$latest" | Out-Null
            $state["owui.notifiedTag"] = $latest
        }
        Set-DailyDone "owuiver"
    } catch { Write-NtfyLog -Level WARN "owui version check failed: $($_.Exception.Message)" }
}

# Clean out state keys for checks that no longer exist.
foreach ($old in @("focus.since","focus.seen","focus.nudged","daily.folders",
                   "folder.E__ai_generated","folder.E__ai_comfyui_ComfyUI_output")) {
    if ($state.ContainsKey($old)) { $state.Remove($old) | Out-Null }
}

Set-NtfyState -State $state
Write-NtfyLog "=== Watch-PcHealth done ==="
