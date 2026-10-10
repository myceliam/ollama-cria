<#
.SYNOPSIS
    The logic behind Start-Recovery.ps1: the interactive menu Liam drives a
    PC rebuild with (docs/FULL-REBUILD-HUMAN.md pairs with it, step for step).

.DESCRIPTION
    Steps 1a, 1b, 2 and 3 get the new PC ready. Each is a list of tasks: the
    menu checks what it can, does what can be done for you (after asking),
    and asks about the rest one question at a time, checking again after
    every answer, until every task passes. A task the rebuild needs cannot
    be skipped; an optional one can, with a reason that goes in the log.

    Steps 4 to 14 run the controller's Stages 1 to 11
    (Invoke-StackRecovery.ps1 -Execute -Stage <n>) and turn its ASK, PROBLEM
    and CHECK FAIL lines into questions and hints.

    Records, all under the controller's state root (E:\recovery-state):
      menu.json      which steps are done, what you confirmed, what you
                     skipped and why, the bundle's SHA-256 and file name.
                     Never a secret.
      menu-log.txt   every check result and answer, with the time.
      help-note.txt  the last note the menu wrote for an assistant.
    The stages' own record stays in state.json, which only the controller
    writes; the menu only reads it.

    Everything that touches the machine comes in through a table of script
    blocks (New-MenuProbe) and every question through another (New-MenuUi),
    so the tests drive the whole menu with fakes.

    Rules it keeps: every path it writes or renames goes through
    tools/Test-RecoveryPath.ps1 first; it never prints a tailnet address or
    domain (only the first label of a node's name); it never echoes what you
    type into a free-text prompt, and never writes it to the log.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RecoveryHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RecoveryState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RecoveryVps.psm1') -Force

# winget: restart to finish, restart started; installers: 3010, 1641 (as
# Stage 3). Then 'no applicable upgrade' (it is there already) and 'no
# package found'.
$script:RebootCodes = @(-1978334967, -1978334965, 3010, 1641)
$script:AlreadyThere = -1978335189
$script:NotFound = -1978335212

# The controller's stages: what each one needs (Invoke-StackRecovery.ps1,
# $catalogue; the tests keep the two the same), and what it means for you.
$script:Stages = @{
    1  = @{ Needs = @(); What = 'The repo, the protected folder and your keys'; Yours = 'Nothing: step 3 already gave it the bundle and its SHA-256' }
    2  = @{ Needs = @(1); What = 'The VPS: trusted, locked down, on the tailnet'; Yours = 'Keep it or rebuild it; the IONOS console if you rebuild' }
    3  = @{ Needs = @(1); What = 'Windows runtime: GPU, WSL, Docker, Python, Ollama'; Yours = 'One admin prompt, one or two restarts'; Admin = $true }
    4  = @{ Needs = @(2, 3); What = 'Settings files with the new addresses, keys in place'; Yours = 'Nothing' }
    5  = @{ Needs = @(4); What = 'The VPS side: guard, VPN, search, Kokoro, dictation relay'; Yours = 'Nothing' }
    6  = @{ Needs = @(1, 3); What = 'ComfyUI, every model and weight'; Yours = 'Download tokens, if it asks' }
    7  = @{ Needs = @(5, 6); What = "Docker images, volumes and Open WebUI's settings"; Yours = 'Make the admin account and an API key' }
    8  = @{ Needs = @(7); What = 'The whole stack starts: Serve and scheduled tasks'; Yours = 'One admin prompt; open OWUI on the phone'; Admin = $true }
    9  = @{ Needs = @(8); What = 'Proof every feature works'; Yours = 'Try nine things in OWUI and on the phone' }
    10 = @{ Needs = @(9); What = 'Restart, outside tests, VPS kill switch, first backup'; Yours = 'Restart; phone test; Bitwarden' }
    11 = @{ Needs = @(10); What = 'Plain copies of your keys deleted, rebuild recorded'; Yours = 'Commit the new seed (an assistant helps)' }
}

# ---------- The catalogue ----------

function Get-RecoveryMenuStep {
    <#
    .SYNOPSIS
        Every step of the menu, in order: 1a, 1b, 2 and 3 get the PC ready,
        4 to 14 run Stages 1 to 11.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    @{ Id = '1a'; Kind = 'prep'; Title = 'GitHub Desktop, sign in, and this repo' }
    @{ Id = '1b'; Kind = 'prep'; Title = 'Windows Update, your drives and Windows settings' }
    @{ Id = '2'; Kind = 'prep'; Title = 'Apps, the GPU driver, Tailscale and your sign-ins' }
    @{ Id = '3'; Kind = 'prep'; Title = 'The secrets bundle from Bitwarden' }
    foreach ($n in 1..11) {
        $s = $script:Stages[$n]
        @{
            Id = "$($n + 3)"; Kind = 'stage'; Stage = $n; Title = "Stage $n - $($s.What)"
            What = $s.What; Yours = $s.Yours; Needs = [int[]]$s.Needs; Admin = [bool]$s['Admin']
        }
    }
}

function Get-MenuStepById([string]$Id) {
    @(Get-RecoveryMenuStep | Where-Object { $_.Id -eq $Id })[0]
}

function Get-StepForStage([int]$Stage) { "$($Stage + 3)" }

# ---------- Output, questions and records ----------

function Get-MenuGlyph {
    <#
    .SYNOPSIS
        The marks the menu prints. Emoji in Windows Terminal; plain ASCII
        elsewhere (the old console shows emoji as boxes), or with -Plain.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$Plain)
    if ($Plain) {
        return @{
            done = '[x] '; failed = '[!] '; 'needs-user' = '[?] '; reboot = '[r] '; skipped = '[-] '; todo = '[ ] '; running = '[~] '
            ok = '[ok]'; bad = '[!!]'; ask = '[??]'; skip = '[--]'; warn = '(!)'; pointer = '>'
        }
    }
    $e = { param([int]$Code) [char]::ConvertFromUtf32($Code) }
    $check = & $e 0x2705; $cross = & $e 0x274C; $hand = & $e 0x270B; $loop = & $e 0x1F501; $ff = & $e 0x23E9; $glass = & $e 0x23F3
    return @{
        done = "[$check]"; failed = "[$cross]"; 'needs-user' = "[$hand]"; reboot = "[$loop]"; skipped = "[$ff]"; todo = '[  ]'; running = "[$glass]"
        ok = $check; bad = $cross; ask = $hand; skip = $ff; warn = (& $e 0x26A0) + ' '; pointer = (& $e 0x25B6)
    }
}

function New-MenuUi {
    <#
    .SYNOPSIS
        The console: Say writes a line in a colour, Ask reads an answer, Key
        waits for any key, Clear clears the screen.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'An interactive menu writes to the console.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a table of script blocks; changes nothing itself.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        Say   = { param([string]$Text = '', [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color }
        Ask   = { param([string]$Prompt) Read-Host -Prompt $Prompt }
        Key   = {
            param([string]$Prompt)
            Write-Host $Prompt -ForegroundColor Cyan
            try { $null = [Console]::ReadKey($true) } catch { $null = Read-Host }
        }
        Clear = { try { Clear-Host } catch { Write-Host '' } }
    }
}

function New-MenuProbe {
    <#
    .SYNOPSIS
        The machine, as the menu sees it: read-only looks, and the few
        actions it takes once you have said yes. -Machine is a
        New-RecoveryHost table.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a table of script blocks; changes nothing itself.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Machine)
    $m = $Machine
    return @{
        Now            = { [DateTime]::UtcNow }
        Exec           = { param([string]$Name, [string[]]$Arguments = @(), [switch]$Stream) & $m.Exec $Name $Arguments -Stream:$Stream }.GetNewClosure()
        BitLocker      = { param([string]$Path) & $m.BitLocker $Path }.GetNewClosure()
        Virtualization = { & $m.Virtualization }.GetNewClosure()
        IsElevated     = { & $m.IsElevated }.GetNewClosure()
        OsBuild        = { [Environment]::OSVersion.Version.Build }
        PwshVersion    = { $PSVersionTable.PSVersion }
        RebootPending  = {
            if (-not $IsWindows) { return $false }
            foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                if (Test-Path -LiteralPath $k) { return $true }
            }
            return $false
        }
        PendingUpdates = {
            # How many software updates Windows Update still offers, or $null
            # when it cannot say. Takes up to a minute; needs no admin rights.
            try {
                $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
                return [int]$searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates.Count
            }
            catch { return $null }
        }
        Drive          = {
            param([string]$Letter)
            $d = [IO.DriveInfo]::new("$($Letter.TrimEnd(':')):\")
            if ($d.DriveType -eq [IO.DriveType]::NoRootDirectory) { return @{ Exists = $false; Ready = $false } }
            if (-not $d.IsReady) { return @{ Exists = $true; Ready = $false } }
            return @{ Exists = $true; Ready = $true; Format = $d.DriveFormat; Free = $d.AvailableFreeSpace; Size = $d.TotalSize }
        }
        TestPath       = { param([string]$Path, [string]$Type = 'Any') Test-Path -LiteralPath $Path -PathType $Type }
        Children       = {
            param([string]$Path)
            @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | ForEach-Object {
                    @{ Name = $_.Name; Folder = [bool]$_.PSIsContainer; Path = $_.FullName }
                })
        }
        ReadText       = { param([string]$Path) [IO.File]::ReadAllText($Path) }
        FileHash       = { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
        FileSize       = { param([string]$Path) ([IO.FileInfo]::new($Path)).Length }
        ZipEntries     = {
            # Entry names only, from the ZIP's directory: no member is read.
            param([string]$Path)
            $zip = [IO.Compression.ZipFile]::OpenRead($Path)
            try { @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
        }
        Protection     = {
            param([string]$Path)
            try { Get-ProtectionProblem -Path $Path -OwnFolder }
            catch { 'this account cannot read its permissions, so it probably belongs to your old Windows account' }
        }
        Service        = {
            param([string]$Name)
            $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if (-not $s) { return $null }
            @{ StartType = "$($s.StartType)"; Status = "$($s.Status)" }
        }
        Board          = {
            # The motherboard's maker and model, or $null.
            try {
                $b = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
                if (-not $b) { return $null }
                @{ Maker = "$($b.Manufacturer)".Trim(); Product = "$($b.Product)".Trim() }
            }
            catch { $null }
        }
        Programs       = {
            # Name and Version of each installed program, from the uninstall keys.
            foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
                foreach ($e in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
                    $name = $e.PSObject.Properties['DisplayName']
                    if (-not $name -or -not $name.Value) { continue }
                    $version = $e.PSObject.Properties['DisplayVersion']
                    @{ Name = [string]$name.Value; Version = $(if ($version) { [string]$version.Value } else { '' }) }
                }
            }
        }
        DriverUpdatesOff = {
            # Whether policy keeps drivers out of Windows Update.
            $v = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name ExcludeWUDriversInQualityUpdate -ErrorAction SilentlyContinue
            [bool]($v -and [int]$v.ExcludeWUDriversInQualityUpdate -eq 1)
        }
        SleepAcMinutes = {
            # Minutes until sleep on mains power (0 = never), or $null.
            $line = @(& powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null) -match 'Current AC Power Setting Index:\s*0x[0-9a-fA-F]+' | Select-Object -First 1
            if (-not $line -or $line -notmatch '0x([0-9a-fA-F]+)') { return $null }
            return [int]([Convert]::ToInt32($Matches[1], 16) / 60)
        }
        SetSleepNever  = { & powercfg /change standby-timeout-ac 0; $LASTEXITCODE }
        HideFileExt    = {
            $v = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -ErrorAction SilentlyContinue
            if ($v) { [int]$v.HideFileExt } else { 1 }
        }
        ShowFileExt    = { Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0 -Type DWord }
        NewProtected   = { param([string]$Path) Initialize-ProtectedFolder -Path $Path }
        NewFolderChain = { param([string]$Path) $null = New-FolderChain -Path $Path }
        Rename         = { param([string]$Path, [string]$NewName) Rename-Item -LiteralPath $Path -NewName $NewName }
        Open           = { param([string]$Target, [string[]]$Arguments = @()) if ($Arguments) { Start-Process -FilePath $Target -ArgumentList $Arguments } else { Start-Process -FilePath $Target } }
        RunElevated    = {
            # Runs -Command in an elevated PowerShell 7 window and returns its
            # exit code (-1 when the Windows prompt was declined).
            param([string]$Command)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
            try { $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-EncodedCommand', $encoded -Verb RunAs -Wait -PassThru }
            catch { return -1 }
            return $p.ExitCode
        }
        Clipboard      = { param([string]$Text) Set-Clipboard -Value $Text }
        RunOnce        = {
            param([string]$Name, [string]$Command)
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
            if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
            Set-ItemProperty -LiteralPath $key -Name $Name -Value $Command
        }
        Restart        = { Restart-Computer }
        RefreshPath    = { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
        Folder         = {
            param([string]$Name)
            switch ($Name) {
                'LocalAppData' { [Environment]::GetFolderPath('LocalApplicationData') }
                'ProgramFiles' { [Environment]::GetFolderPath('ProgramFiles') }
                'Downloads' { Join-Path $HOME 'Downloads' }
                'Pwsh' { (Get-Process -Id $PID).Path }
            }
        }
    }
}

function Say([hashtable]$Ctx, [string]$Text = '', [string]$Color = 'Gray') {
    & $Ctx.Ui.Say $Text $Color
    if ($null -ne $Ctx.Transcript) { $Ctx.Transcript.Add($Text) }
}

function Write-MenuLog([hashtable]$Ctx, [string]$Text) {
    # One line in menu-log.txt. Only check results and choices go here,
    # never what was typed into a free-text prompt.
    if ($Ctx.ReadOnly) { return }
    if (-not $Ctx.LogReady) {
        if (-not (& $Ctx.PathCheck -Path $Ctx.LogPath -Root $Ctx.StateRoot)) { throw [InvalidOperationException]::new("the menu log fails the path check: $($Ctx.LogPath)") }
        Initialize-MenuStateRoot $Ctx
        $Ctx.LogReady = $true
    }
    $line = '{0} [{1}] {2}' -f (& $Ctx.Probe.Now).ToString('yyyy-MM-ddTHH:mm:ssZ'), $(if ($Ctx.CurrentStep) { $Ctx.CurrentStep } else { 'menu' }), $Text
    [IO.File]::AppendAllText($Ctx.LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Initialize-MenuStateRoot([hashtable]$Ctx) {
    if (-not (& $Ctx.PathCheck -Path $Ctx.StateRoot -Root $Ctx.StateRoot -AllowRoot)) { throw [InvalidOperationException]::new("the state root fails the path check: $($Ctx.StateRoot)") }
    if (-not (Test-Path -LiteralPath $Ctx.StateRoot -PathType Container)) { & $Ctx.Probe.NewFolderChain $Ctx.StateRoot }
}

function Read-MenuAnswer {
    # One of -Allowed (lower case letters), asked until it is one of them.
    # The end of input (a closed console, or a test out of answers) is q.
    param([hashtable]$Ctx, [string]$Question, [string[]]$Allowed = @('y', 'n'))
    $words = @{ yes = 'y'; no = 'n'; quit = 'q'; skip = 's'; back = 'q'; menu = 'q' }
    while ($true) {
        $raw = & $Ctx.Ui.Ask "$Question [$($Allowed -join '/')]"
        if ($null -eq $raw) { return 'q' }
        $a = "$raw".Trim().ToLowerInvariant()
        if ($words.ContainsKey($a)) { $a = $words[$a] }
        if ($a -in $Allowed) {
            Write-MenuLog $Ctx "asked: $Question -> $a"
            return $a
        }
        Say $Ctx "  Please type one of: $($Allowed -join ', ')" 'Yellow'
    }
}

function Read-MenuText([hashtable]$Ctx, [string]$Prompt) {
    # Free text. Never echoed, never logged. $null at the end of input.
    $raw = & $Ctx.Ui.Ask $Prompt
    if ($null -eq $raw) { return $null }
    return "$raw".Trim()
}

function Wait-MenuKey([hashtable]$Ctx, [string]$Prompt = 'Press any key to continue...') { & $Ctx.Ui.Key $Prompt }

function New-MenuState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a table in memory.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([datetime]$Now = [DateTime]::UtcNow)
    @{ formatVersion = 1; created = $Now.ToString('o'); updated = $Now.ToString('o'); steps = @{}; answers = @{}; history = @() }
}

function Read-MenuState {
    <#
    .SYNOPSIS
        menu.json as a table, or a new one when it is missing. A file that
        is not a menu record comes back as Problem, with a new State.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ State = New-MenuState; Problem = $null } }
    $s = $null
    try { $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $s = $null }
    if ($s -isnot [hashtable] -or $s['formatVersion'] -ne 1) { return @{ State = New-MenuState; Problem = "$Path is not a menu record this version can read" } }
    foreach ($k in 'steps', 'answers') { if ($s[$k] -isnot [hashtable]) { $s[$k] = @{} } }
    if ($null -eq $s['history']) { $s['history'] = @() }
    foreach ($id in @($s['steps'].Keys)) {
        $e = $s['steps'][$id]
        if ($e -isnot [hashtable]) { $s['steps'].Remove($id); continue }
        if ($null -eq $e['confirmed']) { $e['confirmed'] = @() }
        if ($e['skipped'] -isnot [hashtable]) { $e['skipped'] = @{} }
    }
    return @{ State = $s; Problem = $null }
}

function Save-MenuState([hashtable]$Ctx) {
    if ($Ctx.ReadOnly) { return }
    $tmp = "$($Ctx.MenuPath).tmp"
    if (-not (& $Ctx.PathCheck -Path $Ctx.MenuPath, $tmp -Root $Ctx.StateRoot)) { throw [InvalidOperationException]::new("the menu record fails the path check: $($Ctx.MenuPath)") }
    Initialize-MenuStateRoot $Ctx
    $Ctx.Menu['updated'] = (& $Ctx.Probe.Now).ToString('o')
    [IO.File]::WriteAllText($tmp, ($Ctx.Menu | ConvertTo-Json -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Ctx.MenuPath -Force
}

function Get-MenuStepEntry([hashtable]$Ctx, [string]$Id) {
    $steps = $Ctx.Menu['steps']
    if ($steps[$Id] -isnot [hashtable]) { $steps[$Id] = @{ status = 'todo'; confirmed = @(); skipped = @{}; last = @() } }
    return $steps[$Id]
}

function Add-MenuHistory([hashtable]$Ctx, [string]$Text) {
    $Ctx.Menu['history'] = @(@($Ctx.Menu['history']) + @("$((& $Ctx.Probe.Now).ToString('o')) $Text") | Select-Object -Last 50)
    Write-MenuLog $Ctx $Text
}

function Get-ControllerState([hashtable]$Ctx) {
    # state.json, read only; an empty record when it is missing or unreadable.
    try { return Read-RecoveryState -Path $Ctx.StatePath } catch { return @{ formatVersion = 1; release = @{}; stages = @{}; unreadable = $_.Exception.Message } }
}

function Get-StageEntry($State, [int]$Stage) {
    $e = $State['stages']["$Stage"]
    if ($e -is [hashtable]) { return $e }
    return $null
}

# ---------- The context ----------

function New-MenuContext {
    <#
    .SYNOPSIS
        Everything the menu works with: the repo, the topology, the records,
        the machine (-Probe overrides parts of New-MenuProbe), the console
        (-Ui overrides parts of New-MenuUi) and the controller (-Controller:
        a script block given a hashtable of controller parameters).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a table in memory; writes nothing.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$TopologyPath,
        [string]$StateRoot,
        [hashtable]$Probe = @{},
        [hashtable]$Ui = @{},
        [hashtable]$Machine,
        [scriptblock]$Controller,
        [switch]$ReadOnly,
        [switch]$Plain
    )
    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    if (-not $TopologyPath) { $TopologyPath = Join-Path $RepoRoot 'manifests/topology.json' }
    $topology = Get-Content -LiteralPath $TopologyPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $StateRoot) { $StateRoot = $topology['controller']['stateRoot'] }
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    $read = { param([string]$Name) Get-Content -LiteralPath (Join-Path $RepoRoot "manifests/$Name") -Raw | ConvertFrom-Json -AsHashtable }
    if (-not $Machine) { $Machine = New-RecoveryHost }
    $probes = New-MenuProbe -Machine $Machine
    foreach ($k in $Probe.Keys) { $probes[$k] = $Probe[$k] }
    $console = New-MenuUi
    foreach ($k in $Ui.Keys) { $console[$k] = $Ui[$k] }
    if (-not $Controller) {
        $controllerPath = Join-Path $RepoRoot 'Invoke-StackRecovery.ps1'
        $Controller = { param([hashtable]$Arguments) & $controllerPath -Execute -PassThru @Arguments }.GetNewClosure()
    }
    $menuPath = Join-Path $StateRoot 'menu.json'
    $loaded = Read-MenuState -Path $menuPath
    return @{
        RepoRoot      = $RepoRoot
        StateRoot     = $StateRoot
        StagingRoot   = [IO.Path]::GetFullPath($topology['controller']['stagingRoot'])
        ExpectedRepo  = $topology['controller']['repoRoot']
        MenuPath      = $menuPath
        LogPath       = Join-Path $StateRoot 'menu-log.txt'
        HelpPath      = Join-Path $StateRoot 'help-note.txt'
        StatePath     = Join-Path $StateRoot 'state.json'
        Topology      = $topology
        Apps          = & $read 'windows-apps.json'
        OllamaEnv     = & $read 'ollama-env.json'
        PathCheck     = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
        Machine       = $Machine
        Probe         = $probes
        Ui            = $console
        Glyph         = Get-MenuGlyph -Plain:$Plain
        Menu          = $loaded.State
        MenuProblem   = $loaded.Problem
        Controller    = $Controller
        ReadOnly      = [bool]$ReadOnly
        LogReady      = $false
        RestartNeeded = $false
        Restarting    = $false
        CurrentStep   = $null
        StepLines     = $null
        Transcript    = $null
    }
}

# ---------- Tasks ----------

function New-TaskCheck {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a table in memory.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([bool]$Ok, [string]$Detail = '', [string[]]$Hint = @())
    @{ Ok = $Ok; Detail = $Detail; Hint = [string[]]@($Hint | Where-Object { $_ }) }
}

function Test-TaskSkipped([hashtable]$Ctx, [string]$StepId, [string]$TaskId) {
    $e = $Ctx.Menu['steps'][$StepId]
    return ($e -is [hashtable] -and $e['skipped'] -is [hashtable] -and $e['skipped'].ContainsKey($TaskId))
}

function Write-TaskLine([hashtable]$Ctx, [string]$Mark, [string]$Text, [string]$Color) {
    Say $Ctx "  $Mark $Text" $Color
    if ($null -ne $Ctx.StepLines) { $Ctx.StepLines.Add("$Mark $Text") }
}

function Invoke-MenuTask {
    <#
    .SYNOPSIS
        Runs one task until it passes: 'ok', 'skipped' (optional tasks only,
        with a reason) or 'quit' (back to the menu; progress is kept).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$StepId, [Parameter(Mandatory)][hashtable]$Task)
    $g = $Ctx.Glyph
    $entry = Get-MenuStepEntry $Ctx $StepId
    if ($Task['When'] -and -not (& $Task['When'] $Ctx $Task)) {
        Write-TaskLine $Ctx $g.skip "$($Task.Title): not needed here" 'DarkGray'
        return 'ok'
    }
    if ($entry['skipped'].ContainsKey($Task.Id)) {
        Write-TaskLine $Ctx $g.skip "$($Task.Title): skipped earlier ($($entry['skipped'][$Task.Id]))" 'DarkYellow'
        return 'skipped'
    }
    if ($Task['Info']) {
        Say $Ctx "  $($Task.Title)" 'Cyan'
        foreach ($l in @(& $Task['Lines'] $Ctx $Task)) { Say $Ctx "    $l" }
        Wait-MenuKey $Ctx
        return 'ok'
    }
    $recheck = $true
    $offerAuto = $true
    while ($true) {
        if ($recheck) {
            $c = $null
            if ($Task['Confirm']) {
                if (@($entry['confirmed']) -contains $Task.Id) {
                    Write-TaskLine $Ctx $g.ok "$($Task.Title) (you confirmed this)" 'Green'
                    return 'ok'
                }
                Write-TaskLine $Ctx $g.ask $Task.Title 'Yellow'
            }
            else {
                $c = & $Task.Check $Ctx $Task
                $line = if ($c.Detail) { "$($Task.Title): $($c.Detail)" } else { $Task.Title }
                Write-MenuLog $Ctx "$(if ($c.Ok) { 'ok  ' } else { 'FAIL' }) $line"
                if ($c.Ok) {
                    Write-TaskLine $Ctx $g.ok $line 'Green'
                    foreach ($h in $c.Hint) { Say $Ctx "       $h" 'DarkGray' }
                    return 'ok'
                }
                Write-TaskLine $Ctx $g.bad $line 'Red'
                foreach ($h in $c.Hint) { Say $Ctx "       $h" 'Yellow' }
            }
            if ($Task['Auto'] -and $offerAuto) {
                $offerAuto = $false
                $go = if ($Task['AutoAsk']) { Read-MenuAnswer $Ctx "  $($Task['AutoAsk'])" @('y', 'n', 'q') } else { 'y' }
                if ($go -eq 'q') { return 'quit' }
                if ($go -eq 'y') {
                    try { & $Task['Auto'] $Ctx $Task $c }
                    catch { Say $Ctx "  That did not work: $($_.Exception.Message)" 'Red'; Write-MenuLog $Ctx "auto action failed: $($Task.Id)" }
                    if ($Ctx.Restarting) { return 'quit' }
                    if (-not $Task['Confirm']) { continue }
                }
            }
            if ($Task['Input']) {
                $r = & $Task['Input'] $Ctx $Task
                if ($r -eq 'quit') { return 'quit' }
                continue
            }
            if ($Task['Steps']) {
                Say $Ctx '     What to do:' 'Cyan'
                $i = 0
                foreach ($s in @($Task['Steps'])) { $i++; Say $Ctx "       $i. $s" }
            }
        }
        $allowed = @('y', 'n') + @(if (-not $Task['Required']) { 's' }) + @('q')
        $question = if ($Task['Question']) { "  $($Task['Question'])" } else { '  Fixed? Check again' }
        $a = Read-MenuAnswer $Ctx $question $allowed
        if ($a -eq 'y') {
            if ($Task['Confirm']) {
                $entry['confirmed'] = @(@($entry['confirmed']) + $Task.Id | Select-Object -Unique)
                Save-MenuState $Ctx
                Write-TaskLine $Ctx $g.ok "$($Task.Title) (confirmed)" 'Green'
                return 'ok'
            }
            Say $Ctx '     Checking again...' 'DarkGray'
            $recheck = $true
            $offerAuto = [bool]$Task['AutoAsk']
            continue
        }
        if ($a -eq 'n') {
            Say $Ctx '     No rush. Do it, then answer y. Or type q to go back to the menu: everything so far is saved.' 'DarkGray'
            $recheck = $false
            continue
        }
        if ($a -eq 's') {
            $why = Read-MenuText $Ctx '  Why skip it? A few words for the log'
            if (-not $why) { $why = 'no reason given' }
            $entry['skipped'][$Task.Id] = $why
            Save-MenuState $Ctx
            Write-MenuLog $Ctx "skipped $($Task.Id)"
            Write-TaskLine $Ctx $g.skip "$($Task.Title): skipped" 'DarkYellow'
            return 'skipped'
        }
        return 'quit'
    }
}

function Invoke-PrepStep {
    <#
    .SYNOPSIS
        Runs a prep step's tasks in order. 'done' once every task passed or
        was skipped; 'quit' when you went back to the menu part way.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Step)
    $entry = Get-MenuStepEntry $Ctx $Step.Id
    $Ctx.StepLines = [Collections.Generic.List[string]]::new()
    Say $Ctx ''
    Say $Ctx "Step $($Step.Id) - $($Step.Title)" 'Cyan'
    foreach ($l in @(Get-PrepIntro $Step.Id)) { Say $Ctx "  $l" 'DarkCyan' }
    Say $Ctx ''
    $tasks = @(Get-PrepTask -Ctx $Ctx -StepId $Step.Id)
    $outcome = 'done'
    if ($Step.Id -eq '2') {
        if ((Invoke-AppInstallBatch $Ctx) -eq 'quit') { $outcome = 'quit' }
    }
    if ($outcome -ne 'quit') {
        foreach ($t in $tasks) {
            $r = Invoke-MenuTask -Ctx $Ctx -StepId $Step.Id -Task $t
            if ($r -eq 'quit') { $outcome = 'quit'; $entry['pausedAt'] = $t.Title; break }
        }
    }
    $entry['last'] = [string[]]@($Ctx.StepLines | Select-Object -Last 60)
    $entry['at'] = (& $Ctx.Probe.Now).ToString('o')
    if ($outcome -eq 'quit') {
        $entry['status'] = 'needs-user'
        Save-MenuState $Ctx
        Write-MenuLog $Ctx "paused at: $($entry['pausedAt'])"
        Say $Ctx ''
        Say $Ctx "  Paused at: $($entry['pausedAt']). Everything so far is saved; choose step $($Step.Id) again to carry on." 'Yellow'
        return 'quit'
    }
    $entry['status'] = 'done'
    $entry.Remove('pausedAt')
    Save-MenuState $Ctx
    Write-MenuLog $Ctx "step $($Step.Id) done"
    Say $Ctx ''
    Say $Ctx "  $($Ctx.Glyph.ok) Step $($Step.Id) is done." 'Green'
    if ($Ctx.RestartNeeded) {
        $Ctx.RestartNeeded = $false
        $null = Invoke-RestartOffer $Ctx 'An installer asked for a restart to finish.'
    }
    return 'done'
}

function Get-PrepIntro([string]$StepId) {
    switch ($StepId) {
        '1a' { 'Checks the copy of this repo you cloned with GitHub Desktop, and shows how to update it.' }
        '1b' { 'Windows Update, then the drives the stack lives on (E: and D:), then a few Windows settings.'; 'Restarts are fine: start Start-Recovery.cmd again and it carries on here.' }
        '2' { 'Installs your apps with winget (asks first), then the GPU driver, Windows Search, Tailscale and your sign-ins.'; 'Docker Desktop, Ollama and Python are not here: Stage 3 installs them at the versions the stack was built on, after WSL.' }
        '3' { 'Makes the protected folder, then you save the bundle from Bitwarden into it and give its SHA-256.'; "Don't unzip it: Stage 1 (step 4) checks it and unpacks it into a protected folder itself." }
    }
}

function Get-PrepTask {
    <#
    .SYNOPSIS
        The tasks of prep step -StepId (1a, 1b, 2 or 3), in order.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][ValidateSet('1a', '1b', '2', '3')][string]$StepId)
    switch ($StepId) {
        '1a' { Get-Step1aTask $Ctx }
        '1b' { Get-Step1bTask $Ctx }
        '2' { Get-Step2Task $Ctx }
        '3' { Get-Step3Task $Ctx }
    }
}

# ---------- Step 1a: GitHub Desktop and this repo ----------

function Get-RepoView([hashtable]$Ctx) {
    # The clone, read from .git without the git command (GitHub Desktop
    # brings its own, which is not on PATH). Never the remote's full URL.
    $git = Join-Path $Ctx.RepoRoot '.git'
    $v = @{ IsClone = $false; Origin = $null; Branch = $null; Commit = $null }
    if (-not (& $Ctx.Probe.TestPath $git 'Container')) { return $v }
    $v.IsClone = $true
    $config = Join-Path $git 'config'
    if (& $Ctx.Probe.TestPath $config 'Leaf') {
        $inOrigin = $false
        foreach ($line in ((& $Ctx.Probe.ReadText $config) -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -match '^\[') { $inOrigin = $t -match '^\[remote\s+"origin"\]$'; continue }
            if ($inOrigin -and $t -match '^url\s*=\s*(.+)$') {
                $url = $Matches[1].Trim()
                $v.Origin = if ($url -match '^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9._-]+/[A-Za-z0-9._-]+?)(\.git)?/?$') { $Matches[2] } else { 'another place' }
            }
        }
    }
    $head = Join-Path $git 'HEAD'
    if (& $Ctx.Probe.TestPath $head 'Leaf') {
        $h = (& $Ctx.Probe.ReadText $head).Trim()
        if ($h -match '^ref:\s*refs/heads/(.+)$') {
            $v.Branch = $Matches[1]
            $ref = Join-Path $git "refs/heads/$($v.Branch)"
            if (& $Ctx.Probe.TestPath $ref 'Leaf') { $v.Commit = (& $Ctx.Probe.ReadText $ref).Trim() }
            elseif (& $Ctx.Probe.TestPath (Join-Path $git 'packed-refs') 'Leaf') {
                foreach ($l in ((& $Ctx.Probe.ReadText (Join-Path $git 'packed-refs')) -split "`r?`n")) {
                    if ($l -match "^([0-9a-f]{40}) refs/heads/$([regex]::Escape($v.Branch))$") { $v.Commit = $Matches[1] }
                }
            }
        }
        elseif ($h -match '^[0-9a-f]{40}$') { $v.Commit = $h }
    }
    return $v
}

function Get-Step1aTask([hashtable]$Ctx) {
    $expected = $Ctx.ExpectedRepo
    @{
        Id = 'desktop'; Title = 'GitHub Desktop is installed'; Required = $false
        Check = {
            param($Ctx)
            $exe = Join-Path (& $Ctx.Probe.Folder 'LocalAppData') 'GitHubDesktop/GitHubDesktop.exe'
            if (& $Ctx.Probe.TestPath $exe 'Leaf') { return New-TaskCheck $true 'found' }
            New-TaskCheck $false 'not found in your user folder'
        }
        Steps = @('Download GitHub Desktop from https://desktop.github.com/ and install it.', 'Or in Windows PowerShell: winget install --id GitHub.GitHubDesktop --exact')
        Question = 'Is GitHub Desktop installed?'
    }
    @{
        Id = 'desktop-signin'; Title = 'Signed in to GitHub Desktop'; Required = $false; Confirm = $true
        Steps = @('In GitHub Desktop: File > Options > Accounts > Sign in, and finish in the browser.', 'Your GitHub login and 2FA are in Bitwarden (or your phone).')
        Question = 'Are you signed in to GitHub Desktop?'
    }
    @{
        Id = 'clone'; Title = 'This folder is a clone of myceliam/ollama-cria'; Required = $true
        Check = {
            param($Ctx)
            $v = Get-RepoView $Ctx
            if (-not $v.IsClone) { return New-TaskCheck $false "$($Ctx.RepoRoot) has no .git folder" }
            if ($v.Origin -ne 'myceliam/ollama-cria') { return New-TaskCheck $false "its origin is $(if ($v.Origin) { $v.Origin } else { 'not set' }), not myceliam/ollama-cria" }
            New-TaskCheck $true 'origin is myceliam/ollama-cria'
        }
        Steps = @('In GitHub Desktop: File > Clone repository > GitHub.com > myceliam/ollama-cria.', "Local path: $expected. Then Clone.", "Then start $expected\Start-Recovery.cmd from that copy.")
        Question = 'Have you cloned it?'
    }
    @{
        Id = 'branch'; Title = 'On the main branch'; Required = $true
        Check = {
            param($Ctx)
            $v = Get-RepoView $Ctx
            $short = if ($v.Commit) { $v.Commit.Substring(0, [Math]::Min(12, $v.Commit.Length)) } else { 'unknown' }
            if ($v.Branch -eq 'main') { return New-TaskCheck $true "main, at $short" }
            New-TaskCheck $false "on $(if ($v.Branch) { "branch $($v.Branch)" } else { 'no branch (a detached commit)' }), at $short"
        }
        Steps = @('In GitHub Desktop: Current branch > main.')
        Question = 'Have you switched to main?'
    }
    @{
        Id = 'place'; Title = "In $expected, where the guides expect it"; Required = $false
        Check = {
            param($Ctx)
            if ([string]::Equals($Ctx.RepoRoot.TrimEnd('\', '/'), "$($Ctx.ExpectedRepo)".TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { return New-TaskCheck $true $Ctx.RepoRoot }
            New-TaskCheck $false "this copy is in $($Ctx.RepoRoot)" -Hint 'The controller works from wherever this copy is, but the guides and hints all say the other path.'
        }
        Steps = @("Clone it again into $expected (GitHub Desktop: File > Clone repository), and run the menu from there.")
        Question = 'Check again?'
    }
    @{
        Id = 'clean'; Title = 'No local changes'; Required = $true
        Check = {
            param($Ctx)
            $r = & $Ctx.Probe.Exec 'git' @('-C', $Ctx.RepoRoot, 'status', '--porcelain')
            if ($r.ExitCode -eq -1) { return New-TaskCheck $true 'not checked yet: Git comes in step 2, and Stage 1 checks this again' }
            if ($r.ExitCode -ne 0) { return New-TaskCheck $false "git status failed (exit $($r.ExitCode))" }
            $n = @($r.Output | Where-Object { "$_".Trim() }).Count
            if ($n -eq 0) { return New-TaskCheck $true 'none' }
            New-TaskCheck $false "$n changed or new files" -Hint 'Stage 1 only runs a clean copy of a release.'
        }
        Steps = @('In GitHub Desktop: the Changes tab lists them. Right-click > Discard all changes (or Stash all changes to keep them).')
        Question = 'Have you cleared them?'
    }
    @{
        Id = 'pull'; Title = 'How to update this copy'; Info = $true
        Lines = {
            param($Ctx)
            $controller = Get-ControllerState $Ctx
            $recorded = if ($controller['release'] -is [hashtable]) { $controller['release']['commit'] } else { $null }
            'Pull now, before step 4. In GitHub Desktop: Fetch origin, then Pull origin.'
            "Or in PowerShell, once step 2 has installed Git:  git -C `"$($Ctx.RepoRoot)`" pull --ff-only"
            'Once step 4 (Stage 1) has run, it records this commit. Pulling after that stops every later stage until step 4 runs again.'
            if ($recorded) {
                $now = (Get-RepoView $Ctx).Commit
                if ($now -and $now -ne $recorded) { "$($Ctx.Glyph.warn)Stage 1 recorded $($recorded.Substring(0, 12)), and this copy is at $($now.Substring(0, 12)): run step 4 again before going on." }
                else { 'Stage 1 has recorded this commit, so leave it as it is until the rebuild is finished.' }
            }
        }
    }
}

# ---------- Step 1b: Windows Update, drives, settings ----------

function Get-DriveNeed([hashtable]$Ctx) {
    # Each drive letter the stack's paths use, other than C:, with what
    # uses it: the topology's PC roots and the Ollama profile.
    $need = [ordered]@{}
    $add = {
        param([string]$Path, [string]$Why)
        if ($Path -match '^([A-Za-z]):\\') {
            $l = $Matches[1].ToUpperInvariant()
            if ($l -eq 'C') { return }
            if (-not $need.Contains($l)) { $need[$l] = [Collections.Generic.List[string]]::new() }
            if (-not $need[$l].Contains($Why)) { $need[$l].Add($Why) }
        }
    }
    foreach ($k in @($Ctx.Topology['controller'].Keys | Sort-Object)) { & $add $Ctx.Topology['controller'][$k] 'the recovery folders' }
    foreach ($k in @($Ctx.Topology['roots'].Keys | Sort-Object)) {
        $r = $Ctx.Topology['roots'][$k]
        if ($r['host'] -eq 'pc') { & $add $r['path'] 'the stack' }
    }
    foreach ($v in @($Ctx.OllamaEnv['variables'])) { & $add $v['value'] $v['name'] }
    return $need
}

function Get-DriveTask([hashtable]$Ctx, [string]$Letter, [string[]]$Uses) {
    $main = $Letter -eq 'E'
    $usesText = $Uses -join ', '
    @{
        Id = "drive:$Letter"; Title = "Drive ${Letter}: is there and ready ($usesText)"; Required = $main; Letter = $Letter
        Check = {
            param($Ctx, $Task)
            $d = & $Ctx.Probe.Drive $Task.Letter
            if (-not $d.Exists) { return New-TaskCheck $false 'there is no such drive' }
            if (-not $d.Ready) { return New-TaskCheck $false 'it is there but locked or not ready (BitLocker locks a drive after a reinstall)' }
            if ($d.Format -ne 'NTFS') { return New-TaskCheck $false "it is $($d.Format), not NTFS" -Hint 'BitLocker and owner-only folders need NTFS. Formatting erases the drive.' }
            New-TaskCheck $true ('NTFS, {0:N0} GB free of {1:N0} GB' -f ($d.Free / 1GB), ($d.Size / 1GB))
        }
        Steps = $(if ($main) {
                @('A new or wiped drive: Win+X > Disk Management. Initialise the disk (GPT), New Simple Volume, letter E, NTFS. Then BitLocker (next check).',
                    'A drive that survived a reinstall: double-click it in File Explorer and unlock it with its BitLocker recovery key (https://aka.ms/myrecoverykey, or where you keep it).')
            }
            else {
                @("Two matching SSDs: Settings > System > Storage > Advanced storage settings > Storage Spaces > Add a new storage pool, tick both, then a storage space: Simple (striped, both drives' space, no protection) or Two-way mirror (half the space, survives one drive failing).",
                    "Give the volume the letter ${Letter}: and format it NTFS. Storage Spaces wipes the drives it adds.",
                    "One drive: Disk Management > New Simple Volume > letter ${Letter}, NTFS.",
                    'A drive that survived a reinstall but is locked: unlock it in File Explorer with its BitLocker recovery key.')
            })
        Question = "Is ${Letter}: ready?"
    }
}

function Get-ChipsetDriverPage($Board) {
    # AMD's own chipset driver page for the board's chipset (newer than the
    # copy on the board maker's page), or AMD's driver finder.
    if ($Board -is [hashtable] -and "$($Board['Product'])" -match '\b(X870E|X870|X670E|X670|B850|B840|B650E|B650|A620)\b') {
        return "https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/$($Matches[1].ToLowerInvariant()).html"
    }
    return 'https://www.amd.com/en/support/download/drivers.html'
}

function Open-InEdge([hashtable]$Ctx, [string]$Url) {
    # Edge is on every new Windows, whatever the default browser is.
    & $Ctx.Probe.Open "microsoft-edge:$Url"
}

function Get-BoardDriverPage($Board) {
    # The board maker's driver downloads for this board: ASUS's page for a
    # ROG STRIX board, ASUS's download centre for another ASUS board, or
    # $null for any other maker.
    if ($Board -isnot [hashtable] -or "$($Board['Maker'])" -notmatch 'ASUS') { return $null }
    $product = "$($Board['Product'])"
    if ($product -match '^ROG STRIX ') {
        $slug = ($product.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        return "https://rog.asus.com/motherboards/rog-strix/$slug-model/helpdesk_download/"
    }
    return 'https://www.asus.com/support/download-center/'
}

function Get-BoardLabel($Board) {
    if ($Board -isnot [hashtable] -or -not "$($Board['Product'])") { return 'your motherboard' }
    "your $(("$($Board['Maker'])" -replace '(?i)^ASUSTeK COMPUTER INC\.?$', 'ASUS').Trim()) $($Board['Product'])".Replace('  ', ' ')
}

function Get-Step1bTask([hashtable]$Ctx) {
    $staging = $Ctx.StagingRoot
    $stagingDrive = $staging.Substring(0, 2)
    @{
        Id = 'win11'; Title = 'Windows 11'; Required = $true
        Check = {
            param($Ctx)
            $b = [int](& $Ctx.Probe.OsBuild)
            if ($b -ge 22000) { return New-TaskCheck $true "build $b" }
            New-TaskCheck $false "build $b is older than Windows 11 (22000)"
        }
        Steps = @('The stack is built for Windows 11 (Pro, for BitLocker). Install it, then run this again.')
    }
    @{
        Id = 'board-chipset'; Title = 'The AMD chipset driver, from AMD, before Windows Update'; Required = $false
        Check = {
            param($Ctx)
            $c = @(& $Ctx.Probe.Programs | Where-Object { $_.Name -like 'AMD Chipset Software*' })
            if ($c) { return New-TaskCheck $true ("$($c[0].Name) $($c[0].Version)".Trim() + ' is installed') }
            New-TaskCheck $false "not installed, for $(Get-BoardLabel (& $Ctx.Probe.Board))" `
                -Hint 'Windows'' own chipset driver is generic. AMD''s package is newer than the copy on the board maker''s page, and carries the PSP driver (AMD''s side of what Intel boards call the Management Engine).'
        }
        Auto = {
            param($Ctx)
            $page = Get-ChipsetDriverPage (& $Ctx.Probe.Board)
            Open-InEdge $Ctx $page
            Say $Ctx "     Opened in Edge: $page" 'Green'
        }
        AutoAsk = 'Open AMD''s chipset driver page in Edge now?'
        Steps = @('On AMD''s page: AMD Chipset Drivers, Windows 11 64-bit, Download. Run it (the default install), and restart when it asks: this menu opens again where it stopped.',
            'Not on the page? Pick your chipset on AMD''s driver finder (Chipsets > Socket AM5 > your chipset).')
        Question = 'Is the chipset driver installed?'
    }
    @{
        Id = 'board-drivers'; Title = 'LAN, Wi-Fi, Bluetooth and audio drivers from your board''s maker'; Required = $false; Confirm = $true
        Auto = {
            param($Ctx)
            $board = & $Ctx.Probe.Board
            $page = Get-BoardDriverPage $board
            if ($page) { Open-InEdge $Ctx $page; Say $Ctx "     Opened in Edge: the driver page for $(Get-BoardLabel $board)." 'Green' }
            else { Say $Ctx "     This is not an ASUS board ($(Get-BoardLabel $board)): open its maker's support page instead." 'Yellow' }
        }
        AutoAsk = 'Open your board''s driver page in Edge now?'
        Steps = @('On the page: Driver & Tool (or Driver & Utility), Windows 11 64-bit. Install LAN, Wireless (Wi-Fi), Bluetooth and Audio; one restart at the end is enough.',
            'Skip its Chipset section (AMD''s, above, is newer) and the graphics driver (step 2 gets it from nvidia.com). Armoury Crate is optional: only for RGB and fans.',
            'Leave out what you don''t use.')
        Question = 'Have you installed them?'
    }
    @{
        Id = 'wu-drivers'; Title = 'Windows Update leaves your drivers alone'; Required = $false
        Check = {
            param($Ctx)
            if (& $Ctx.Probe.DriverUpdatesOff) { return New-TaskCheck $true 'policy keeps drivers out of Windows Update' }
            New-TaskCheck $false 'Windows Update may swap your board''s drivers for its own generic ones' `
                -Hint 'The trade-off: Windows Update then installs no drivers at all, so update them from ASUS and NVIDIA yourself now and then.'
        }
        Auto = {
            param($Ctx)
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            $code = & $Ctx.Probe.RunElevated "`$k = '$key'; if (-not (Test-Path -LiteralPath `$k)) { `$null = New-Item -Path `$k -Force }; Set-ItemProperty -LiteralPath `$k -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord -ErrorAction Stop"
            if ($code -ne 0) { Say $Ctx "     The admin window ended with exit code $code (the prompt was declined, or the change failed)." 'Yellow' }
        }
        AutoAsk = 'Stop Windows Update installing drivers? A Windows admin prompt (UAC) appears: click Yes'
        Steps = @('Or by hand: Win+R > gpedit.msc > Computer Configuration > Administrative Templates > Windows Components > Windows Update > Manage updates offered from Windows Update > Do not include drivers with Windows Updates > Enabled.',
            'To undo it later, set that policy back to Not Configured.')
        Question = 'Check again?'
    }
    @{
        Id = 'updates'; Title = 'Windows Update has nothing left to install'; Required = $true; Confirm = $true
        Auto = {
            param($Ctx)
            & $Ctx.Probe.Open 'ms-settings:windowsupdate'
            Say $Ctx '     Asking Windows Update what is still waiting (up to a minute)...' 'DarkGray'
            $n = & $Ctx.Probe.PendingUpdates
            if ($null -eq $n) { Say $Ctx '     Windows Update could not say; go by the Settings page.' 'DarkGray' }
            elseif ($n -eq 0) { Say $Ctx '     Windows Update lists no software updates waiting.' 'Green' }
            else { Say $Ctx "     Windows Update still lists $n update(s) not installed (some may be optional previews)." 'Yellow' }
        }
        AutoAsk = 'Open Windows Update and ask it what is still waiting?'
        Steps = @('Settings > Windows Update > Check for updates. Install everything, restarting when it asks: this menu opens where it stopped.',
            'Skip Advanced options > Optional updates > Driver updates: your board''s drivers came from its maker above, and the GPU driver comes in step 2.',
            'Carry on when it says "You''re up to date".')
        Question = 'Does Windows Update say you''re up to date?'
    }
    @{
        Id = 'reboot'; Title = 'No restart pending'; Required = $true
        Check = {
            param($Ctx)
            if (& $Ctx.Probe.RebootPending) { return New-TaskCheck $false 'Windows is waiting to restart to finish updates' }
            New-TaskCheck $true 'none'
        }
        Auto = { param($Ctx) $null = Invoke-RestartOffer $Ctx 'Windows needs a restart to finish installing updates.' }
        Steps = @('Restart from the Start menu, sign in, and start Start-Recovery.cmd again.')
        Question = 'Have you restarted?'
    }
    @{
        Id = 'pwsh'; Title = 'PowerShell 7.4 or later'; Required = $true
        Check = { param($Ctx) $v = & $Ctx.Probe.PwshVersion; New-TaskCheck ($v -ge [version]'7.4') "$v" }
        Steps = @('Run Install-PowerShell7.cmd in this repo, then Start-Recovery.cmd again.')
    }
    @{
        Id = 'winget'; Title = 'winget works'; Required = $true
        Check = {
            param($Ctx)
            $r = & $Ctx.Probe.Exec 'winget' @('--version')
            if ($r.ExitCode -eq 0 -and $r.Output) { return New-TaskCheck $true "$($r.Output[0])".Trim() }
            New-TaskCheck $false $(if ($r.ExitCode -eq -1) { 'the winget command is not found' } else { "winget --version failed (exit $($r.ExitCode))" })
        }
        Steps = @('Open the Microsoft Store > Library > Get updates (it updates App Installer, which brings winget). Or search the Store for App Installer.', 'Then close this window and start Start-Recovery.cmd again.')
    }
    @{
        Id = 'disk-test'; Title = 'New drives tested before you choose striped or separate: health and speed'; Required = $false; Confirm = $true
        Auto = {
            param($Ctx)
            foreach ($p in @(@{ Id = 'CrystalDewWorld.CrystalDiskInfo'; Name = 'CrystalDiskInfo' }, @{ Id = 'CrystalDewWorld.CrystalDiskMark'; Name = 'CrystalDiskMark' })) {
                if ((Test-MenuPackage -Ctx $Ctx -Package $p).Ok) { Say $Ctx "     $($p.Name) is already installed." 'Green'; continue }
                $null = Install-MenuPackage -Ctx $Ctx -Package $p
            }
        }
        AutoAsk = 'Install CrystalDiskInfo and CrystalDiskMark with winget now?'
        Steps = @('CrystalDiskInfo (Start menu; click Yes to the admin prompt): every drive should say Good. Note each NVMe drive''s Health %, Total Host Writes and temperature. Caution or Bad: keep it out of a stripe, and copy anything you need off it.',
            'CrystalDiskMark needs a drive letter: give each new drive a temporary volume in Disk Management (New Simple Volume). Storage Spaces wipes it later anyway.',
            'CrystalDiskMark: close other apps, pick each new drive in turn (top right), 5 runs of 1 GiB, then All. Compare SEQ1M Q8T1 (big files: models, game installs) and RND4K Q1T1 (small reads: what Windows and games mostly feel).',
            'Stripe them (Storage Spaces, Simple) only if both are healthy and their SEQ1M numbers are close: big-file speed roughly doubles, RND4K Q1T1 barely changes, and losing either drive loses everything on the stripe.',
            'If one is much slower (often a cheaper drive whose writes drop on long copies), keep them separate: two drives, nothing lost together.')
        Question = 'Have you tested them and chosen?'
    }
    $need = Get-DriveNeed $Ctx
    foreach ($l in $need.Keys) { Get-DriveTask $Ctx $l ([string[]]$need[$l]) }
    @{
        Id = 'bitlocker'; Title = "BitLocker is on for $stagingDrive (the secrets bundle lands there)"; Required = $true
        Check = {
            param($Ctx)
            $b = & $Ctx.Probe.BitLocker $Ctx.StagingRoot
            New-TaskCheck ($b -eq 'On') $b
        }
        Auto = { param($Ctx) & $Ctx.Probe.Open 'control.exe' @('/name', 'Microsoft.BitLockerDriveEncryption') }
        AutoAsk = 'Open BitLocker in Control Panel?'
        Steps = @("BitLocker Drive Encryption > $stagingDrive > Turn on BitLocker. Save the recovery key to your Microsoft account and Bitwarden.",
            'Encrypt used space only is fine on a new drive. You can carry on while it encrypts once it shows BitLocker on.')
        Question = 'Is BitLocker on?'
    }
    @{
        Id = 'autounlock'; Title = "$stagingDrive unlocks by itself after a restart"; Required = $false; Confirm = $true
        Steps = @("Control Panel > BitLocker Drive Encryption > $stagingDrive > Turn on auto-unlock.",
            'Without it, every restart locks the drive, and this menu (which lives on it) cannot start until you unlock it.',
            'If the option is missing, C: is not encrypted: turn BitLocker on for C: first, or unlock the drive by hand after each restart.')
        Question = 'Is auto-unlock on?'
    }
    @{
        Id = 'space'; Title = "At least 400 GB free on $stagingDrive"; Required = $false
        Check = {
            param($Ctx)
            $d = & $Ctx.Probe.Drive $Ctx.StagingRoot.Substring(0, 1)
            if (-not $d.Ready) { return New-TaskCheck $false 'the drive is not ready' }
            $gb = [Math]::Floor($d.Free / 1GB)
            New-TaskCheck ($gb -ge 400) "$gb GB free"
        }
        Steps = @('Models, weights and Docker images need about 400 GB. Free some space, or skip (s) if the models are already on the drive.')
        Question = 'Check again?'
    }
    @{
        Id = 'leftovers'; Title = 'Nothing from before is in the way of Stage 4'; Required = $true
        Check = {
            param($Ctx)
            $found = @(Get-Leftover $Ctx)
            if (-not $found) { return New-TaskCheck $true 'the stack folders are new or empty' }
            New-TaskCheck $false "$($found.Count) folder(s) from before hold files: $(($found | ForEach-Object { $_.Path }) -join ', ')" `
                -Hint 'Stage 4 never overwrites files it did not place, so it would stop on them. Your models folder is not touched.'
        }
        Auto = {
            param($Ctx)
            $stamp = (& $Ctx.Probe.Now).ToString('yyyyMMdd')
            foreach ($f in @(Get-Leftover $Ctx)) {
                $new = "$([IO.Path]::GetFileName($f.Path))-before-rebuild-$stamp"
                $parent = [IO.Path]::GetDirectoryName($f.Path)
                if (-not (& $Ctx.PathCheck -Path $f.Path, (Join-Path $parent $new) -Root $parent)) { Say $Ctx "     Not renamed: $($f.Path) fails the path check." 'Red'; continue }
                & $Ctx.Probe.Rename $f.Path $new
                Say $Ctx "     Renamed $($f.Path) to $new" 'Green'
                Write-MenuLog $Ctx "renamed $($f.Path) to $new"
            }
        }
        AutoAsk = 'Rename them aside now (each gets -before-rebuild-<date> on its name; nothing is deleted)?'
        Steps = @('Or rename them yourself in File Explorer, then check again.')
        Question = 'Check again?'
    }
    @{
        Id = 'virtualisation'; Title = 'Virtualisation is on in the firmware (WSL and Docker need it)'; Required = $false
        Check = {
            param($Ctx)
            $v = & $Ctx.Probe.Virtualization
            New-TaskCheck ([bool]($v['Firmware'] -or $v['Hypervisor'])) $(if ($v['Hypervisor']) { 'a hypervisor is running' } elseif ($v['Firmware']) { 'on' } else { 'off' })
        }
        Steps = @('Restart into the BIOS (Del or F2 at power-on). AMD boards: Advanced > CPU Configuration > SVM Mode > Enabled. Save and exit.', 'Stage 3 checks this again.')
        Question = 'Check again?'
    }
    @{
        Id = 'file-ext'; Title = 'File Explorer shows file extensions'; Required = $false
        Check = { param($Ctx) New-TaskCheck ((& $Ctx.Probe.HideFileExt) -eq 0) $(if ((& $Ctx.Probe.HideFileExt) -eq 0) { 'shown' } else { 'hidden' }) -Hint 'With them hidden, a folder and a .zip of the same name look alike, which is how the bundle got zipped twice on 10 October.' }
        Auto = { param($Ctx) & $Ctx.Probe.ShowFileExt; Say $Ctx '     Done. New File Explorer windows show them.' 'Green' }
        AutoAsk = 'Show file extensions now?'
        Steps = @('File Explorer > View > Show > File name extensions.')
        Question = 'Check again?'
    }
    @{
        Id = 'sleep'; Title = 'The PC never sleeps on mains power (OWUI and ntfy serve your phone)'; Required = $false
        Check = {
            param($Ctx)
            $m = & $Ctx.Probe.SleepAcMinutes
            if ($null -eq $m) { return New-TaskCheck $false 'powercfg could not say' }
            New-TaskCheck ($m -eq 0) $(if ($m -eq 0) { 'never' } else { "after $m minutes" })
        }
        Auto = { param($Ctx) $null = & $Ctx.Probe.SetSleepNever }
        AutoAsk = 'Set sleep to Never on mains power now?'
        Steps = @('Settings > System > Power > Screen and sleep > When plugged in, put my device to sleep after: Never.')
        Question = 'Check again?'
    }
}

function Get-Leftover([hashtable]$Ctx) {
    # Stack folders Stage 4 renders into that hold files from before the
    # rebuild. Once Stage 1 has run they are the controller's, not leftovers.
    $state = Get-ControllerState $Ctx
    if (Get-StageEntry $state 1) { return }
    foreach ($name in 'stack', 'dashboard') {
        $root = $Ctx.Topology['roots'][$name]
        if ($root -isnot [hashtable] -or $root['host'] -ne 'pc') { continue }
        $path = $root['path']
        if (-not (& $Ctx.Probe.TestPath $path 'Container')) { continue }
        $inside = @(try { & $Ctx.Probe.Children $path } catch { @{ Name = '?' } })
        if ($inside.Count) { @{ Name = $name; Path = $path } }
    }
}

# ---------- Step 2: apps, driver, Tailscale, sign-ins ----------

function Get-MenuPackage {
    <#
    .SYNOPSIS
        The apps step 2 installs with winget, in order. Versions come from
        manifests/windows-apps.json where it pins them.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $pinned = @{}
    foreach ($p in @($Ctx.Apps['packages'])) { $pinned[$p['id']] = $p['version'] }
    @{ Id = 'Git.Git'; Name = 'Git'; Version = $pinned['Git.Git']; Required = $true; Url = 'https://git-scm.com/download/win'; Paths = @('{ProgramFiles}/Git/cmd/git.exe') }
    @{ Id = 'Tailscale.Tailscale'; Name = 'Tailscale'; Version = $pinned['Tailscale.Tailscale']; Required = $true; Url = 'https://tailscale.com/download/windows'; Paths = @('{ProgramFiles}/Tailscale/tailscale.exe') }
    @{ Id = 'Bitwarden.Bitwarden'; Name = 'Bitwarden'; Required = $true; Url = 'https://bitwarden.com/download/' }
    @{ Id = 'Mozilla.Firefox'; Name = 'Firefox'; Url = 'https://www.mozilla.org/firefox/new/' }
    @{ Id = 'GitHub.GitHubDesktop'; Name = 'GitHub Desktop'; Url = 'https://desktop.github.com/'; Paths = @('{LocalAppData}/GitHubDesktop/GitHubDesktop.exe') }
    @{ Id = 'LibreHardwareMonitor.LibreHardwareMonitor'; Name = 'Libre Hardware Monitor (the ntfy PC-health watcher reads it)'; Version = $pinned['LibreHardwareMonitor.LibreHardwareMonitor']; Url = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases' }
    @{ Id = 'Ditto.Ditto'; Name = 'Ditto (clipboard history)'; Url = 'https://ditto-cp.sourceforge.io/' }
    @{ Id = 'voidtools.Everything'; Name = 'Everything (file search)'; Url = 'https://www.voidtools.com/downloads/' }
    @{ Id = 'Anthropic.Claude'; Name = 'Claude'; Url = 'https://claude.ai/download' }
    @{ Id = '9PLM9XGG6VKS'; Source = 'msstore'; Name = 'ChatGPT'; Url = 'https://openai.com/chatgpt/download/' }
    @{ Id = 'Google.Antigravity'; Name = 'Antigravity'; Url = 'https://antigravity.google/download' }
    @{ Id = 'Google.AntigravityIDE'; Name = 'Antigravity IDE'; Url = 'https://antigravity.google/download' }
}

function Get-PackageLabel([hashtable]$Package, [switch]$AnyVersion) {
    if ($Package['Version'] -and -not $AnyVersion) { return "$($Package.Name) $($Package['Version'])" }
    return $Package.Name
}

function Test-MenuPackage {
    <#
    .SYNOPSIS
        Whether winget lists the package (or, for an app installed some
        other way, whether its program is where it installs).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Package)
    $source = if ($Package['Source']) { $Package['Source'] } else { 'winget' }
    $r = & $Ctx.Probe.Exec 'winget' @('list', '--id', $Package.Id, '--exact', '--source', $source, '--accept-source-agreements', '--disable-interactivity')
    if ($r.ExitCode -eq 0) { return New-TaskCheck $true 'installed' }
    foreach ($p in @($Package['Paths'])) {
        if (-not $p) { continue }
        $full = $p -replace '\{ProgramFiles\}', (& $Ctx.Probe.Folder 'ProgramFiles') -replace '\{LocalAppData\}', (& $Ctx.Probe.Folder 'LocalAppData')
        if (& $Ctx.Probe.TestPath $full 'Leaf') { return New-TaskCheck $true 'installed (not through winget)' -Hint 'Stage 3 checks some apps with winget; if it says this one is missing, reinstall it with winget.' }
    }
    if ($r.ExitCode -eq -1) { return New-TaskCheck $false 'not checked: winget is not found (step 1b)' }
    return New-TaskCheck $false 'not installed'
}

function Install-MenuPackage {
    <#
    .SYNOPSIS
        Installs one package with winget, its output on screen. Returns
        installed, restart, not-found, no-winget or failed, and the exit code.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Package, [switch]$AnyVersion)
    $source = if ($Package['Source']) { $Package['Source'] } else { 'winget' }
    $label = Get-PackageLabel $Package -AnyVersion:$AnyVersion
    $arguments = @('install', '--id', $Package.Id, '--exact', '--source', $source, '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Package['Version'] -and -not $AnyVersion) { $arguments += @('--version', $Package['Version']) }
    Say $Ctx "  Installing $label with winget..." 'Cyan'
    $r = & $Ctx.Probe.Exec 'winget' $arguments -Stream
    $code = [int]$r.ExitCode
    $status = if ($code -eq 0 -or $code -eq $script:AlreadyThere) { 'installed' }
    elseif ($code -in $script:RebootCodes) { 'restart' }
    elseif ($code -eq $script:NotFound) { 'not-found' }
    elseif ($code -eq -1) { 'no-winget' }
    else { 'failed' }
    if ($status -eq 'restart') { $Ctx.RestartNeeded = $true }
    Write-MenuLog $Ctx "winget install $($Package.Id)$(if ($Package['Version'] -and -not $AnyVersion) { " $($Package['Version'])" }): $status (exit $code)"
    $text = switch ($status) {
        'installed' { "  $($Ctx.Glyph.ok) $label installed." }
        'restart' { "  $($Ctx.Glyph.ok) $label installed; it needs a restart to finish (the menu offers one at the end of this step)." }
        'not-found' { "  $($Ctx.Glyph.bad) winget cannot find $label (exit $code)." }
        'no-winget' { "  $($Ctx.Glyph.bad) winget is not found: step 1b checks it." }
        default { "  $($Ctx.Glyph.bad) winget could not install $label (exit $code)." }
    }
    Say $Ctx $text $(if ($status -in 'installed', 'restart') { 'Green' } else { 'Red' })
    if ($status -in 'not-found', 'failed' -and $Package['Version'] -and -not $AnyVersion) {
        $a = Read-MenuAnswer $Ctx "  Install the newest $($Package.Name) instead? The stages accept any version of it" @('y', 'n')
        if ($a -eq 'y') { return Install-MenuPackage -Ctx $Ctx -Package $Package -AnyVersion }
    }
    return @{ Status = $status; Code = $code }
}

function Invoke-AppInstallBatch([hashtable]$Ctx) {
    # Step 2's first part: list every app, then install the missing ones in
    # one go once you say yes. Each app is then its own task.
    Say $Ctx '  Checking which apps are installed (winget, a few seconds each)...' 'DarkGray'
    $missing = @()
    foreach ($p in @(Get-MenuPackage $Ctx)) {
        if (Test-TaskSkipped $Ctx '2' "app:$($p.Id)") { continue }
        $c = Test-MenuPackage -Ctx $Ctx -Package $p
        if ($c.Ok) { Say $Ctx "  $($Ctx.Glyph.ok) $(Get-PackageLabel $p)" 'Green' }
        else { Say $Ctx "  $($Ctx.Glyph.todo) $(Get-PackageLabel $p): $($c.Detail)" 'Yellow'; $missing += $p }
    }
    if (-not $missing) { return 'ok' }
    Say $Ctx ''
    $a = Read-MenuAnswer $Ctx "  Install the $($missing.Count) missing app(s) now? Some show a Windows prompt (UAC): click Yes" @('y', 'n', 'q')
    if ($a -eq 'q') { return 'quit' }
    if ($a -eq 'n') { Say $Ctx '  OK: each app comes up below on its own, with how to install it by hand.' 'DarkGray'; return 'ok' }
    foreach ($p in $missing) { $null = Install-MenuPackage -Ctx $Ctx -Package $p }
    & $Ctx.Probe.RefreshPath
    Say $Ctx '  Picked up the new commands in this window (PATH refreshed).' 'DarkGray'
    return 'ok'
}

function Get-NodeLabel([string]$DnsName) {
    # The first label of a MagicDNS name: the node's name, never its domain.
    if (-not $DnsName) { return $null }
    return ($DnsName.TrimEnd('.') -split '\.')[0].ToLowerInvariant()
}

function Get-TailscaleView {
    <#
    .SYNOPSIS
        What 'tailscale status --json' says, cut down to what the menu
        shows: the state, this node's name (first label only), whether its
        key expires, and whether the VPS node is online. No address and no
        domain leave this function.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $v = @{ Installed = $false; State = $null; Name = $null; KeyExpiry = $false; VpsFound = $false; VpsOnline = $false }
    $r = & $Ctx.Probe.Exec 'tailscale' @('status', '--json')
    if ($r.ExitCode -eq -1) { return $v }
    $v.Installed = $true
    $s = $null
    try { $s = ($r.Output -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $s = $null }
    if ($s -isnot [hashtable]) { $v.State = 'not running'; return $v }
    $v.State = [string]$s['BackendState']
    if ($s['Self'] -is [hashtable]) {
        $v.Name = Get-NodeLabel $s['Self']['DNSName']
        $v.KeyExpiry = [bool]$s['Self']['KeyExpiry']
    }
    $alias = $Ctx.Topology['hosts']['vps']['sshAlias']
    if ($s['Peer'] -is [hashtable]) {
        foreach ($p in $s['Peer'].Values) {
            if ($p -is [hashtable] -and (Get-NodeLabel $p['DNSName']) -eq $alias) { $v.VpsFound = $true; $v.VpsOnline = [bool]$p['Online'] }
        }
    }
    return $v
}

function Get-Step2Task([hashtable]$Ctx) {
    foreach ($p in @(Get-MenuPackage $Ctx)) {
        @{
            Id = "app:$($p.Id)"; Title = Get-PackageLabel $p; Required = [bool]$p['Required']; Package = $p
            Check = { param($Ctx, $Task) Test-MenuPackage -Ctx $Ctx -Package $Task.Package }
            Auto = { param($Ctx, $Task) $null = Install-MenuPackage -Ctx $Ctx -Package $Task.Package; & $Ctx.Probe.RefreshPath }
            AutoAsk = "Install $($p.Name) with winget now?"
            Steps = @("Or download it from $($p.Url) and install it.")
            Question = "Is $($p.Name) installed now?"
        }
    }
    $gpu = $Ctx.Apps['gpu']
    @{
        Id = 'gpu'; Title = "NVIDIA driver for the $($gpu['name'])"; Required = $false
        Check = {
            param($Ctx)
            $want = $Ctx.Apps['gpu']
            $r = & $Ctx.Probe.Exec 'nvidia-smi' @('--query-gpu=name,driver_version', '--format=csv,noheader')
            if ($r.ExitCode -ne 0 -or -not $r.Output) { return New-TaskCheck $false 'no NVIDIA driver answers (nvidia-smi)' }
            $parts = @("$($r.Output[0])" -split ',' | ForEach-Object { $_.Trim() })
            $name = $parts[0]
            $driver = if ($parts.Count -gt 1) { $parts[1] } else { '?' }
            if ($name -ne $want['name']) { return New-TaskCheck $false "nvidia-smi reports $name, not $($want['name'])" -Hint 'Stage 3 asks about this too (its question id is gpu).' }
            New-TaskCheck $true "$name, driver $driver" -Hint $(if ($driver -ne $want['driver']) { "The old PC ran $($want['driver']); Stage 3 notes the difference and carries on." })
        }
        Auto = { param($Ctx) & $Ctx.Probe.Open 'https://www.nvidia.com/en-gb/drivers/' }
        AutoAsk = 'Open NVIDIA''s driver download page in your browser? (The driver is not on winget.)'
        Steps = @("Choose GeForce > RTX 40 Series > $($gpu['name'] -replace '^NVIDIA GeForce ', '') > Windows 11, Game Ready or Studio driver, version $($gpu['driver']) or newer.",
            'Install it (Express is fine). Restart if it asks: this menu carries on where it stopped.')
        Question = 'Have you installed the NVIDIA driver?'
    }
    @{
        Id = 'search-off'; Title = 'Windows Search indexing is off (Everything replaces it)'; Required = $false
        Check = {
            param($Ctx)
            $s = & $Ctx.Probe.Service 'WSearch'
            if (-not $s) { return New-TaskCheck $true 'the Windows Search service is not on this PC' }
            if ($s.StartType -eq 'Disabled' -and $s.Status -eq 'Stopped') { return New-TaskCheck $true 'service disabled and stopped' }
            New-TaskCheck $false "the Windows Search service is $("$($s.Status)".ToLowerInvariant()) and starts $("$($s.StartType)".ToLowerInvariant())"
        }
        Auto = {
            param($Ctx)
            $code = & $Ctx.Probe.RunElevated 'Stop-Service -Name WSearch -Force -ErrorAction Stop; Set-Service -Name WSearch -StartupType Disabled -ErrorAction Stop'
            if ($code -ne 0) { Say $Ctx "     The admin window ended with exit code $code (the prompt was declined, or the change failed)." 'Yellow' }
        }
        AutoAsk = 'Turn it off now? A Windows admin prompt (UAC) appears: click Yes'
        Steps = @('Or by hand: Win+R > services.msc > Windows Search > Stop, then Startup type: Disabled > OK.')
        Question = 'Have you turned it off?'
    }
    @{
        Id = 'ts-up'; Title = 'Tailscale is signed in and connected'; Required = $true
        Check = {
            param($Ctx)
            $v = Get-TailscaleView $Ctx
            if (-not $v.Installed) { return New-TaskCheck $false 'the tailscale command is not found (install Tailscale above, then open a new window if it still is not)' }
            if ($v.State -eq 'Running') { return New-TaskCheck $true 'connected' }
            New-TaskCheck $false "Tailscale says: $($v.State)"
        }
        Steps = @('Open Tailscale from the Start menu if its icon is not by the clock (it may hide under ^).',
            'Click the icon > Log in, and sign in with the account your tailnet uses (the login is in Bitwarden). Approve this device if your tailnet asks.')
        Question = 'Have you signed in to Tailscale?'
    }
    @{
        Id = 'ts-name'; Title = 'This PC is named pc on the tailnet'; Required = $true
        Check = {
            param($Ctx)
            $v = Get-TailscaleView $Ctx
            if (-not $v.Name) { return New-TaskCheck $false 'Tailscale does not report a name yet' }
            if ($v.Name -eq 'pc') { return New-TaskCheck $true 'pc' }
            New-TaskCheck $false "this PC is '$($v.Name)', not 'pc'"
        }
        Auto = { param($Ctx) & $Ctx.Probe.Open 'https://login.tailscale.com/admin/machines' }
        AutoAsk = 'Open the Tailscale admin console (Machines) in your browser?'
        Steps = @("Find the old 'pc' (offline, last seen before the rebuild). Before anything else, write down its 100.x address: the next task gives it to this PC.",
            "On the old 'pc': ... (three dots) > Remove.",
            "On this PC (probably 'pc-1'): ... > Edit machine name > untick Auto-generate from OS hostname > type pc > Update name.")
        Question = 'Have you renamed this PC to pc?'
    }
    @{
        Id = 'ts-address'; Title = 'This PC has the old pc''s tailnet address'; Required = $false; Confirm = $true
        Steps = @("In the admin console: 'pc' > ... > Edit machine IPv4 > the old address you wrote down > Update.",
            'Then every file on the VPS and every link on your phone that names the PC still points at the right place.',
            'If the old node is already gone and you do not know its address, skip this (s): Stage 5 tells you if a VPS file needs moving away.')
        Question = 'Have you given this PC the old address?'
    }
    @{
        Id = 'ts-expiry'; Title = 'Its Tailscale key never expires'; Required = $false
        Check = {
            param($Ctx)
            $v = Get-TailscaleView $Ctx
            if ($v.KeyExpiry) { return New-TaskCheck $false 'it expires (Tailscale signs the PC out after 180 days)' }
            New-TaskCheck $true 'key expiry is off'
        }
        Steps = @("In the admin console: 'pc' > ... > Disable key expiry.")
        Question = 'Have you disabled key expiry?'
    }
    $alias = $Ctx.Topology['hosts']['vps']['sshAlias']
    @{
        Id = 'ts-vps'; Title = "The VPS ('$alias') is online on the tailnet"; Required = $false
        Check = {
            param($Ctx)
            $v = Get-TailscaleView $Ctx
            $a = $Ctx.Topology['hosts']['vps']['sshAlias']
            if (-not $v.VpsFound) { return New-TaskCheck $false "no '$a' node in the tailnet" }
            New-TaskCheck $v.VpsOnline $(if ($v.VpsOnline) { 'online' } else { 'offline' })
        }
        Steps = @('Rebuilding the VPS? Skip this (s): step 5 (Stage 2) brings it back.', 'Keeping it? Check the server is running in the IONOS panel.')
        Question = 'Check again?'
    }
    @{
        Id = 'signin:bitwarden'; Title = 'Signed in to Bitwarden'; Required = $true; Confirm = $true
        Steps = @('Open Bitwarden and sign in with your master password and 2FA. Step 3 downloads the secrets bundle from it.')
        Question = 'Are you signed in to Bitwarden?'
    }
    foreach ($s in @(
            @{ App = 'Mozilla.Firefox'; Name = 'Firefox'; How = 'Firefox > Settings > Sync, if you use it.' }
            @{ App = 'Anthropic.Claude'; Name = 'Claude'; How = 'Open Claude and sign in.' }
            @{ App = '9PLM9XGG6VKS'; Name = 'ChatGPT'; How = 'Open ChatGPT and sign in.' }
            @{ App = 'Google.Antigravity'; Name = 'Antigravity'; How = 'Open Antigravity (and the Antigravity IDE) and sign in with Google.' })) {
        @{
            Id = "signin:$($s.App)"; Title = "Signed in to $($s.Name)"; Required = $false; Confirm = $true; App = $s.App
            When = { param($Ctx, $Task) -not (Test-TaskSkipped $Ctx '2' "app:$($Task.App)") }
            Steps = @($s.How); Question = "Are you signed in to $($s.Name)?"
        }
    }
}

# ---------- Step 3: the secrets bundle ----------

function Get-BundleZip([hashtable]$Ctx) {
    # The stack-secrets-*.zip files directly in the staging folder.
    if (-not (& $Ctx.Probe.TestPath $Ctx.StagingRoot 'Container')) { return @() }
    @(& $Ctx.Probe.Children $Ctx.StagingRoot | Where-Object { -not $_.Folder -and $_.Name -like 'stack-secrets-*.zip' })
}

function Test-BundleShape {
    <#
    .SYNOPSIS
        Whether ZIP entry names -Entry are a full secrets bundle: the restore
        map at the top and folder 03 (the OWUI secrets) in it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][string[]]$Entry = @())
    $names = @($Entry | ForEach-Object { $_ -replace '\\', '/' })
    if ($names -contains '00-RESTORE-MAP.json') {
        if (@($names | Where-Object { $_ -like '03/*' }).Count) { return New-TaskCheck $true 'the full bundle: the restore map is at the top, and folder 03 is in it' }
        return New-TaskCheck $false 'the restore map is at the top, but folder 03 (the OWUI secrets) is missing: this looks like the key safety copy, not the full bundle' `
            -Hint 'Use the stack-secrets-<date>.zip from Bitwarden. With only the safety copy, follow Path B in docs/START-HERE.md with an assistant.'
    }
    if (@($names | Where-Object { $_ -match '^[^/]+/00-RESTORE-MAP\.json$' }).Count) {
        return New-TaskCheck $false 'the restore map is one folder down: this ZIP holds a folder that was zipped again' `
            -Hint 'Use the ZIP that was uploaded to Bitwarden as it came out of the capture (the file inside the run folder, not a ZIP of the folder).'
    }
    return New-TaskCheck $false 'there is no 00-RESTORE-MAP.json in it: this is not a stack-secrets bundle'
}

function Get-Step3Task([hashtable]$Ctx) {
    $staging = $Ctx.StagingRoot
    @{
        Id = 'old-staging'; Title = "No $staging from your old Windows account"; Required = $true
        Check = {
            param($Ctx)
            $p = $Ctx.StagingRoot
            if (-not (& $Ctx.Probe.TestPath $p 'Any')) { return New-TaskCheck $true 'not there yet: the next task makes it' }
            if (-not (& $Ctx.Probe.TestPath $p 'Container')) { return New-TaskCheck $false 'a file has that name' }
            $why = & $Ctx.Probe.Protection $p
            if (-not $why) { return New-TaskCheck $true 'it is there, and only you can open it' }
            New-TaskCheck $false "it is there, but $why" -Hint 'Stage 1 only uses a folder that only this account can open.'
        }
        Steps = @("In File Explorer, rename $staging to $([IO.Path]::GetFileName($staging))-old (click Continue if Windows asks for admin rights).",
            'It may hold plain copies of your keys from the last capture: delete it once the rebuild is finished (Shift+Delete).',
            'The menu then makes a new one that only this account can open.')
        Question = 'Have you renamed it?'
    }
    @{
        Id = 'staging'; Title = "$staging is there and only you can open it"; Required = $true
        Check = {
            param($Ctx)
            $p = $Ctx.StagingRoot
            if (-not (& $Ctx.Probe.TestPath $p 'Container')) { return New-TaskCheck $false 'not there yet' }
            $why = & $Ctx.Probe.Protection $p
            if ($why) { return New-TaskCheck $false $why }
            New-TaskCheck $true 'owner-only, not inherited'
        }
        Auto = {
            param($Ctx)
            $p = $Ctx.StagingRoot
            if (& $Ctx.Probe.TestPath $p 'Any') { return }
            if (-not (& $Ctx.PathCheck -Path $p -Root $p -AllowRoot)) { throw [InvalidOperationException]::new("$p fails the path check") }
            & $Ctx.Probe.NewFolderChain ([IO.Path]::GetDirectoryName($p))
            & $Ctx.Probe.NewProtected $p
            Write-MenuLog $Ctx "made $p, owner-only"
            Say $Ctx "     Made ${p}: only your account can open it." 'Green'
        }
        Steps = @('If the menu could not make it, the line above says why. Fix that, then check again.')
        Question = 'Check again?'
    }
    @{
        Id = 'bitlocker'; Title = "BitLocker is on for $($staging.Substring(0, 2))"; Required = $true
        Check = { param($Ctx) $b = & $Ctx.Probe.BitLocker $Ctx.StagingRoot; New-TaskCheck ($b -eq 'On') $b }
        Steps = @('Step 1b turns it on: run step 1b again.')
        Question = 'Check again?'
    }
    @{
        Id = 'zip'; Title = "One stack-secrets-*.zip in $staging"; Required = $true
        Check = {
            param($Ctx)
            $zips = @(Get-BundleZip $Ctx)
            $others = @(if (& $Ctx.Probe.TestPath $Ctx.StagingRoot 'Container') { & $Ctx.Probe.Children $Ctx.StagingRoot | Where-Object { $_.Name -notlike 'stack-secrets-*.zip' } })
            $unzipped = @($others | Where-Object { $_.Folder -and $_.Name -like 'stack-secrets-*' })
            if ($unzipped) {
                return New-TaskCheck $false "an unzipped copy is there too ($($unzipped[0].Name))" -Hint 'Delete the unzipped folder (Shift+Delete). Stage 1 unpacks the ZIP into a protected folder itself; a plain copy lying around is one more copy of your keys.'
            }
            if ($zips.Count -eq 0) { return New-TaskCheck $false 'none there yet' }
            if ($zips.Count -gt 1) { return New-TaskCheck $false "$($zips.Count) of them" -Hint 'Keep only the one whose SHA-256 is in Bitwarden: move the others out.' }
            $hint = if ($others) { "Also there: $(($others | ForEach-Object { $_.Name }) -join ', '). Stage 11 expects the folder to end up empty, so move anything you put there yourself." } else { $null }
            New-TaskCheck $true $zips[0].Name -Hint $hint
        }
        Auto = { param($Ctx) & $Ctx.Probe.Open 'explorer.exe' @("`"$($Ctx.StagingRoot)`"") }
        AutoAsk = 'Open the folder in File Explorer for you?'
        Steps = @('In Bitwarden, open the item that holds the secrets bundle and download the attachment stack-secrets-<date>.zip.',
            "Save it straight into $staging (not Downloads), with its name as it is.",
            "Don't unzip it. Step 4 (Stage 1) checks its SHA-256 and unpacks it into a protected folder.")
        Question = 'Have you saved the ZIP there?'
    }
    @{
        Id = 'sha'; Title = 'Its SHA-256 matches the one in Bitwarden'; Required = $true
        Check = {
            param($Ctx)
            $zips = @(Get-BundleZip $Ctx)
            if ($zips.Count -ne 1) { return New-TaskCheck $false 'no single ZIP to check' }
            $want = $Ctx.Menu['answers']['bundleSha256']
            if (-not $want) { return New-TaskCheck $false 'not checked yet' }
            if ($Ctx.Menu['answers']['bundleName'] -ne $zips[0].Name) { return New-TaskCheck $false 'the SHA-256 you gave was for another ZIP' }
            $have = & $Ctx.Probe.FileHash $zips[0].Path
            if ($have -eq $want) { return New-TaskCheck $true "matches ($($want.Substring(0, 8))...$($want.Substring(56)))" }
            New-TaskCheck $false 'the ZIP has changed since you checked it'
        }
        Input = {
            param($Ctx)
            $zips = @(Get-BundleZip $Ctx)
            if ($zips.Count -ne 1) { return 'quit' }
            while ($true) {
                $text = Read-MenuText $Ctx '  Paste the SHA-256 from the Bitwarden item (or q to go back to the menu)'
                if ($null -eq $text -or $text -eq 'q') { return 'quit' }
                $sha = ($text -replace '\s', '').ToLowerInvariant()
                if ($sha -notmatch '^[0-9a-f]{64}$') { Say $Ctx '     That is not a SHA-256: it should be 64 characters, 0-9 and a-f.' 'Yellow'; continue }
                Say $Ctx "     Hashing $($zips[0].Name)..." 'DarkGray'
                $have = & $Ctx.Probe.FileHash $zips[0].Path
                if ($have -eq $sha) {
                    $Ctx.Menu['answers']['bundleSha256'] = $sha
                    $Ctx.Menu['answers']['bundleName'] = $zips[0].Name
                    $Ctx.Menu['answers']['bundleBytes'] = [long](& $Ctx.Probe.FileSize $zips[0].Path)
                    Save-MenuState $Ctx
                    Write-MenuLog $Ctx "bundle SHA-256 matches: $($zips[0].Name)"
                    return 'ok'
                }
                Write-MenuLog $Ctx "bundle SHA-256 differs: $($zips[0].Name)"
                Say $Ctx '     They differ. Check, in this order:' 'Red'
                Say $Ctx '       1. You copied the SHA-256 from the same Bitwarden item as the ZIP.'
                Say $Ctx '       2. The download finished (compare the size with the one in Bitwarden).'
                Say $Ctx '       3. It is the ZIP as it was uploaded, not a folder zipped again.'
                Say $Ctx '     Then download it again into the folder, replacing this one, and paste the SHA-256 again.'
            }
        }
    }
    @{
        Id = 'shape'; Title = 'It is the full bundle'; Required = $true
        Check = {
            param($Ctx)
            $zips = @(Get-BundleZip $Ctx)
            if ($zips.Count -ne 1) { return New-TaskCheck $false 'no single ZIP to look at' }
            $entries = @(try { & $Ctx.Probe.ZipEntries $zips[0].Path } catch { @() })
            if (-not $entries) { return New-TaskCheck $false 'it cannot be opened as a ZIP (a broken download?)' }
            Test-BundleShape -Entry $entries
        }
        Steps = @('Download the right file from Bitwarden into the folder, then check again.')
        Question = 'Check again?'
    }
    @{
        Id = 'downloads'; Title = 'No other copy of the bundle in Downloads'; Required = $false
        Check = {
            param($Ctx)
            $d = & $Ctx.Probe.Folder 'Downloads'
            $copies = @(if (& $Ctx.Probe.TestPath $d 'Container') { & $Ctx.Probe.Children $d | Where-Object { $_.Name -like 'stack-secrets-*' } })
            if (-not $copies) { return New-TaskCheck $true 'none' }
            New-TaskCheck $false "$($copies.Count) there: $(($copies | ForEach-Object { $_.Name }) -join ', ')" -Hint 'Downloads is on C:, which may not be encrypted.'
        }
        Steps = @('Delete them (Shift+Delete) now the one in the protected folder is checked.')
        Question = 'Have you deleted them?'
    }
}

# ---------- Steps 4 to 14: the controller's stages ----------

function Get-StageAsk {
    <#
    .SYNOPSIS
        The ASK lines of a controller report, as Id (or $null) and Text.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][string[]]$Line = @())
    foreach ($l in $Line) {
        if ($l -match '^\s*ASK\s+(?:\[(?<id>[^\]]+)\]\s+)?(?<text>.+)$') { @{ Id = $(if ($Matches['id']) { $Matches['id'] } else { $null }); Text = $Matches['text'].Trim() } }
    }
}

function Get-StageFailureHint {
    <#
    .SYNOPSIS
        Plain-words hints for a failed stage report: Text, and Step when
        another step is the fix.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][string[]]$Line = @())
    $text = $Line -join "`n"
    if ($text -match 'the repo is at [0-9a-f]+, not [0-9a-f]+ as Stage 1 checked' -or $text -match 'manifests/\S+ (changed|is gone) since Stage 1') {
        @{ Text = 'The repo changed after Stage 1 recorded it (a pull, or another branch). Run step 4 (Stage 1) again so it records this commit, then this step.'; Step = '4' }
    }
    foreach ($m in [regex]::Matches($text, "Stage (\d+)'s checkpoint no longer passes")) {
        $n = [int]$m.Groups[1].Value
        @{ Text = "Stage $n's checkpoint fails now: something it set up has changed. Run step $(Get-StepForStage $n) (Stage $n) again; it only redoes what is missing."; Step = Get-StepForStage $n }
    }
    foreach ($m in [regex]::Matches($text, 'needs Stage (\d+) first')) {
        $n = [int]$m.Groups[1].Value
        @{ Text = "This stage needs Stage $n first: step $(Get-StepForStage $n)."; Step = Get-StepForStage $n }
    }
    if ($text -match 'holds the lock') { @{ Text = 'Another controller run is still going: most likely the admin window of Stage 3 or 8. Let it finish (or close it), then run this again.' } }
    if ($text -match 'move it away|a different file is already there') { @{ Text = 'A file from before is in the way: the controller never overwrites what it did not place. Rename the file it names (add .old), then run this again.' } }
    if ($text -match 'BitLocker is not on') { @{ Text = 'BitLocker is off for the drive: step 1b turns it on.'; Step = '1b' } }
    if ($text -match 'changed or new files') { @{ Text = 'This copy of the repo has local changes. In GitHub Desktop: Changes > right-click > Discard all changes (or Stash), then run again.' } }
    if ($text -match 'elevated window could not start') { @{ Text = 'The Windows admin prompt was declined or did not open. Run again and click Yes.' } }
    @{ Text = 'Read the PROBLEM and CHECK FAIL lines above: each says what is wrong, and most say what to do. Press a to copy a note for an assistant if you are stuck.' }
}

function Write-StageLine([hashtable]$Ctx, [string[]]$Line) {
    foreach ($l in $Line) {
        $color = if ($l -match '^\s*CHECK ok') { 'Green' }
        elseif ($l -match '^\s*(CHECK FAIL|PROBLEM)') { 'Red' }
        elseif ($l -match '^\s*(ASK|WARN)') { 'Yellow' }
        elseif ($l -match '^\s*Result:') { 'Cyan' }
        else { 'Gray' }
        Say $Ctx $l $color
    }
}

function Get-KeptVpsHostKey {
    <#
    .SYNOPSIS
        For a VPS kept as it is: the host key it offers now that matches one
        filed for it in known_hosts (placed from the bundle by Stage 1).
        Ok and Fingerprint, or Why it cannot be trusted that way.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $alias = $Ctx.Topology['hosts']['vps']['sshAlias']
    $config = Get-SshHostConfig -Machine $Ctx.Machine -Alias $alias
    if (-not $config) { return @{ Ok = $false; Why = "ssh cannot read its settings for '$alias' (Stage 1 places them from the bundle)" } }
    if (-not $config.KnownHosts -or -not (& $Ctx.Probe.TestPath $config.KnownHosts 'Leaf')) { return @{ Ok = $false; Why = 'there is no known_hosts file from the bundle' } }
    $filed = @(Get-KnownHostKey -Text (& $Ctx.Probe.ReadText $config.KnownHosts) -Token (Get-KnownHostToken -Config $config))
    if (-not $filed) { return @{ Ok = $false; Why = "the known_hosts from your backup has no key for '$alias'" } }
    $scan = & $Ctx.Machine.Exec 'ssh-keyscan' @('-T', '15', '-p', "$($config.Port)", '-t', 'ed25519,ecdsa,rsa', $config.HostName)
    $keys = @(Read-ScannedHostKey -Line $scan.Output)
    if (-not $keys) { return @{ Ok = $false; Why = "the VPS did not answer ssh-keyscan: is it on, and is '$alias' online in Tailscale?" } }
    $known = @($filed | ForEach-Object { $_.Fingerprint })
    $match = @($keys | Where-Object { $known -ccontains $_.Fingerprint } | Sort-Object { if ($_.Type -eq 'ssh-ed25519') { 0 } else { 1 } })
    if (-not $match) { return @{ Ok = $false; Mismatch = $true; Why = 'the VPS offers different host keys from the ones in your backup' } }
    return @{ Ok = $true; Fingerprint = $match[0].Fingerprint; Type = $match[0].Type }
}

function Resolve-VpsBootstrap([hashtable]$Ctx, [string]$AskText) {
    # Stage 2's first question: keep the VPS as it is, or rebuild it. Returns
    # controller parameters to run Stage 2 again with, or $null for the menu.
    $choice = $Ctx.Menu['answers']['vps']
    if (-not $choice) {
        Say $Ctx ''
        Say $Ctx '  Your VPS: keep it, or rebuild it?' 'Cyan'
        Say $Ctx '    k = keep it as it is (it still works): the menu checks it is the same server as in your backup, then Stage 2 checks and tops up its base.'
        Say $Ctx '    r = rebuild it from scratch in the IONOS console. This wipes the VPS; only for a lost or broken one.'
        $a = Read-MenuAnswer $Ctx '  Keep or rebuild?' @('k', 'r', 'q')
        if ($a -eq 'q') { return $null }
        if ($a -eq 'r') {
            $t = Read-MenuText $Ctx '  Type REBUILD to confirm you will wipe and rebuild the VPS (anything else goes back)'
            if ($t -cne 'REBUILD') { Say $Ctx '  Not confirmed: nothing changes.' 'Yellow'; return $null }
        }
        $choice = if ($a -eq 'k') { 'keep' } else { 'rebuild' }
        $Ctx.Menu['answers']['vps'] = $choice
        Save-MenuState $Ctx
        Add-MenuHistory $Ctx "VPS: $choice"
    }
    if ($choice -eq 'keep') {
        Say $Ctx '  Checking the VPS is the same server as in your backup (ssh-keyscan against known_hosts)...' 'DarkGray'
        $k = Get-KeptVpsHostKey $Ctx
        if (-not $k.Ok) {
            Say $Ctx "  $($Ctx.Glyph.bad) Not trusted: $($k.Why)." 'Red'
            if ($k['Mismatch']) { Say $Ctx '     Stop here. If the VPS was rebuilt, choose rebuild (type R at the menu to start the menu over, or ask an assistant). If not, something is wrong: ask for help before going on.' 'Yellow' }
            return $null
        }
        Say $Ctx "  $($Ctx.Glyph.ok) The VPS offers the $($k.Type) key filed in your backup: $($k.Fingerprint)" 'Green'
        if ((Read-MenuAnswer $Ctx '  Trust it and carry on with Stage 2?' @('y', 'n')) -ne 'y') { return $null }
        return @{ Accept = @('vps-bootstrap'); HostKeyFingerprint = $k.Fingerprint }
    }
    Say $Ctx ''
    Say $Ctx '  Rebuild the VPS. What the controller asks:' 'Cyan'
    Say $Ctx "    $AskText"
    Say $Ctx '  In order:' 'Cyan'
    Say $Ctx '    1. IONOS: rebuild the server with Ubuntu 24.04 and open its web console as root.'
    Say $Ctx '    2. Paste the bootstrap file the line above names into the console. At the end it prints the server''s host key fingerprint (SHA256:...).'
    Say $Ctx '    3. Tailscale admin console: remove the old vps node, then approve the new one so it is named vps.'
    if ((Read-MenuAnswer $Ctx '  Have you done all three?' @('y', 'n')) -ne 'y') { return $null }
    $fp = Read-HostKeyFingerprint $Ctx
    if (-not $fp) { return $null }
    return @{ Accept = @('vps-bootstrap'); HostKeyFingerprint = $fp }
}

function Read-HostKeyFingerprint([hashtable]$Ctx) {
    while ($true) {
        $t = Read-MenuText $Ctx '  Type the fingerprint the console printed, SHA256:... (or q to go back)'
        if ($null -eq $t -or $t -eq 'q') { return $null }
        $t = $t -replace '\s', ''
        if ($t -cmatch '^SHA256:[A-Za-z0-9+/]{43}$') { return $t }
        Say $Ctx '     That is not a fingerprint: it is SHA256: then 43 letters, digits, + or /. Check each character against the console.' 'Yellow'
    }
}

function Invoke-StageStep {
    <#
    .SYNOPSIS
        Runs one of Stages 1 to 11 through the controller, as many times as
        it takes: answers its questions, offers restarts, explains failures.
        Returns done, needs-user, reboot, failed, or a step id to go to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Step)
    $n = $Step.Stage
    $entry = Get-MenuStepEntry $Ctx $Step.Id
    Say $Ctx ''
    Say $Ctx "Step $($Step.Id) - Stage $n of 11: $($Step.What)" 'Cyan'
    Say $Ctx "  Your part: $($Step.Yours)" 'DarkCyan'
    $arguments = @{ Stage = $n }
    if ($n -eq 1) {
        $sha = $Ctx.Menu['answers']['bundleSha256']
        if (-not $sha) { Say $Ctx "  $($Ctx.Glyph.bad) Step 3 has not recorded the bundle's SHA-256 yet: do step 3 first." 'Red'; return 'failed' }
        $arguments['BundleSha256'] = $sha
    }
    if ($Step.Admin) { Say $Ctx '  This stage needs admin rights: a Windows prompt (UAC) appears, click Yes. It runs in a second window, and this one waits for it.' 'Yellow' }
    if ((Read-MenuAnswer $Ctx "  Run Stage $n now?" @('y', 'n')) -ne 'y') { return 'needs-user' }
    while ($true) {
        Say $Ctx "  Running Stage $n. Its own report follows; it stops at its checkpoint." 'DarkGray'
        Write-MenuLog $Ctx "running Stage $n"
        try { $r = & $Ctx.Controller $arguments }
        catch { $r = [pscustomobject]@{ Status = 'failed'; Lines = [string[]]@("PROBLEM  the controller stopped: $($_.Exception.Message)") } }
        $lines = [string[]]@($r.Lines)
        Write-StageLine $Ctx $lines
        $entry['last'] = [string[]]@($lines | Select-Object -Last 60)
        $entry['at'] = (& $Ctx.Probe.Now).ToString('o')
        $entry['status'] = [string]$r.Status
        $entry.Remove('redo')
        Save-MenuState $Ctx
        Write-MenuLog $Ctx "Stage ${n}: $($r.Status)"
        if ($r.Status -eq 'done') {
            Say $Ctx ''
            Say $Ctx "  $($Ctx.Glyph.ok) Step $($Step.Id) is done: checkpoint $n passed." 'Green'
            if ($n -eq 1) { Say $Ctx '  Stage 1 recorded this commit of the repo: do not pull until the rebuild is finished.' 'DarkGray' }
            return 'done'
        }
        if ($r.Status -eq 'reboot') {
            $null = Invoke-RestartOffer $Ctx "Stage $n needs a restart; it carries on when you run step $($Step.Id) again."
            return 'reboot'
        }
        if ($r.Status -eq 'needs-user') {
            $next = Resolve-StageAsk $Ctx $Step $lines
            if ($null -eq $next) { return 'needs-user' }
            foreach ($k in $next.Keys) { $arguments[$k] = $next[$k] }
            continue
        }
        $go = Resolve-StageFailure $Ctx $Step $lines
        if ($go -eq 'rerun') { continue }
        return $go
    }
}

function Resolve-StageAsk([hashtable]$Ctx, [hashtable]$Step, [string[]]$Lines) {
    # The stage's questions, one by one. Returns controller parameters to
    # run it again with, or $null to go back to the menu.
    $asks = @(Get-StageAsk -Line $Lines)
    $vps = $asks | Where-Object { $_.Id -eq 'vps-bootstrap' } | Select-Object -First 1
    if ($Step.Stage -eq 2 -and $vps) { return Resolve-VpsBootstrap $Ctx $vps.Text }
    if ($Step.Stage -eq 2 -and ($asks | Where-Object { $_.Text -like '*host key fingerprint*' })) {
        $fp = Read-HostKeyFingerprint $Ctx
        if (-not $fp) { return $null }
        return @{ HostKeyFingerprint = $fp }
    }
    Say $Ctx ''
    Say $Ctx "  Stage $($Step.Stage) needs you:" 'Cyan'
    $accepted = @()
    $i = 0
    foreach ($a in $asks) {
        $i++
        Say $Ctx "    $i. $($a.Text)" 'Yellow'
        if ($a.Id) {
            $ans = Read-MenuAnswer $Ctx "    Done, or accepted? (y answers '$($a.Id)' for you; n leaves it open)" @('y', 'n', 'q')
            if ($ans -eq 'q') { return $null }
            if ($ans -eq 'y') { $accepted += $a.Id }
        }
        else { Say $Ctx '       Do what it says; then run the stage again.' 'DarkGray' }
    }
    if (-not $asks) { Say $Ctx '    (No ASK lines: read the report above.)' 'DarkGray' }
    if ((Read-MenuAnswer $Ctx "  Run Stage $($Step.Stage) again now?" @('y', 'n')) -ne 'y') { return $null }
    $next = @{}
    if ($accepted) { $next['Accept'] = [string[]]$accepted }
    return $next
}

function Resolve-StageFailure([hashtable]$Ctx, [hashtable]$Step, [string[]]$Lines) {
    $state = Get-ControllerState $Ctx
    $e = Get-StageEntry $state $Step.Stage
    $evidence = if ($e -and $e['evidence']) { [IO.Path]::ChangeExtension([string]$e['evidence'], '.txt') } else { $null }
    Say $Ctx ''
    Say $Ctx "  $($Ctx.Glyph.bad) Stage $($Step.Stage) did not pass. What to try:" 'Red'
    $offers = @()
    foreach ($h in @(Get-StageFailureHint -Line $Lines)) {
        Say $Ctx "    - $($h.Text)" 'Yellow'
        if ($h['Step'] -and $h['Step'] -notin $offers) { $offers += $h['Step'] }
    }
    if ($evidence) { Say $Ctx "    The full report: $evidence" 'DarkGray' }
    while ($true) {
        $choices = @('r') + @(if ($evidence) { 'e' }) + @('a') + @($offers | ForEach-Object { "go$_" }) + @('m')
        Say $Ctx "  r = run Stage $($Step.Stage) again$(if ($evidence) { ', e = open the full report' }), a = copy a note for an assistant$(($offers | ForEach-Object { ", go$_ = go to step $_" }) -join ''), m = back to the menu" 'Cyan'
        $a = Read-MenuAnswer $Ctx '  Choose' $choices
        if ($a -eq 'r') { return 'rerun' }
        if ($a -eq 'e') { & $Ctx.Probe.Open 'notepad.exe' @("`"$evidence`""); continue }
        if ($a -eq 'a') { Copy-MenuHelpNote $Ctx; continue }
        if ($a -like 'go*') { return $a.Substring(2) }
        return 'failed'
    }
}

function Get-RunOnceCommand([hashtable]$Ctx) {
    # Starts the menu once at the next sign-in, after waiting up to 90
    # seconds for the drive it lives on (BitLocker auto-unlock). RunOnce
    # values are limited to 260 characters.
    $pwsh = & $Ctx.Probe.Folder 'Pwsh'
    $script = Join-Path $Ctx.RepoRoot 'Start-Recovery.ps1'
    return "`"$pwsh`" -NoProfile -ExecutionPolicy Bypass -Command `"`$f='$script';1..90|%{if(!(Test-Path `$f)){sleep 1}};& `$f`""
}

function Invoke-RestartOffer([hashtable]$Ctx, [string]$Why) {
    Say $Ctx ''
    Say $Ctx "  $($Ctx.Glyph.reboot) $Why" 'Yellow'
    $a = Read-MenuAnswer $Ctx '  Restart the PC now? The menu opens again by itself after you sign in' @('y', 'n')
    if ($a -ne 'y') {
        Say $Ctx '  OK. Restart when you are ready, then start Start-Recovery.cmd: it carries on where it stopped.' 'DarkGray'
        return 'later'
    }
    $command = Get-RunOnceCommand $Ctx
    if ($command.Length -gt 260) { Say $Ctx '  (Too long a path to reopen by itself: start Start-Recovery.cmd after the restart.)' 'Yellow' }
    else { & $Ctx.Probe.RunOnce 'OllamaCriaRecoveryMenu' $command }
    Add-MenuHistory $Ctx "restart: $Why"
    Save-MenuState $Ctx
    $Ctx.Restarting = $true
    Say $Ctx '  Restarting. See you after you sign in.' 'Cyan'
    & $Ctx.Probe.Restart
    return 'restarting'
}

# ---------- The menu ----------

function Get-MenuStepStatus {
    <#
    .SYNOPSIS
        done, failed, needs-user, reboot, running, skipped or todo. Prep
        steps from menu.json; stage steps from the controller's state.json,
        unless you went back to one with B.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Step, $ControllerState)
    $e = $Ctx.Menu['steps'][$Step.Id]
    if ($Step.Kind -eq 'prep') {
        if ($e -is [hashtable] -and $e['status']) { return [string]$e['status'] }
        return 'todo'
    }
    if ($e -is [hashtable] -and $e['redo']) { return 'todo' }
    if ($e -is [hashtable] -and $e['skipped'] -is [hashtable] -and $e['skipped'].ContainsKey('step')) { return 'skipped' }
    if ($null -eq $ControllerState) { $ControllerState = Get-ControllerState $Ctx }
    $s = Get-StageEntry $ControllerState $Step.Stage
    if (-not $s -or -not $s['status'] -or $s['status'] -eq 'not started') { return 'todo' }
    return [string]$s['status']
}

function Get-NextMenuStep([hashtable]$Ctx, $ControllerState) {
    foreach ($s in @(Get-RecoveryMenuStep)) {
        if ((Get-MenuStepStatus -Ctx $Ctx -Step $s -ControllerState $ControllerState) -notin 'done', 'skipped') { return $s }
    }
    return $null
}

function Get-MenuTable([hashtable]$Ctx, $ControllerState, [hashtable]$Next) {
    foreach ($s in @(Get-RecoveryMenuStep)) {
        $status = Get-MenuStepStatus -Ctx $Ctx -Step $s -ControllerState $ControllerState
        $mark = $Ctx.Glyph[$status]
        if (-not $mark) { $mark = $Ctx.Glyph.todo }
        $pointer = if ($Next -and $Next.Id -eq $s.Id) { $Ctx.Glyph.pointer } else { ' ' }
        $note = switch ($status) { 'failed' { '  (failed: choose it for what to do)' } 'needs-user' { '  (waiting for you)' } 'reboot' { '  (restart, then choose it again)' } 'running' { '  (interrupted: choose it to carry on)' } default { '' } }
        @{ Text = ('{0} {1,-3} {2} {3}{4}' -f $pointer, $s.Id, $mark, $s.Title, $note); Status = $status }
    }
}

function Show-MenuScreen([hashtable]$Ctx) {
    $state = Get-ControllerState $Ctx
    $next = Get-NextMenuStep $Ctx $state
    $repo = Get-RepoView $Ctx
    & $Ctx.Ui.Clear
    Say $Ctx 'ollama-cria: rebuild the PC, one step at a time' 'Cyan'
    Say $Ctx ("Repo {0}  ({1} at {2})    Records {3}" -f $Ctx.RepoRoot, $(if ($repo.Branch) { $repo.Branch } else { 'no branch' }), $(if ($repo.Commit) { $repo.Commit.Substring(0, 12) } else { '?' }), $Ctx.StateRoot) 'DarkGray'
    $recorded = if ($state['release'] -is [hashtable]) { $state['release']['commit'] } else { $null }
    if ($recorded -and $repo.Commit -and $repo.Commit -ne $recorded) { Say $Ctx "$($Ctx.Glyph.warn)The repo moved since Stage 1 recorded it: run step 4 again before any later step." 'Yellow' }
    if ($Ctx.MenuProblem) { Say $Ctx "$($Ctx.Glyph.warn)$($Ctx.MenuProblem); started a new record." 'Yellow' }
    Say $Ctx ''
    foreach ($row in @(Get-MenuTable $Ctx $state $next)) {
        $color = switch ($row.Status) { 'done' { 'Green' } 'failed' { 'Red' } 'skipped' { 'DarkYellow' } 'todo' { 'Gray' } default { 'Yellow' } }
        Say $Ctx $row.Text $color
    }
    Say $Ctx ''
    if ($next) { Say $Ctx "Enter = step $($next.Id) (next)    1a, 1b, 2 ... 14 = that step    c = check everything again" 'Cyan' }
    else { Say $Ctx "Every step is done.    1a, 1b, 2 ... 14 = run a step again    c = check everything again" 'Green' }
    Say $Ctx 'b = go back a step    r = start from scratch    a = copy a note for an assistant    h = help    q = quit (any time: progress is saved)' 'Cyan'
}

function Get-MenuStatusText {
    <#
    .SYNOPSIS
        Where the rebuild is up to, as plain text for an assistant: every
        step, the last lines of each step that needs attention, and the end
        of the log. Reads the records; changes nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $plain = Get-MenuGlyph -Plain
    $saved = $Ctx.Glyph
    $Ctx.Glyph = $plain
    try {
        $state = Get-ControllerState $Ctx
        $next = Get-NextMenuStep $Ctx $state
        $repo = Get-RepoView $Ctx
        "ollama-cria rebuild menu: status at $((& $Ctx.Probe.Now).ToString('yyyy-MM-dd HH:mm')) UTC"
        "Repo: $($Ctx.RepoRoot), $(if ($repo.Branch) { $repo.Branch } else { 'no branch' }) at $(if ($repo.Commit) { $repo.Commit.Substring(0, 12) } else { 'unknown' })"
        "Records: $($Ctx.MenuPath), $($Ctx.LogPath), $($Ctx.StatePath)"
        if ($state['unreadable']) { "state.json: $($state['unreadable'])" }
        "Next: $(if ($next) { "step $($next.Id)" } else { 'nothing: every step is done' })"
        'Marks: [x] done, [!] failed, [?] waiting for Liam, [r] restart needed, [-] skipped, [ ] not done'
        ''
        foreach ($row in @(Get-MenuTable $Ctx $state $next)) { $row.Text }
        foreach ($s in @(Get-RecoveryMenuStep)) {
            $status = Get-MenuStepStatus -Ctx $Ctx -Step $s -ControllerState $state
            $e = $Ctx.Menu['steps'][$s.Id]
            $skips = if ($e -is [hashtable] -and $e['skipped'] -is [hashtable]) { $e['skipped'] } else { @{} }
            if ($status -in 'done', 'todo' -and -not $skips.Count) { continue }
            ''
            "Step $($s.Id) ($status)$(if ($e -is [hashtable] -and $e['pausedAt']) { ", paused at: $($e['pausedAt'])" })"
            foreach ($k in $skips.Keys) { "  skipped $k because: $($skips[$k])" }
            if ($s.Kind -eq 'stage') {
                $se = Get-StageEntry $state $s.Stage
                if ($se -and $se['evidence']) { "  evidence: $([IO.Path]::ChangeExtension([string]$se['evidence'], '.txt')) (attempt $($se['attempts']))" }
            }
            if ($e -is [hashtable] -and $e['last']) { foreach ($l in @($e['last'] | Select-Object -Last 25)) { "  | $l" } }
        }
        ''
        'The end of menu-log.txt:'
        if (& $Ctx.Probe.TestPath $Ctx.LogPath 'Leaf') { foreach ($l in @((& $Ctx.Probe.ReadText $Ctx.LogPath) -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 30)) { "  $l" } }
        else { '  (no log yet)' }
        ''
        'For an assistant: read docs/MENU-HELP-FOR-AI.md in the repo first. Liam drives the menu; help him read what it says and fix what it asks for.'
    }
    finally { $Ctx.Glyph = $saved }
}

function Copy-MenuHelpNote([hashtable]$Ctx) {
    # The status text, to the clipboard and to help-note.txt.
    $text = (@('I am rebuilding my PC with the ollama-cria recovery menu (Start-Recovery.cmd) and I am stuck. Read docs/MENU-HELP-FOR-AI.md in the repo, then this:', '') + @(Get-MenuStatusText -Ctx $Ctx)) -join [Environment]::NewLine
    try { & $Ctx.Probe.Clipboard $text; Say $Ctx '  Copied. Paste it into Claude (or another assistant).' 'Green' }
    catch { Say $Ctx '  The clipboard is not available here.' 'Yellow' }
    if ((& $Ctx.PathCheck -Path $Ctx.HelpPath -Root $Ctx.StateRoot) -and -not $Ctx.ReadOnly) {
        Initialize-MenuStateRoot $Ctx
        [IO.File]::WriteAllText($Ctx.HelpPath, $text + "`n", [Text.UTF8Encoding]::new($false))
        Say $Ctx "  Also saved as $($Ctx.HelpPath), for an assistant that can read your files." 'DarkGray'
    }
    Write-MenuLog $Ctx 'wrote a help note'
}

function Show-MenuHelp([hashtable]$Ctx) {
    $g = $Ctx.Glyph
    Say $Ctx ''
    Say $Ctx 'How the menu works' 'Cyan'
    foreach ($l in @(
            'Type a step (1a, 1b, 2, 3, 4 ... 14) and press Enter, or just Enter for the next one.',
            'Inside a step, the menu checks each task, does what it can for you (it always asks first), and asks you about the rest.',
            "Answers: y = yes / done (it checks again), n = not yet, s = skip (optional tasks only; you give a reason), q = back to the menu.",
            "Marks: $($g.done) done, $($g.failed) failed, $($g['needs-user']) waiting for you, $($g.reboot) restart needed, $($g.skipped) skipped, $($g.todo) not done.",
            'Restarts are expected. The menu saves after every answer: start Start-Recovery.cmd again and it carries on (it can reopen itself after a restart).',
            'b goes back a step: it is marked not done and runs again next. A stage run again only redoes what is missing.',
            'r starts the menu from scratch (its record is kept as menu-<time>.json).',
            "Stuck? a copies a note for an assistant: paste it into Claude. It points at docs/MENU-HELP-FOR-AI.md.",
            "Records: $($Ctx.MenuPath), $($Ctx.LogPath) and, for the stages, $($Ctx.StatePath).")) { Say $Ctx "  $l" }
    Wait-MenuKey $Ctx
}

function Undo-MenuStep([hashtable]$Ctx) {
    # 'b': the last step that is done goes back to not done.
    $state = Get-ControllerState $Ctx
    $done = @(Get-RecoveryMenuStep | Where-Object { (Get-MenuStepStatus -Ctx $Ctx -Step $_ -ControllerState $state) -in 'done', 'skipped' })
    if (-not $done) { Say $Ctx '  Nothing is done yet, so there is nothing to go back to.' 'Yellow'; return }
    $s = $done[-1]
    if ((Read-MenuAnswer $Ctx "  Go back to step $($s.Id) ($($s.Title))? It will show as not done and run again when you choose it" @('y', 'n')) -ne 'y') { return }
    $e = Get-MenuStepEntry $Ctx $s.Id
    if ($s.Kind -eq 'prep') {
        $e['status'] = 'todo'
        $e['confirmed'] = @()
        $e['skipped'] = @{}
    }
    else {
        $e['redo'] = $true
        if ($e['skipped'] -is [hashtable]) { $e['skipped'].Remove('step') }
    }
    Add-MenuHistory $Ctx "went back to step $($s.Id)"
    Save-MenuState $Ctx
    Say $Ctx "  Step $($s.Id) is next." 'Green'
}

function Get-FreeName([hashtable]$Ctx, [string]$Base, [string]$Extension) {
    # <state root>\<Base><Extension>, or <Base>-2<Extension> and so on when
    # that is taken: a record set aside never replaces an older one.
    $path = Join-Path $Ctx.StateRoot "$Base$Extension"
    for ($i = 2; & $Ctx.Probe.TestPath $path 'Any'; $i++) { $path = Join-Path $Ctx.StateRoot "$Base-$i$Extension" }
    return $path
}

function Reset-RecoveryMenu {
    <#
    .SYNOPSIS
        'r': the menu starts from scratch. Its record is kept beside it as
        menu-<time>.json. The controller's state.json is set aside only when
        you ask for that too, and never while a stage runs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive: it asks before changing anything.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Ctx)
    Say $Ctx ''
    Say $Ctx '  Start the menu from scratch: every step shows as not done, and every question is asked again.' 'Yellow'
    $t = Read-MenuText $Ctx '  Type RESET to do it (anything else keeps everything)'
    if ($t -cne 'RESET') { Say $Ctx '  Kept as it is.' 'DarkGray'; return }
    $stamp = (& $Ctx.Probe.Now).ToString('yyyyMMdd-HHmmss')
    if (& $Ctx.Probe.TestPath $Ctx.MenuPath 'Leaf') {
        $old = Get-FreeName $Ctx "menu-$stamp" '.json'
        if (-not (& $Ctx.PathCheck -Path $Ctx.MenuPath, $old -Root $Ctx.StateRoot)) { throw [InvalidOperationException]::new('the menu record fails the path check') }
        & $Ctx.Probe.Rename $Ctx.MenuPath ([IO.Path]::GetFileName($old))
        Say $Ctx "  The old record is kept as $old." 'DarkGray'
    }
    $Ctx.Menu = New-MenuState -Now (& $Ctx.Probe.Now)
    Save-MenuState $Ctx
    Add-MenuHistory $Ctx 'started from scratch'
    Save-MenuState $Ctx
    if (-not (& $Ctx.Probe.TestPath $Ctx.StatePath 'Leaf')) { return }
    Say $Ctx ''
    Say $Ctx '  The controller has its own record (state.json) of Stages 1 to 11.' 'Yellow'
    Say $Ctx '  Setting it aside makes Stage 1 onward start from zero. Files the stages placed stay where they are, and the stages refuse files they did not place in the new record, so you may have to move some away. Only do this to redo the stages on purpose.'
    if ((Read-MenuAnswer $Ctx '  Set state.json aside too?' @('y', 'n')) -ne 'y') { return }
    if (& $Ctx.Probe.TestPath (Join-Path $Ctx.StateRoot 'state.lock') 'Leaf') { Say $Ctx '  A stage is running (state.lock is there): not now.' 'Red'; return }
    $oldState = Get-FreeName $Ctx "state-$stamp" '.json'
    if (-not (& $Ctx.PathCheck -Path $Ctx.StatePath, $oldState -Root $Ctx.StateRoot)) { throw [InvalidOperationException]::new('state.json fails the path check') }
    & $Ctx.Probe.Rename $Ctx.StatePath ([IO.Path]::GetFileName($oldState))
    Add-MenuHistory $Ctx "set state.json aside as $([IO.Path]::GetFileName($oldState))"
    Save-MenuState $Ctx
    Say $Ctx "  state.json is kept as $oldState." 'DarkGray'
}

function Invoke-MenuCheck([hashtable]$Ctx) {
    # 'c': every prep task's check again, without questions; then the
    # controller's own plan if you want it. Changes nothing.
    Say $Ctx ''
    foreach ($id in '1a', '1b', '2', '3') {
        Say $Ctx "Step $id" 'Cyan'
        foreach ($t in @(Get-PrepTask -Ctx $Ctx -StepId $id)) {
            if ($t['Info']) { continue }
            if ($t['When'] -and -not (& $t['When'] $Ctx $t)) { continue }
            if (Test-TaskSkipped $Ctx $id $t.Id) { Say $Ctx "  $($Ctx.Glyph.skip) $($t.Title): skipped" 'DarkYellow'; continue }
            if ($t['Confirm']) {
                $e = $Ctx.Menu['steps'][$id]
                $yes = $e -is [hashtable] -and @($e['confirmed']) -contains $t.Id
                Say $Ctx "  $(if ($yes) { $Ctx.Glyph.ok } else { $Ctx.Glyph.ask }) $($t.Title)$(if ($yes) { ' (you confirmed this)' } else { ' (not confirmed yet)' })" $(if ($yes) { 'Green' } else { 'Yellow' })
                continue
            }
            $c = & $t.Check $Ctx $t
            Say $Ctx "  $(if ($c.Ok) { $Ctx.Glyph.ok } else { $Ctx.Glyph.bad }) $($t.Title)$(if ($c.Detail) { ": $($c.Detail)" })" $(if ($c.Ok) { 'Green' } else { 'Red' })
        }
    }
    if ((Read-MenuAnswer $Ctx '  Also show the controller''s plan for Stages 1 to 11 (changes nothing)?' @('y', 'n')) -eq 'y') {
        $controllerPath = Join-Path $Ctx.RepoRoot 'Invoke-StackRecovery.ps1'
        $plan = & $controllerPath -PassThru
        Write-StageLine $Ctx ([string[]]@($plan.Lines))
    }
    Wait-MenuKey $Ctx
}

function Get-OpenPrepStep([hashtable]$Ctx) {
    @(Get-RecoveryMenuStep | Where-Object { $_.Kind -eq 'prep' -and (Get-MenuStepStatus -Ctx $Ctx -Step $_) -notin 'done', 'skipped' })
}

function Invoke-MenuStep {
    <#
    .SYNOPSIS
        Runs step -Id (1a to 14), with the gates in front of it. Returns
        what the step returned, or a step id to go to next.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Id)
    $step = Get-MenuStepById $Id
    if (-not $step) { Say $Ctx "  There is no step $Id." 'Yellow'; return 'none' }
    $Ctx.CurrentStep = $Id
    try {
        if ($step.Kind -eq 'prep') { return Invoke-PrepStep -Ctx $Ctx -Step $step }
        $open = @(Get-OpenPrepStep $Ctx)
        if ($open) {
            Say $Ctx ''
            Say $Ctx "  Steps $(($open | ForEach-Object { $_.Id }) -join ', ') are not done yet. The stages assume they are." 'Yellow'
            $t = Read-MenuText $Ctx '  Type SKIP to run this step anyway (it goes in the log), or press Enter to go back'
            if ($t -cne 'SKIP') { return 'none' }
            $why = Read-MenuText $Ctx '  Why? A few words for the log'
            Add-MenuHistory $Ctx "ran step $Id before steps $(($open | ForEach-Object { $_.Id }) -join ', '): $(if ($why) { 'reason given' } else { 'no reason' })"
            if ($why) { (Get-MenuStepEntry $Ctx $Id)['gateReason'] = $why }
            Save-MenuState $Ctx
        }
        $state = Get-ControllerState $Ctx
        $waiting = @($step.Needs | Where-Object { (Get-MenuStepStatus -Ctx $Ctx -Step (Get-MenuStepById (Get-StepForStage $_)) -ControllerState $state) -ne 'done' })
        if ($waiting) {
            $first = Get-StepForStage $waiting[0]
            Say $Ctx "  Stage $($step.Stage) needs Stage $($waiting -join ' and ') first (step $(($waiting | ForEach-Object { Get-StepForStage $_ }) -join ' and '))." 'Yellow'
            if ((Read-MenuAnswer $Ctx "  Go to step $first instead?" @('y', 'n')) -eq 'y') { return $first }
            return 'none'
        }
        return Invoke-StageStep -Ctx $Ctx -Step $step
    }
    finally { $Ctx.CurrentStep = $null }
}

function Start-RecoveryMenu {
    <#
    .SYNOPSIS
        The menu loop: shows every step, runs the one you choose, and comes
        back here after each. -Step opens one straight away.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive: every change is asked for in the menu.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Ctx, [string]$Step)
    if (& $Ctx.Probe.IsElevated) {
        Say $Ctx "$($Ctx.Glyph.warn)This window runs as Administrator. Start Start-Recovery.cmd normally instead: what the stages make from here would belong to the Administrators group." 'Yellow'
        if ((Read-MenuAnswer $Ctx 'Carry on anyway?' @('y', 'n')) -ne 'y') { return }
    }
    if ($Ctx.MenuProblem) {
        $stamp = (& $Ctx.Probe.Now).ToString('yyyyMMdd-HHmmss')
        $broken = Get-FreeName $Ctx "menu-unreadable-$stamp" '.json'
        if (& $Ctx.PathCheck -Path $Ctx.MenuPath, $broken -Root $Ctx.StateRoot) { & $Ctx.Probe.Rename $Ctx.MenuPath ([IO.Path]::GetFileName($broken)) }
    }
    Write-MenuLog $Ctx 'menu started'
    $goto = $Step
    while ($true) {
        if ($goto) {
            $id = $goto
            $goto = $null
            try { $r = Invoke-MenuStep -Ctx $Ctx -Id $id }
            catch {
                $r = 'error'
                Say $Ctx ''
                Say $Ctx "  $($Ctx.Glyph.bad) Step $id hit an error the menu did not expect: $($_.Exception.Message)" 'Red'
                Say $Ctx '     It is in menu-log.txt. Your progress is saved; choose the step again, or press a for a note to give an assistant.' 'Yellow'
                Write-MenuLog $Ctx "error in step ${id}: $($_.Exception.Message)"
            }
            if ($Ctx.Restarting) { return }
            if ($r -match '^(1a|1b|[2-9]|1[0-4])$') { $goto = $r; continue }
            Wait-MenuKey $Ctx 'Press any key for the menu...'
        }
        Show-MenuScreen $Ctx
        $raw = & $Ctx.Ui.Ask 'Choose'
        if ($null -eq $raw) { return }
        $c = "$raw".Trim().ToLowerInvariant()
        if ($c -eq '') {
            $next = Get-NextMenuStep $Ctx $null
            if ($next) { $goto = $next.Id }
            continue
        }
        if ($c -match '^(1a|1b|[2-9]|1[0-4])$') { $goto = $c; continue }
        if ($c -eq 'q') { Write-MenuLog $Ctx 'menu closed'; Say $Ctx 'Progress is saved. Start Start-Recovery.cmd to carry on.' 'Cyan'; return }
        if ($c -eq 'b') { Undo-MenuStep $Ctx; Wait-MenuKey $Ctx; continue }
        if ($c -eq 'r') { Reset-RecoveryMenu -Ctx $Ctx; Wait-MenuKey $Ctx; continue }
        if ($c -eq 'c') { Invoke-MenuCheck $Ctx; continue }
        if ($c -eq 'a') { Copy-MenuHelpNote $Ctx; Wait-MenuKey $Ctx; continue }
        if ($c -eq 'h') { Show-MenuHelp $Ctx; continue }
        Say $Ctx "  '$c' is not a choice here: type a step (1a ... 14), or b, c, r, a, h, q." 'Yellow'
        Wait-MenuKey $Ctx
    }
}

Export-ModuleMember -Function Get-RecoveryMenuStep, Get-MenuGlyph, New-MenuUi, New-MenuProbe, New-MenuContext, New-MenuState, Read-MenuState, New-TaskCheck,
Get-PrepTask, Invoke-MenuTask, Invoke-PrepStep, Get-MenuPackage, Test-MenuPackage, Install-MenuPackage, Get-TailscaleView, Test-BundleShape,
Get-StageAsk, Get-StageFailureHint, Get-KeptVpsHostKey, Invoke-StageStep, Get-MenuStepStatus, Get-MenuStatusText, Reset-RecoveryMenu,
Invoke-MenuStep, Start-RecoveryMenu
