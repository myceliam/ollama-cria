#Requires -Version 7.0
<#
    Watch-Fast.ps1 - always-on 10-second watcher. Created 2026-10-03 (see AI-CHANGELOG.csv).

    WHY A SEPARATE, LONG-RUNNING SCRIPT
      Both rules below need a rolling 60-second window sampled every 10 s.
      A 15-minute scheduled task would see one minute in fifteen and miss nearly
      everything, so this runs as a loop. Cost: one sensor read + one ping per
      10 s - negligible.

    RULES (Liam, 2026-10-03)
      CPU runaway   : 5 of the last 6 samples >= 90 C  -> pc-alert p5
                      Normal ceiling with FanControl is 82-84 C, so 90 C sustained
                      means a stalled fan, failing pump or stuck process - not boost.
                      All-clear once all 6 samples are back under 90 C.
      VPS unreachable: 5 of the last 6 tailnet pings fail -> pc-alert p4
                      Message says whether the PC itself can still reach the
                      internet (1.1.1.1), so "VPS down" and "my internet is down"
                      are not confused. All-clear after 3 successful pings in a row.

    CPU SENSOR
      Windows has no reliable built-in Ryzen temperature. This reads the newest
      row of LibreHardwareMonitor's CSV sensor log ("Core (Tctl/Tdie)"). LHM 0.9.x
      has no WMI provider, and its web server was rejected (extra listener).
      LHM must be RUNNING elevated with Options -> Log Sensors on. A row older
      than 60 s counts as no reading. If no sensor is found the CPU rule is skipped and ONE
      low-priority alert says so; the VPS rule keeps working regardless.

    SAFETY
      Single instance (named mutex). The scheduled task re-launches it every
      15 minutes; a second copy exits immediately, so a crash self-heals.
      Own state file (ntfy-fast.state.json) - never races Watch-PcHealth.
#>

[CmdletBinding()]
param(
    [int]$IntervalSec  = 10,
    [int]$Window       = 6,
    [int]$CpuLimitC    = 90,
    [int]$CpuNeed      = 5,
    [int]$VpsNeed      = 5,
    [string]$VpsTarget = "{{VPS_TS_IP}}",     # VPS tailnet IP ({{VPS_TS_NAME}})
    [switch]$Once                            # one sample, print, exit - for testing
)

Import-Module "$PSScriptRoot\NtfyCore.psm1" -Force

$mutex = [Threading.Mutex]::new($false, "Global\OWUI-ntfy-Fast")
if (-not $Once -and -not $mutex.WaitOne(0)) { exit 0 }

$StatePath = "E:\ai\ollama\logs\ntfy-fast.state.json"
function Get-FastState {
    try { if (Test-Path $StatePath) { $h = Get-Content $StatePath -Raw | ConvertFrom-Json -AsHashtable; if ($h) { return $h } } } catch { }
    return @{}
}
function Save-FastState { param($S) try { $S | ConvertTo-Json -Depth 5 | Set-Content $StatePath -Encoding UTF8 } catch { } }

# LibreHardwareMonitor CSV log (Options -> Log Sensors). Chosen 2026-10-03 by Liam
# over LHM's web server: a file read opens no listening port. LHM writes
# LibreHardwareMonitorLog-YYYY-MM-DD.csv next to its exe: row 1 = sensor
# identifiers, row 2 = sensor names, then one timestamped row per log interval.
$LhmDir   = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe"
$MaxRowAgeSec = 60          # a newer-than-this row is required, else the reading counts as missing
$script:LhmCol  = @{}       # file -> column index cache

function Read-SharedText {
    param([string]$Path, [int]$TailBytes = 0)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        if ($TailBytes -gt 0 -and $fs.Length -gt $TailBytes) { [void]$fs.Seek(-$TailBytes, [IO.SeekOrigin]::End) }
        $sr = [IO.StreamReader]::new($fs)
        return $sr.ReadToEnd()
    } finally { $fs.Dispose() }
}

function Get-CpuTemp {
    try {
        $log = Get-ChildItem $LhmDir -Filter "LibreHardwareMonitorLog-*.csv" -ErrorAction Stop |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $log) { return $null }
        if (((Get-Date) - $log.LastWriteTime).TotalSeconds -gt $MaxRowAgeSec) { return $null }

        if (-not $script:LhmCol.ContainsKey($log.FullName)) {
            $head  = (Read-SharedText $log.FullName) -split "`r?`n" | Select-Object -First 2
            $ids   = $head[0] -split ","
            $names = $head[1] -split ","
            $idx = -1
            for ($i = 0; $i -lt $names.Count; $i++) {
                $n = $names[$i].Trim('"'); $id = $ids[$i].Trim('"')
                if ($id -match "cpu" -and $id -match "temperature" -and $n -match "Tctl|Tdie") { $idx = $i; break }
            }
            if ($idx -lt 0) {   # fall back to any CPU temperature column (e.g. "Core (Tctl/Tdie)" renamed, or CPU Package)
                for ($i = 0; $i -lt $ids.Count; $i++) { if ($ids[$i] -match "cpu.*temperature") { $idx = $i; break } }
            }
            if ($idx -lt 0) { return $null }
            $script:LhmCol[$log.FullName] = $idx
        }
        $idx  = $script:LhmCol[$log.FullName]
        $last = ((Read-SharedText $log.FullName -TailBytes 65536) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) -split ","
        if ($last.Count -le $idx) { return $null }
        $v = $last[$idx].Trim('"') -replace ",", "."
        $out = 0.0
        if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$out) -and $out -gt 0) { return $out }
    } catch { }
    return $null
}

function Remove-OldLhmLogs {
    # LHM logs every sensor on the machine (~15-20 MB/day at 10 s). Keep 3 days.
    try {
        Get-ChildItem $LhmDir -Filter "LibreHardwareMonitorLog-*.csv" -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Test-Ping { param([string]$Ip)
    try { return [bool](Test-Connection $Ip -Count 1 -TimeoutSeconds 2 -Quiet -ErrorAction Stop) } catch { return $false }
}

$state   = Get-FastState
$cpuBuf  = [Collections.Generic.Queue[object]]::new()
$vpsBuf  = [Collections.Generic.Queue[bool]]::new()
$okRun   = 0
$lastSensorWarn = [datetime]::MinValue
$lastPrune = [datetime]::MinValue

Write-NtfyLog "=== Watch-Fast started (pid $PID) ==="

while ($true) {
    try {
        # ---------------------------------------------------------- CPU
        if (((Get-Date) - $lastPrune).TotalHours -ge 1) { Remove-OldLhmLogs; $lastPrune = Get-Date }
        $t = Get-CpuTemp
        $cpuBuf.Enqueue($t); while ($cpuBuf.Count -gt $Window) { [void]$cpuBuf.Dequeue() }
        $valid = @($cpuBuf | Where-Object { $null -ne $_ })

        if ($null -eq $t) {
            if (((Get-Date) - $lastSensorWarn).TotalHours -ge 6) { Write-NtfyLog -Level WARN "CPU sensor unavailable - is LibreHardwareMonitor running (admin) with Log Sensors on?"; $lastSensorWarn = Get-Date }
        }
        # Sensor-missing alert: only after 10 minutes of no readings, once, low priority.
        $noSensor = ($cpuBuf.Count -ge $Window -and $valid.Count -eq 0)
        if (-not $state.ContainsKey("cpu.nosensor.since")) { $state["cpu.nosensor.since"] = $null }
        if ($noSensor) {
            if (-not $state["cpu.nosensor.since"]) { $state["cpu.nosensor.since"] = (Get-Date).ToString("o") }
            $since = ConvertTo-NtfyDate $state["cpu.nosensor.since"]
            if (((Get-Date) - $since).TotalMinutes -ge 10) {
                Send-NtfyTransition -Key "cpu.nosensor" -IsBad $true -State $state -Priority 2 -Tags @("thermometer","grey_question") `
                    -BadTitle "CPU temperature watch is blind" `
                    -BadMessage "No CPU temperature for 10+ minutes. LibreHardwareMonitor must be running (admin) with Options > Log Sensors ticked. The VPS check is unaffected."
            }
        } elseif ($valid.Count -gt 0) {
            $state["cpu.nosensor.since"] = $null
            Send-NtfyTransition -Key "cpu.nosensor" -IsBad $false -State $state -OkTitle "" -OkMessage ""
        }

        if ($valid.Count -ge $Window) {
            $hotN = @($valid | Where-Object { $_ -ge $CpuLimitC }).Count
            $max  = ($valid | Measure-Object -Maximum).Maximum
            $wasBad = $state.ContainsKey("cpu.runaway") -and $state["cpu.runaway"].bad
            $isBad  = if ($wasBad) { $hotN -gt 0 } else { $hotN -ge $CpuNeed }   # hysteresis: clear only when all 6 < limit
            Send-NtfyTransition -Key "cpu.runaway" -IsBad $isBad -State $state -Repeat 1 -Priority 5 -Tags @("fire","rotating_light") `
                -BadTitle ("CPU runaway heat: {0:N0} C" -f $max) `
                -BadMessage ("{0} of the last {1} readings at or above {2} C (normal ceiling 82-84 C).`nCheck FanControl, the AIO pump, and Task Manager for a stuck process." -f $hotN, $valid.Count, $CpuLimitC) `
                -OkTitle "CPU temperature back to normal" -OkMessage ("Now {0:N0} C." -f $t)
        }

        # ---------------------------------------------------------- VPS
        $up = Test-Ping $VpsTarget
        $vpsBuf.Enqueue($up); while ($vpsBuf.Count -gt $Window) { [void]$vpsBuf.Dequeue() }
        $okRun = if ($up) { $okRun + 1 } else { 0 }

        if ($vpsBuf.Count -ge $Window) {
            $fails  = @($vpsBuf | Where-Object { -not $_ }).Count
            $wasBad = $state.ContainsKey("vps.down") -and $state["vps.down"].bad
            $isBad  = if ($wasBad) { $okRun -lt 3 } else { $fails -ge $VpsNeed }
            if ($isBad -and -not $wasBad) {
                $net = Test-Ping "1.1.1.1"
                $why = if ($net) { "This PC can still reach the internet, so the VPS (or its Tailscale) is the problem." }
                       else      { "This PC cannot reach 1.1.1.1 either - it is probably YOUR internet, not the VPS." }
                $msg = "{0} of the last {1} pings to the VPS tailnet address failed.`n{2}" -f $fails, $Window, $why
            } else { $msg = "Still unreachable." }
            Send-NtfyTransition -Key "vps.down" -IsBad $isBad -State $state -Repeat 6 -Priority 4 -Tags @("satellite","warning") `
                -BadTitle "VPS unreachable" -BadMessage $msg `
                -OkTitle "VPS reachable again" -OkMessage "Three pings in a row answered."
        }

        if ($Once) {
            "cpu={0} vps={1} cpuBuf=[{2}] vpsBuf=[{3}]" -f $t, $up, ($cpuBuf -join ","), ($vpsBuf -join ",")
            break
        }
        Save-FastState $state
    } catch {
        Write-NtfyLog -Level WARN "fast loop error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $IntervalSec
}
