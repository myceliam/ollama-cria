#Requires -Version 7.0
<#
    Send-MorningBrief.ps1 - the 07:05 digest. Item 29.
    Created 2026-09-11 (see AI-CHANGELOG.csv).

    One notification to pc-info that answers "did anything happen overnight,
    and what does today look like". Every section degrades independently:
    a dead gcal bridge must not cost you the stack summary.

    SECTIONS
      1  Stack        - containers up, anything unhealthy
      2  Machine      - disk headroom, GPU idle temp and VRAM
      3  Backups      - last nightly, last offsite push
      4  Today        - calendar events and tasks due
      5  Security     - critical CVEs published in the last 24h (NVD)
#>

[CmdletBinding()]
param([switch]$Now)

Import-Module "$PSScriptRoot\NtfyCore.psm1" -Force
Write-NtfyLog "=== Send-MorningBrief run ==="

$lines = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$T) $lines.Add($T) }

# ------------------------------------------------------------------ 1. stack
try {
    $ps = docker ps --format "{{.Names}}|{{.Status}}" 2>$null
    $all = @($ps | Where-Object { $_ })
    $unhealthy = @($all | Where-Object { $_ -match "unhealthy|Restarting|Exited" })
    $expected = 16
    $icon = if ($unhealthy.Count -eq 0 -and $all.Count -ge $expected) { "OK" } else { "CHECK" }
    Add-Line ("STACK [{0}]  {1} containers up" -f $icon, $all.Count)
    if ($unhealthy.Count) {
        foreach ($u in $unhealthy) { Add-Line ("   ! " + ($u -replace "\|", "  ")) }
    }
    if ($all.Count -lt $expected) {
        $names = ($all | ForEach-Object { ($_ -split "\|")[0] }) -join ", "
        Add-Line ("   expected {0}, running: {1}" -f $expected, $names)
    }
} catch { Add-Line "STACK [??]  docker not reachable" }

# ---------------------------------------------------------------- 2. machine
try {
    $bits = @()
    foreach ($d in @("C","D","E","G")) {
        $drv = Get-PSDrive -Name $d -ErrorAction SilentlyContinue
        if ($drv -and $null -ne $drv.Free) { $bits += ("{0}:{1}G" -f $d, [math]::Round($drv.Free/1GB)) }
    }
    Add-Line ("DISK       free  " + ($bits -join "  "))
} catch { }

try {
    $g = (nvidia-smi --query-gpu=temperature.gpu,memory.used,memory.total --format=csv,noheader 2>$null | Select-Object -First 1)
    if ($g) {
        $p = $g -split ","
        Add-Line ("GPU        {0}C   {1} / {2} used" -f $p[0].Trim(), $p[1].Trim(), $p[2].Trim())
    }
} catch { }

try {
    $up = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Add-Line ("UPTIME     {0}d {1}h" -f $up.Days, $up.Hours)
} catch { }

# ---------------------------------------------------------------- 3. backups
try {
    $nightLog = Get-ChildItem "D:\owuibackups\nightly\backup-*.log" -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1
    if ($nightLog) {
        $t = Get-Content $nightLog.FullName -Raw
        $sz = if ($t -match "Backup complete:\s*([\d.]+)\s*GB") { $Matches[1] + " GB" } else { "size?" }
        $ok = if ($t -match "=== DONE \(nightly\)") { "OK" } else { "FAILED" }
        $age = [int]((Get-Date) - $nightLog.LastWriteTime).TotalHours
        Add-Line ("BACKUP     nightly {0}  {1}  ({2}h ago)" -f $ok, $sz, $age)
    } else { Add-Line "BACKUP     no nightly log found" }

    $pushLog = Get-ChildItem "D:\owuibackups\push-vps-*.log" -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1
    if ($pushLog) {
        $pb = Get-Content $pushLog.FullName -Raw
        $pok = if ($pb -match "OFFSITE COPY CONFIRMED") { "confirmed" } else { "NOT CONFIRMED" }
        $pd = [math]::Round(((Get-Date) - $pushLog.LastWriteTime).TotalDays, 1)
        Add-Line ("OFFSITE    {0}  ({1}d ago, runs every 3d)" -f $pok, $pd)
    }
} catch { Add-Line "BACKUP     check failed" }

# ------------------------------------------------------------------ 4. today
try {
    $gk = (docker exec gcal-owui-bridge printenv GCAL_BRIDGE_API_KEY 2>$null).Trim()
    if ($gk) {
        $h  = @{ "X-API-Key" = $gk }
        $s  = (Get-Date).Date.ToString("yyyy-MM-ddTHH:mm:sszzz")
        $e  = (Get-Date).Date.AddDays(1).AddSeconds(-1).ToString("yyyy-MM-ddTHH:mm:sszzz")
        $ev = Invoke-RestMethod -Uri ("http://127.0.0.1:18100/events/live?start={0}&end={1}" -f [uri]::EscapeDataString($s), [uri]::EscapeDataString($e)) -Headers $h -TimeoutSec 25

        Add-Line ""
        if ($ev.count -gt 0) {
            Add-Line ("TODAY      {0} event(s)" -f $ev.count)
            foreach ($x in ($ev.events | Select-Object -First 6)) {
                $when = if ($x.all_day) { "all day" } else { try { ([datetime]$x.start).ToString("HH:mm") } catch { "?" } }
                Add-Line ("   {0}  {1}" -f $when.PadRight(7), $x.title)
            }
        } else { Add-Line "TODAY      nothing in the calendar" }

        try {
            $td = Invoke-RestMethod -Uri "http://127.0.0.1:18100/tasks/due?days=1" -Headers $h -TimeoutSec 25
            if ($td.count -gt 0) {
                Add-Line ("TASKS      {0} due" -f $td.count)
                foreach ($x in ($td.tasks | Select-Object -First 5)) { Add-Line ("   - " + $x.title) }
            }
        } catch { }
    }
} catch { Add-Line "TODAY      calendar bridge unreachable" }

# --------------------------------------------------------------- 5. security
try {
    $nvdKey = ""
    $envLine = Select-String -Path "E:\ai\ollama\.env" -Pattern "^NVD_API_KEY=" -EA SilentlyContinue | Select-Object -First 1
    if ($envLine) { $nvdKey = ($envLine.Line -split "=", 2)[1].Trim().Trim('"') }

    $start = (Get-Date).AddDays(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000")
    $end   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000")
    $uri   = "https://services.nvd.nist.gov/rest/json/cves/2.0?pubStartDate=$start&pubEndDate=$end&cvssV3Severity=CRITICAL&resultsPerPage=20"
    $hdr   = if ($nvdKey) { @{ apiKey = $nvdKey } } else { @{} }
    $cve   = Invoke-RestMethod -Uri $uri -Headers $hdr -TimeoutSec 35

    Add-Line ""
    if ($cve.totalResults -gt 0) {
        Add-Line ("CVE        {0} CRITICAL published in 24h" -f $cve.totalResults)
        foreach ($v in ($cve.vulnerabilities | Select-Object -First 3)) {
            $id = $v.cve.id
            $desc = ($v.cve.descriptions | Where-Object { $_.lang -eq "en" } | Select-Object -First 1).value
            if ($desc.Length -gt 90) { $desc = $desc.Substring(0, 90) + "..." }
            Add-Line ("   {0}  {1}" -f $id, $desc)
        }
    } else { Add-Line "CVE        nothing CRITICAL in the last 24h" }
} catch { Add-Line "CVE        NVD lookup failed" }

# ------------------------------------------------------------------- publish
$body = ($lines -join "`n")
Send-Ntfy -Title ("Morning brief - {0:ddd dd MMM}" -f (Get-Date)) -Message $body `
          -Topic pc-info -Priority 3 -Tags @("sunrise") | Out-Null
Write-NtfyLog "=== Send-MorningBrief done ==="
