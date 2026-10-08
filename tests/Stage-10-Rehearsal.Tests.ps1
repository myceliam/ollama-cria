#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 10 (windows/stages/10-rehearsal.ps1) on a fake PC that has just
# restarted. The other stages are tests/fakes/fake-stage.ps1, the collector
# is tests/fakes/fake-collect.ps1, the VPS answers from $global:CriaVps and
# its scripts are decoded here (tests/Linux-Stages.Tests.ps1 and
# tests/python/test_killswitch.py run the scripts themselves). Public
# addresses are documentation addresses.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')
    $script:Restarted = [DateTime]::new(2026, 10, 7, 9, 0, 0, [DateTimeKind]::Utc)
    $script:Addresses = @('203.0.113.10', '2001:db8::10', '198.51.100.20', '2001:db8::20')

    function Write-Text([string]$Path, [string]$Text) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, $Text)
    }

    function Add-Line([string]$Path, [string]$Line) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::AppendAllText($Path, "$Line`r`n")
    }

    function Get-Stamp([DateTime]$Utc) { $Utc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }

    function Set-Heartbeat([DateTime]$At, [string[]]$Skip = @()) {
        # Every sign of life the stage looks for, written at -At.
        $s = Get-Stamp $At
        $logs = Join-Path $script:Stack 'logs'
        if ('OWUI-Stack-Startup' -notin $Skip) {
            $p = Join-Path $logs 'start-stack-20261007-090100.log'
            Write-Text $p 'transcript'
            (Get-Item -LiteralPath $p).LastWriteTimeUtc = $At
        }
        if ('OWUI-mcpo-Watchdog' -notin $Skip) { Add-Line (Join-Path $logs 'mcpo-watchdog.log') "$s  stack: tailscale-service=ok owui=ok" }
        if ('OWUI-ntfy-Fast' -notin $Skip) { Add-Line (Join-Path $logs 'ntfy-monitor.log') "[$s] INFO === Watch-Fast started (pid 4242) ===" }
        if ('OWUI-ntfy-PcHealth' -notin $Skip) { Add-Line (Join-Path $logs 'ntfy-monitor.log') "[$s] INFO === Watch-PcHealth run ===" }
        if ('OWUI ComfyUI AutoFree.lnk' -notin $Skip) { Add-Line (Join-Path $logs 'autofree.log') "$s  INFO  watchdog started (idle=120s poll=10s minheld=512MB pid=99)" }
        if ('Tailscale-Status-Feed' -notin $Skip) {
            $p = Join-Path $script:Dashboard 'data/tailscale-status.json'
            Write-Text $p '{}'
            (Get-Item -LiteralPath $p).LastWriteTimeUtc = $At
        }
        foreach ($t in 'OWUI-Windows-PowerShell-Tool', 'LibreHardwareMonitor') {
            if ($t -notin $Skip) { $global:CriaFake.TaskInfo[$t] = @{ State = 'Running'; LastRunTime = $At; LastTaskResult = 267009 } }
        }
    }

    function Get-Restarted {
        # What the first visit recorded, an hour before the restart.
        $base = @{}
        foreach ($n in 1..9) { $base["$n"] = 0 }
        @{ PcBootBefore = $script:Restarted.AddHours(-1).ToString('o'); InterruptBaseline = $base }
    }

    function Get-PassedData {
        # Every part passed, as state.json would hold it.
        $d = Get-Restarted
        $closed = @{ '4' = @{ Probed = 20; Open = @() }; '6' = @{ Probed = 20; Open = @() } }
        $d.PcRestart = @{ Ok = $true; Stage8 = 'passed'; Stage9 = @{ Total = 3; Passed = 3; Failed = @() }; Heartbeats = @{ 'OWUI-ntfy-Fast' = 'ok' } }
        $d.Outside = @{ Ok = $true; Vps = $closed; Pc = $closed }
        $d.VpsRestart = @{ Ok = $true }
        $d.GuardBreak = @{ Ok = $true }
        $d.KillSwitch = @{ Ok = $true; Leaks = @() }
        $d.Reminder = @{ Ok = $true; Sent = 'yes' }
        $d.Backup = @{ Ok = $true; Zip = 'stack-secrets-x.zip'; Sha256 = 'a' * 64; SeedFiles = 12; RunFolder = 'run'; RoundTripFolder = 'roundtrip' }
        $d.RoundTrip = @{ Ok = $true }
        return (ConvertTo-Json -InputObject $d -Depth 10 | ConvertFrom-Json -AsHashtable)
    }

    function New-Stage10 {
        param(
            [string]$Mode = 'Run',
            [string[]]$Accepted = @(),
            [hashtable]$Data = (Get-Restarted),
            [string[]]$Quiet = @()
        )
        Reset-Fake
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $c = New-TestContext -Stage 10 -Mode $Mode -Base $base -Accepted $Accepted -Data $Data
        $stages = Join-Path $base 'stages'
        $null = New-Item -ItemType Directory -Path $stages
        foreach ($n in 1..9) { Copy-Item -LiteralPath (Join-Path $script:RealRepo 'tests/fakes/fake-stage.ps1') -Destination (Join-Path $stages ('{0:D2}-fake.ps1' -f $n)) }
        $c.StageRoot = $stages
        $c.Tools.CollectSecrets = Join-Path $script:RealRepo 'tests/fakes/fake-collect.ps1'
        foreach ($n in 1..9) { $c.State['stages']["$n"] = @{ status = 'done'; attempts = 1; accepted = @(); data = @{}; interruptions = 0 } }
        $global:CriaStage = @{ '9' = @{ Data = @{ Results = @{ 'ollama-models' = @{ ok = $true; group = 1; owner = 3; actual = 'passed' } } } } }
        $global:CriaStageCalls = [Collections.Generic.List[string]]::new()
        $global:CriaStageSeen = @{}
        $global:CriaCollect = @{ Calls = [Collections.Generic.List[object]]::new(); Fail = $null }

        $script:Stack = $c.Topology['roots']['stack']['path']
        $script:Dashboard = $c.Topology['roots']['dashboard']['path']
        Write-Text (Join-Path $script:Stack 'run-hidden.vbs') "' hidden`r`n"
        Write-Text (Join-Path $script:Stack '_support/scripts/scheduled/NtfyCore.psm1') "# ntfy`r`n"
        Initialize-ProtectedFolder -Path $c.StagingRoot

        $global:CriaFake.Boot = $script:Restarted
        $global:CriaFake.Status = { param($Uri) if ($Uri -like '*:8188/*') { 200 } else { 0 } }
        Set-Heartbeat $script:Restarted.AddMinutes(2) -Skip $Quiet

        # The reminder task, when started, logs what ntfy did:
        # $global:CriaReminder is 'SENT', 'FAIL' or anything else for nothing.
        $global:CriaReminder = 'SENT'
        $log = Join-Path $script:Stack 'logs/ntfy-monitor.log'
        $c.Machine.StartTask = {
            param($Name)
            $global:CriaCalls.Add("run-task $Name")
            $global:CriaFake.Tasks[$Name] = 'Running'
            $s = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
            switch ($global:CriaReminder) {
                'SENT' { [IO.File]::AppendAllText($log, "[$s] SENT pc-info p3 | Monthly backup check`r`n") }
                'FAIL' { [IO.File]::AppendAllText($log, "[$s] FAIL publish failed (Monthly backup check): refused`r`n") }
            }
        }.GetNewClosure()

        $global:CriaVps = @{
            BootId   = '1b4e28ba-2fa1-11d2-883f-0016d3cca427'
            Boot     = @{ guard_first = 'yes'; guard_active = 'yes'; docker_active = 'yes' }
            Guard    = [ordered]@{ docker_refused = 'yes'; guard_active = 'yes'; guard_loaded = 'yes'; docker_active = 'yes'; egress_running = '6/6'; kokoro_running = '1/1'; gluetun_health = 'healthy' }
            Kill     = [ordered]@{
                ks_before_tcp4 = 'connected'; ks_before_dns = 'resolved'; ks_search = 'network_error'; ks_read = 'transport_error'; ks_reader = 'blocked'
                ks_searxng = 'none'; ks_proxy_8888 = 'blocked'; ks_proxy_8889 = 'blocked'; ks_tcp4 = 'blocked'; ks_tcp6 = 'blocked'
                ks_dns_new_name = 'no-address'; ks_dns_plain_1 = 'no-answer'; ks_dns_plain_2 = 'no-answer'; ks_still_stopped = 'yes'; ks_recovered = 'yes'
            }
            Vps4     = $script:Addresses[0]
            Vps6     = $script:Addresses[1]
            Pc4      = $script:Addresses[2]
            Pc6      = $script:Addresses[3]
            Ports    = '22,51820'
            Status   = '{"Self":{"Online":true},"ExitNodeStatus":null}'
            VpsOpen  = @()
            PcOpen   = @()
            Probed   = [Collections.Generic.List[string]]::new()
            Input    = @{}
        }
        $global:CriaFake.Vps = {
            param($Call, $InputLines)
            $v = $global:CriaVps
            $facts = { param($Table) New-ExecResult 0 @($Table.Keys | ForEach-Object { "FACT $_ $($Table[$_])" }) }
            if ($Call.Name -eq '05-services.sh') {
                return (& $facts ([ordered]@{ 'egress-running' = '6/6'; 'kokoro-running' = '1/1'; 'gluetun-health' = 'healthy' }))
            }
            if ($Call.Name -ne '10-vps.sh') { return New-ExecResult 1 @("FAIL unexpected script $($Call.Name)") }
            $mode = $Call.Arguments[0]
            $v.Input[$mode] = @($InputLines)
            switch ($mode) {
                'boot' { return (& $facts ([ordered]@{ boot_id = $v.BootId } + $v.Boot)) }
                'reboot' { $v.BootId = '6fa459ea-ee8a-3ca4-894e-db77e160355e'; return New-ExecResult 0 @('STEP the VPS restarts in 5 seconds') }
                'guard-break' { return (& $facts $v.Guard) }
                'kill-switch' { return (& $facts $v.Kill) }
                'public-ip' { return (& $facts ([ordered]@{ public_ipv4 = $v.Vps4; public_ipv6 = $v.Vps6; tcp_ports = $v.Ports })) }
                'probe' {
                    $out = foreach ($l in $InputLines) {
                        $a, $p = $l -split ' '
                        $f = if ($a.Contains(':')) { '6' } else { '4' }
                        "FACT probe_${f}_$p $(if ("$f/$p" -in $v.PcOpen) { 'open' } else { 'closed' })"
                    }
                    return New-ExecResult 0 @($out)
                }
            }
            return New-ExecResult 1 @('FAIL usage')
        }
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            if ($Name -eq 'tailscale') { return New-ExecResult 0 @($global:CriaVps.Status) }
            if ($Name -ne 'curl') { return New-ExecResult 0 @() }
            $a = if ($Arguments[0] -eq '-4') { $global:CriaVps.Pc4 } else { $global:CriaVps.Pc6 }
            if (-not $a) { return New-ExecResult 6 @() }
            return New-ExecResult 0 @($a)
        }
        $global:CriaFake.Tcp = {
            param($Address, $Ports)
            $global:CriaVps.Probed.Add("$Address $(@($Ports) -join ',')")
            $o = @{}
            foreach ($p in $Ports) { $o[$p] = if ("$p" -in $global:CriaVps.VpsOpen) { 'open' } else { 'closed' } }
            $o
        }
        return $c
    }

    function Invoke-Visit([hashtable]$Context) {
        # One -Execute as the controller runs it: Run, the data kept, then
        # Check when Run is done.
        $run = Invoke-Stage '10-rehearsal.ps1' $Context
        foreach ($k in @($run.Data.Keys)) { $Context.Data[$k] = $run.Data[$k] }
        $check = if ($run.Status -eq 'done') { Invoke-Stage '10-rehearsal.ps1' (Copy-Context $Context 'Check') } else { $null }
        return @{ Run = $run; Check = $check }
    }

    function Get-Call([string]$Pattern) { @($global:CriaCalls | Where-Object { $_ -like $Pattern }) }

    function Get-Text($Result) {
        # Everything a result would put in the evidence.
        (@($Result.Steps) + @($Result.Problems) + @($Result.Warnings) + @($Result.Asks | ForEach-Object Text) +
            @($Result.Checks | ForEach-Object { "$($_.What) $($_.Expected) $($_.Actual)" }) + @(ConvertTo-Json -InputObject $Result.Data -Depth 20)) -join "`n"
    }
}

AfterAll {
    Remove-Variable -Name CriaFake, CriaCalls, CriaStage, CriaStageCalls, CriaStageSeen, CriaCollect, CriaVps, CriaReminder, CriaLive -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 10: the PC restart' {
    It 'records when Windows started and the interruptions on the first visit, then asks for a restart' {
        $c = New-Stage10 -Data @{}
        $c.State['stages']['7']['interruptions'] = 2
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Status | Should -Be 'reboot'
        (ConvertTo-Json $r.Data['PcBootBefore']) | Should -Match '2026-10-07T09:00:00'
        $r.Data['InterruptBaseline']['7'] | Should -Be 2
        $r.Steps -join ' ' | Should -Match 'restart this PC'
        $global:CriaStageCalls.Count | Should -Be 0
        (Get-Call 'vps *').Count | Should -Be 0
    }

    It 'asks again until Windows has restarted' {
        $c = New-Stage10 -Data @{ PcBootBefore = $script:Restarted.ToString('o') }
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Status | Should -Be 'reboot'
        $r.Steps -join ' ' | Should -Match 'has not restarted'
        $global:CriaStageCalls.Count | Should -Be 0
    }

    It 'checks Stage 8 again, reruns Stage 9 and finds a sign of life from every task, then asks for the rest' {
        $c = New-Stage10
        $v = Invoke-Visit $c
        $v.Run.Problems | Should -BeNullOrEmpty
        $v.Run.Status | Should -Be 'done'
        $global:CriaStageCalls | Should -Contain '8:Check'
        $global:CriaStageCalls | Should -Contain '9:Run'
        $c.Data['PcRestart']['Ok'] | Should -BeTrue
        $c.Data['PcRestart']['Heartbeats'].Count | Should -Be 9
        @($c.Data['PcRestart']['Heartbeats'].Values | Where-Object { $_ -ne 'ok' }) | Should -BeNullOrEmpty
        $v.Check.Status | Should -Be 'needs-user'
        @($v.Check.Asks | Where-Object Id | ForEach-Object Id) | Sort-Object | Should -Be @('lan-closed', 'reminder', 'vps-tests')
        @($v.Check.Asks | Where-Object { -not $_.Id }).Count | Should -Be 1
        @($v.Check.Asks | Where-Object { $_.Text -like 'Interruption*' }) | Should -BeNullOrEmpty
        @($v.Check.Checks | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        (Get-Call 'vps vps 10-vps.sh reboot*').Count | Should -Be 0
    }

    It 'names a task with no sign of life since the restart, and an older line does not count' {
        $c = New-Stage10 -Quiet 'OWUI-ntfy-PcHealth'
        Add-Line (Join-Path $script:Stack 'logs/ntfy-monitor.log') "[$(Get-Stamp $script:Restarted.AddMinutes(-10))] INFO === Watch-PcHealth run ==="
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems -join "`n" | Should -Match 'OWUI-ntfy-PcHealth: no line in logs/ntfy-monitor.log since the restart \(C-51\)'
        $r.Data['PcRestart']['Ok'] | Should -BeFalse
    }

    It 'needs the PowerShell tool''s broker running since the restart' {
        $c = New-Stage10
        $global:CriaFake.TaskInfo['OWUI-Windows-PowerShell-Tool'] = @{ State = 'Ready'; LastRunTime = $script:Restarted.AddMinutes(1); LastTaskResult = 2147942402 }
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'OWUI-Windows-PowerShell-Tool: the task is Ready, .*last result 0x80070002'
    }

    It 'needs Stage 8 to pass again with the pagefile in effect' {
        $c = New-Stage10
        $global:CriaStage['8'] = @{ Rows = @(@{ What = 'pagefile C:\pagefile.sys (R-07)'; Actual = 'managed by Windows (set; waits for the restart in Stage 10)'; Ok = $true }) }
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'the pagefile is still managed by Windows;'
        $r.Data['PcRestart']['Stage8'] | Should -Be 'the pagefile did not take effect at the restart'
    }

    It 'waits for Stage 8 and reports it when it never passes' {
        $c = New-Stage10
        $global:CriaStage['8'] = @{ Check = 'failed' }
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        @($global:CriaStageCalls | Where-Object { $_ -eq '8:Check' }).Count | Should -Be 20
        $r.Problems -join "`n" | Should -Match "Stage 8's checkpoint does not pass: fake check: failed"
    }

    It 'names a Stage 9 row that fails after the restart' {
        $c = New-Stage10
        $global:CriaStage['9'] = @{ Data = @{ Results = [ordered]@{ 'ollama-models' = @{ ok = $true; group = 1; owner = 3; actual = 'passed' }; 'kokoro-speech' = @{ ok = $false; group = 8; owner = 5; actual = 'HTTP 500' } } } }
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Data['PcRestart']['Stage9']['Failed'] | Should -Be @('kokoro-speech')
        $r.Data['PcRestart']['Ok'] | Should -BeFalse
        $c2 = Copy-Context $c 'Check'
        $c2.Data = $r.Data
        $k = Invoke-Stage '10-rehearsal.ps1' $c2
        $k.Status | Should -Be 'failed'
        @($k.Checks | Where-Object { -not $_.Ok }).Actual | Should -Contain '1 of 2; failed: kokoro-speech'
    }

    It 'lets the other stages it runs record or remove nothing' {
        $c = New-Stage10
        $global:CriaLive = $c.Base
        $global:CriaStage['9'] = @{ Create = @('made.txt') }
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match "Stage 9: stopped: Stage 10 runs other stages' checks and tests only"
        @(Get-OwnedItem -State $c.State -Stage 9) | Should -BeNullOrEmpty
    }
}

Describe 'Stage 10: from outside the tailnet' {
    It 'probes both public addresses each way and keeps the addresses out of the evidence' {
        $c = New-Stage10
        $v = Invoke-Visit $c
        $c.Data['Outside']['Ok'] | Should -BeTrue
        $global:CriaVps.Probed.Count | Should -Be 2
        $global:CriaVps.Probed[0] | Should -Match '^203\.0\.113\.10 .*\b22\b.*\b8889\b.*\b51820\b'
        $global:CriaVps.Probed[1] | Should -Match '^2001:db8::10 '
        $global:CriaVps.Input['probe'] | Should -Contain '198.51.100.20 3389'
        $global:CriaVps.Input['probe'] | Should -Contain '2001:db8::20 8188'
        foreach ($text in (Get-Text $v.Run), (Get-Text $v.Check)) {
            foreach ($a in $script:Addresses) { $text.Contains($a) | Should -BeFalse -Because "$a must stay in memory" }
        }
    }

    It 'fails on a VPS port that answers, naming the port and the family only' {
        $c = New-Stage10
        $global:CriaVps.VpsOpen = @('8080')
        $v = Invoke-Visit $c
        $v.Run.Status | Should -Be 'failed'
        $v.Run.Problems -join "`n" | Should -Match 'the VPS answers on TCP 8080 over IPv4 \(C-52\)'
        foreach ($a in $script:Addresses) { (Get-Text $v.Run).Contains($a) | Should -BeFalse }
    }

    It 'fails on a PC port the VPS can reach' {
        $c = New-Stage10
        $global:CriaVps.PcOpen = @('4/3389')
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'this PC answers on TCP 3389 over IPv4'
        $r.Data['Outside']['Pc']['4']['Open'] | Should -Be @(3389)
    }

    It 'warns when a side has no IPv6, and fails when it has no IPv4' {
        $c = New-Stage10
        $global:CriaVps.Vps6 = 'none'
        $global:CriaVps.Pc6 = $null
        $v = Invoke-Visit $c
        $c.Data['Outside']['Ok'] | Should -BeTrue
        $v.Check.Warnings -join "`n" | Should -Match 'the VPS: IPv6 not probed \(no address\)'
        $c2 = New-Stage10
        $global:CriaVps.Pc4 = $null
        $r = Invoke-Stage '10-rehearsal.ps1' $c2
        $r.Data['Outside']['Ok'] | Should -BeFalse
        $r.Problems -join "`n" | Should -Match 'this PC was not probed over IPv4 from outside \(no address\)'
        $r.Problems -join "`n" | Should -Match 'the VPS was not probed over IPv4 from outside \(this PC has no IPv4 to probe from\)'
    }

    It 'probes an address only from a host with the same family' {
        $c = New-Stage10
        $global:CriaVps.Vps6 = 'none'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        @($global:CriaVps.Input['probe'] | Where-Object { $_ -like '2001:db8::20 *' }) | Should -BeNullOrEmpty
        $r.Data['Outside']['Pc']['6'] | Should -Be 'the VPS has no IPv6 to probe from'
        $global:CriaVps.Probed.Count | Should -Be 1
    }

    It 'probes nothing while this PC uses an exit node' {
        $c = New-Stage10
        $global:CriaVps.Status = '{"Self":{"Online":true},"ExitNodeStatus":{"ID":"n1","Online":true}}'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'through a Tailscale exit node'
        $global:CriaVps.Probed.Count | Should -Be 0
        (Get-Call 'vps vps 10-vps.sh public-ip*').Count | Should -Be 0
        $r.Data['Outside']['Ok'] | Should -BeFalse
    }
}

Describe 'Stage 10: the VPS tests' {
    It 'runs nothing on the VPS that changes it until Stage 2 still passes' {
        $c = New-Stage10 -Accepted 'vps-tests'
        $global:CriaStage['2'] = @{ Check = 'failed' }
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'only on the rebuilt VPS'
        (Get-Call 'vps vps 10-vps.sh reboot*').Count | Should -Be 0
        (Get-Call 'vps vps 10-vps.sh guard-break*').Count | Should -Be 0
    }

    It 'restarts the VPS, breaks the guard and stops the tunnel, in that order' {
        $c = New-Stage10 -Accepted 'vps-tests'
        $v = Invoke-Visit $c
        $v.Run.Problems | Should -BeNullOrEmpty
        $order = @(Get-Call 'vps vps 10-vps.sh *' | Where-Object { $_ -match ' (reboot|guard-break|kill-switch)' } | ForEach-Object { ($_ -split ' ')[3] })
        $order | Should -Be @('reboot', 'guard-break', 'kill-switch')
        (Get-Call 'vps vps 10-vps.sh guard-break liam').Count | Should -Be 1
        $global:CriaStageCalls | Should -Contain '2:Check'
        $global:CriaStageCalls | Should -Contain '5:Check'
        $global:CriaVps.Input['kill-switch'] -join "`n" | Should -Match 'def main\(\):'
        foreach ($p in 'VpsRestart', 'GuardBreak', 'KillSwitch') { $c.Data[$p]['Ok'] | Should -BeTrue -Because $p }
        @($v.Check.Checks | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($v.Check.Asks | Where-Object Id | ForEach-Object Id) | Should -Not -Contain 'vps-tests'
    }

    It 'stops when the guard did not start before Docker' {
        $c = New-Stage10 -Accepted 'vps-tests'
        $global:CriaVps.Boot.guard_first = 'no'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'the guard did not start before Docker \(no\)'
        (Get-Call 'vps vps 10-vps.sh guard-break*').Count | Should -Be 0
    }

    It 'fails the guard test when Docker starts with the guard broken' {
        $c = New-Stage10 -Accepted 'vps-tests'
        $global:CriaVps.Guard.docker_refused = 'no'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'Docker started while the guard was broken'
        $r.Data['GuardBreak']['Ok'] | Should -BeFalse
        (Get-Call 'vps vps 10-vps.sh kill-switch*').Count | Should -Be 0
    }

    It 'names every probe that did not fail closed' {
        $c = New-Stage10 -Accepted 'vps-tests'
        $global:CriaVps.Kill.ks_dns_plain_2 = 'answered'
        $global:CriaVps.Kill.ks_search = 'ok'
        $v = Invoke-Visit $c
        $v.Run.Problems -join "`n" | Should -Match 'did not fail closed \(C-21\): search=ok, dns_plain_2=answered'
        $c.Data['KillSwitch']['Leaks'] | Should -Be @('search=ok', 'dns_plain_2=answered')
    }

    It 'says how to bring the tunnel back when it did not recover' {
        $c = New-Stage10 -Accepted 'vps-tests'
        $global:CriaVps.Kill.ks_recovered = 'no'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'docker restart vps-web-gluetun'
    }

    It 'does not run a part that passed again' {
        $d = Get-Restarted
        $d.VpsRestart = @{ Ok = $true }
        $d.GuardBreak = @{ Ok = $true }
        $c = New-Stage10 -Accepted 'vps-tests' -Data $d
        $null = Invoke-Stage '10-rehearsal.ps1' $c
        (Get-Call 'vps vps 10-vps.sh reboot*').Count | Should -Be 0
        (Get-Call 'vps vps 10-vps.sh guard-break*').Count | Should -Be 0
        (Get-Call 'vps vps 10-vps.sh kill-switch*').Count | Should -Be 1
    }
}

Describe 'Stage 10: the reminder and the first backup' {
    It 'places the reminder, registers it for this account and sends it once' {
        $c = New-Stage10
        $null = Invoke-Visit $c
        $placed = Join-Path $script:Stack '_support/scripts/scheduled/Send-BackupReminder.ps1'
        (Get-FileHash -LiteralPath $placed).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:RealRepo 'windows/reminder/Send-BackupReminder.ps1')).Hash
        $owned = @(Get-OwnedItem -State $c.State -Path $placed)
        $owned[0]['retry'] | Should -Be 'keep'
        $owned[0]['plaintext'] | Should -BeFalse
        $xml = $global:CriaFake.Registered['OWUI-ntfy-BackupReminder']
        $xml | Should -Match 'encoding="UTF-16"'
        $xml | Should -Match '<UserId>S-1-5-21-1000-2000-3000-1001</UserId>'
        $xml | Should -Not -Match '\{\{'
        $c.Data['Reminder']['Sent'] | Should -Be 'yes'
        $null = Invoke-Visit $c
        (Get-Call 'run-task OWUI-ntfy-BackupReminder').Count | Should -Be 1
        (Get-Call 'register OWUI-ntfy-BackupReminder').Count | Should -Be 1
    }

    It 'reports ntfy refusing the reminder' {
        $c = New-Stage10
        $global:CriaReminder = 'FAIL'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match "ntfy refused 'Monthly backup check'"
        $r.Data['Reminder']['Ok'] | Should -BeFalse
    }

    It 'leaves a different reminder script alone' {
        $c = New-Stage10
        $placed = Join-Path $script:Stack '_support/scripts/scheduled/Send-BackupReminder.ps1'
        Write-Text $placed '# mine'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems -join "`n" | Should -Match 'a different .*Send-BackupReminder.ps1 is already there'
        Get-Content -LiteralPath $placed -Raw | Should -Be '# mine'
        (Get-Call 'register *').Count | Should -Be 0
    }

    It 'collects once, keeps the seed out of the repo and records the plaintext for Stage 11' {
        $c = New-Stage10
        $v = Invoke-Visit $c
        $global:CriaCollect.Calls.Count | Should -Be 1
        $call = $global:CriaCollect.Calls[0]
        $call.Execute | Should -BeTrue
        $call.SeedOut | Should -Be ([IO.Path]::GetFullPath((Join-Path $c.StateRoot 'owui-seed-new')))
        $call.HelperImage | Should -Match '@sha256:[0-9a-f]{64}$'
        $call.SshHost | Should -Be 'vps'
        $b = $c.Data['Backup']
        $b['Sha256'] | Should -Match '^[0-9a-f]{64}$'
        $plain = @(Get-OwnedItem -State $c.State -Plaintext | ForEach-Object { $_['path'] })
        $plain | Should -Contain $b['RunFolder']
        $plain | Should -Contain $b['RoundTripFolder']
        Get-ProtectionProblem -Path $b['RoundTripFolder'] | Should -BeNullOrEmpty
        $ask = @($v.Check.Asks | Where-Object { $_.Text -like 'Upload *' })[0].Text
        $ask | Should -Match $b['Sha256']
        $ask | Should -Match ([regex]::Escape($b['RoundTripFolder']))
        $null = Invoke-Visit $c
        $global:CriaCollect.Calls.Count | Should -Be 1
    }

    It 'reports a failed collection and still records its run folder for removal' {
        $c = New-Stage10
        $global:CriaCollect.Fail = 'seed: the export failed'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Problems | Should -Contain 'collector: seed: the export failed'
        @(Get-OwnedItem -State $c.State -Plaintext).Count | Should -Be 1
        $r.Data['Backup']['Ok'] | Should -BeFalse
    }

    It 'passes the round trip only when the ZIP from Bitwarden matches' {
        $c = New-Stage10
        $null = Invoke-Visit $c
        $b = $c.Data['Backup']
        $down = Join-Path $b['RoundTripFolder'] 'downloaded.zip'
        [IO.File]::WriteAllBytes($down, [byte[]](1, 2, 3))
        $v = Invoke-Visit $c
        $v.Run.Problems -join "`n" | Should -Match "the downloaded ZIP's SHA-256 is [0-9a-f]{64}, not the bundle's"
        Copy-Item -LiteralPath (Join-Path $b['RunFolder'] $b['Zip']) -Destination $down -Force
        $v = Invoke-Visit $c
        $c.Data['RoundTrip']['Ok'] | Should -BeTrue
        @($v.Check.Asks | Where-Object { $_.Text -like 'Upload *' }) | Should -BeNullOrEmpty
    }
}

Describe 'Stage 10: the interruption and the second run' {
    It 'passes the interruption once the interrupted stage finished, and fails it before' {
        $d = Get-PassedData
        $c = New-Stage10 -Mode Check -Data $d -Accepted 'vps-tests', 'reminder', 'lan-closed'
        $c.State['stages']['9']['interruptions'] = 1
        $c.State['stages']['9']['status'] = 'failed'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        @($r.Checks | Where-Object { $_.What -like 'interrupted*' })[0].Ok | Should -BeFalse
        $c.State['stages']['9']['status'] = 'done'
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        @($r.Checks | Where-Object { $_.What -like 'interrupted*' })[0].Actual | Should -Be 'Stage 9 interrupted, then done'
    }

    It 'runs every checkpoint from 1 to 9 once everything has passed and been answered' {
        $c = New-Stage10 -Data (Get-PassedData) -Accepted 'vps-tests', 'reminder', 'lan-closed'
        $c.State['stages']['9']['interruptions'] = 1
        $v = Invoke-Visit $c
        $v.Run.Problems | Should -BeNullOrEmpty
        $global:CriaStageCalls | Should -Be @(1..9 | ForEach-Object { "${_}:Check" })
        $c.Data['Rerun']['Ok'] | Should -BeTrue
        $v.Check.Status | Should -Be 'passed'
        # As state.json gives it back to the next run, and to Stage 11's check.
        $c2 = Copy-Context $c 'Check'
        $c2.Data = ConvertTo-Json -InputObject $c.Data -Depth 20 | ConvertFrom-Json -AsHashtable
        (Invoke-Stage '10-rehearsal.ps1' $c2).Status | Should -Be 'passed'
    }

    It 'passes without the interruption test, which is optional' {
        $c = New-Stage10 -Data (Get-PassedData) -Accepted 'vps-tests', 'reminder', 'lan-closed'
        $v = Invoke-Visit $c
        $v.Run.Problems | Should -BeNullOrEmpty
        $global:CriaStageCalls | Should -Be @(1..9 | ForEach-Object { "${_}:Check" })
        $v.Check.Status | Should -Be 'passed'
        $row = @($v.Check.Checks | Where-Object { $_.What -like 'interrupted*' })[0]
        $row.Actual | Should -Be 'not run'
        $row.Ok | Should -BeTrue
        $v.Check.Steps -join ' ' | Should -Match 'optional, not run: the interruption test'
    }

    It 'waits for an interrupted stage to finish before the second run' {
        $c = New-Stage10 -Data (Get-PassedData) -Accepted 'vps-tests', 'reminder', 'lan-closed'
        $c.State['stages']['9']['interruptions'] = 1
        $c.State['stages']['9']['status'] = 'failed'
        $v = Invoke-Visit $c
        $global:CriaStageCalls.Count | Should -Be 0
        $v.Check.Status | Should -Be 'failed'
    }

    It 'fails the second run when a checkpoint no longer passes' {
        $c = New-Stage10 -Data (Get-PassedData) -Accepted 'vps-tests', 'reminder', 'lan-closed'
        $c.State['stages']['9']['interruptions'] = 1
        $global:CriaStage['4'] = @{ Check = 'failed' }
        $v = Invoke-Visit $c
        $v.Run.Status | Should -Be 'failed'
        $v.Run.Problems -join "`n" | Should -Match "second run: Stage 4's checkpoint does not pass"
        $c.Data['Rerun']['Ok'] | Should -BeFalse
    }

    It 'waits for the answers before the second run' {
        $c = New-Stage10 -Data (Get-PassedData) -Accepted 'vps-tests', 'lan-closed'
        $c.State['stages']['9']['interruptions'] = 1
        $v = Invoke-Visit $c
        $global:CriaStageCalls.Count | Should -Be 0
        $v.Check.Status | Should -Be 'needs-user'
        @($v.Check.Asks | ForEach-Object Id) | Should -Be @('reminder')
    }
}

Describe 'Stage 10: plan and checkpoint' {
    It 'plans without calling anything' {
        $c = New-Stage10 -Mode Plan
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Status | Should -Be 'planned'
        $r.Steps -join ' ' | Should -Match 'would carry on with: PcRestart, Outside'
        $global:CriaCalls.Count | Should -Be 0
        $global:CriaStageCalls.Count | Should -Be 0
        $global:CriaCollect.Calls.Count | Should -Be 0
    }

    It 'fails a checkpoint with nothing recorded, without stopping' {
        $c = New-Stage10 -Mode Check -Data @{}
        $r = Invoke-Stage '10-rehearsal.ps1' $c
        $r.Status | Should -Be 'failed'
        @($r.Checks | Where-Object { -not $_.Ok }).Actual | Should -Contain 'not tested yet'
    }
}
