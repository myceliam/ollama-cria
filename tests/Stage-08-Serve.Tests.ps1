#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 8 (windows/stages/08-serve.ps1) against a small fake repo and a fake
# PC: Docker, netsh, winnat, Tailscale Serve, OWUI, the firewall, the
# pagefile and the Task Scheduler all answer from $global:CriaStack and
# $global:CriaFake. Keys and names are made up at run time.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')

    function Write-Text([string]$Path, [string]$Text) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, $Text)
    }

    function Write-Json([string]$Path, $Object) { Write-Text $Path ($Object | ConvertTo-Json -Depth 8) }

    function New-TaskXml([string]$Command, [string]$Trigger, [switch]$Disabled) {
        @"
<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals>
    <Principal id="Author">
      <UserId>{{USER_SID}}</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <Enabled>$(if ($Disabled) { 'false' } else { 'true' })</Enabled>
  </Settings>
  <Triggers>
    $Trigger
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$Command</Command>
      <WorkingDirectory>{{USER_PROFILE}}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    }

    function ConvertTo-ServeJson {
        $s = $global:CriaStack
        $tcp = @{}; $web = @{}
        foreach ($r in $s.Serve) {
            if ($r.kind -eq 'tcp') { $tcp["$($r.port)"] = @{ TCPForward = $r.target }; continue }
            $tcp["$($r.port)"] = @{ HTTPS = $true }
            $web["node:$($r.port)"] = @{ Handlers = @{ $r.path = @{ Proxy = $r.target } } }
        }
        $doc = @{}
        if ($tcp.Count) { $doc['TCP'] = $tcp; $doc['Web'] = $web }
        if ($s.Funnel) { $doc['AllowFunnel'] = @{ "node:$($s.Funnel)" = $true } }
        return ($doc | ConvertTo-Json -Depth 8)
    }

    function New-Stage8([string]$Mode = 'Run') {
        Reset-Fake
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $repo = Join-Path $base 'repo'
        foreach ($f in 'manifests/serve.json', 'manifests/stack-files.json') {
            Write-Text (Join-Path $repo $f) ([IO.File]::ReadAllText((Join-Path $script:RealRepo $f)))
        }
        $live = Join-Path $base 'live/ollama'
        foreach ($f in 'start-stack.ps1', 'mcpo-watchdog.ps1', 'autofree-watchdog.ps1', 'windows-powershell-tool/server.py') { Write-Text (Join-Path $live $f) '# script' }
        $python = Join-Path $base 'Python313/python.exe'
        $pwshExe = Join-Path $base 'PowerShell/pwsh.exe'
        $wscript = Join-Path $base 'system32/wscript.exe'
        foreach ($p in $python, $pwshExe, $wscript) { Write-Text $p 'exe' }

        Write-Text (Join-Path $repo 'windows/startup/start_comfyui_hidden.vbs') "Set sh = CreateObject(`"WScript.Shell`")`r`n"
        Write-Text (Join-Path $repo 'windows/tasks/OWUI-Stack-Startup.xml') (New-TaskXml 'powershell.exe' '<LogonTrigger />')
        Write-Text (Join-Path $repo 'windows/tasks/OWUI-mcpo-Watchdog.xml') (New-TaskXml $wscript '<TimeTrigger><StartBoundary>2026-06-29T03:26:52+01:00</StartBoundary></TimeTrigger>')
        Write-Text (Join-Path $repo 'windows/tasks/OWUI-ntfy-MorningBrief.xml') (New-TaskXml $wscript '<CalendarTrigger />' -Disabled)
        Write-Text (Join-Path $repo 'windows/tasks/OWUI-Windows-PowerShell-Tool.xml') (New-TaskXml $python "<LogonTrigger><UserId>{{USER_ID}}</UserId></LogonTrigger>")
        Write-Json (Join-Path $repo 'manifests/tasks.json') @{
            formatVersion = 1
            tasks         = @(
                @{ name = 'OWUI-Stack-Startup'; enabled = $true; install = 'xml'; xml = 'windows/tasks/OWUI-Stack-Startup.xml'; runs = @('stack/start-stack.ps1') }
                @{ name = 'OWUI-mcpo-Watchdog'; enabled = $true; install = 'xml'; xml = 'windows/tasks/OWUI-mcpo-Watchdog.xml'; runs = @('stack/mcpo-watchdog.ps1') }
                @{ name = 'OWUI-ntfy-MorningBrief'; enabled = $false; install = 'xml'; xml = 'windows/tasks/OWUI-ntfy-MorningBrief.xml'; runs = @() }
                @{ name = 'OWUI-Windows-PowerShell-Tool'; enabled = $true; install = 'xml'; xml = 'windows/tasks/OWUI-Windows-PowerShell-Tool.xml'; runs = @('stack/windows-powershell-tool/server.py') }
            )
            startup       = @(
                @{ name = 'OWUI ComfyUI AutoFree.lnk'; kind = 'shortcut'; target = $pwshExe; arguments = '-NoProfile -File "{{USER_PROFILE}}\autofree-watchdog.ps1"'; workingDirectory = '{{USER_PROFILE}}'; runs = @('stack/autofree-watchdog.ps1') }
                @{ name = 'start_comfyui_hidden.vbs'; kind = 'file'; file = 'windows/startup/start_comfyui_hidden.vbs' }
            )
            retired       = @()
        }
        Write-Json (Join-Path $repo 'manifests/owui-seed/seed/config.json') @{
            'tool_server.connections' = @(
                @{ url = 'http://mcpo-core:8000/time'; type = 'openapi'; config = @{ enable = $true }; info = @{ id = 'time'; name = 'time' } }
                @{ url = 'http://gcal-owui-bridge:18100'; config = @{ enable = $true }; info = @{ name = 'Calendar' } }
                @{ url = 'http://mcpo-core:8000/memory/mcp'; type = 'mcp'; config = @{ enable = $true }; info = @{ id = 'memory'; name = 'memory' } }
                @{ url = 'http://retired:9000'; config = @{ enable = $false }; info = @{ id = 'retired'; name = 'retired' } }
            )
        }

        $c = New-TestContext -Stage 8 -Mode $Mode -RepoRoot $repo -Base $base
        Initialize-ProtectedFolder -Path $c.StagingRoot
        $c.Topology['composeProjects'] = @(
            @{ name = 'ollama'; root = 'stack'; file = 'docker-compose.yml' }
            @{ name = 'gmail-owui-bridge'; root = 'stack'; file = 'gmail-owui-bridge/docker-compose.yml' }
            @{ name = 'cline-dashboard'; root = 'dashboard'; file = 'docker-compose.yml' }
            @{ name = 'owui-web-egress'; root = 'vps-egress'; file = 'compose.yml' }
        )
        $key = 'sk-' + ('A' * 40)
        $k = Open-NewOwnerOnlyFile -Path (Join-Path $c.StagingRoot 'owui-api-key.txt')
        try { $b = [Text.Encoding]::ASCII.GetBytes($key); $k.Write($b, 0, $b.Length) } finally { $k.Dispose() }

        $startup = Join-Path $base 'Startup'
        $null = New-Item -ItemType Directory -Path $startup -Force
        $global:CriaFake.Account = @{ Sid = 'S-1-5-21-1000-2000-3000-1001'; Id = 'PC\liam'; Profile = (Join-Path $base 'profile'); Startup = $startup; Console = 'PC\liam' }
        $global:CriaFake.OnStart = { param($Path) if ($Path -like '*start_comfyui_hidden.vbs') { $global:CriaStack.Comfy = $true } }

        $global:CriaStack = @{
            Key            = $key
            Up             = $false
            Comfy          = $false
            StartStack     = 0
            StartStackExit = 0
            Services       = @{
                'ollama'            = @('open-webui', 'mcpo-core', 'gcal-owui-bridge', 'dozzle')
                'gmail-owui-bridge' = @('gmail-owui-bridge')
                'cline-dashboard'   = @('dashboard')
            }
            State          = @{ dozzle = 'running' }
            Stale          = @{}
            Health         = @{}
            Catalogue      = @('brave_search', 'server:time', 'server:1', 'server:mcp:memory')
            AfterRestart   = $null
            Restarted      = 0
            Ranges         = [Collections.Generic.List[string]]@('      5357        5357', '     50000       50059     *')
            WinNat         = $true
            AddFails       = $false
            Serve          = [Collections.Generic.List[object]]::new()
            Funnel         = $null
        }
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            $s = $global:CriaStack
            $a = @($Arguments)
            switch ($Name) {
                'docker' {
                    if ($a[0] -eq 'info') { return New-ExecResult 0 @('29.0.0') }
                    if ($a[0] -eq 'ps') {
                        $project = $a[3] -replace '^label=com\.docker\.compose\.project=', ''
                        return New-ExecResult 0 @($s.Services[$project] | ForEach-Object { "$_ $(if ($s.Stale[$_]) { 'old' } else { "hash-$_" })" })
                    }
                    if ($a[0] -ne 'compose') { return New-ExecResult 2 }
                    $project = $a[2]
                    switch ($a[7]) {
                        'config' {
                            if ($a[8] -eq '--services') { return New-ExecResult 0 $s.Services[$project] }
                            return New-ExecResult 0 @($s.Services[$project] | ForEach-Object { "$_ hash-$_" })
                        }
                        'ps' {
                            if (-not $s.Up) { return New-ExecResult 0 @() }
                            return New-ExecResult 0 @($s.Services[$project] | ForEach-Object { "$_ $(if ($s.State.ContainsKey($_)) { $s.State[$_] } else { 'running healthy' })" })
                        }
                        'up' { foreach ($svc in $a[12..($a.Count - 1)]) { $s.Stale.Remove($svc) }; return New-ExecResult 0 }
                        'restart' { $s.Restarted++; if ($s.AfterRestart) { $s.Catalogue = $s.AfterRestart }; return New-ExecResult 0 }
                    }
                    return New-ExecResult 2
                }
                'pwsh' { $s.Up = $true; $s.StartStack++; return New-ExecResult $s.StartStackExit }
                'netsh' {
                    if ($a[0] -eq 'interface') {
                        return New-ExecResult 0 (@('', 'Protocol tcp Port Exclusion Ranges', '', 'Start Port    End Port', '----------    --------') + $s.Ranges + @('', '* - Administered port exclusions.'))
                    }
                    if ($s.AddFails) { return New-ExecResult 1 @('The process cannot access the file because it is being used by another process.') }
                    $s.Ranges.Add('      8188        8188     *')
                    return New-ExecResult 0 @('Ok.')
                }
                'sc.exe' { return New-ExecResult 0 @('SERVICE_NAME: winnat', "        STATE              : $(if ($s.WinNat) { '4  RUNNING' } else { '1  STOPPED' })") }
                'net' { $s.WinNat = $a[0] -eq 'start'; return New-ExecResult 0 }
                'tailscale' {
                    if ($a[1] -eq 'status') { return New-ExecResult 0 @((ConvertTo-ServeJson) -split "`n") }
                    if ($a[2] -match '^--tcp=(\d+)$') { $s.Serve.Add(@{ port = [int]$Matches[1]; kind = 'tcp'; target = ($a[3] -replace '^tcp://', '') }) }
                    elseif ($a[2] -match '^--https=(\d+)$') { $s.Serve.Add(@{ port = [int]$Matches[1]; kind = 'https'; path = '/'; target = $a[-1] }) }
                    return New-ExecResult 0
                }
            }
            return New-ExecResult -1
        }
        $global:CriaFake.Status = {
            param($Uri, $Headers)
            $s = $global:CriaStack
            if ($Uri -like '*/api/v1/tools/') { return $(if ($Headers['Authorization'] -eq "Bearer $($s.Key)") { 200 } else { 401 }) }
            if ($Uri -like '*:8188/*') { return $(if ($s.Comfy) { 200 } else { 0 }) }
            if ($Uri -like '*:11434/*') { return 200 }
            if (-not $s.Up) { return 0 }
            if ($s.Health.ContainsKey($Uri)) { return $s.Health[$Uri] }
            return 200
        }
        $global:CriaFake.Http = {
            param($Uri, $Headers)
            if ($Uri -like '*/api/v1/tools/') { return @($global:CriaStack.Catalogue | ForEach-Object { [pscustomobject]@{ id = $_; name = $_ } }) }
            return $null
        }
        $c['Live'] = $live
        $c['Startup'] = $startup
        return $c
    }

    function Get-Call([string]$Like) { @($global:CriaCalls | Where-Object { $_ -like $Like }) }
}

Describe 'Stage 8: start services, Tailscale Serve and automation' {

    It 'brings a new PC up: port, firewall, pagefile, startup items, the stack, Serve and tasks' {
        $c = New-Stage8
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'

        # 8a: winnat stopped, the range added, winnat started again.
        $order = @($global:CriaCalls | Where-Object { $_ -match '^(net |netsh int )' })
        $order | Should -Be @('net stop winnat', 'netsh int ipv4 add excludedportrange protocol=tcp startport=8188 numberofports=1', 'net start winnat')
        Get-Call 'firewall ComfyUI 8188 - loopback and tailnet only' | Should -HaveCount 1
        @($global:CriaFake.Firewall)[0].RemoteAddress | Should -Be @('100.64.0.0/10', '127.0.0.1')
        Get-Call 'pagefile C:\pagefile.sys 32768 81920' | Should -HaveCount 1
        $r.Data['PagefileChanged'] | Should -BeTrue

        # 8b: the launcher copied and run, the shortcut filled for this account.
        Test-Path -LiteralPath (Join-Path $c.Startup 'start_comfyui_hidden.vbs') -PathType Leaf | Should -BeTrue
        Get-Call "start $(Join-Path $c.Startup 'start_comfyui_hidden.vbs')" | Should -HaveCount 1
        $lnk = $global:CriaFake.Shortcuts[(Join-Path $c.Startup 'OWUI ComfyUI AutoFree.lnk')]
        $lnk.Arguments | Should -Be "-NoProfile -File `"$($global:CriaFake.Account.Profile)\autofree-watchdog.ps1`""
        $global:CriaStack.StartStack | Should -Be 1
        $r.Data['StartStackExit'] | Should -Be 0
        $r.Steps | Should -Contain "OWUI's tool catalogue lists all 3 tool servers"
        $global:CriaStack.Restarted | Should -Be 0

        # 8c: every serve.json rule, as tailscale serve --bg.
        Get-Call 'tailscale serve --bg *' | Should -HaveCount 7
        Get-Call 'tailscale serve --bg --https=443 http://127.0.0.1:3000' | Should -HaveCount 1
        Get-Call 'tailscale serve --bg --tcp=8188 tcp://127.0.0.1:8188' | Should -HaveCount 1

        # 8d: the tasks, for this account; the broker started, the stack's
        # own task not run again, MorningBrief imported disabled.
        @($global:CriaFake.Registered.Keys) | Sort-Object | Should -Be @('OWUI-mcpo-Watchdog', 'OWUI-ntfy-MorningBrief', 'OWUI-Stack-Startup', 'OWUI-Windows-PowerShell-Tool')
        $xml = $global:CriaFake.Registered['OWUI-Windows-PowerShell-Tool']
        $xml | Should -Match '^<\?xml version="1.0" encoding="UTF-16"\?>'
        $xml | Should -Match '<UserId>S-1-5-21-1000-2000-3000-1001</UserId>'
        $xml | Should -Match '<UserId>PC\\liam</UserId>'
        $xml | Should -Not -Match '\{\{'
        Get-Call 'run-task *' | Should -Be @('run-task OWUI-Windows-PowerShell-Tool')
        $global:CriaFake.Tasks['OWUI-ntfy-MorningBrief'] | Should -Be 'Disabled'
    }

    It 'passes checkpoint 8 once Liam has opened OWUI from the phone' {
        $c = New-Stage8
        $run = Invoke-Stage '08-serve.ps1' $c
        $cc = Copy-Context $c 'Check'
        $cc.Data = $run.Data
        $check = Invoke-Stage '08-serve.ps1' $cc
        $check.Status | Should -Be 'needs-user'
        $check.Asks[0].Id | Should -Be 'owui-phone'
        @($check.Checks | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty

        $c2 = Copy-Context $c 'Check'
        $c2.Accepted = @('owui-phone')
        $c2.Data = $run.Data
        $done = Invoke-Stage '08-serve.ps1' $c2
        $done.Status | Should -Be 'passed'
        @($done.Checks).Count | Should -Be 13
    }

    It 'changes nothing on a second run' {
        $c = New-Stage8
        $first = Invoke-Stage '08-serve.ps1' $c
        $global:CriaCalls.Clear()
        $c.Data = $first.Data
        $r = Invoke-Stage '08-serve.ps1' (Copy-Context $c 'Run')
        $r.Status | Should -Be 'done'
        Get-Call 'net *' | Should -BeNullOrEmpty
        Get-Call 'netsh int ipv4 add*' | Should -BeNullOrEmpty
        Get-Call 'firewall *' | Should -BeNullOrEmpty
        Get-Call 'pagefile *' | Should -BeNullOrEmpty
        Get-Call 'shortcut *' | Should -BeNullOrEmpty
        Get-Call 'start *' | Should -BeNullOrEmpty
        Get-Call 'tailscale serve --bg *' | Should -BeNullOrEmpty
        Get-Call 'register *' | Should -BeNullOrEmpty
        Get-Call 'run-task *' | Should -BeNullOrEmpty
    }

    It 'refuses a window elevated as another account' {
        $c = New-Stage8
        $global:CriaFake.Account.Console = 'PC\someone'
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems[0] | Should -Match 'runs as PC\\liam, but PC\\someone is signed in'
        $global:CriaCalls | Should -BeNullOrEmpty
    }

    It 'fails when start-stack.ps1 says 0 but a service or health URL is not right (C-27)' {
        $c = New-Stage8
        $global:CriaStack.State['mcpo-core'] = 'running unhealthy'
        $global:CriaStack.Health['http://127.0.0.1:3001/'] = 404
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain 'service ollama/mcpo-core: unhealthy'
        $r.Problems | Should -Contain 'health URL Jina Reader via the relay (HTTP 404)'
        $global:CriaStack.Restarted | Should -Be 0

        $global:CriaStack.StartStackExit = 1
        $r2 = Invoke-Stage '08-serve.ps1' (Copy-Context $c 'Run')
        $r2.Problems | Should -Contain "start-stack.ps1 exited 1 (its log is in $(Join-Path $c.Live 'logs'))"
    }

    It 'recreates a container left on an older configuration' {
        $c = New-Stage8
        $global:CriaStack.Stale['gcal-owui-bridge'] = $true
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'done'
        $r.Steps | Should -Contain 'ollama: recreated gcal-owui-bridge on its current configuration'
        Get-Call 'docker compose -p ollama * up -d --no-build --pull never gcal-owui-bridge' | Should -HaveCount 1
    }

    It 'restarts OWUI once for a stale tool catalogue, and names a server still missing' {
        $c = New-Stage8
        $global:CriaStack.Catalogue = @('server:time')
        $global:CriaStack.AfterRestart = @('server:time', 'server:1', 'server:mcp:memory')
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'done'
        $global:CriaStack.Restarted | Should -Be 1
        $r.Steps | Should -Contain 'OWUI restarted to load its tool servers again (2 were missing)'

        $c2 = New-Stage8
        $global:CriaStack.Catalogue = @('server:time', 'server:mcp:memory')
        $r2 = Invoke-Stage '08-serve.ps1' $c2
        $r2.Status | Should -Be 'failed'
        $global:CriaStack.Restarted | Should -Be 1
        $r2.Problems | Should -Contain "OWUI's tool catalogue lacks 1 of 3 tool servers: Calendar. 'docker logs mcpo-core' and 'docker logs open-webui' say why"
    }

    It 'asks when the API key cannot read the tool list, and takes -Accept tool-catalogue' {
        $c = New-Stage8
        $global:CriaStack.Key = 'sk-' + ('B' * 40)
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Id | Should -Be 'tool-catalogue'
        $r.Asks[0].Text | Should -Match 'HTTP 401'

        $c2 = Copy-Context $c 'Run'
        $c2.Accepted = @('tool-catalogue')
        (Invoke-Stage '08-serve.ps1' $c2).Status | Should -Be 'done'
    }

    It 'reports Serve rules and Funnel it did not make, and changes none of them (C-23)' {
        $c = New-Stage8
        $global:CriaStack.Serve.Add(@{ port = 443; kind = 'https'; path = '/'; target = 'http://127.0.0.1:9999' })
        $global:CriaStack.Serve.Add(@{ port = 5000; kind = 'tcp'; target = '127.0.0.1:5000' })
        $global:CriaStack.Funnel = 8443
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain "Serve: port 443 serves http://127.0.0.1:9999, not http://127.0.0.1:3000. Turn that port off with 'tailscale serve --https=<port> off' (or --tcp) and run again"
        $r.Problems | Should -Contain "Serve: port 5000 is not in serve.json; turn it off with 'tailscale serve' and run again"
        $r.Problems | Should -Contain "Funnel is on for port 8443; the stack never uses Funnel (C-23). Turn it off with 'tailscale funnel --https=8443 off'"
        Get-Call 'tailscale serve --bg --https=443 *' | Should -BeNullOrEmpty
        Get-Call 'tailscale serve --bg *' | Should -HaveCount 6
    }

    It 'asks before leaving a firewall rule that opens 8188 wider, and keeps a wrong rule of its own name' {
        $c = New-Stage8
        $global:CriaFake.Firewall.Add([pscustomobject]@{
                DisplayName = 'python'; Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'
                LocalPort = [string[]]@('Any'); RemoteAddress = [string[]]@('Any'); Program = 'C:\Python311\python.exe'
            })
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match "through 'python' \(C:\\Python311\\python.exe\)"

        $c2 = New-Stage8
        $global:CriaFake.Firewall.Add([pscustomobject]@{
                DisplayName = 'ComfyUI 8188 - loopback and tailnet only'; Enabled = $false; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'
                LocalPort = [string[]]@('8188'); RemoteAddress = [string[]]@('100.64.0.0/255.192.0.0', '127.0.0.1'); Program = 'Any'
            })
        $r2 = Invoke-Stage '08-serve.ps1' $c2
        $r2.Status | Should -Be 'failed'
        $r2.Problems | Should -Contain "the firewall rule 'ComfyUI 8188 - loopback and tailnet only' is there but is disabled Inbound Allow TCP 8188 from 100.64.0.0/255.192.0.0 and 127.0.0.1; set it to inbound TCP 8188 allowed from 100.64.0.0/10 and 127.0.0.1 only, or remove it, then run again"
        Get-Call 'firewall *' | Should -BeNullOrEmpty
    }

    It 'takes 8188 back from WinNAT and starts winnat again even when adding fails (C-31)' {
        $c = New-Stage8
        $global:CriaStack.Ranges[0] = '      8100        8199'
        $global:CriaStack.AddFails = $true
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain 'netsh could not reserve TCP 8188 (exit 1); if ComfyUI is running, stop it and run again'
        Get-Call 'net *' | Should -Be @('net stop winnat', 'net start winnat')
        $global:CriaStack.WinNat | Should -BeTrue
    }

    It 'imports no task whose script or program is missing, leaves tasks that are there, and disables MorningBrief' {
        $c = New-Stage8
        Remove-Item -LiteralPath (Join-Path $c.Live 'mcpo-watchdog.ps1')
        Remove-Item -LiteralPath (Join-Path $c.Base 'Python313/python.exe')
        $global:CriaFake.Tasks['OWUI-Stack-Startup'] = 'Ready'
        $global:CriaFake.Tasks['OWUI-ntfy-MorningBrief'] = 'Ready'
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain "task OWUI-mcpo-Watchdog: not imported; it runs $(Join-Path $c.Live 'mcpo-watchdog.ps1'), which is not on this PC"
        $r.Problems | Should -Contain "task OWUI-Windows-PowerShell-Tool: not imported; it runs $(Join-Path $c.Base 'Python313/python.exe'), which is not on this PC"
        Get-Call 'register *' | Should -BeNullOrEmpty
        Get-Call 'disable *' | Should -Be @('disable OWUI-ntfy-MorningBrief')
    }

    It 'plans without touching the machine' {
        $c = New-Stage8 -Mode 'Plan'
        $r = Invoke-Stage '08-serve.ps1' $c
        $r.Status | Should -Be 'planned'
        $r.Steps.Count | Should -Be 3
        $global:CriaCalls | Should -BeNullOrEmpty
    }

    It 'every task XML in the repo becomes a whole task for a new account' {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:RealRepo 'windows/tasks') -Filter '*.xml') {
            $text = [IO.File]::ReadAllText($f.FullName).Replace('{{USER_SID}}', 'S-1-5-21-1-2-3-1001').Replace('{{USER_ID}}', 'PC\liam').Replace('{{USER_PROFILE}}', 'C:\Users\liam')
            $text | Should -Not -Match '\{\{' -Because $f.Name
            { [xml]$text } | Should -Not -Throw -Because $f.Name
        }
    }
}
