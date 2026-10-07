<#
.SYNOPSIS
    What the controller and its stages use to touch the machine (docs/RESTORE.md,
    The controller).

.DESCRIPTION
    New-RecoveryHost returns a table of script blocks: native commands, ssh,
    environment variables, Windows features, processes, HTTP on this machine
    and the tailnet, free space, BitLocker, the account, scheduled tasks,
    shortcuts, firewall rules and the pagefile. Stages touch the machine only
    through it, so the tests can hand a stage a fake machine and check every
    decision it makes.

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
        ollama, curl, py, tailscale, ssh, ssh-keyscan) to the program to run
        instead.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a table of script blocks; changes nothing itself.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Command = @{})

    $commands = @{
        git = 'git'; winget = 'winget'; wsl = 'wsl'; 'nvidia-smi' = 'nvidia-smi'; docker = 'docker'
        ollama = 'ollama'; curl = $(if ($script:OnWindows) { 'curl.exe' } else { 'curl' }); py = 'py'
        tailscale = 'tailscale'; ssh = 'ssh'; 'ssh-keyscan' = 'ssh-keyscan'
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

        # The same, with -InputText on the program's standard input (UTF-8),
        # so a secret or a script never goes on a command line.
        ExecInput      = {
            param([string]$Name, [string[]]$Arguments = @(), [string]$InputText = '')
            $program = if ($commands.ContainsKey($Name)) { $commands[$Name] } else { $Name }
            if (-not (Get-Command -Name $program -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ ExitCode = -1; Output = [string[]]@("$Name is not installed") }
            }
            $global:LASTEXITCODE = 0
            $saved = $OutputEncoding
            try {
                $OutputEncoding = [Text.UTF8Encoding]::new($false)
                $output = @($InputText | & $program @Arguments 2>&1 | ForEach-Object { "$_" })
            }
            finally { $OutputEncoding = $saved }
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

        # One command on the VPS over ssh, its host key checked, never a
        # prompt; -InputLines go to its standard input. tools/RecoveryVps.psm1
        # builds the commands.
        Ssh            = {
            param([string]$Alias, [string]$Remote, [string[]]$InputLines = @())
            $global:LASTEXITCODE = 0
            $options = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20')
            $output = @(@($InputLines) | & $commands['ssh'] @options $Alias $Remote 2>&1 | ForEach-Object { "$_" })
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = [string[]]$output }
        }.GetNewClosure()

        # GET on this machine only, with headers that stay in this process;
        # $null when nothing answers.
        HttpJson       = {
            param([string]$Uri, [hashtable]$Headers = @{})
            if ($Uri -notmatch '^http://127\.0\.0\.1:[0-9]+/') { throw [ArgumentException]::new('HttpJson only reads from 127.0.0.1') }
            try { return Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 10 -ErrorAction Stop }
            catch { return $null }
        }

        # The HTTP status of a GET on this machine only, with headers that
        # stay in this process; 0 when nothing answers.
        HttpStatus     = {
            param([string]$Uri, [hashtable]$Headers = @{})
            if ($Uri -notmatch '^http://127\.0\.0\.1:[0-9]+/') { throw [ArgumentException]::new('HttpStatus only reads from 127.0.0.1') }
            try { return [int](Invoke-WebRequest -Uri $Uri -Headers $Headers -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop).StatusCode }
            catch { return 0 }
        }

        # One request to this machine (127.0.0.1) or a tailnet address
        # (100.64.0.0/10), with headers and body that stay in this process:
        # @{ Status; Body }, Status 0 when nothing answers. Stage 9's probes.
        HttpCall       = {
            param([string]$Method, [string]$Uri, [hashtable]$Headers = @{}, [string]$Body, [int]$TimeoutSec = 30)
            if ($Uri -notmatch '^http://(127\.0\.0\.1|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}):[0-9]+/') {
                throw [ArgumentException]::new('HttpCall only reaches 127.0.0.1 and tailnet addresses')
            }
            $request = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = $TimeoutSec; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
            if ($PSBoundParameters.ContainsKey('Body')) { $request.Body = [Text.UTF8Encoding]::new($false).GetBytes($Body); $request.ContentType = 'application/json' }
            try {
                $r = Invoke-WebRequest @request
                $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
                return @{ Status = [int]$r.StatusCode; Body = $text }
            }
            catch { return @{ Status = 0; Body = '' } }
        }

        FreeBytes      = { param([string]$Path) [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))).AvailableFreeSpace }

        BitLocker      = { param([string]$Path) Get-BitLockerProtection $Path }

        IsElevated     = {
            if (-not $IsWindows) { return $false }
            ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        Wait           = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }

        # The account running this window and the one signed in at the
        # console, for the scheduled tasks and the Startup folder (Stage 8).
        Account        = {
            $console = try { [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName } catch { '' }
            @{
                Sid     = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                Id      = "$env:USERDOMAIN\$env:USERNAME"
                Profile = $env:USERPROFILE
                Startup = [Environment]::GetFolderPath('Startup')
                Console = $console
            }
        }

        # A scheduled task in the root folder: its state (Ready, Running,
        # Disabled, ...), or $null when there is none.
        TaskState      = {
            param([string]$Name)
            $t = Get-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction SilentlyContinue
            if ($t) { return [string]$t.State }
            return $null
        }

        # A new task from its XML; never replaces one.
        RegisterTask   = {
            param([string]$Name, [string]$Xml)
            if (Get-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction SilentlyContinue) { throw [InvalidOperationException]::new("the task $Name is already there") }
            $null = Register-ScheduledTask -TaskPath '\' -TaskName $Name -Xml $Xml -ErrorAction Stop
        }

        DisableTask    = { param([string]$Name) $null = Disable-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction Stop }

        StartTask      = { param([string]$Name) Start-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction Stop }

        # A shortcut's target, arguments and working folder, or $null.
        ReadShortcut   = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
            $l = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
            @{ Target = [string]$l.TargetPath; Arguments = [string]$l.Arguments; WorkingDirectory = [string]$l.WorkingDirectory }
        }

        WriteShortcut  = {
            param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDirectory)
            if (Test-Path -LiteralPath $Path) { throw [InvalidOperationException]::new("$Path is already there") }
            $l = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
            $l.TargetPath = $Target
            $l.Arguments = $Arguments
            $l.WorkingDirectory = $WorkingDirectory
            $l.Save()
        }

        # The firewall rules that name TCP port -Port or a python(w).exe, as
        # plain objects.
        FirewallRules  = {
            param([int]$Port)
            $found = @(Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | Where-Object { @($_.LocalPort) -contains [string]$Port } | Get-NetFirewallRule -ErrorAction SilentlyContinue) +
            @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -match '\\pythonw?\.exe$' } | Get-NetFirewallRule -ErrorAction SilentlyContinue)
            foreach ($r in @($found | Sort-Object -Property Name -Unique)) {
                $ports = $r | Get-NetFirewallPortFilter
                [pscustomobject]@{
                    DisplayName   = [string]$r.DisplayName
                    Enabled       = [string]$r.Enabled -eq 'True'
                    Direction     = [string]$r.Direction
                    Action        = [string]$r.Action
                    Protocol      = [string]$ports.Protocol
                    LocalPort     = [string[]]@($ports.LocalPort)
                    RemoteAddress = [string[]]@(($r | Get-NetFirewallAddressFilter).RemoteAddress)
                    Program       = [string](($r | Get-NetFirewallApplicationFilter).Program)
                }
            }
        }

        # An inbound allow rule for TCP -Port from -RemoteAddress only, on
        # every profile.
        AddFirewallRule = {
            param([string]$DisplayName, [int]$Port, [string[]]$RemoteAddress)
            $null = New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
                -RemoteAddress $RemoteAddress -Profile Any -ErrorAction Stop
        }

        # Whether Windows manages the pagefile, and each pagefile set by hand
        # (sizes in MB).
        Pagefile       = {
            @{
                Automatic = [bool](Get-CimInstance -ClassName Win32_ComputerSystem).AutomaticManagedPagefile
                Files     = @(Get-CimInstance -ClassName Win32_PageFileSetting | ForEach-Object {
                        @{ Name = [string]$_.Name; InitialSize = [int]$_.InitialSize; MaximumSize = [int]$_.MaximumSize }
                    })
            }
        }

        # Turns Windows' management off and sets one pagefile's sizes (MB);
        # they take effect at the next restart.
        SetPagefile    = {
            param([string]$Name, [int]$InitialSize, [int]$MaximumSize)
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem
            if ($cs.AutomaticManagedPagefile) { $null = Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop }
            $filter = "Name='$($Name.Replace("'", '').Replace('\', '\\'))'"
            $pf = Get-CimInstance -ClassName Win32_PageFileSetting -Filter $filter -ErrorAction SilentlyContinue
            if (-not $pf) {
                $null = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $Name } -ErrorAction Stop
                $pf = Get-CimInstance -ClassName Win32_PageFileSetting -Filter $filter -ErrorAction Stop
            }
            $null = Set-CimInstance -InputObject $pf -Property @{ InitialSize = [uint32]$InitialSize; MaximumSize = [uint32]$MaximumSize } -ErrorAction Stop
        }
    }
}

Export-ModuleMember -Function Get-CurrentUserSid, Get-ProtectionProblem, Initialize-ProtectedFolder, New-FolderChain,
Open-NewOwnerOnlyFile, New-RecoveryHost
