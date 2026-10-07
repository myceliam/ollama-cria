# Dot-sourced by the stage tests. A fake machine (every script block the
# stages use, driven by $global:CriaFake) and a stage context like the one
# Invoke-StackRecovery.ps1 builds, with every root in the test drive.

$script:RealRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RealRepo 'tools/RecoveryState.psm1') -Force
Import-Module (Join-Path $script:RealRepo 'tools/RecoveryHost.psm1') -Force

function New-ExecResult([int]$Code = 0, [string[]]$Output = @()) {
    [pscustomobject]@{ ExitCode = $Code; Output = [string[]]$Output }
}

function Reset-Fake {
    # A healthy machine. Tests replace the parts they need.
    $global:CriaCalls = [Collections.Generic.List[string]]::new()
    $global:CriaFake = @{
        Exec           = { param($Name, $Arguments) New-ExecResult 0 @() }
        Env            = @{}
        Feature        = @{ VirtualMachinePlatform = 'Enabled' }
        Virtualization = @{ Firmware = $true; Hypervisor = $false }
        Http           = { param($Uri) $null }
        Free           = [long]4TB
        BitLocker      = 'On'
        OnStart        = $null
    }
}

function New-FakeMachine {
    @{
        Commands       = @{ tailscale = (Join-Path $script:RealRepo 'tests/fakes/fake-tailscale.ps1'); ssh = 'ssh'; docker = 'docker' }
        Exec           = {
            param([string]$Name, [string[]]$Arguments = @(), [switch]$Stream)
            $global:CriaCalls.Add(("$Name " + (@($Arguments) -join ' ')).Trim())
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
        HttpJson       = { param($Uri) & $global:CriaFake.Http $Uri }
        FreeBytes      = { param($Path) $global:CriaFake.Free }
        BitLocker      = { param($Path) $global:CriaFake.BitLocker }
        IsElevated     = { $true }
        Wait           = { param($Seconds) }
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
