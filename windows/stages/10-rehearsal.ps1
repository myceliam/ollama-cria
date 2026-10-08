#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 10: reboot, rerun and the backup routine (docs/RESTORE.md Stage 10).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context, as the signed-in user. Needs Stage 9. It takes
    several visits: run the same command again after the restart and after
    each answer. A part that passed is not run again; one that failed runs
    again on the next visit.

      10a  PC restart. The first visit records when Windows last started and
           asks for a restart (exit code 3). After it: Stage 8's checkpoint
           must pass again (waiting up to ten minutes for the stack), with
           the pagefile now in effect; Stage 9's auto rows run again; and
           every scheduled task and startup item must show that it ran since
           the restart (C-51): a line its script logs, a file it writes, or
           Task Scheduler showing it running. It waits until 25 minutes
           after the restart for them.
      10b  From outside the tailnet (C-52). The VPS's public IPv4 and IPv6
           (10-vps.sh public-ip, from the host, not the tunnel) are probed
           from this PC on every TCP port anything listens on there and on
           the stack's ports; this PC's public addresses (api.ipify.org) are
           probed from the VPS (10-vps.sh probe) on the stack's ports and
           Windows' own. Nothing may answer. The addresses stay in memory:
           the evidence holds ports only. A side with no IPv6 is a warning.
      10c  The VPS tests, only once 'vps-tests' is accepted, and only while
           Stage 2's checkpoint passes (known_hosts holds the host key
           recorded for the rebuilt VPS), each only after the one before it
           passed: restart the VPS, then the guard must have started before
           Docker and Stage 5's checkpoint must pass again; break the guard
           on purpose, then Docker must refuse to start and everything must
           come back (C-20, C-43); stop the tunnel, then everything must fail
           closed and recover (C-21, linux/stages/10-killswitch.py).
      10d  The monthly reminder (C-47): windows/reminder/Send-BackupReminder.ps1
           next to NtfyCore.psm1, and the task OWUI-ntfy-BackupReminder
           registered for this account and started once. Its log line must
           show ntfy took the notification.
      10e  The first backup, once 10a has passed: tools/Collect-StackSecrets.ps1
           -Execute into the staging folder, with the OWUI seed written to
           <state root>\owui-seed-new (not into the repo, whose manifests
           must not change before Stage 11). The run folder and an
           owner-only 'roundtrip' folder for the download from Bitwarden are
           recorded as plaintext, so Stage 11 removes them. Once a ZIP is in
           'roundtrip', its SHA-256 must match the bundle's.
      10f  The second run, once everything above has passed and been
           answered: every checkpoint from 1 to 9 again, changing nothing.

    The interruption test (C-45) is optional (Liam, 8 October 2026): the
    controller's own tests prove the wipe and rerun, so a real rebuild can
    skip it. To run it, interrupt a stage with Ctrl+C while it runs, and run
    it again. state.json counts the interruption; this stage compares the
    count with the one it recorded on its first visit. An interrupted stage
    that has not finished since still fails the checkpoint.

    Other stages' checks and tests run from -Context's StageRoot with that
    stage's own recorded data and answers; they cannot create or remove
    anything here.

    Check is checkpoint 10. It reads what Run recorded and calls nothing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Run', 'Check')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../tools/RecoveryState.psm1')
Import-Module (Join-Path $PSScriptRoot '../../tools/RecoveryHost.psm1')
Import-Module (Join-Path $PSScriptRoot '../../tools/RecoveryVps.psm1')
Import-Module $Context.Tools.StackCapture

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
foreach ($k in @($Context.Data.Keys)) { $result.Data[$k] = $Context.Data[$k] }
$machine = $Context.Machine
$repo = $Context.RepoRoot
$alias = $Context.Topology['hosts']['vps']['sshAlias']
$account = $Context.Topology['hosts']['vps']['user']
$vpsScript = Join-Path $repo 'linux/stages/10-vps.sh'
$stageRoot = if ($Context['StageRoot']) { [string]$Context['StageRoot'] } else { $PSScriptRoot }
$stackRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['stack']['path']))
$dashboardRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['dashboard']['path']))
$taskManifest = Get-Content -LiteralPath (Join-Path $repo 'manifests/tasks.json') -Raw | ConvertFrom-Json -AsHashtable
$reminderTask = 'OWUI-ntfy-BackupReminder'
$reminderTitle = 'Monthly backup check'
$userIds = 'vps-tests', 'reminder', 'lan-closed'

# What proves each enabled task in manifests/tasks.json, and each startup
# item, ran since the restart (C-51). 'line': the newest line matching Line
# in a log under the stack root, whose first group is its local time.
# 'file': a file matching Filter written since. 'task': Task Scheduler shows
# it running, started since. 'url': it answers 200.
$heartbeats = [ordered]@{
    'OWUI-Stack-Startup'           = @{ Kind = 'file'; Root = $stackRoot; Folder = 'logs'; Filter = 'start-stack-*.log' }
    'OWUI-mcpo-Watchdog'           = @{ Kind = 'line'; File = 'logs/mcpo-watchdog.log'; Line = '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)  stack: ' }
    'OWUI-ntfy-Fast'               = @{ Kind = 'line'; File = 'logs/ntfy-monitor.log'; Line = '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] INFO === Watch-Fast started' }
    'OWUI-ntfy-PcHealth'           = @{ Kind = 'line'; File = 'logs/ntfy-monitor.log'; Line = '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] INFO === Watch-PcHealth run ===' }
    'OWUI-Windows-PowerShell-Tool' = @{ Kind = 'task' }
    'Tailscale-Status-Feed'        = @{ Kind = 'file'; Root = $dashboardRoot; Folder = 'data'; Filter = 'tailscale-status.json' }
    'LibreHardwareMonitor'         = @{ Kind = 'task' }
    'OWUI ComfyUI AutoFree.lnk'    = @{ Kind = 'line'; File = 'logs/autofree.log'; Line = '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)  INFO  watchdog started' }
    'start_comfyui_hidden.vbs'     = @{ Kind = 'url'; Url = 'http://127.0.0.1:8188/system_stats' }
}

# Ports probed from outside the tailnet, besides those the VPS reports
# listening: the stack's own (Appendix E and every published port) and the
# usual remote-access ones. All must be closed.
$vpsPorts = @(22, 80, 443, 3000, 3001, 8000, 8080, 8443, 8880, 8888, 8889, 11434, 13000, 13055, 13100, 18080, 18099)
$pcPorts = @(22, 80, 135, 139, 443, 444, 445, 2000, 3000, 3001, 3389, 5985, 6080, 8080, 8090, 8188, 8443, 8880, 8931, 9000,
    11434, 13100, 18000, 18019, 18088, 18100, 18101, 18110)

# What the kill-switch test must report while the tunnel is stopped, and
# after: 'not:ok' is anything but ok.
$killSwitch = [ordered]@{
    search = 'not:ok'; read = 'not:ok'; reader = 'blocked'; searxng = 'none'; proxy_8888 = 'blocked'; proxy_8889 = 'blocked'
    tcp4 = 'blocked'; tcp6 = 'blocked'; dns_new_name = 'no-address'; dns_plain_1 = 'no-answer'; dns_plain_2 = 'no-answer'
    still_stopped = 'yes'; recovered = 'yes'
}

# ---------- helpers ----------

function Test-Passed($Part) { return $Part -is [Collections.IDictionary] -and [bool]$Part['Ok'] }

function Get-List($Value) {
    # A recorded list without nulls (state.json may give $null for none).
    return , @(@($Value) | Where-Object { $null -ne $_ -and "$_" -ne '' })
}

function Get-Part($Part, [string]$Key) {
    # A recorded table inside a part, or an empty one.
    if ($Part -is [Collections.IDictionary] -and $Part[$Key] -is [Collections.IDictionary]) { return $Part[$Key] }
    return @{}
}

function ConvertTo-Utc($Value) {
    # A time from state.json (a string or, once parsed, a DateTime) in UTC.
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Get-Now { [DateTime]::UtcNow }

function Get-Why($Stage) {
    # A stage result's failed checks, problems and open questions, short.
    $bad = @(@($Stage.Checks | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.What): $($_.Actual)" }) + @($Stage.Problems) +
        @($Stage.Asks | ForEach-Object { if ($_.Id) { "waits for -Accept $($_.Id)" } else { 'waits for a person' } }))
    if (-not $bad.Count) { return "status $($Stage.Status)" }
    $more = if ($bad.Count -gt 3) { " (and $($bad.Count - 3) more)" } else { '' }
    return (($bad | Select-Object -First 3) -join '; ') + $more
}

function Copy-Data($Value) {
    # A deep copy of a stage's recorded data, as state.json would give it.
    if ($null -eq $Value) { return @{} }
    $copy = ConvertTo-Json -InputObject $Value -Depth 30 -Compress | ConvertFrom-Json -AsHashtable
    if ($copy -isnot [hashtable]) { return @{} }
    return $copy
}

function Get-OtherContext([int]$Number, [string]$OtherMode) {
    # Another stage's context: its own recorded data and answers. It may
    # read and test; recording or removing anything throws.
    $entry = $Context.State['stages']["$Number"]
    $c = $Context.Clone()
    $c.Stage = $Number
    $c.Mode = $OtherMode
    $c.Data = if ($entry -is [hashtable] -and $entry['data'] -is [hashtable]) { Copy-Data $entry['data'] } else { @{} }
    $c.Accepted = [string[]]@(if ($entry -is [hashtable] -and $entry['accepted']) { $entry['accepted'] })
    $c.HostKey = $null
    $refuse = { throw [InvalidOperationException]::new("Stage 10 runs other stages' checks and tests only; they cannot create or remove anything from it") }
    $c.Own = $refuse
    $c.Keep = $refuse
    $c.RemoveOwned = $refuse
    return $c
}

function Invoke-OtherStage([int]$Number, [string]$OtherMode) {
    # Runs another stage's script in -OtherMode; a stage that throws or
    # returns nothing comes back failed.
    $found = @(Get-ChildItem -LiteralPath $stageRoot -Filter ('{0:D2}-*.ps1' -f $Number) -File -ErrorAction SilentlyContinue)
    if ($found.Count -ne 1) {
        $r = New-StageResult -Status 'failed'
        $r.Problems.Add("there is not exactly one script for Stage $Number in $stageRoot")
        return $r
    }
    try {
        $r = & $found[0].FullName -Mode $OtherMode -Context (Get-OtherContext $Number $OtherMode)
        $r = @($r | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Status'] }) | Select-Object -Last 1
        if ($null -eq $r) { throw [InvalidOperationException]::new('it returned no result') }
        return $r
    }
    catch {
        $r = New-StageResult -Status 'failed'
        $r.Problems.Add("stopped: $($_.Exception.Message)")
        return $r
    }
}

function Invoke-VpsStep([string[]]$Arguments, [string[]]$InputLines = @(), $Into = $result) {
    # 10-vps.sh with -Arguments; its lines go into -Into. Returns the facts
    # and the exit code.
    $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path $vpsScript -Arguments $Arguments -InputLines $InputLines
    $facts = Add-VpsOutput -Result $Into -Run $run -Label "10-vps.sh $($Arguments[0])"
    return @{ Facts = $facts; ExitCode = $run.ExitCode }
}

function Get-VpsAddress {
    try { return (Get-TailnetEndpoint -SshHost $alias -TailscaleCommand $machine.Commands['tailscale'])['VPS_TS_IP'] }
    catch { $result.Problems.Add("tailnet: $($_.Exception.Message)"); return $null }
}

function Test-AllUp([string]$Value) { return $Value -match '^([1-9][0-9]*)/([0-9]+)$' -and $Matches[1] -eq $Matches[2] }

function Get-InterruptCount {
    $out = @{}
    foreach ($n in 1..9) {
        $e = $Context.State['stages']["$n"]
        $out["$n"] = if ($e -is [hashtable] -and $e['interruptions']) { [int]$e['interruptions'] } else { 0 }
    }
    return $out
}

function Get-Interrupted {
    # The stages interrupted since this stage's first visit: @{ Done; Open }.
    $base = $result.Data['InterruptBaseline']
    $now = Get-InterruptCount
    $done = [Collections.Generic.List[string]]::new(); $open = [Collections.Generic.List[string]]::new()
    foreach ($n in 1..9) {
        $was = if ($base -is [Collections.IDictionary] -and $null -ne $base["$n"]) { [int]$base["$n"] } else { 0 }
        if ($now["$n"] -le $was) { continue }
        $e = $Context.State['stages']["$n"]
        if ($e -is [hashtable] -and $e['status'] -eq 'done') { $done.Add("$n") } else { $open.Add("$n") }
    }
    return @{ Done = $done.ToArray(); Open = $open.ToArray() }
}

# ---------- 10a: the PC restart ----------

function Read-LogTime([string]$Path, [string]$Pattern) {
    # The UTC time of the newest line in the last megabyte of a log that
    # matches -Pattern (its first group, this PC's local time), or $null.
    # Lines are never kept or shown.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = [IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $take = [Math]::Min($stream.Length, 1MB)
        $null = $stream.Seek(-$take, 'End')
        $buffer = [byte[]]::new($take)
        $read = 0
        while ($read -lt $take) { $n = $stream.Read($buffer, $read, $take - $read); if ($n -le 0) { break }; $read += $n }
    }
    finally { $stream.Dispose() }
    $newest = $null
    foreach ($line in ([Text.Encoding]::UTF8.GetString($buffer, 0, $read) -split "`r?`n")) {
        $m = [regex]::Match($line.TrimStart([char]0xFEFF), $Pattern)
        if (-not $m.Success) { continue }
        $t = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$t)) { continue }
        $t = $t.ToUniversalTime()
        if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
    }
    return $newest
}

function Get-HeartbeatState([string]$Name, $Beat, [DateTime]$Boot) {
    # 'ok', or what is missing.
    switch ($Beat.Kind) {
        'line' {
            $t = Read-LogTime (Join-Path $stackRoot $Beat.File) $Beat.Line
            if ($t -and $t -ge $Boot) { return 'ok' }
            return "no line in $($Beat.File) since the restart"
        }
        'file' {
            $folder = Join-Path $Beat.Root $Beat.Folder
            $newest = @(Get-ChildItem -LiteralPath $folder -Filter $Beat.Filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending) | Select-Object -First 1
            if ($newest -and $newest.LastWriteTimeUtc -ge $Boot) { return 'ok' }
            return "no $($Beat.Filter) written in $folder since the restart"
        }
        'task' {
            $i = & $machine.TaskInfo $Name
            if (-not $i) { return 'the task is missing' }
            $ran = ConvertTo-Utc $i['LastRunTime']
            if ($i['State'] -eq 'Running' -and $ran -and $ran -ge $Boot) { return 'ok' }
            return "the task is $($i['State']), last started $(if ($ran) { $ran.ToString('u') } else { 'never' })$(if ($null -ne $i['LastTaskResult']) { ", last result 0x{0:X}" -f [long]$i['LastTaskResult'] })"
        }
        'url' {
            $code = & $machine.HttpStatus $Beat.Url
            if ($code -eq 200) { return 'ok' }
            return "$($Beat.Url) gives $(if ($code) { "HTTP $code" } else { 'no answer' })"
        }
    }
    return "no heartbeat kind '$($Beat.Kind)'"
}

function Wait-Heartbeat([DateTime]$Boot) {
    # Every enabled task and startup item: 'ok' or why not. Waits until 25
    # minutes after the restart (two minutes at least) for the slow ones.
    $names = @(@($taskManifest['tasks'] | Where-Object { $_['enabled'] } | ForEach-Object { [string]$_['name'] }) + @($taskManifest['startup'] | ForEach-Object { [string]$_['name'] }))
    $out = [ordered]@{}
    foreach ($n in $names) { if (-not $heartbeats.Contains($n)) { $out[$n] = 'no heartbeat is defined for it in 10-rehearsal.ps1' } }
    $left = [Math]::Max(($Boot.AddMinutes(25) - (Get-Now)).TotalSeconds, 120)
    $polls = [int][Math]::Min([Math]::Ceiling($left / 30), 50)
    for ($i = 0; ; $i++) {
        $missing = 0
        foreach ($n in $names) {
            if (-not $heartbeats.Contains($n)) { continue }
            if ($out.Contains($n) -and $out[$n] -eq 'ok') { continue }
            $out[$n] = Get-HeartbeatState $n $heartbeats[$n] $Boot
            if ($out[$n] -ne 'ok') { $missing++ }
        }
        if (-not $missing -or $i -ge $polls) { return $out }
        if ($i -eq 0) { & $Context.Say "waiting for $missing scheduled task(s) to show they ran since the restart" }
        & $machine.Wait 30
    }
}

function Invoke-PcRestart([DateTime]$Boot) {
    $part = @{ Ok = $false; Boot = $Boot.ToString('o'); Tested = (Get-Now).ToString('o') }
    $result.Data['PcRestart'] = $part

    & $Context.Say 'after the restart: waiting up to ten minutes for Stage 8''s checkpoint to pass again'
    $eight = $null
    for ($i = 0; $i -lt 20; $i++) {
        $eight = Invoke-OtherStage 8 'Check'
        if ($eight.Status -ne 'failed') { break }
        & $machine.Wait 30
    }
    $part['Stage8'] = if ($eight.Status -eq 'passed') { 'passed' } else { Get-Why $eight }
    $pagefile = @($eight.Checks | Where-Object { $_.What -like 'pagefile*' }) | Select-Object -First 1
    if ($pagefile -and "$($pagefile.Actual)" -like '*waits for the restart*') {
        $part['Stage8'] = 'the pagefile did not take effect at the restart'
        $now = ([string]$pagefile.Actual -split ' [(]set;')[0]
        $result.Problems.Add("after the restart, the pagefile is still $now; set it in System > Advanced system settings > Performance > Virtual memory, as Stage 8 says, and restart")
    }
    elseif ($part['Stage8'] -ne 'passed') { $result.Problems.Add("after the restart, Stage 8's checkpoint does not pass: $($part['Stage8'])") }

    & $Context.Say 'after the restart: running Stage 9''s auto rows again'
    $nine = Invoke-OtherStage 9 'Run'
    $rows = $nine.Data['Results']
    $failedRows = @(if ($rows -is [Collections.IDictionary]) { $rows.Keys | Where-Object { -not $rows[$_]['ok'] } })
    $total = if ($rows -is [Collections.IDictionary]) { $rows.Count } else { 0 }
    $part['Stage9'] = @{ Total = $total; Passed = $total - $failedRows.Count; Failed = @($failedRows) }
    foreach ($p in $nine.Problems) { $result.Problems.Add("after the restart, Stage 9: $p") }
    if (-not $total -and -not $nine.Problems.Count) { $result.Problems.Add('after the restart, Stage 9 ran no rows') }
    $nineOk = $nine.Status -eq 'done' -and $total -gt 0 -and -not $failedRows.Count

    $beats = Wait-Heartbeat $Boot
    $part['Heartbeats'] = $beats
    $quiet = @($beats.Keys | Where-Object { $beats[$_] -ne 'ok' })
    foreach ($q in $quiet) { $result.Problems.Add("after the restart, $($q): $($beats[$q]) (C-51)") }

    $part['Ok'] = $part['Stage8'] -eq 'passed' -and $nineOk -and -not $quiet.Count
    $result.Steps.Add("after the restart: Stage 8 checkpoint $(if ($part['Stage8'] -eq 'passed') { 'passed' } else { 'FAILED' }); Stage 9 $($part['Stage9']['Passed']) of $total auto rows; $($beats.Count - $quiet.Count) of $($beats.Count) tasks and startup items ran since the restart")
}

# ---------- 10b: from outside the tailnet ----------

function Get-PcPublicAddress([string]$Family) {
    $url = if ($Family -eq '4') { 'https://api.ipify.org' } else { 'https://api6.ipify.org' }
    $r = & $machine.Exec 'curl' @("-$Family", '-fsS', '--max-time', '15', $url)
    if ($r.ExitCode -ne 0) { return $null }
    $a = "$(@($r.Output)[0])".Trim()
    if (-not (Test-PublicAddress $a) -or ($a.Contains(':') -ne ($Family -eq '6'))) { return $null }
    return $a
}

function Format-Side($Side) {
    # 'IPv4: none of 20 open; IPv6: no address' for the evidence.
    $parts = foreach ($f in '4', '6') {
        $s = $Side[$f]
        if ($s -isnot [Collections.IDictionary]) { "IPv${f}: $s" }
        elseif ((Get-List $s['Open']).Count) { "IPv${f}: OPEN $((Get-List $s['Open']) -join ', ')" }
        else { "IPv${f}: none of $($s['Probed']) open" }
    }
    return $parts -join '; '
}

function Test-SideClosed($Side) {
    # Closed when IPv4 was probed with nothing open and IPv6 has nothing open.
    foreach ($f in '4', '6') {
        $s = $Side[$f]
        if ($s -is [Collections.IDictionary]) { if ((Get-List $s['Open']).Count) { return $false } }
        elseif ($f -eq '4') { return $false }
    }
    return $true
}

function Test-ExitNode {
    # $true, with a problem, when this PC's internet traffic goes through a
    # Tailscale exit node (or that cannot be read): its probes would reach
    # the VPS through the tailnet, and its public address would be the exit
    # node's.
    $r = & $machine.Exec 'tailscale' @('status', '--json')
    $s = $null
    if ($r.ExitCode -eq 0) { try { $s = ConvertFrom-Json -InputObject (@($r.Output) -join "`n") -ErrorAction Stop } catch { $s = $null } }
    if ($null -eq $s) {
        $result.Problems.Add("'tailscale status --json' did not answer, so whether this PC uses an exit node is unknown; nothing was probed from outside (C-52)")
        return $true
    }
    if ($s.PSObject.Properties['ExitNodeStatus'] -and $null -ne $s.ExitNodeStatus) {
        $result.Problems.Add("this PC sends its internet traffic through a Tailscale exit node, so the probes from outside would mean nothing. Turn it off for the test ('tailscale set --exit-node='), run again, then turn it back on")
        return $true
    }
    return $false
}

function Invoke-Outside {
    # Each public address is probed only from a host that has the same
    # family, so a missing route never reads as a closed port.
    $part = @{ Ok = $false; Vps = @{ '4' = 'not tested'; '6' = 'not tested' }; Pc = @{ '4' = 'not tested'; '6' = 'not tested' }; Tested = (Get-Now).ToString('o') }
    $result.Data['Outside'] = $part
    if (Test-ExitNode) { return }
    $ip = Invoke-VpsStep @('public-ip')
    if ($ip.ExitCode -ne 0) { return }
    $vpsAddress = @{}; $pcAddress = @{}
    foreach ($f in '4', '6') {
        $a = [string]$ip.Facts["public_ipv$f"]
        if ($a -and $a -ne 'none' -and (Test-PublicAddress $a) -and $a.Contains(':') -eq ($f -eq '6')) { $vpsAddress[$f] = $a }
        $a = Get-PcPublicAddress $f
        if ($a) { $pcAddress[$f] = $a }
    }
    $listening = @("$($ip.Facts['tcp_ports'])" -split ',' | Where-Object { $_ -match '^[0-9]{1,5}$' } | ForEach-Object { [int]$_ })
    $ports = @($vpsPorts + $listening | Where-Object { $_ -ge 1 -and $_ -le 65535 } | Sort-Object -Unique)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($f in '4', '6') {
        if (-not $vpsAddress[$f]) { $part.Vps[$f] = 'no address' }
        elseif (-not $pcAddress[$f]) { $part.Vps[$f] = "this PC has no IPv$f to probe from" }
        else {
            $probe = & $machine.TcpProbe $vpsAddress[$f] $ports 4000
            $part.Vps[$f] = @{ Probed = $ports.Count; Open = @($ports | Where-Object { $probe[$_] -ne 'closed' }) }
        }
        if (-not $pcAddress[$f]) { $part.Pc[$f] = 'no address' }
        elseif (-not $vpsAddress[$f]) { $part.Pc[$f] = "the VPS has no IPv$f to probe from" }
        else {
            foreach ($p in $pcPorts) { $lines.Add("$($pcAddress[$f]) $p") }
            $part.Pc[$f] = @{ Probed = $pcPorts.Count; Open = @() }
        }
    }
    if ($lines.Count) {
        $probe = Invoke-VpsStep @('probe') $lines.ToArray()
        foreach ($f in '4', '6') {
            if ($part.Pc[$f] -isnot [Collections.IDictionary]) { continue }
            $part.Pc[$f]['Open'] = @($pcPorts | Where-Object { $probe.Facts["probe_${f}_$_"] -ne 'closed' })
        }
    }
    $part['Ok'] = (Test-SideClosed $part.Vps) -and (Test-SideClosed $part.Pc)
    $result.Steps.Add("from outside the tailnet, the VPS: $(Format-Side $part.Vps)")
    $result.Steps.Add("from outside the tailnet, this PC (from the VPS): $(Format-Side $part.Pc)")
    foreach ($side in @(@{ Name = 'the VPS'; Data = $part.Vps }, @{ Name = 'this PC'; Data = $part.Pc })) {
        if ($side.Data['4'] -isnot [Collections.IDictionary]) { $result.Problems.Add("$($side.Name) was not probed over IPv4 from outside ($($side.Data['4'])) (C-52)") }
        foreach ($f in '4', '6') {
            $s = $side.Data[$f]
            if ($s -is [Collections.IDictionary] -and (Get-List $s['Open']).Count) {
                $result.Problems.Add("from outside the tailnet, $($side.Name) answers on TCP $((Get-List $s['Open']) -join ', ') over IPv$f (C-52). Close each: a published Docker port, a firewall rule or a router forward")
            }
        }
    }
}

# ---------- 10c: the VPS tests ----------

function Invoke-VpsRestart {
    $part = @{ Ok = $false; Tested = (Get-Now).ToString('o') }
    $result.Data['VpsRestart'] = $part
    $before = Invoke-VpsStep @('boot')
    $old = [string]$before.Facts['boot_id']
    if (-not $old) { $part['Why'] = 'the VPS did not report its boot id'; $result.Problems.Add($part['Why']); return }
    $reboot = Invoke-VpsStep @('reboot')
    if ($reboot.ExitCode -ne 0) { $part['Why'] = 'the restart was not scheduled'; return }
    & $Context.Say 'the VPS is restarting; waiting up to ten minutes for it'
    & $machine.Wait 30
    $after = $null
    for ($i = 0; $i -lt 40; $i++) {
        $quiet = New-StageResult
        $b = Invoke-VpsStep @('boot') -Into $quiet
        if ($b.Facts['boot_id'] -and $b.Facts['boot_id'] -ne $old -and $b.Facts['docker_active'] -eq 'yes') { $after = $b.Facts; break }
        & $machine.Wait 15
    }
    if (-not $after) { $part['Why'] = 'it did not come back with Docker running within ten minutes'; $result.Problems.Add("VPS restart: $($part['Why'])"); return }
    $part['GuardFirst'] = [string]$after['guard_first']
    if ($part['GuardFirst'] -ne 'yes') {
        $part['Why'] = "the guard did not start before Docker ($($part['GuardFirst']))"
        $result.Problems.Add("VPS restart: $($part['Why']); Docker must need the guard (C-20, C-43). Stage 5 sets it up")
        return
    }
    $address = Get-VpsAddress
    if (-not $address) { $part['Why'] = 'the tailnet addresses could not be read'; return }
    & $Context.Say 'waiting up to ten minutes for the VPS stack to come back healthy'
    for ($i = 0; $i -lt 40; $i++) {
        $quiet = New-StageResult
        $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path (Join-Path $repo 'linux/stages/05-services.sh') -Arguments @('check', $account, $address)
        $f = Add-VpsOutput -Result $quiet -Run $run -Label '05-services.sh'
        if ((Test-AllUp $f['egress-running']) -and (Test-AllUp $f['kokoro-running']) -and $f['gluetun-health'] -eq 'healthy') { break }
        & $machine.Wait 15
    }
    $five = Invoke-OtherStage 5 'Check'
    if ($five.Status -ne 'passed') {
        $part['Why'] = "Stage 5's checkpoint does not pass: $(Get-Why $five)"
        $result.Problems.Add("after the VPS restart, $($part['Why'])")
        return
    }
    $part['Ok'] = $true
    $result.Steps.Add('VPS restart: the guard started before Docker, and Stage 5''s checkpoint passes again')
}

function Invoke-GuardBreak {
    $part = @{ Ok = $false; Tested = (Get-Now).ToString('o') }
    $result.Data['GuardBreak'] = $part
    $run = Invoke-VpsStep @('guard-break', $account)
    $f = $run.Facts
    foreach ($k in 'docker_refused', 'guard_active', 'guard_loaded', 'docker_active', 'egress_running', 'kokoro_running', 'gluetun_health') {
        $part[$k] = if ($f.ContainsKey($k)) { [string]$f[$k] } else { 'not reported' }
    }
    if ($run.ExitCode -ne 0) { $part['Why'] = 'the test did not run'; return }
    if ($part['docker_refused'] -ne 'yes') {
        $part['Why'] = 'Docker started with the guard broken'
        $result.Problems.Add('guard test: Docker started while the guard was broken, so it does not need it (C-20, C-43); Stage 5 sets Requires= and After= on Docker')
    }
    $back = $part['guard_active'] -eq 'yes' -and $part['guard_loaded'] -eq 'yes' -and $part['docker_active'] -eq 'yes' -and
    (Test-AllUp $part['egress_running']) -and (Test-AllUp $part['kokoro_running']) -and $part['gluetun_health'] -eq 'healthy'
    if (-not $back) {
        $part['Why'] = 'the stack did not all come back'
        $result.Problems.Add("guard test: afterwards the guard is $($part['guard_active']) (loaded $($part['guard_loaded'])), Docker $($part['docker_active']), egress $($part['egress_running']), Kokoro $($part['kokoro_running']), gluetun $($part['gluetun_health']). Run -Stage 5 -Execute to bring it back")
    }
    $part['Ok'] = $part['docker_refused'] -eq 'yes' -and $back
    if ($part['Ok']) { $result.Steps.Add('guard test: Docker refused to start without the guard, then everything came back') }
}

function Invoke-KillSwitch {
    $part = @{ Ok = $false; Tested = (Get-Now).ToString('o') }
    $result.Data['KillSwitch'] = $part
    $test = @([IO.File]::ReadAllText((Join-Path $repo 'linux/stages/10-killswitch.py')) -replace "`r", '' -split "`n")
    & $Context.Say 'kill-switch test: the tunnel is stopped for a few minutes'
    $run = Invoke-VpsStep @('kill-switch') $test
    $f = $run.Facts
    $leaks = [Collections.Generic.List[string]]::new()
    foreach ($k in $killSwitch.Keys) {
        $have = if ($f.ContainsKey("ks_$k")) { [string]$f["ks_$k"] } else { 'not reported' }
        $part[$k] = $have
        $want = $killSwitch[$k]
        $ok = if ($want -eq 'not:ok') { $have -and $have -ne 'ok' -and $have -ne 'not reported' } else { $have -eq $want }
        if (-not $ok) { $leaks.Add("$k=$have") }
    }
    if ($run.ExitCode -ne 0) { $part['Why'] = 'the test did not run to the end'; return }
    $part['Leaks'] = @($leaks)
    if ($part['recovered'] -ne 'yes') { $result.Problems.Add('kill-switch test: the tunnel did not come back within two minutes; on the VPS run: docker restart vps-web-gluetun, then -Stage 5 -Execute') }
    if ($part['still_stopped'] -ne 'yes') { $result.Problems.Add('kill-switch test: gluetun started the tunnel again by itself during the test, so the probes prove nothing; run the stage again') }
    $leaked = @($leaks | Where-Object { $_ -notmatch '^(still_stopped|recovered)=' })
    if ($leaked.Count) { $result.Problems.Add("kill-switch test: with the tunnel stopped these did not fail closed (C-21): $($leaked -join ', ')") }
    $part['Ok'] = -not $leaks.Count
    if ($part['Ok']) { $result.Steps.Add("kill-switch test: all $($killSwitch.Count - 2) probes failed closed with the tunnel stopped, and it recovered") }
}

function Invoke-VpsTest {
    $parts = 'VpsRestart', 'GuardBreak', 'KillSwitch'
    if (-not @($parts | Where-Object { -not (Test-Passed $result.Data[$_]) }).Count) { return }
    $two = Invoke-OtherStage 2 'Check'
    if ($two.Status -ne 'passed') {
        $result.Problems.Add("the VPS tests run only on the rebuilt VPS, and Stage 2's checkpoint (the host key recorded for it) does not pass now: $(Get-Why $two). Nothing on the VPS was changed")
        return
    }
    if (-not (Test-Passed $result.Data['VpsRestart'])) { Invoke-VpsRestart }
    if ((Test-Passed $result.Data['VpsRestart']) -and -not (Test-Passed $result.Data['GuardBreak'])) { Invoke-GuardBreak }
    if ((Test-Passed $result.Data['GuardBreak']) -and -not (Test-Passed $result.Data['KillSwitch'])) { Invoke-KillSwitch }
}

# ---------- 10d: the monthly reminder ----------

function Get-Account {
    $a = & $machine.Account
    if ($a.Console -and $a.Console -ne $a.Id) {
        $result.Problems.Add("this window runs as $($a.Id), but $($a.Console) is signed in; run the controller from that account, so the reminder task is its own")
        return $null
    }
    return $a
}

function Expand-AccountText([string]$Text, $Account) {
    # The account's SID, name and profile folder in place of the
    # placeholders, escaped for XML.
    $values = @{ '{{USER_SID}}' = $Account.Sid; '{{USER_ID}}' = $Account.Id; '{{USER_PROFILE}}' = $Account.Profile }
    foreach ($k in $values.Keys) { $Text = $Text.Replace($k, [Security.SecurityElement]::Escape([string]$values[$k])) }
    return $Text
}

function Copy-ReminderScript {
    # Send-BackupReminder.ps1 next to NtfyCore.psm1; $true when it is there.
    $source = Join-Path $repo 'windows/reminder/Send-BackupReminder.ps1'
    $check = @(& $Context.PathCheck -Path '_support/scripts/scheduled/Send-BackupReminder.ps1' -Root $stackRoot -Relative -Detailed)[0]
    if (-not $check.IsValid) { $result.Problems.Add("reminder: $($check.Reason)"); return $false }
    $dest = $check.FullPath
    $want = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $want) { return $true }
        if (-not (& $Context.IsOwned $dest)) { $result.Problems.Add("reminder: a different $dest is already there; move it away and run again"); return $false }
        $null = & $Context.RemoveOwned $dest
    }
    elseif (Test-Path -LiteralPath $dest) { $result.Problems.Add("reminder: $dest is not a file; move it away and run again"); return $false }
    $temp = "$dest.cria-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    [IO.File]::Copy($source, $temp, $false)
    [IO.File]::Move($temp, $dest, $false)
    & $Context.Own 'file' $dest $stackRoot 'keep'
    $result.Steps.Add("copied Send-BackupReminder.ps1 into $([IO.Path]::GetDirectoryName($dest))")
    return $true
}

function Wait-ReminderLog([DateTime]$Since) {
    # 'yes' once ntfy-monitor.log says ntfy took it, 'failed' when it says it
    # did not, 'no' after a minute of neither.
    $log = Join-Path $stackRoot 'logs/ntfy-monitor.log'
    $title = [regex]::Escape($reminderTitle)
    for ($i = 0; $i -lt 12; $i++) {
        $sent = Read-LogTime $log ('^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] SENT pc-info p3 \| ' + $title + '$')
        if ($sent -and $sent -ge $Since) { return 'yes' }
        $failed = Read-LogTime $log ('^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] FAIL publish failed \(' + $title + '\)')
        if ($failed -and $failed -ge $Since) { return 'failed' }
        & $machine.Wait 5
    }
    return 'no'
}

function Install-Reminder {
    $part = if ($result.Data['Reminder'] -is [Collections.IDictionary]) { $result.Data['Reminder'] } else { @{} }
    $part['Ok'] = $false
    $result.Data['Reminder'] = $part
    $needs = @((Join-Path $stackRoot 'run-hidden.vbs'), (Join-Path $stackRoot '_support/scripts/scheduled/NtfyCore.psm1'))
    $missing = @($needs | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count) { $result.Problems.Add("reminder: $($missing -join ' and ') missing; Stage 4 places the stack's files"); return }
    $a = Get-Account
    if (-not $a) { return }
    if (-not (Copy-ReminderScript)) { return }
    if (-not (& $machine.TaskState $reminderTask)) {
        $xml = Expand-AccountText ([IO.File]::ReadAllText((Join-Path $repo "windows/reminder/$reminderTask.xml"))) $a
        $xml = [regex]::Replace($xml, '^(\s*<\?xml[^>]*encoding=")UTF-8(")', '${1}UTF-16$2')
        try { & $machine.RegisterTask $reminderTask $xml }
        catch { $result.Problems.Add("reminder: Task Scheduler refused $reminderTask ($($_.Exception.Message))"); return }
        $result.Steps.Add("registered ${reminderTask}: 10:00 on the 1st of each month, or at the next sign-in after")
    }
    if ($part['Sent'] -ne 'yes') {
        $since = (Get-Now).AddSeconds(-2)
        try { & $machine.StartTask $reminderTask }
        catch { $result.Problems.Add("reminder: $reminderTask did not start ($($_.Exception.Message))"); return }
        $part['Sent'] = Wait-ReminderLog $since
        switch ($part['Sent']) {
            'yes' { $result.Steps.Add("started $reminderTask once; ntfy took '$reminderTitle'") }
            'failed' { $result.Problems.Add("reminder: ntfy refused '$reminderTitle' (logs\ntfy-monitor.log says why); fix ntfy and run again") }
            default { $result.Problems.Add("reminder: $reminderTask started, but logs\ntfy-monitor.log shows no '$reminderTitle' within a minute") }
        }
    }
    $part['Ok'] = $part['Sent'] -eq 'yes'
}

# ---------- 10e: the first backup and its round trip ----------

function Get-HelperImage {
    $images = Get-Content -LiteralPath (Join-Path $repo 'manifests/images.json') -Raw | ConvertFrom-Json -AsHashtable
    $relay = @($images['pc'] | Where-Object { $_['container'] -eq 'web-vps-relay' })[0]
    if ($relay -and "$($relay['image'])" -match '@sha256:[0-9a-f]{64}$') { return $relay['image'] }
    return $null
}

function Invoke-Backup {
    $part = @{ Ok = $false; Taken = (Get-Now).ToString('o') }
    $result.Data['Backup'] = $part
    $helper = Get-HelperImage
    if (-not $helper) { $result.Problems.Add('backup: manifests/images.json gives web-vps-relay no pinned image to use as the volume helper'); return }
    $seed = @(& $Context.PathCheck -Path 'owui-seed-new' -Root $Context.StateRoot -Relative -Detailed)[0]
    if (-not $seed.IsValid) { $result.Problems.Add("backup: $($seed.Reason)"); return }
    & $Context.Say 'collecting the secrets bundle and exporting the OWUI seed (a few minutes)'
    $collector = $Context.Tools['CollectSecrets']
    $c = & $collector -Execute -StagingRoot $Context.StagingRoot -SshHost $alias -SeedOut $seed.FullPath -HelperImage $helper `
        -DockerCommand $machine.Commands['docker'] -SshCommand $machine.Commands['ssh'] -TailscaleCommand $machine.Commands['tailscale'] -PassThru
    $c = @($c | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['IsValid'] }) | Select-Object -Last 1
    if ($null -eq $c) { $result.Problems.Add('backup: the collector returned no result'); return }
    if ($c.RunFolder -and (Test-Path -LiteralPath $c.RunFolder -PathType Container)) {
        # Plaintext, whether or not the run passed: Stage 11 removes it.
        & $Context.Own 'folder' $c.RunFolder $Context.StagingRoot 'keep' -Plaintext
    }
    foreach ($w in @($c.Warnings)) { $result.Warnings.Add("collector: $w") }
    if (-not $c.IsValid) {
        foreach ($p in @($c.Problems)) { $result.Problems.Add("collector: $p") }
        if (-not @($c.Problems).Count) { $result.Problems.Add('backup: the collector failed') }
        return
    }
    $part['Zip'] = [IO.Path]::GetFileName([string]$c.ZipPath)
    $part['Sha256'] = ([string]$c.ZipSha256).ToLowerInvariant()
    $part['RunFolder'] = [string]$c.RunFolder
    $part['SeedOut'] = $seed.FullPath
    $part['SeedFiles'] = [int]$c.SeedFiles
    $round = @(& $Context.PathCheck -Path 'roundtrip' -Root $Context.StagingRoot -Relative -Detailed)[0]
    if (-not $round.IsValid) { $result.Problems.Add("backup: $($round.Reason)"); return }
    if (-not (Test-Path -LiteralPath $round.FullPath)) {
        Initialize-ProtectedFolder -Path $round.FullPath
        & $Context.Own 'folder' $round.FullPath $Context.StagingRoot 'keep' -Plaintext
    }
    elseif (-not (& $Context.IsOwned $round.FullPath)) { $result.Problems.Add("backup: $($round.FullPath) is already there and this controller did not create it; move it away and run again"); return }
    $part['RoundTripFolder'] = $round.FullPath
    $part['Ok'] = $true
    $result.Steps.Add("first backup: $($part['Zip']) (SHA-256 $($part['Sha256'])); the OWUI seed ($($part['SeedFiles']) files) in $($part['SeedOut'])")
}

function Test-RoundTrip {
    $b = $result.Data['Backup']
    $folder = [string]$b['RoundTripFolder']
    $zips = @(Get-ChildItem -LiteralPath $folder -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    if (-not $zips.Count) { return }
    $part = @{ Ok = $false; Tested = (Get-Now).ToString('o') }
    $result.Data['RoundTrip'] = $part
    if ($zips.Count -gt 1) { $result.Problems.Add("round trip: $folder holds $($zips.Count) ZIP files; leave only the one downloaded from Bitwarden"); return }
    $sha = (Get-FileHash -LiteralPath $zips[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $part['Ok'] = $sha -eq $b['Sha256']
    if ($part['Ok']) { $result.Steps.Add('round trip: the ZIP downloaded from Bitwarden matches the bundle (SHA-256)') }
    else { $result.Problems.Add("round trip: the downloaded ZIP's SHA-256 is $sha, not the bundle's $($b['Sha256']); download it from Bitwarden again into $folder, replacing it") }
}

# ---------- 10f: the second run ----------

function Test-ReadyForRerun {
    foreach ($p in 'PcRestart', 'Outside', 'VpsRestart', 'GuardBreak', 'KillSwitch', 'Reminder', 'Backup', 'RoundTrip') { if (-not (Test-Passed $result.Data[$p])) { return $false } }
    foreach ($id in $userIds) { if ($Context.Accepted -notcontains $id) { return $false } }
    return -not (Get-Interrupted).Open.Count
}

function Invoke-Rerun {
    & $Context.Say 'the second run: every checkpoint from 1 to 9 again'
    $results = [ordered]@{}
    foreach ($n in 1..9) {
        $r = Invoke-OtherStage $n 'Check'
        $results["$n"] = if ($r.Status -eq 'passed') { 'passed' } else { Get-Why $r }
        if ($results["$n"] -ne 'passed') { $result.Problems.Add("second run: Stage $n's checkpoint does not pass: $($results["$n"])") }
    }
    $ok = -not @($results.Values | Where-Object { $_ -ne 'passed' }).Count
    $result.Data['Rerun'] = @{ Ok = $ok; Results = $results; Tested = (Get-Now).ToString('o') }
    if ($ok) { $result.Steps.Add('second run: checkpoints 1 to 9 all pass, nothing changed') }
}

# ---------- Check ----------

function Get-PartActual($Part, [string]$Passed) {
    if ($null -eq $Part) { return 'not run' }
    if ($Part['Ok']) { return $Passed }
    if ($Part['Why']) { return [string]$Part['Why'] }
    return 'failed'
}

function Invoke-Checkpoint {
    $flag = @{ Failed = $false }
    $asks = [Collections.Generic.List[object]]::new()
    $row = {
        param([string]$What, [string]$Expected, [string]$Actual, [bool]$Ok)
        Add-StageCheck $result $What $Expected $Actual $Ok
        if (-not $Ok) { $flag.Failed = $true }
    }

    # 10a
    $pc = $result.Data['PcRestart']
    if ($pc -isnot [Collections.IDictionary]) { & $row 'the PC restart (10a)' 'tested' 'not tested yet' $false }
    else {
        & $row "after the restart: Stage 8's checkpoint, pagefile in effect" 'passed' ([string]$pc['Stage8']) ($pc['Stage8'] -eq 'passed')
        $s9 = Get-Part $pc 'Stage9'
        $t = [int]$s9['Total']; $p = [int]$s9['Passed']
        $bad = Get-List $s9['Failed']
        & $row "after the restart: Stage 9's auto rows" "$t of $t" "$p of $t$(if ($bad.Count) { "; failed: $($bad -join ', ')" })" ($t -gt 0 -and $p -eq $t)
        $beats = Get-Part $pc 'Heartbeats'
        $quiet = @($beats.Keys | Where-Object { $beats[$_] -ne 'ok' })
        $n = $beats.Count
        & $row 'after the restart: every scheduled task and startup item ran (C-51)' "$n of $n" "$($n - $quiet.Count) of $n$(if ($quiet.Count) { "; no sign: $($quiet -join ', ')" })" ($n -gt 0 -and -not $quiet.Count)
    }

    # 10b
    $out = $result.Data['Outside']
    if ($out -isnot [Collections.IDictionary]) { & $row 'from outside the tailnet (C-52)' 'nothing answers' 'not probed yet' $false }
    else {
        foreach ($side in @(@{ Key = 'Vps'; Name = 'the VPS' }, @{ Key = 'Pc'; Name = 'this PC' })) {
            $d = Get-Part $out $side.Key
            & $row "from outside the tailnet: $($side.Name) (C-52)" 'nothing answers' (Format-Side $d) (Test-SideClosed $d)
            if ($d['6'] -isnot [Collections.IDictionary]) { $result.Warnings.Add("$($side.Name): IPv6 not probed ($($d['6']))") }
        }
    }
    if ($Context.Accepted -notcontains 'lan-closed') {
        $asks.Add(@{ Id = 'lan-closed'; Text = ("From your phone on the home Wi-Fi with Tailscale switched off, open http://<this PC's LAN address>:3000, then :8188, :11434 and :6080 " +
                "('ipconfig' shows the address as IPv4 Address). None may load. Then run again with -Accept lan-closed.") })
    }

    # 10c
    if ($Context.Accepted -notcontains 'vps-tests') {
        $asks.Add(@{ Id = 'vps-tests'; Text = ("The VPS tests restart the rebuilt VPS, break its egress guard on purpose and stop its VPN tunnel for a few minutes; web search, " +
                'page reading and speech are down meanwhile. Run them only on the rebuilt VPS, when nothing needs it for twenty minutes: run again with -Accept vps-tests.') })
    }
    else {
        & $row 'VPS restart: the guard starts before Docker; Stage 5 passes again' 'passed' (Get-PartActual $result.Data['VpsRestart'] 'passed') (Test-Passed $result.Data['VpsRestart'])
        & $row 'guard broken on purpose: Docker refuses to start, then all returns (C-20, C-43)' 'passed' (Get-PartActual $result.Data['GuardBreak'] 'passed') (Test-Passed $result.Data['GuardBreak'])
        $ks = $result.Data['KillSwitch']
        $ksActual = if ($ks -is [Collections.IDictionary] -and (Get-List $ks['Leaks']).Count) { "did not fail closed: $((Get-List $ks['Leaks']) -join ', ')" } else { Get-PartActual $ks 'failed closed, then recovered' }
        & $row 'kill switch: tunnel stopped, everything fails closed, then recovers (C-21)' 'failed closed, then recovered' $ksActual (Test-Passed $ks)
    }

    # 10d
    $rem = $result.Data['Reminder']
    & $row "monthly reminder: $reminderTask registered, ntfy took it (C-47)" 'yes' $(if (Test-Passed $rem) { 'yes' } elseif ($rem -is [Collections.IDictionary]) { "not sent ($($rem['Sent']))" } else { 'not set up' }) (Test-Passed $rem)
    if ((Test-Passed $rem) -and $Context.Accepted -notcontains 'reminder') {
        $asks.Add(@{ Id = 'reminder'; Text = "A notification '$reminderTitle' went to pc-info. When it is on your phone, run again with -Accept reminder." })
    }

    # 10e
    $b = $result.Data['Backup']
    if ($b -isnot [Collections.IDictionary]) {
        if (Test-Passed $pc) { & $row 'first backup: bundle collected, seed exported' 'done' 'not run' $false }
    }
    else {
        & $row 'first backup: bundle collected, seed exported' 'done' $(if (Test-Passed $b) { "$($b['Zip']), $($b['SeedFiles']) seed files" } else { 'failed' }) (Test-Passed $b)
        $rt = $result.Data['RoundTrip']
        if (Test-Passed $rt) { & $row 'Bitwarden round trip: hashes match' 'match' 'match' $true }
        elseif ($rt -is [Collections.IDictionary]) { & $row 'Bitwarden round trip: hashes match' 'match' 'no match' $false }
        elseif (Test-Passed $b) {
            $asks.Add(@{ Id = $null; Text = ("Upload $($b['RunFolder'])\$($b['Zip']) to the bundle's Bitwarden item (replacing the old attachment) and put its SHA-256 in the notes: " +
                    "$($b['Sha256']). Then download it from Bitwarden into $($b['RoundTripFolder']) and run again; the hashes must match.") })
        }
    }

    # Interruption (optional)
    $int = Get-Interrupted
    $what = 'interrupted run, then run again: finished (C-45, optional)'
    if ($int.Open.Count) { & $row $what 'finished, or not run' "Stage $($int.Open -join ', ') interrupted and not done since" $false }
    elseif ($int.Done.Count) { & $row $what 'finished, or not run' "Stage $($int.Done -join ', ') interrupted, then done" $true }
    else {
        & $row $what 'finished, or not run' 'not run' $true
        $result.Steps.Add("optional, not run: the interruption test (C-45). To run it, run Invoke-StackRecovery.ps1 -Execute -Stage 9, press Ctrl+C once it says 'running', run the same command again until checkpoint 9 passes, then run this stage again")
    }

    # 10f
    $rr = $result.Data['Rerun']
    if ($rr -is [Collections.IDictionary]) {
        $rerun = Get-Part $rr 'Results'
        $bad = @($rerun.Keys | Where-Object { $rerun[$_] -ne 'passed' } | Sort-Object)
        & $row 'second run: checkpoints 1 to 9 pass, nothing changed' '9 of 9' "$(9 - $bad.Count) of 9$(if ($bad.Count) { "; Stage $($bad -join ', ') do not pass" })" (Test-Passed $rr)
    }
    elseif (-not $flag.Failed -and -not $asks.Count) { & $row 'second run: checkpoints 1 to 9 pass, nothing changed' '9 of 9' 'not run' $false }
    elseif (-not $flag.Failed) { $result.Steps.Add('the second run (every checkpoint from 1 to 9) comes last, once everything above is done and answered') }

    foreach ($a in $asks) { if ($a.Id) { Add-StageAsk $result $a.Text -Id $a.Id } else { Add-StageAsk $result $a.Text } }
    $ids = @($asks | Where-Object { $_.Id } | ForEach-Object { $_.Id })
    if ($ids.Count -gt 1) { $result.Steps.Add("to answer every question with an id at once: -Accept $($ids -join ',')") }
    $result.Status = if ($flag.Failed -or $result.Problems.Count) { 'failed' } elseif ($asks.Count) { 'needs-user' } else { 'passed' }
}

# ---------- main ----------

if ($Mode -eq 'Check') {
    Invoke-Checkpoint
    return $result
}

$boot = ConvertTo-Utc (& $machine.BootTime)
$before = ConvertTo-Utc $result.Data['PcBootBefore']

if ($Mode -eq 'Plan') {
    if (-not $before) { $result.Steps.Add('would record when Windows last started and ask you to restart this PC') }
    elseif ($boot -le $before.AddSeconds(30)) { $result.Steps.Add('waits for this PC to restart') }
    else {
        $todo = @(foreach ($p in 'PcRestart', 'Outside', 'VpsRestart', 'GuardBreak', 'KillSwitch', 'Reminder', 'Backup', 'RoundTrip', 'Rerun') { if (-not (Test-Passed $result.Data[$p])) { $p } })
        $result.Steps.Add("would carry on with: $(if ($todo.Count) { $todo -join ', ' } else { 'nothing; every part has passed' })")
        if ($Context.Accepted -notcontains 'vps-tests') { $result.Steps.Add('the VPS tests wait for -Accept vps-tests') }
    }
    $result.Status = 'planned'
    return $result
}

if (-not $before) {
    $result.Data['PcBootBefore'] = $boot.ToString('o')
    $result.Data['InterruptBaseline'] = Get-InterruptCount
    $result.Steps.Add('recorded when Windows last started')
    $result.Steps.Add('restart this PC now (Start > Power > Restart), sign in, wait for the desktop, then run the same command again')
    $result.Status = 'reboot'
    return $result
}
if ($boot -le $before.AddSeconds(30)) {
    $result.Steps.Add('Windows has not restarted since this stage asked; restart this PC (Start > Power > Restart), sign in, then run the same command again')
    $result.Status = 'reboot'
    return $result
}

if (-not (Test-Passed $result.Data['PcRestart'])) { Invoke-PcRestart $boot }
else { $result.Steps.Add('the PC restart passed on an earlier visit') }
if (-not (Test-Passed $result.Data['Outside'])) { Invoke-Outside }
if ($Context.Accepted -contains 'vps-tests') { Invoke-VpsTest }
if (-not (Test-Passed $result.Data['Reminder'])) { Install-Reminder }
if ((Test-Passed $result.Data['PcRestart']) -and -not (Test-Passed $result.Data['Backup'])) { Invoke-Backup }
if ((Test-Passed $result.Data['Backup']) -and -not (Test-Passed $result.Data['RoundTrip'])) { Test-RoundTrip }
if (-not (Test-Passed $result.Data['Rerun']) -and (Test-ReadyForRerun)) { Invoke-Rerun }

if ($result.Problems.Count) { $result.Status = 'failed' }
return $result
