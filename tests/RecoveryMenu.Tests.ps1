#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The rebuild menu (Start-Recovery.ps1, tools/RecoveryMenu.psm1), driven end
# to end with fakes: the console is a queue of answers and a list of lines,
# the machine a table of script blocks, the controller a script block that
# returns reports. Every record lands in the test drive. Addresses, domains
# and keys are made at run time, so none is ever in a file.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:Repo 'tools/RecoveryMenu.psm1') -Force
    Import-Module (Join-Path $script:Repo 'tools/RecoveryVps.psm1') -Force

    function New-ExecResult([int]$Code = 0, [string[]]$Output = @()) { [pscustomobject]@{ ExitCode = $Code; Output = [string[]]$Output } }

    function New-ZipFile([string]$Path, [string[]]$Entry) {
        $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($e in $Entry) {
                $w = [IO.StreamWriter]::new($zip.CreateEntry($e).Open())
                try { $w.Write('x') } finally { $w.Dispose() }
            }
        }
        finally { $zip.Dispose() }
    }

    function New-TestMenu {
        # A repo copy (manifests and a .git folder), a topology whose
        # controller folders are in the test drive, and a context with every
        # probe faked. Answers come from $global:MenuAnswers.
        param([hashtable]$Probe = @{}, [scriptblock]$Controller, [hashtable]$Machine)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8))
        $repo = Join-Path $root 'recovery'
        $null = New-Item -ItemType Directory -Path (Join-Path $repo '.git/refs/heads') -Force
        Copy-Item -LiteralPath (Join-Path $script:Repo 'manifests') -Destination (Join-Path $repo 'manifests') -Recurse
        [IO.File]::WriteAllText((Join-Path $repo '.git/config'), "[core]`n`tbare = false`n[remote `"origin`"]`n`turl = https://github.com/myceliam/ollama-cria.git`n`tfetch = +refs/heads/*:refs/remotes/origin/*`n")
        [IO.File]::WriteAllText((Join-Path $repo '.git/HEAD'), "ref: refs/heads/main`n")
        [IO.File]::WriteAllText((Join-Path $repo '.git/refs/heads/main'), ('a' * 40) + "`n")
        $topology = Get-Content -LiteralPath (Join-Path $script:Repo 'manifests/topology.json') -Raw | ConvertFrom-Json -AsHashtable
        $topology['controller']['repoRoot'] = $repo
        $topology['controller']['stateRoot'] = Join-Path $root 'recovery-state'
        $topology['controller']['stagingRoot'] = Join-Path $root 'recovery-secrets'
        $topologyPath = Join-Path $root 'topology.json'
        [IO.File]::WriteAllText($topologyPath, ($topology | ConvertTo-Json -Depth 10))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'Downloads'), (Join-Path $root 'LocalAppData'), (Join-Path $root 'ProgramFiles') -Force

        $global:MenuAnswers = [Collections.Generic.Queue[string]]::new()
        $global:MenuOut = [Collections.Generic.List[string]]::new()
        $global:MenuCalls = [Collections.Generic.List[string]]::new()
        $global:MenuActions = [Collections.Generic.List[string]]::new()
        $global:MenuExec = { param($Name, $Arguments) New-ExecResult 0 @() }
        $global:MenuRoot = $root
        $probes = @{
            Now            = { [DateTime]::new(2026, 10, 10, 1, 0, 0, [DateTimeKind]::Utc) }
            Exec           = {
                param([string]$Name, [string[]]$Arguments = @(), [switch]$Stream)
                $global:MenuCalls.Add(("$Name " + (@($Arguments) -join ' ')).Trim())
                & $global:MenuExec $Name @($Arguments)
            }
            BitLocker      = { param([string]$Path) $null = $Path; 'On' }
            Virtualization = { @{ Firmware = $true; Hypervisor = $false } }
            IsElevated     = { $false }
            OsBuild        = { 26100 }
            RebootPending  = { $false }
            PendingUpdates = { 0 }
            Drive          = { param([string]$Letter) $null = $Letter; @{ Exists = $true; Ready = $true; Format = 'NTFS'; Free = [long]900GB; Size = [long]1800GB } }
            Protection     = { param([string]$Path) $null = $Path; $null }
            Service        = { param([string]$Name) $null = $Name; @{ StartType = 'Disabled'; Status = 'Stopped' } }
            Board          = { @{ Maker = 'ASUSTeK COMPUTER INC.'; Product = 'ROG STRIX X670E-F GAMING WIFI' } }
            Programs       = { @(@{ Name = 'AMD Chipset Software'; Version = '7.06.02.123' }) }
            DriverUpdatesOff = { $true }
            SleepAcMinutes = { 0 }
            SetSleepNever  = { $global:MenuActions.Add('sleep'); 0 }
            HideFileExt    = { 0 }
            ShowFileExt    = { $global:MenuActions.Add('show-ext') }
            NewProtected   = { param([string]$Path) $global:MenuActions.Add("protected $Path"); $null = New-Item -ItemType Directory -Path $Path }
            Open           = { param([string]$Target, [string[]]$Arguments = @()) $global:MenuActions.Add(("open $Target " + ($Arguments -join ' ')).Trim()) }
            RunElevated    = { param([string]$Command) $global:MenuActions.Add("elevated $Command"); 0 }
            Clipboard      = { param([string]$Text) $global:MenuClipboard = $Text }
            RunOnce        = { param([string]$Name, [string]$Command) $global:MenuActions.Add("runonce $Name $Command") }
            Restart        = { $global:MenuActions.Add('restart') }
            RefreshPath    = { $global:MenuActions.Add('refresh-path') }
            Folder         = {
                param([string]$Name)
                switch ($Name) {
                    'LocalAppData' { Join-Path $global:MenuRoot 'LocalAppData' }
                    'ProgramFiles' { Join-Path $global:MenuRoot 'ProgramFiles' }
                    'Downloads' { Join-Path $global:MenuRoot 'Downloads' }
                    'Pwsh' { 'C:\Program Files\PowerShell\7\pwsh.exe' }
                }
            }
        }
        foreach ($k in $Probe.Keys) { $probes[$k] = $Probe[$k] }
        $ui = @{
            Say   = { param([string]$Text = '', [string]$Color = 'Gray') $null = $Color; $global:MenuOut.Add($Text) }
            Ask   = { param([string]$Prompt) $global:MenuOut.Add("?? $Prompt"); if ($global:MenuAnswers.Count) { $global:MenuAnswers.Dequeue() } else { $null } }
            Key   = { param([string]$Prompt) $global:MenuOut.Add("-- $Prompt") }
            Clear = { $global:MenuOut.Add('<clear>') }
        }
        if (-not $Controller) { $Controller = { param([hashtable]$Arguments) throw "the controller was not expected: $($Arguments | ConvertTo-Json -Compress)" } }
        $params = @{ RepoRoot = $repo; TopologyPath = $topologyPath; Probe = $probes; Ui = $ui; Controller = $Controller; Plain = $true }
        if ($Machine) { $params['Machine'] = $Machine }
        New-MenuContext @params
    }

    function Add-Answer([string[]]$Answer) { foreach ($a in $Answer) { $global:MenuAnswers.Enqueue($a) } }
    function Get-Out { $global:MenuOut -join "`n" }
    function Get-Log([hashtable]$Ctx) { if (Test-Path -LiteralPath $Ctx.LogPath) { [IO.File]::ReadAllText($Ctx.LogPath) } else { '' } }
    function Get-SavedMenu([hashtable]$Ctx) { Get-Content -LiteralPath $Ctx.MenuPath -Raw | ConvertFrom-Json -AsHashtable }

    function New-Report([string]$Status, [string[]]$Lines) { [pscustomobject]@{ Mode = 'Execute'; Stage = 1; Status = $Status; Lines = [string[]]$Lines; Run = $null; Check = $null } }

    function Set-ControllerState([hashtable]$Ctx, [hashtable]$Stages, [string]$Commit) {
        $null = New-Item -ItemType Directory -Path $Ctx.StateRoot -Force
        $s = @{ formatVersion = 1; release = @{}; stages = @{}; owned = @() }
        if ($Commit) { $s['release'] = @{ commit = $Commit; manifests = @{} } }
        foreach ($k in $Stages.Keys) { $s['stages']["$k"] = @{ status = $Stages[$k]; attempts = 1; accepted = @(); data = @{} } }
        [IO.File]::WriteAllText($Ctx.StatePath, ($s | ConvertTo-Json -Depth 10))
    }

    function Set-PrepDone([hashtable]$Ctx) {
        foreach ($id in '1a', '1b', '2', '3') { $Ctx.Menu['steps'][$id] = @{ status = 'done'; confirmed = @(); skipped = @{}; last = @() } }
    }

    function New-KeyBlob {
        $type = [Text.Encoding]::ASCII.GetBytes('ssh-ed25519')
        $key = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($key)
        [Convert]::ToBase64String([byte[]](@(0, 0, 0, $type.Length) + $type + @(0, 0, 0, 32) + $key))
    }
}

Describe 'The catalogue' {
    It 'has steps 1a, 1b, 2 and 3, then 4 to 14 for Stages 1 to 11' {
        $steps = @(Get-RecoveryMenuStep)
        @($steps | ForEach-Object { $_.Id }) | Should -Be (@('1a', '1b', '2', '3') + @(4..14 | ForEach-Object { "$_" }))
        @($steps | Where-Object Kind -EQ 'stage' | ForEach-Object { $_.Stage }) | Should -Be @(1..11)
        @($steps | Where-Object Admin | ForEach-Object { $_.Stage }) | Should -Be @(3, 8)
    }

    It 'gives each stage the same needs as the controller' {
        $text = Get-Content -LiteralPath (Join-Path $script:Repo 'Invoke-StackRecovery.ps1') -Raw
        foreach ($s in @(Get-RecoveryMenuStep | Where-Object Kind -EQ 'stage')) {
            $text -match "(?m)^\s+$($s.Stage)\s+= @\{ Title = '[^']+'; Needs = @\(([0-9, ]*)\)" | Should -BeTrue -Because "Stage $($s.Stage) is in the controller's catalogue"
            $want = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { [int]$_ })
            @($s.Needs) | Should -Be $want -Because "Stage $($s.Stage)'s needs"
        }
    }

    It 'installs the PowerShell 7 the manifest records, in Install-PowerShell7.cmd' {
        $apps = Get-Content -LiteralPath (Join-Path $script:Repo 'manifests/windows-apps.json') -Raw | ConvertFrom-Json -AsHashtable
        $version = @($apps['packages'] | Where-Object { $_['id'] -eq 'Microsoft.PowerShell' })[0]['version']
        Get-Content -LiteralPath (Join-Path $script:Repo 'Install-PowerShell7.cmd') -Raw | Should -Match ([regex]::Escape("--version $version "))
    }

    It 'pins Git, Tailscale and Libre Hardware Monitor at the versions Stage 3 records' {
        $ctx = New-TestMenu
        $apps = @{}
        foreach ($p in @($ctx.Apps['packages'])) { $apps[$p['id']] = $p['version'] }
        foreach ($p in @(Get-MenuPackage -Ctx $ctx | Where-Object { $_.Version })) { $p.Version | Should -Be $apps[$p.Id] }
        @(Get-MenuPackage -Ctx $ctx | Where-Object { $_.Version } | ForEach-Object { $_.Id }) | Should -Be @('Git.Git', 'Tailscale.Tailscale', 'LibreHardwareMonitor.LibreHardwareMonitor')
    }
}

Describe 'The records' {
    It 'starts a new record, and saves it in the state root through the path check' {
        $ctx = New-TestMenu
        $ctx.Menu['answers']['x'] = 'y'
        Test-Path -LiteralPath $ctx.StateRoot | Should -BeFalse
        Add-Answer 'y'
        $task = @{ Id = 't'; Title = 'A thing'; Confirm = $true; Required = $true; Question = 'Done?' }
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'ok'
        (Get-SavedMenu $ctx)['answers']['x'] | Should -Be 'y'
        @(Get-ChildItem -LiteralPath $ctx.StateRoot -Filter '*.tmp') | Should -BeNullOrEmpty
    }

    It 'reads an unreadable record as a problem and a new record' {
        $f = Join-Path $TestDrive 'bad-menu.json'
        [IO.File]::WriteAllText($f, '{ not json')
        $r = Read-MenuState -Path $f
        $r.Problem | Should -Match 'not a menu record'
        $r.State['formatVersion'] | Should -Be 1
    }
}

Describe 'A task' {
    It 'passes without a question when its check passes' {
        $ctx = New-TestMenu
        $task = @{ Id = 't'; Title = 'Thing'; Required = $true; Check = { New-TaskCheck $true 'fine' } }
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'ok'
        Get-Out | Should -Not -Match '\?\?'
        Get-Log $ctx | Should -Match 'ok   Thing: fine'
    }

    It 'shows what to do, and checks again after y until it passes' {
        $ctx = New-TestMenu
        $global:Fixed = $false
        $task = @{
            Id = 't'; Title = 'Thing'; Required = $true; Question = 'Have you fixed it?'; Steps = @('Do the thing.')
            Check = { if ($global:Fixed) { New-TaskCheck $true 'fixed' } else { $global:Fixed = $true; New-TaskCheck $false 'broken' -Hint 'Here is why.' } }
        }
        Add-Answer 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'ok'
        $out = Get-Out
        $out | Should -Match 'Thing: broken'
        $out | Should -Match 'Here is why'
        $out | Should -Match '1\. Do the thing\.'
        $out | Should -Match 'Thing: fixed'
        Get-Log $ctx | Should -Match '(?s)FAIL Thing: broken.*ok   Thing: fixed'
    }

    It 'never lets a task the rebuild needs be skipped, and q goes back with progress kept' {
        $ctx = New-TestMenu
        $task = @{ Id = 't'; Title = 'Thing'; Required = $true; Check = { New-TaskCheck $false 'broken' } }
        Add-Answer 's', 'n', 'q'
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'quit'
        Get-Out | Should -Match 'Please type one of: y, n, q'
        Get-Out | Should -Match 'No rush'
    }

    It 'skips an optional task with a reason, kept in the record and never asked again' {
        $ctx = New-TestMenu
        $task = @{ Id = 'opt'; Title = 'Nice to have'; Required = $false; Check = { New-TaskCheck $false 'missing' } }
        Add-Answer 's', 'not today'
        Invoke-MenuTask -Ctx $ctx -StepId '2' -Task $task | Should -Be 'skipped'
        (Get-SavedMenu $ctx)['steps']['2']['skipped']['opt'] | Should -Be 'not today'
        Get-Log $ctx | Should -Not -Match 'not today'
        $global:MenuOut.Clear()
        Invoke-MenuTask -Ctx $ctx -StepId '2' -Task $task | Should -Be 'skipped'
        Get-Out | Should -Match 'skipped earlier \(not today\)'
    }

    It 'remembers a confirmation, so it is not asked again after a restart' {
        $ctx = New-TestMenu
        $task = @{ Id = 'signin'; Title = 'Signed in'; Required = $true; Confirm = $true; Question = 'Signed in?' }
        Add-Answer 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '2' -Task $task | Should -Be 'ok'
        $again = New-MenuContext -RepoRoot $ctx.RepoRoot -TopologyPath (Join-Path (Split-Path $ctx.RepoRoot) 'topology.json') -Probe $ctx.Probe -Ui $ctx.Ui -Controller $ctx.Controller -Plain
        $global:MenuOut.Clear()
        Invoke-MenuTask -Ctx $again -StepId '2' -Task $task | Should -Be 'ok'
        Get-Out | Should -Match 'you confirmed this'
        Get-Out | Should -Not -Match '\?\?'
    }

    It 'asks before it does something for you, then checks again' {
        $ctx = New-TestMenu
        $global:Done = $false
        $task = @{
            Id = 't'; Title = 'Thing'; Required = $true; AutoAsk = 'Do it for you?'
            Check = { New-TaskCheck $global:Done $(if ($global:Done) { 'done' } else { 'not yet' }) }
            Auto = { $global:Done = $true }
        }
        Add-Answer 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'ok'
        Get-Out | Should -Match '\?\? +Do it for you\?'
        Get-Out | Should -Match 'Thing: done'
    }
}

Describe 'Step 1a: GitHub Desktop and the repo' {
    It 'reads the clone, its origin and its branch without git' {
        $ctx = New-TestMenu
        $tasks = @(Get-PrepTask -Ctx $ctx -StepId '1a')
        (& ($tasks | Where-Object Id -EQ 'clone').Check $ctx).Ok | Should -BeTrue
        $branch = & ($tasks | Where-Object Id -EQ 'branch').Check $ctx
        $branch.Ok | Should -BeTrue
        $branch.Detail | Should -Be ('main, at ' + ('a' * 12))
    }

    It 'names only owner/repo for another origin, never the URL' {
        $ctx = New-TestMenu
        $url = 'https://someone:' + ('hunter' + '2') + '@example.com/other/repo.git'   # built at run time: no URL with a password in this file
        [IO.File]::WriteAllText((Join-Path $ctx.RepoRoot '.git/config'), "[remote `"origin`"]`n`turl = $url`n")
        $c = & (@(Get-PrepTask -Ctx $ctx -StepId '1a') | Where-Object Id -EQ 'clone').Check $ctx
        $c.Ok | Should -BeFalse
        $c.Detail | Should -Match 'another place'
        $c.Detail | Should -Not -Match 'hunter2|example\.com'
    }

    It 'prints how to pull, and waits for a key' {
        $ctx = New-TestMenu
        $global:MenuExec = { param($Name, $Arguments) if ($Name -eq 'git') { New-ExecResult 0 @() } else { New-ExecResult -1 @() } }
        $null = New-Item -ItemType Directory -Path (Join-Path $global:MenuRoot 'LocalAppData/GitHubDesktop')
        [IO.File]::WriteAllText((Join-Path $global:MenuRoot 'LocalAppData/GitHubDesktop/GitHubDesktop.exe'), 'x')
        Add-Answer 'y'
        Invoke-MenuStep -Ctx $ctx -Id '1a' | Should -Be 'done'
        $out = Get-Out
        $out | Should -Match 'Fetch origin, then Pull origin'
        $out | Should -Match 'pull --ff-only'
        $out | Should -Match '-- Press any key'
        (Get-SavedMenu $ctx)['steps']['1a']['status'] | Should -Be 'done'
    }
}

Describe 'Step 1b: Windows and the drives' {
    It 'starts with the board''s own drivers, before Windows Update' {
        $ids = @(Get-PrepTask -Ctx (New-TestMenu) -StepId '1b' | ForEach-Object { $_.Id })
        $ids[0..4] | Should -Be @('win11', 'board-chipset', 'board-drivers', 'wu-drivers', 'updates')
    }

    It 'opens AMD''s chipset page for this board''s chipset in Edge, and passes once the chipset driver is installed' {
        $ctx = New-TestMenu -Probe @{ Programs = { @(@{ Name = 'Realtek Audio Driver'; Version = '1' }) } }
        $task = @(Get-PrepTask -Ctx $ctx -StepId '1b') | Where-Object Id -EQ 'board-chipset'
        $c = & $task.Check $ctx $task
        $c.Ok | Should -BeFalse
        $c.Detail | Should -Be 'not installed, for your ASUS ROG STRIX X670E-F GAMING WIFI'
        & $task.Auto $ctx $task
        $global:MenuActions | Should -Contain 'open microsoft-edge:https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/x670e.html'
        $ctx.Probe.Programs = { @(@{ Name = 'AMD Chipset Software'; Version = '7.06.02.123' }) }
        (& $task.Check $ctx $task).Detail | Should -Be 'AMD Chipset Software 7.06.02.123 is installed'
    }

    It 'opens the board''s own ASUS page in Edge for LAN, Wi-Fi, Bluetooth and audio' {
        $ctx = New-TestMenu
        $task = @(Get-PrepTask -Ctx $ctx -StepId '1b') | Where-Object Id -EQ 'board-drivers'
        Add-Answer 'y', 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'ok'
        $global:MenuActions | Should -Contain 'open microsoft-edge:https://rog.asus.com/motherboards/rog-strix/rog-strix-x670e-f-gaming-wifi-model/helpdesk_download/'
        (Get-SavedMenu $ctx)['steps']['1b']['confirmed'] | Should -Contain 'board-drivers'
    }

    It 'sends another ASUS board to ASUS''s download centre, another maker''s board to its own site, and an unknown chipset to AMD''s finder' {
        $ctx = New-TestMenu -Probe @{ Board = { @{ Maker = 'ASUSTeK COMPUTER INC.'; Product = 'TUF GAMING B650-PLUS' } } }
        $tasks = @(Get-PrepTask -Ctx $ctx -StepId '1b')
        $chipset = $tasks | Where-Object Id -EQ 'board-chipset'
        $board = $tasks | Where-Object Id -EQ 'board-drivers'
        & $board.Auto $ctx $board
        & $chipset.Auto $ctx $chipset
        $global:MenuActions | Should -Contain 'open microsoft-edge:https://www.asus.com/support/download-center/'
        $global:MenuActions | Should -Contain 'open microsoft-edge:https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/b650.html'
        $ctx = New-TestMenu -Probe @{ Board = { @{ Maker = 'Micro-Star International Co., Ltd.'; Product = 'MAG TOMAHAWK' } } }
        & $board.Auto $ctx $board
        & $chipset.Auto $ctx $chipset
        @($global:MenuActions) | Should -Be @('open microsoft-edge:https://www.amd.com/en/support/download/drivers.html')
        Get-Out | Should -Match 'not an ASUS board \(your Micro-Star International Co., Ltd. MAG TOMAHAWK\)'
    }

    It 'installs CrystalDiskInfo and CrystalDiskMark only when missing, before the drives are chosen' {
        $ctx = New-TestMenu
        $global:MenuExec = { param($Name, $Arguments) if ($Arguments[0] -eq 'list' -and $Arguments[2] -eq 'CrystalDewWorld.CrystalDiskInfo') { New-ExecResult 0 @() } elseif ($Arguments[0] -eq 'list') { New-ExecResult -1978335212 @() } else { New-ExecResult 0 @() } }
        $tasks = @(Get-PrepTask -Ctx $ctx -StepId '1b')
        $ids = @($tasks | ForEach-Object { $_.Id })
        [array]::IndexOf($ids, 'disk-test') | Should -BeLessThan ([array]::IndexOf($ids, 'drive:E'))
        [array]::IndexOf($ids, 'disk-test') | Should -BeGreaterThan ([array]::IndexOf($ids, 'winget'))
        $task = $tasks | Where-Object Id -EQ 'disk-test'
        $task.Required | Should -BeFalse
        Add-Answer 'y', 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'ok'
        @($global:MenuCalls | Where-Object { $_ -like 'winget install *' }) | Should -Be @('winget install --id CrystalDewWorld.CrystalDiskMark --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity')
        Get-Out | Should -Match 'CrystalDiskInfo is already installed'
        Get-Out | Should -Match 'SEQ1M Q8T1'
    }

    It 'keeps drivers out of Windows Update in an admin window, adding to the policy key rather than replacing it' {
        $ctx = New-TestMenu -Probe @{ DriverUpdatesOff = { $false } }
        $task = @(Get-PrepTask -Ctx $ctx -StepId '1b') | Where-Object Id -EQ 'wu-drivers'
        $task.Required | Should -BeFalse
        (& $task.Check $ctx $task).Ok | Should -BeFalse
        & $task.Auto $ctx $task
        $cmd = @($global:MenuActions | Where-Object { $_ -like 'elevated *' })[0]
        $cmd | Should -Match 'ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord'
        $cmd | Should -Match 'if \(-not \(Test-Path -LiteralPath \$k\)\) \{ \$null = New-Item'
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput(($cmd -replace '^elevated ', ''), [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'checks every drive the stack uses, including D: for the Hugging Face cache' {
        $ctx = New-TestMenu -Probe @{ Drive = { param([string]$Letter) if ($Letter -eq 'D') { @{ Exists = $false; Ready = $false } } else { @{ Exists = $true; Ready = $true; Format = 'NTFS'; Free = [long]900GB; Size = [long]1800GB } } } }
        $tasks = @(Get-PrepTask -Ctx $ctx -StepId '1b')
        $d = $tasks | Where-Object Id -EQ 'drive:D'
        $d.Title | Should -Match 'HF_HOME'
        $d.Required | Should -BeFalse
        (& $d.Check $ctx $d).Detail | Should -Be 'there is no such drive'
        @($d.Steps) -join ' ' | Should -Match 'Storage Spaces'
    }

    It 'finds stack folders from before Stage 1 and renames them aside when you say yes' {
        $ctx = New-TestMenu
        $stack = Join-Path $global:MenuRoot 'ai/ollama'
        $null = New-Item -ItemType Directory -Path $stack -Force
        [IO.File]::WriteAllText((Join-Path $stack 'docker-compose.yml'), 'old')
        $ctx.Topology['roots']['stack']['path'] = $stack
        $ctx.Topology['roots']['dashboard']['path'] = Join-Path $global:MenuRoot 'ai/dashboard'
        $task = @(Get-PrepTask -Ctx $ctx -StepId '1b') | Where-Object Id -EQ 'leftovers'
        Add-Answer 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'ok'
        Test-Path -LiteralPath $stack | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $global:MenuRoot 'ai/ollama-before-rebuild-20261010/docker-compose.yml') | Should -BeTrue
    }

    It 'leaves the stack folders alone once Stage 1 has run' {
        $ctx = New-TestMenu
        $stack = Join-Path $global:MenuRoot 'ai/ollama'
        $null = New-Item -ItemType Directory -Path $stack -Force
        [IO.File]::WriteAllText((Join-Path $stack 'x'), 'x')
        $ctx.Topology['roots']['stack']['path'] = $stack
        Set-ControllerState $ctx @{ 1 = 'done' }
        $task = @(Get-PrepTask -Ctx $ctx -StepId '1b') | Where-Object Id -EQ 'leftovers'
        (& $task.Check $ctx $task).Ok | Should -BeTrue
    }

    It 'offers a restart when one is pending, and sets the menu to open again after it' {
        $ctx = New-TestMenu -Probe @{ RebootPending = { $true } }
        $task = @(Get-PrepTask -Ctx $ctx -StepId '1b') | Where-Object Id -EQ 'reboot'
        Add-Answer 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '1b' -Task $task | Should -Be 'quit'
        $ctx.Restarting | Should -BeTrue
        $global:MenuActions | Should -Contain 'restart'
        $run = @($global:MenuActions | Where-Object { $_ -like 'runonce *' })[0]
        $run | Should -Match 'Start-Recovery\.ps1'
        ($run -replace '^runonce OllamaCriaRecoveryMenu ', '').Length | Should -BeLessOrEqual 260
    }
}

Describe 'Step 2: apps, the driver and Tailscale' {
    BeforeAll {
        $script:Domain = 'example-tailnet' + '.ts' + '.net'
        $script:PcIp = @('100', '64', '0', '7') -join '.'
        $script:VpsIp = @('100', '64', '0', '8') -join '.'
        function New-TailscaleJson([string]$Name, [bool]$VpsOnline = $true, [switch]$Expires) {
            $self = @{ DNSName = "$Name.$($script:Domain)."; TailscaleIPs = @($script:PcIp); Online = $true }
            if ($Expires) { $self['KeyExpiry'] = '2027-04-01T00:00:00Z' }
            @{
                BackendState = 'Running'; Self = $self
                Peer = @{ 'nodekey:1' = @{ DNSName = "vps.$($script:Domain)."; TailscaleIPs = @($script:VpsIp); Online = $VpsOnline } }
            } | ConvertTo-Json -Depth 5
        }
    }

    It 'installs pinned apps at their version, and offers the newest when that version fails' {
        $ctx = New-TestMenu
        $global:Tries = 0
        $global:MenuExec = { param($Name, $Arguments) $global:Tries++; if ($Arguments -contains '--version') { New-ExecResult -1978335212 } else { New-ExecResult 0 } }
        $git = @(Get-MenuPackage -Ctx $ctx)[0]
        Add-Answer 'y'
        (Install-MenuPackage -Ctx $ctx -Package $git).Status | Should -Be 'installed'
        $global:MenuCalls[0] | Should -Match "install --id Git\.Git --exact --source winget .*--version $([regex]::Escape($git.Version))"
        $global:MenuCalls[1] | Should -Not -Match '--version'
    }

    It 'treats the restart codes as installed, and offers the restart at the end of the step' {
        $ctx = New-TestMenu
        $global:MenuExec = { param($Name, $Arguments) New-ExecResult 3010 }
        (Install-MenuPackage -Ctx $ctx -Package @{ Id = 'X.Y'; Name = 'XY' }).Status | Should -Be 'restart'
        $ctx.RestartNeeded | Should -BeTrue
    }

    It 'installs every missing app in one go once you say yes, then refreshes PATH' {
        $ctx = New-TestMenu
        $global:Installed = [Collections.Generic.HashSet[string]]::new()
        $global:MenuExec = {
            param($Name, $Arguments)
            if ($Arguments[0] -eq 'list') { if ($global:Installed.Contains($Arguments[2])) { New-ExecResult 0 } else { New-ExecResult -1978335212 } }
            elseif ($Arguments[0] -eq 'install') { $null = $global:Installed.Add($Arguments[2]); New-ExecResult 0 }
            else { New-ExecResult 0 }
        }
        $null = $global:Installed.Add('Git.Git')
        Add-Answer 'y'
        & (Get-Module RecoveryMenu) { param($c) Invoke-AppInstallBatch $c } $ctx | Should -Be 'ok'
        $installs = @($global:MenuCalls | Where-Object { $_ -like 'winget install *' })
        $installs.Count | Should -Be (@(Get-MenuPackage -Ctx $ctx).Count - 1)
        @($installs | Where-Object { $_ -match '--id 9PLM9XGG6VKS --exact --source msstore' }).Count | Should -Be 1
        $global:MenuActions | Should -Contain 'refresh-path'
    }

    It "shows only the node's first label, never the tailnet domain or an address" {
        $ctx = New-TestMenu
        $global:Json = New-TailscaleJson 'pc-1'
        $global:MenuExec = { param($Name, $Arguments) if ($Name -eq 'tailscale') { New-ExecResult 0 ($global:Json -split "`n") } else { New-ExecResult 0 } }
        $task = @(Get-PrepTask -Ctx $ctx -StepId '2') | Where-Object Id -EQ 'ts-name'
        Add-Answer 'n', 'q'
        Invoke-MenuTask -Ctx $ctx -StepId '2' -Task $task | Should -Be 'quit'
        $out = Get-Out
        $out | Should -Match "this PC is 'pc-1', not 'pc'"
        $out | Should -Not -Match ([regex]::Escape($script:Domain))
        $out | Should -Not -Match ([regex]::Escape($script:PcIp))
        Get-Log $ctx | Should -Not -Match ([regex]::Escape($script:Domain))
        $global:Json = New-TailscaleJson 'pc'
        (& $task.Check $ctx $task).Ok | Should -BeTrue
    }

    It 'sees the VPS node, and a key that expires' {
        $ctx = New-TestMenu
        $global:Json = New-TailscaleJson 'pc' -VpsOnline $false -Expires
        $global:MenuExec = { param($Name, $Arguments) New-ExecResult 0 ($global:Json -split "`n") }
        $v = Get-TailscaleView -Ctx $ctx
        $v.Name | Should -Be 'pc'
        $v.VpsFound | Should -BeTrue
        $v.VpsOnline | Should -BeFalse
        $v.KeyExpiry | Should -BeTrue
        ($v.Values | ForEach-Object { "$_" }) -join ' ' | Should -Not -Match ([regex]::Escape($script:Domain))
    }

    It 'turns Windows Search off in an admin window once you say yes' {
        $ctx = New-TestMenu -Probe @{ Service = { param([string]$Name) $null = $Name; if ($global:MenuActions -match '^elevated') { @{ StartType = 'Disabled'; Status = 'Stopped' } } else { @{ StartType = 'Automatic'; Status = 'Running' } } } }
        $task = @(Get-PrepTask -Ctx $ctx -StepId '2') | Where-Object Id -EQ 'search-off'
        Add-Answer 'y'
        Invoke-MenuTask -Ctx $ctx -StepId '2' -Task $task | Should -Be 'ok'
        @($global:MenuActions | Where-Object { $_ -like 'elevated *Set-Service -Name WSearch -StartupType Disabled*' }).Count | Should -Be 1
    }

    It 'asks for sign-ins only to apps you did not skip' {
        $ctx = New-TestMenu
        $ctx.Menu['steps']['2'] = @{ status = 'todo'; confirmed = @(); skipped = @{ 'app:9PLM9XGG6VKS' = 'later' }; last = @() }
        $task = @(Get-PrepTask -Ctx $ctx -StepId '2') | Where-Object Id -EQ 'signin:9PLM9XGG6VKS'
        Invoke-MenuTask -Ctx $ctx -StepId '2' -Task $task | Should -Be 'ok'
        Get-Out | Should -Match 'Signed in to ChatGPT: not needed here'
    }
}

Describe 'Step 3: the secrets bundle' {
    BeforeEach {
        $script:Ctx = New-TestMenu
        $null = New-Item -ItemType Directory -Path $script:Ctx.StagingRoot
        $script:Zip = Join-Path $script:Ctx.StagingRoot 'stack-secrets-20261010T000121Z.zip'
        New-ZipFile $script:Zip @('00-RESTORE-MAP.json', '01/stack.env', '03/values.json')
        $script:Sha = (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'checks the SHA-256 you paste, and records it only when it matches' {
        $task = @(Get-PrepTask -Ctx $script:Ctx -StepId '3') | Where-Object Id -EQ 'sha'
        Add-Answer 'not a hash', ('0' * 64), $script:Sha.ToUpperInvariant()
        Invoke-MenuTask -Ctx $script:Ctx -StepId '3' -Task $task | Should -Be 'ok'
        $out = Get-Out
        $out | Should -Match 'That is not a SHA-256'
        $out | Should -Match 'They differ'
        $out | Should -Not -Match 'not a hash'
        $saved = Get-SavedMenu $script:Ctx
        $saved['answers']['bundleSha256'] | Should -Be $script:Sha
        $saved['answers']['bundleName'] | Should -Be 'stack-secrets-20261010T000121Z.zip'
        Get-Log $script:Ctx | Should -Not -Match '0{64}'
    }

    It 'runs the whole step: the folder is there, one ZIP, the hash, the full bundle' {
        Add-Answer $script:Sha
        Invoke-MenuStep -Ctx $script:Ctx -Id '3' | Should -Be 'done'
        (Get-SavedMenu $script:Ctx)['steps']['3']['status'] | Should -Be 'done'
        Get-Out | Should -Match 'the full bundle'
    }

    It 'makes the protected folder when it is missing' {
        Remove-Item -LiteralPath $script:Ctx.StagingRoot -Recurse -Force
        $task = @(Get-PrepTask -Ctx $script:Ctx -StepId '3') | Where-Object Id -EQ 'staging'
        Invoke-MenuTask -Ctx $script:Ctx -StepId '3' -Task $task | Should -Be 'ok'
        $global:MenuActions | Should -Contain "protected $($script:Ctx.StagingRoot)"
    }

    It 'refuses an old folder this account cannot use' {
        $ctx = New-TestMenu -Probe @{ Protection = { param([string]$Path) $null = $Path; 'it is owned by another account' } }
        $null = New-Item -ItemType Directory -Path $ctx.StagingRoot
        $task = @(Get-PrepTask -Ctx $ctx -StepId '3') | Where-Object Id -EQ 'old-staging'
        $c = & $task.Check $ctx $task
        $c.Ok | Should -BeFalse
        $c.Detail | Should -Match 'owned by another account'
        @($task.Steps) -join ' ' | Should -Match 'rename'
    }

    It 'stops on an unzipped copy beside the ZIP' {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Ctx.StagingRoot 'stack-secrets-20261010T000121Z')
        $task = @(Get-PrepTask -Ctx $script:Ctx -StepId '3') | Where-Object Id -EQ 'zip'
        $c = & $task.Check $script:Ctx $task
        $c.Ok | Should -BeFalse
        $c.Detail | Should -Match 'unzipped copy'
    }

    It 'tells the full bundle from a folder zipped again and from the safety copy' {
        (Test-BundleShape -Entry @('00-RESTORE-MAP.json', '03/values.json')).Ok | Should -BeTrue
        (Test-BundleShape -Entry @('stack-secrets-x/00-RESTORE-MAP.json', 'stack-secrets-x/03/v.json')).Detail | Should -Match 'one folder down'
        (Test-BundleShape -Entry @('00-RESTORE-MAP.json', '01/stack.env')).Detail | Should -Match 'safety copy'
        (Test-BundleShape -Entry @('readme.txt')).Detail | Should -Match 'not a stack-secrets bundle'
    }
}

Describe 'Steps 4 to 14: the stages' {
    It 'needs the SHA-256 from step 3 before Stage 1' {
        $ctx = New-TestMenu
        Set-PrepDone $ctx
        Invoke-MenuStep -Ctx $ctx -Id '4' | Should -Be 'failed'
        Get-Out | Should -Match 'do step 3 first'
    }

    It 'runs Stage 1 with the recorded SHA-256 and records the result' {
        $global:Calls = [Collections.Generic.List[hashtable]]::new()
        $ctx = New-TestMenu -Controller { param([hashtable]$Arguments) $global:Calls.Add($Arguments.Clone()); New-Report 'done' @('Stage 1  Recovery release  [EXECUTE]', '  CHECK ok   repo: clean', '  Result: done.') }
        Set-PrepDone $ctx
        $ctx.Menu['answers']['bundleSha256'] = 'b' * 64
        Add-Answer 'y'
        Invoke-MenuStep -Ctx $ctx -Id '4' | Should -Be 'done'
        $global:Calls[0]['Stage'] | Should -Be 1
        $global:Calls[0]['BundleSha256'] | Should -Be ('b' * 64)
        (Get-SavedMenu $ctx)['steps']['4']['status'] | Should -Be 'done'
        Get-Out | Should -Match 'do not pull until the rebuild is finished'
    }

    It 'answers an ASK by its id, then runs the stage again with it' {
        $global:Calls = [Collections.Generic.List[hashtable]]::new()
        $ctx = New-TestMenu -Controller {
            param([hashtable]$Arguments)
            $global:Calls.Add($Arguments.Clone())
            if ($Arguments['Accept'] -contains 'gpu') { New-Report 'done' @('  Result: done.') }
            else { New-Report 'needs-user' @('  ASK      [gpu] No NVIDIA driver answers. Install it, then run again.', '  Result: needs you.') }
        }
        Set-PrepDone $ctx
        Set-ControllerState $ctx @{ 1 = 'done' }
        Add-Answer 'y', 'y', 'y'
        Invoke-MenuStep -Ctx $ctx -Id '6' | Should -Be 'done'
        $global:Calls.Count | Should -Be 2
        @($global:Calls[1]['Accept']) | Should -Be @('gpu')
        Get-Out | Should -Match 'admin rights'
    }

    It 'turns a moved repo into a way back to step 4' {
        $ctx = New-TestMenu -Controller { param([hashtable]$Arguments) $null = $Arguments; New-Report 'failed' @('Stage 7 does not run: the repo is at abcdef012345, not 0123456789ab as Stage 1 checked. Check out the release, or run -Stage 1 -Execute again.') }
        Set-PrepDone $ctx
        Set-ControllerState $ctx @{ 1 = 'done'; 2 = 'done'; 3 = 'done'; 4 = 'done'; 5 = 'done'; 6 = 'done' }
        Add-Answer 'y', 'go4'
        Invoke-MenuStep -Ctx $ctx -Id '10' | Should -Be '4'
        Get-Out | Should -Match 'Run step 4 \(Stage 1\) again'
    }

    It 'offers the step a stage needs first, and never calls the controller for it' {
        $ctx = New-TestMenu
        Set-PrepDone $ctx
        Set-ControllerState $ctx @{ 1 = 'done'; 2 = 'done'; 3 = 'done' }
        Add-Answer 'y'
        Invoke-MenuStep -Ctx $ctx -Id '8' | Should -Be '7'
        Get-Out | Should -Match 'needs Stage 4 first \(step 7\)'
    }

    It 'stops at the gate while steps 1a to 3 are open, unless you type SKIP' {
        $ctx = New-TestMenu
        Add-Answer ''
        Invoke-MenuStep -Ctx $ctx -Id '4' | Should -Be 'none'
        Get-Out | Should -Match 'Steps 1a, 1b, 2, 3 are not done yet'
    }

    It 'offers a restart when a stage asks for one' {
        $ctx = New-TestMenu -Controller { param([hashtable]$Arguments) $null = $Arguments; New-Report 'reboot' @('  Result: restart the PC.') }
        Set-PrepDone $ctx
        Set-ControllerState $ctx @{ 1 = 'done' }
        Add-Answer 'y', 'y'
        Invoke-MenuStep -Ctx $ctx -Id '6' | Should -Be 'reboot'
        $global:MenuActions | Should -Contain 'restart'
    }

    Context 'Stage 2: keep the VPS' {
        BeforeAll {
            function New-SshMachine([string]$Known, [string]$Offered) {
                $global:KnownHosts = Join-Path $TestDrive 'known_hosts'
                [IO.File]::WriteAllText($global:KnownHosts, "vps ssh-ed25519 $Known`n")
                $global:Offered = $Offered
                @{
                    Exec = {
                        param([string]$Name, [string[]]$Arguments = @(), [switch]$Stream)
                        $null = $Stream
                        if ($Name -eq 'ssh' -and $Arguments[0] -eq '-G') { return New-ExecResult 0 @('hostname vps', 'port 22', "userknownhostsfile $global:KnownHosts") }
                        if ($Name -eq 'ssh-keyscan') { return New-ExecResult 0 @("vps ssh-ed25519 $global:Offered") }
                        New-ExecResult 0
                    }
                }
            }
        }

        It 'trusts the key filed in the backup, then runs Stage 2 with it' {
            $blob = New-KeyBlob
            $global:Calls = [Collections.Generic.List[hashtable]]::new()
            $ctx = New-TestMenu -Machine (New-SshMachine $blob $blob) -Controller {
                param([hashtable]$Arguments)
                $global:Calls.Add($Arguments.Clone())
                if ($Arguments['HostKeyFingerprint']) { New-Report 'done' @('  Result: done.') }
                else { New-Report 'needs-user' @('  ASK      [vps-bootstrap] Rebuild the VPS with Ubuntu 24.04 in the provider''s console.') }
            }
            Set-PrepDone $ctx
            Set-ControllerState $ctx @{ 1 = 'done' }
            Add-Answer 'y', 'k', 'y'
            Invoke-MenuStep -Ctx $ctx -Id '5' | Should -Be 'done'
            $global:Calls[1]['HostKeyFingerprint'] | Should -Be (Get-SshKeyFingerprint -Blob $blob)
            @($global:Calls[1]['Accept']) | Should -Be @('vps-bootstrap')
            (Get-SavedMenu $ctx)['answers']['vps'] | Should -Be 'keep'
        }

        It 'stops when the VPS offers a different key from the backup' {
            $ctx = New-TestMenu -Machine (New-SshMachine (New-KeyBlob) (New-KeyBlob)) -Controller {
                param([hashtable]$Arguments)
                if ($Arguments['HostKeyFingerprint']) { throw 'must not run' }
                New-Report 'needs-user' @('  ASK      [vps-bootstrap] Rebuild the VPS.')
            }
            Set-PrepDone $ctx
            Set-ControllerState $ctx @{ 1 = 'done' }
            Add-Answer 'y', 'k'
            Invoke-MenuStep -Ctx $ctx -Id '5' | Should -Be 'needs-user'
            Get-Out | Should -Match 'different host keys'
        }

        It 'rebuilds only after REBUILD is typed, and checks the fingerprint you give' {
            $blob = New-KeyBlob
            $fp = Get-SshKeyFingerprint -Blob $blob
            $global:Calls = [Collections.Generic.List[hashtable]]::new()
            $ctx = New-TestMenu -Controller {
                param([hashtable]$Arguments)
                $global:Calls.Add($Arguments.Clone())
                if ($Arguments['HostKeyFingerprint']) { New-Report 'done' @('  Result: done.') }
                else { New-Report 'needs-user' @('  ASK      [vps-bootstrap] Rebuild the VPS.') }
            }
            Set-PrepDone $ctx
            Set-ControllerState $ctx @{ 1 = 'done' }
            Add-Answer 'y', 'r', 'rebuild'
            Invoke-MenuStep -Ctx $ctx -Id '5' | Should -Be 'needs-user'
            $ctx.Menu['answers']['vps'] | Should -BeNullOrEmpty
            Add-Answer 'y', 'r', 'REBUILD', 'y', 'SHA256:short', $fp
            Invoke-MenuStep -Ctx $ctx -Id '5' | Should -Be 'done'
            $global:Calls[-1]['HostKeyFingerprint'] | Should -Be $fp
            Get-Out | Should -Match 'That is not a fingerprint'
        }
    }
}

Describe 'The menu' {
    It 'shows every step with its mark, and Enter runs the next one' {
        $ctx = New-TestMenu
        $ctx.Menu['steps']['1a'] = @{ status = 'done'; confirmed = @(); skipped = @{}; last = @() }
        Set-ControllerState $ctx @{ 1 = 'failed' }
        Add-Answer 'q'
        Start-RecoveryMenu -Ctx $ctx
        $out = Get-Out
        $out | Should -Match '(?m)^  1a  \[x\]  GitHub Desktop'
        $out | Should -Match '(?m)^> 1b  \[ \]  Windows Update'
        $out | Should -Match '(?m)^  4   \[!\]  Stage 1 .*\(failed'
        $out | Should -Match 'Enter = step 1b \(next\)'
        Get-Log $ctx | Should -Match 'menu closed'
    }

    It 'keeps going when a step hits an error, and logs it' {
        $ctx = New-TestMenu -Probe @{ OsBuild = { throw 'boom' } }
        $ctx.Menu['steps']['1a'] = @{ status = 'done'; confirmed = @(); skipped = @{}; last = @() }
        Add-Answer '1b', 'q'
        Start-RecoveryMenu -Ctx $ctx
        Get-Out | Should -Match 'Step 1b hit an error the menu did not expect: boom'
        Get-Log $ctx | Should -Match 'error in step 1b: boom'
    }

    It 'turns a controller that throws into a failed stage, not a crash' {
        $ctx = New-TestMenu -Controller { param([hashtable]$Arguments) $null = $Arguments; throw 'kaput' }
        Set-PrepDone $ctx
        Set-ControllerState $ctx @{ 1 = 'done' }
        Add-Answer 'y', 'm'
        Invoke-MenuStep -Ctx $ctx -Id '6' | Should -Be 'failed'
        Get-Out | Should -Match 'the controller stopped: kaput'
    }

    It 'goes back a step: it is not done any more and asks its questions again' {
        $ctx = New-TestMenu
        Set-PrepDone $ctx
        $ctx.Menu['steps']['2']['confirmed'] = @('signin:bitwarden')
        Add-Answer 'y'
        & (Get-Module RecoveryMenu) { param($c) Undo-MenuStep $c } $ctx
        $saved = Get-SavedMenu $ctx
        $saved['steps']['3']['status'] | Should -Be 'todo'
        $saved['steps']['2']['status'] | Should -Be 'done'
        Add-Answer 'y'
        & (Get-Module RecoveryMenu) { param($c) Undo-MenuStep $c } $ctx
        @((Get-SavedMenu $ctx)['steps']['2']['confirmed']) | Should -BeNullOrEmpty
    }

    It 'goes back to a stage by running it again, without touching state.json' {
        $ctx = New-TestMenu
        Set-PrepDone $ctx
        Set-ControllerState $ctx @{ 1 = 'done' }
        $before = [IO.File]::ReadAllText($ctx.StatePath)
        Add-Answer 'y'
        & (Get-Module RecoveryMenu) { param($c) Undo-MenuStep $c } $ctx
        Get-MenuStepStatus -Ctx $ctx -Step (Get-RecoveryMenuStep | Where-Object Id -EQ '4') | Should -Be 'todo'
        [IO.File]::ReadAllText($ctx.StatePath) | Should -Be $before
    }

    It 'starts from scratch only after RESET, keeping the old records beside the new' {
        $ctx = New-TestMenu
        Set-PrepDone $ctx
        & (Get-Module RecoveryMenu) { param($c) Save-MenuState $c } $ctx
        Set-ControllerState $ctx @{ 1 = 'done' }
        Add-Answer 'reset'
        Reset-RecoveryMenu -Ctx $ctx
        (Get-SavedMenu $ctx)['steps']['1a']['status'] | Should -Be 'done'
        Add-Answer 'RESET', 'n'
        Reset-RecoveryMenu -Ctx $ctx
        (Get-SavedMenu $ctx)['steps'].Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $ctx.StateRoot 'menu-20261010-010000.json') | Should -BeTrue
        Test-Path -LiteralPath $ctx.StatePath | Should -BeTrue
        Add-Answer 'RESET', 'y'
        Reset-RecoveryMenu -Ctx $ctx
        Test-Path -LiteralPath $ctx.StatePath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $ctx.StateRoot 'state-20261010-010000.json') | Should -BeTrue
    }

    It 'writes a status for an assistant that changes nothing and holds no address' {
        $ctx = New-TestMenu
        $ctx.Menu['steps']['2'] = @{ status = 'needs-user'; pausedAt = 'This PC is named pc on the tailnet'; confirmed = @(); skipped = @{ 'app:Ditto.Ditto' = 'later' }; last = @('[!!] This PC is named pc on the tailnet: this PC is ''pc-1'', not ''pc''') }
        $text = (Get-MenuStatusText -Ctx $ctx) -join "`n"
        Test-Path -LiteralPath $ctx.StateRoot | Should -BeFalse
        $text | Should -Match 'Step 2 \(needs-user\), paused at: This PC is named pc'
        $text | Should -Match 'skipped app:Ditto.Ditto because: later'
        $text | Should -Match 'MENU-HELP-FOR-AI\.md'
        $text | Should -Not -Match '100\.\d+\.\d+\.\d+'
    }

    It 'copies a help note to the clipboard and to help-note.txt' {
        $ctx = New-TestMenu
        & (Get-Module RecoveryMenu) { param($c) Copy-MenuHelpNote $c } $ctx
        $global:MenuClipboard | Should -Match 'I am stuck'
        [IO.File]::ReadAllText($ctx.HelpPath) | Should -Match 'Next: step 1a'
    }
}

Describe 'Start-Recovery.ps1' {
    It 'prints the status with -Status and writes nothing' {
        $ctx = New-TestMenu
        $out = & (Join-Path $script:Repo 'Start-Recovery.ps1') -Status -TopologyPath (Join-Path (Split-Path $ctx.RepoRoot) 'topology.json')
        ($out -join "`n") | Should -Match '(?m)^> 1a  \[ \]  GitHub Desktop'
        Test-Path -LiteralPath $ctx.StateRoot | Should -BeFalse
    }

    It 'refuses a step that does not exist' {
        { & (Join-Path $script:Repo 'Start-Recovery.ps1') -Step '15' } | Should -Throw
    }
}
