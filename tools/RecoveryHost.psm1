<#
.SYNOPSIS
    What the controller and its stages use to touch the machine (docs/RESTORE.md,
    The controller).

.DESCRIPTION
    New-RecoveryHost returns a table of script blocks: native commands,
    environment variables, Windows features, processes, HTTP on this machine,
    free space and BitLocker. Stages touch the machine only through it, so the
    tests can hand a stage a fake machine and check every decision it makes.

    The other exported functions create and check owner-only folders and
    files, the same way tools/Collect-StackSecrets.ps1 and
    tools/Restore-StackSecrets.ps1 do:

      Get-CurrentUserSid      the SID of the account running this
      Get-ProtectionProblem   $null when only that account can reach a path,
                              or the reason
      Initialize-ProtectedFolder
                              a folder that only that account can reach from
                              the moment it exists
      Open-NewOwnerOnlyFile   a new file, never an existing name or link,
                              owner-only from birth
      New-FolderChain         creates the missing folders down to a path, one
                              at a time, and returns the ones it created
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OnWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)

function Get-CurrentUserSid {
    <#
    .SYNOPSIS
        The SID of the account running this process (Windows only).
    #>
    [CmdletBinding()]
    [OutputType([Security.Principal.SecurityIdentifier])]
    param()
    [Security.Principal.WindowsIdentity]::GetCurrent().User
}

function Get-ProtectionProblem {
    <#
    .SYNOPSIS
        $null when only the current account can reach -Path, or the reason.
        With -OwnFolder the item must also be owned by that account and, on
        Windows, not inherit permissions from its parent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$OwnFolder
    )
    if ($script:OnWindows) {
        $sid = Get-CurrentUserSid
        $acl = Get-Acl -LiteralPath $Path
        if ($OwnFolder) {
            if (-not $acl.AreAccessRulesProtected) { return 'it inherits permissions from its parent' }
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $sid) { return 'it is owned by another account' }
        }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference -ne $sid) {
                return 'another account has access'
            }
        }
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($OwnFolder -and $item.UnixStat.UserId -ne [int](& id -u)) { return 'it is owned by another account' }
    $others = [IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
    if ($item.UnixFileMode -band $others) { return 'group or others have access' }
    return $null
}

function Initialize-ProtectedFolder {
    <#
    .SYNOPSIS
        Creates -Path with only the current account on it from birth: an ACL
        with inheritance off on Windows, mode 0700 elsewhere.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create an owner-only folder')) { return }
    if ($script:OnWindows) {
        $sid = Get-CurrentUserSid
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        [void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path), $security)
    }
    else {
        $null = [IO.Directory]::CreateDirectory($Path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    }
}

function New-FolderChain {
    <#
    .SYNOPSIS
        Creates every missing folder down to -Path, one at a time (so each gets
        the right protection), and returns the folders it created, top first.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Protected
    )
    $missing = [Collections.Generic.Stack[string]]::new()
    for ($p = [IO.Path]::GetFullPath($Path); $p -and -not [IO.Directory]::Exists($p); $p = [IO.Path]::GetDirectoryName($p)) { $missing.Push($p) }
    while ($missing.Count -gt 0) {
        $next = $missing.Pop()
        if (-not $PSCmdlet.ShouldProcess($next, 'Create folder')) { return }
        if ($Protected) { Initialize-ProtectedFolder $next }
        elseif ($script:OnWindows) { $null = [IO.Directory]::CreateDirectory($next) }
        else { $null = [IO.Directory]::CreateDirectory($next, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute') }
        $next
    }
}

function Open-NewOwnerOnlyFile {
    <#
    .SYNOPSIS
        Creates -Path new (never an existing name or link), readable and
        writable by the current account only from birth, and returns the
        open stream.
    #>
    [CmdletBinding()]
    [OutputType([IO.FileStream])]
    param([Parameter(Mandatory)][string]$Path)
    if ($script:OnWindows) {
        $sid = Get-CurrentUserSid
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
        return [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 81920, [IO.FileOptions]::None, $security)
    }
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    $options.UnixCreateMode = [IO.UnixFileMode]'UserRead, UserWrite'
    return [IO.FileStream]::new($Path, $options)
}

function Get-BitLockerProtection([string]$Path) {
    # The shell's BitLocker property, which needs no admin rights: 1 is on.
    if (-not $script:OnWindows) { return 'NotApplicable' }
    try {
        $drive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        $shell = New-Object -ComObject Shell.Application
        $value = $shell.NameSpace($drive).Self.ExtendedProperty('System.Volume.BitLockerProtection')
    }
    catch { return 'Unknown' }
    switch ($value) {
        1 { return 'On' }
        2 { return 'Off' }
        $null { return 'Unknown' }
        default { return "Not on (state $value)" }
    }
}

function New-RecoveryHost {
    <#
    .SYNOPSIS
        The real machine, as the table of script blocks the stages use.
        -Command maps a command name (git, winget, wsl, nvidia-smi, docker,
        ollama, curl, py, tailscale, ssh) to the program to run instead.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a table of script blocks; changes nothing itself.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Command = @{})

    $commands = @{
        git = 'git'; winget = 'winget'; wsl = 'wsl'; 'nvidia-smi' = 'nvidia-smi'; docker = 'docker'
        ollama = 'ollama'; curl = $(if ($script:OnWindows) { 'curl.exe' } else { 'curl' }); py = 'py'
        tailscale = 'tailscale'; ssh = 'ssh'
    }
    foreach ($k in $Command.Keys) { $commands[$k] = $Command[$k] }

    return @{
        Commands       = $commands

        # A native command: its exit code and its output as lines. With
        # -Stream the output goes to the console instead (long downloads).
        # A program that is not installed gives exit code -1.
        Exec           = {
            param([string]$Name, [string[]]$Arguments = @(), [switch]$Stream)
            $program = if ($commands.ContainsKey($Name)) { $commands[$Name] } else { $Name }
            if (-not (Get-Command -Name $program -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ ExitCode = -1; Output = [string[]]@("$Name is not installed") }
            }
            $global:LASTEXITCODE = 0
            if ($Stream) {
                & $program @Arguments | Out-Host
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = [string[]]@() }
            }
            $output = @(& $program @Arguments 2>&1 | ForEach-Object { "$_" })
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = [string[]]$output }
        }.GetNewClosure()

        GetEnv         = { param([string]$Name, [string]$Scope) [Environment]::GetEnvironmentVariable($Name, $Scope) }

        # $null as the value removes the variable.
        SetEnv         = { param([string]$Name, [AllowNull()][string]$Value, [string]$Scope) [Environment]::SetEnvironmentVariable($Name, $Value, $Scope) }

        EnvNames       = { param([string]$Scope) @([Environment]::GetEnvironmentVariables($Scope).Keys | ForEach-Object { [string]$_ }) }

        # 'Enabled', 'Disabled', 'EnablePending', ... or 'Unknown'. Without
        # admin rights DISM refuses, so CIM answers (it has no pending state).
        Feature        = {
            param([string]$Name)
            try { return [string](Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State }
            catch { $null = $_ }
            try {
                $f = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='$($Name -replace "'", '')'" -ErrorAction Stop
                switch ([int]$f.InstallState) { 1 { return 'Enabled' } 2 { return 'Disabled' } 3 { return 'Absent' } }
            }
            catch { $null = $_ }
            return 'Unknown'
        }

        # Firmware virtualisation reads False once a hypervisor runs, so both.
        Virtualization = {
            $cpu = @(Get-CimInstance -ClassName Win32_Processor)
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem
            @{ Firmware = [bool]($cpu | Where-Object VirtualizationFirmwareEnabled); Hypervisor = [bool]$cs.HypervisorPresent }
        }

        StopProcess    = {
            param([string]$Name)
            $found = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
            $found | Stop-Process -Force -ErrorAction SilentlyContinue
            foreach ($p in $found) { try { $p.WaitForExit(15000) | Out-Null } catch { $null = $_ } }
            return $found.Count
        }

        # Starts a program as the signed-in user: from an elevated window it
        # goes through Explorer, so Docker Desktop and Ollama never run as
        # admin.
        StartProcess   = {
            param([string]$Path)
            $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($elevated) { Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList "`"$Path`"" }
            else { Start-Process -FilePath $Path }
        }

        # GET on this machine only; $null when nothing answers.
        HttpJson       = {
            param([string]$Uri)
            if ($Uri -notmatch '^http://127\.0\.0\.1:[0-9]+/') { throw [ArgumentException]::new('HttpJson only reads from 127.0.0.1') }
            try { return Invoke-RestMethod -Uri $Uri -TimeoutSec 10 -ErrorAction Stop }
            catch { return $null }
        }

        FreeBytes      = { param([string]$Path) [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))).AvailableFreeSpace }

        BitLocker      = { param([string]$Path) Get-BitLockerProtection $Path }

        IsElevated     = {
            if (-not $IsWindows) { return $false }
            ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        Wait           = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    }
}

Export-ModuleMember -Function Get-CurrentUserSid, Get-ProtectionProblem, Initialize-ProtectedFolder, New-FolderChain,
Open-NewOwnerOnlyFile, New-RecoveryHost
