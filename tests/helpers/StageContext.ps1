# Dot-sourced by the stage tests. A fake machine (every script block the
# stages use, driven by $global:CriaFake) and a stage context like the one
# Invoke-StackRecovery.ps1 builds, with every root in the test drive.

$script:RealRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RealRepo 'tools/RecoveryState.psm1') -Force
Import-Module (Join-Path $script:RealRepo 'tools/RecoveryHost.psm1') -Force

function New-ExecResult([int]$Code = 0, [string[]]$Output = @()) {
    [pscustomobject]@{ ExitCode = $Code; Output = [string[]]$Output }
}

function ConvertFrom-VpsCommand([string]$Remote) {
    # The repo script and arguments in a command tools/RecoveryVps.psm1
    # built, or $null for any other remote command.
    if ($Remote -notmatch '^t=\$\(mktemp\) && echo (\S+) \| base64 -d > \$t && sudo -n bash \$t (.*?); r=\$\?; rm -f \$t; exit \$r$') { return $null }
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
    $name = $null
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../linux/stages') -Filter '*.sh') {
        if (([IO.File]::ReadAllText($f.FullName) -replace "`r", '') -eq $text) { $name = $f.Name }
    }
    @{ Name = $name; Text = $text; Arguments = [string[]]@($Matches[2] -split ' ' | Where-Object { $_ }) }
}

function Reset-Fake {
    # A healthy machine. Tests replace the parts they need.
    $global:CriaCalls = [Collections.Generic.List[string]]::new()
    $global:CriaFake = @{
        Exec           = { param($Name, $Arguments) New-ExecResult 0 @() }
        Vps            = { param($Call, $InputLines) New-ExecResult 0 @() }
        Env            = @{}
        Feature        = @{ VirtualMachinePlatform = 'Enabled' }
        Virtualization = @{ Firmware = $true; Hypervisor = $false }
        Http           = { param($Uri) $null }
        Status         = { param($Uri, $Headers) 0 }
        Input          = @{}
        Free           = [long]4TB
        BitLocker      = 'On'
        OnStart        = $null
        Account        = @{ Sid = 'S-1-5-21-1000-2000-3000-1001'; Id = 'PC\liam'; Profile = 'C:\Users\liam'; Startup = $null; Console = 'PC\liam' }
        Tasks          = @{}
        Registered     = @{}
        Shortcuts      = @{}
        Firewall       = [Collections.Generic.List[object]]::new()
        Pagefile       = @{ Automatic = $true; Files = @() }
    }
}

function New-FakeMachine {
    @{
        Commands       = @{ tailscale = (Join-Path $script:RealRepo 'tests/fakes/fake-tailscale.ps1'); ssh = 'ssh'; docker = 'docker'; 'ssh-keyscan' = 'ssh-keyscan' }
        Exec           = {
            param([string]$Name, [string[]]$Arguments = @(), [switch]$Stream)
            $global:CriaCalls.Add(("$Name " + (@($Arguments) -join ' ')).Trim())
            & $global:CriaFake.Exec $Name @($Arguments)
        }
        Ssh            = {
            param([string]$Alias, [string]$Remote, [string[]]$InputLines = @())
            $call = ConvertFrom-VpsCommand $Remote
            if (-not $call) { $global:CriaCalls.Add("ssh $Alias $Remote"); return New-ExecResult 255 @('not a VPS script') }
            $global:CriaCalls.Add(("vps $Alias $($call.Name) " + ($call.Arguments -join ' ')).Trim())
            & $global:CriaFake.Vps $call @($InputLines)
        }
        ExecInput      = {
            # The input is kept by command for the tests to read, never logged.
            param([string]$Name, [string[]]$Arguments = @(), [string]$InputText = '')
            $global:CriaCalls.Add(("$Name " + (@($Arguments) -join ' ')).Trim())
            $global:CriaFake.Input[$Name] = $InputText
            & $global:CriaFake.Exec $Name @($Arguments)
        }
        GetEnv         = { param($Name, $Scope) $global:CriaFake.Env["$Scope/$Name"] }
        SetEnv         = {
            param($Name, $Value, $Scope)
            $global:CriaCalls.Add("setenv $Scope/$Name")
            if ($null -eq $Value) { $global:CriaFake.Env.Remove("$Scope/$Name") } else { $global:CriaFake.Env["$Scope/$Name"] = $Value }
        }
        EnvNames       = { param($Scope) @($global:CriaFake.Env.Keys | Where-Object { $_ -like "$Scope/*" } | ForEach-Object { $_.Substring($Scope.Length + 1) }) }
        Feature        = { param($Name) $(if ($global:CriaFake.Feature.ContainsKey($Name)) { $global:CriaFake.Feature[$Name] } else { 'Unknown' }) }
        Virtualization = { $global:CriaFake.Virtualization }
        StopProcess    = { param($Name) $global:CriaCalls.Add("stop $Name"); 1 }
        StartProcess   = { param($Path) $global:CriaCalls.Add("start $Path"); if ($global:CriaFake.OnStart) { & $global:CriaFake.OnStart $Path } }
        HttpJson       = { param($Uri, $Headers = @{}) & $global:CriaFake.Http $Uri $Headers }
        HttpStatus     = { param($Uri, $Headers = @{}) $global:CriaCalls.Add("status $Uri"); & $global:CriaFake.Status $Uri $Headers }
        FreeBytes      = { param($Path) $global:CriaFake.Free }
        BitLocker      = { param($Path) $global:CriaFake.BitLocker }
        IsElevated     = { $true }
        Wait           = { param($Seconds) }
        Account        = { $global:CriaFake.Account }
        TaskState      = { param($Name) $global:CriaFake.Tasks[$Name] }
        RegisterTask   = {
            param($Name, $Xml)
            $global:CriaCalls.Add("register $Name")
            if ($global:CriaFake.Tasks.ContainsKey($Name)) { throw [InvalidOperationException]::new("the task $Name is already there") }
            $global:CriaFake.Registered[$Name] = $Xml
            $global:CriaFake.Tasks[$Name] = $(if ($Xml -match '<Enabled>false</Enabled>') { 'Disabled' } else { 'Ready' })
        }
        DisableTask    = { param($Name) $global:CriaCalls.Add("disable $Name"); $global:CriaFake.Tasks[$Name] = 'Disabled' }
        StartTask      = { param($Name) $global:CriaCalls.Add("run-task $Name"); $global:CriaFake.Tasks[$Name] = 'Running' }
        ReadShortcut   = { param($Path) $global:CriaFake.Shortcuts[$Path] }
        WriteShortcut  = {
            param($Path, $Target, $Arguments, $WorkingDirectory)
            $global:CriaCalls.Add("shortcut $([IO.Path]::GetFileName($Path))")
            $global:CriaFake.Shortcuts[$Path] = @{ Target = $Target; Arguments = $Arguments; WorkingDirectory = $WorkingDirectory }
            [IO.File]::WriteAllText($Path, 'shortcut')
        }
        FirewallRules  = { param($Port) $global:CriaFake.Firewall.ToArray() }
        AddFirewallRule = {
            param($DisplayName, $Port, $RemoteAddress)
            $global:CriaCalls.Add("firewall $DisplayName")
            $global:CriaFake.Firewall.Add([pscustomobject]@{
                    DisplayName = $DisplayName; Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'
                    LocalPort = [string[]]@("$Port"); RemoteAddress = [string[]]@($RemoteAddress); Program = 'Any'
                })
        }
        Pagefile       = { $global:CriaFake.Pagefile }
        SetPagefile    = {
            param($Name, $InitialSize, $MaximumSize)
            $global:CriaCalls.Add("pagefile $Name $InitialSize $MaximumSize")
            $global:CriaFake.Pagefile = @{ Automatic = $false; Files = @(@{ Name = $Name; InitialSize = $InitialSize; MaximumSize = $MaximumSize }) }
        }
    }
}

function New-TestTopology([string]$Base) {
    @{
        formatVersion   = 1
        controller      = @{ repoRoot = $script:RealRepo; stateRoot = (Join-Path $Base 'state'); stagingRoot = (Join-Path $Base 'staging') }
        hosts           = @{ pc = @{ os = 'windows' }; vps = @{ os = 'linux'; sshAlias = 'vps'; user = 'liam' } }
        roots           = [ordered]@{
            stack           = @{ host = 'pc'; path = (Join-Path $Base 'live/ollama'); create = $true; holds = 'test' }
            dashboard       = @{ host = 'pc'; path = (Join-Path $Base 'live/dashboard'); create = $true; holds = 'test' }
            comfyui         = @{ host = 'pc'; path = (Join-Path $Base 'live/comfyui/ComfyUI'); create = $false; holds = 'test' }
            'ollama-models' = @{ host = 'pc'; path = (Join-Path $Base 'live/ollama-models'); create = $true; holds = 'test' }
            'vps-egress'    = @{ host = 'vps'; path = '/home/liam/owui-web-egress'; create = $true; holds = 'test' }
        }
        composeProjects = @()
    }
}

function New-TestContext {
    param(
        [int]$Stage,
        [ValidateSet('Plan', 'Run', 'Check')][string]$Mode = 'Run',
        [string]$RepoRoot = $script:RealRepo,
        [string]$Base = (Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))),
        [hashtable]$State,
        [string]$StatePath,
        [string[]]$Accepted = @(),
        [hashtable]$Data = @{}
    )
    $stateRoot = Join-Path $Base 'state'
    $null = New-Item -ItemType Directory -Path $stateRoot -Force
    if (-not $StatePath) { $StatePath = Join-Path $stateRoot 'state.json' }
    if (-not $State) { $State = Read-RecoveryState -Path $StatePath }
    $topology = New-TestTopology $Base
    $ownership = Get-OwnershipCallback -State $State -StatePath $StatePath -Stage $Stage -PlanOnly:($Mode -eq 'Plan')
    @{
        Stage       = $Stage
        Mode        = $Mode
        Base        = $Base
        StatePath   = $StatePath
        RepoRoot    = $RepoRoot
        StateRoot   = $stateRoot
        StagingRoot = $topology.controller.stagingRoot
        Topology    = $topology
        Machine     = New-FakeMachine
        State       = $State
        Accepted    = $Accepted
        Data        = $Data
        Bundle      = @{ Path = $null; Sha256 = $null }
        PathCheck   = Join-Path $script:RealRepo 'tools/Test-RecoveryPath.ps1'
        RootsPath   = Join-Path $RepoRoot 'manifests/recovery-roots.json'
        Tools       = @{
            RestoreSecrets = Join-Path $script:RealRepo 'tests/fakes/fake-restore-secrets.ps1'
            StackCapture   = Join-Path $script:RealRepo 'tools/StackCapture.psm1'
        }
        Own         = $ownership.Own
        Keep        = $ownership.Keep
        IsOwned     = $ownership.IsOwned
        RemoveOwned = $ownership.RemoveOwned
        Say         = { param($Text) }
    }
}

function Copy-Context([hashtable]$Context, [string]$Mode) {
    # The same machine, state and roots, for the next mode (Run, then Check).
    $c = $Context.Clone()
    $c.Mode = $Mode
    $ownership = Get-OwnershipCallback -State $c.State -StatePath $c.StatePath -Stage $c.Stage -PlanOnly:($Mode -eq 'Plan')
    foreach ($k in 'Own', 'Keep', 'IsOwned', 'RemoveOwned') { $c[$k] = $ownership[$k] }
    return $c
}

function Invoke-Stage([string]$Name, [hashtable]$Context) {
    & (Join-Path $script:RealRepo "windows/stages/$Name") -Mode $Context.Mode -Context $Context
}

function Set-OwnerOnly([string]$Path) {
    # Makes an existing file or folder owner-only, as the restorer leaves it.
    if ($IsWindows) {
        $sid = Get-CurrentUserSid
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($r) }
        $acl.SetOwner($sid)
        $inherit = if (Test-Path -LiteralPath $Path -PathType Container) { 'ContainerInherit, ObjectInherit' } else { 'None' }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inherit, 'None', 'Allow'))
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else {
        $mode = if (Test-Path -LiteralPath $Path -PathType Container) { '700' } else { '600' }
        & chmod $mode $Path
    }
}
