<#
.SYNOPSIS
    What the controller's VPS stages (2 and 5) use to reach the VPS over SSH
    (docs/RESTORE.md, The controller, and Stage 2c).

.DESCRIPTION
    Exported functions:

      Invoke-VpsScript        runs one of linux/stages/*.sh on the VPS as root
                              through the machine's Ssh block
      Add-VpsOutput           turns the script's STEP, WARN, FAIL and FACT
                              lines into a stage result, and returns the facts
      Get-SshHostConfig       hostname, port, host key alias and known_hosts
                              file of an alias, from 'ssh -G'
      Get-SshKeyFingerprint   'SHA256:...' of a public key, as ssh-keygen -l
                              prints it
      Read-ScannedHostKey     the keys in ssh-keyscan's output
      Get-KnownHostToken      the name a host's keys are filed under in
                              known_hosts
      Update-KnownHostFile    replaces the keys filed under one host with the
                              verified ones, keeping a backup

    Nothing here prints a key, an address or a name; the callers decide what
    goes into a stage's evidence.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RecoveryHost.psm1')

$script:KeyLine = '^(?<type>ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|ssh-rsa|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) (?<blob>[A-Za-z0-9+/]+={0,3})(?: .*)?$'

function Invoke-VpsScript {
    <#
    .SYNOPSIS
        Runs the bash script at -Path on the VPS as root (sudo -n), with
        -Arguments, through $Machine.Ssh. The script travels base64-encoded
        on the command line into a private temporary file, removed
        afterwards; -InputLines go to its standard input. Arguments must be
        plain words (no spaces or quotes). Returns the exit code and output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Machine,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [string[]]$InputLines = @()
    )
    foreach ($a in $Arguments) {
        if ($a -notmatch '^[A-Za-z0-9._:/@%+=,-]+$') { throw [ArgumentException]::new("not a plain word for the VPS command line: '$a'") }
    }
    $text = [IO.File]::ReadAllText($Path) -replace "`r", ''
    $b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($text))
    $remote = 't=$(mktemp) && echo ' + $b64 + ' | base64 -d > $t && sudo -n bash $t ' + ($Arguments -join ' ') + '; r=$?; rm -f $t; exit $r'
    return (& $Machine.Ssh $Alias $remote $InputLines)
}

function Add-VpsOutput {
    <#
    .SYNOPSIS
        Adds a VPS script's 'STEP', 'WARN' and 'FAIL' lines to -Result's
        steps, warnings and problems, and returns its 'FACT <name> <value>'
        lines as a table. Other lines (sudo's or bash's own errors) become
        one problem when the script failed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Label
    )
    $facts = @{}
    $failed = $false
    foreach ($line in @($Run.Output)) {
        $l = [string]$line
        if ($l -match '^STEP (.+)$') { $Result.Steps.Add("${Label}: $($Matches[1])") }
        elseif ($l -match '^WARN (.+)$') { $Result.Warnings.Add("${Label}: $($Matches[1])") }
        elseif ($l -match '^FAIL (.+)$') { $Result.Problems.Add("${Label}: $($Matches[1])"); $failed = $true }
        elseif ($l -match '^FACT (\S+) ?(.*)$') { $facts[$Matches[1]] = $Matches[2] }
    }
    if ($Run.ExitCode -ne 0 -and -not $failed) {
        $why = if (@($Run.Output) -match 'a password is required|sudo:') { 'sudo -n refused; does the account have passwordless sudo (the bootstrap gives it)?' }
        elseif ($Run.ExitCode -eq 255) { 'ssh could not connect' }
        else { "exit $($Run.ExitCode)" }
        $Result.Problems.Add("${Label}: the VPS script stopped ($why)")
    }
    return $facts
}

function Get-SshHostConfig {
    <#
    .SYNOPSIS
        What 'ssh -G <alias>' says: HostName, Port, HostKeyAlias (or $null)
        and the first UserKnownHostsFile with ~ expanded. $null when ssh
        cannot read its configuration.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Machine,
        [Parameter(Mandatory)][string]$Alias
    )
    $r = & $Machine.Exec 'ssh' @('-G', $Alias)
    if ($r.ExitCode -ne 0) { return $null }
    $c = @{ HostName = $null; Port = 22; HostKeyAlias = $null; KnownHosts = $null }
    foreach ($line in @($r.Output)) {
        $k, $v = ([string]$line).Trim() -split ' ', 2
        switch ($k) {
            'hostname' { $c.HostName = $v }
            'port' { $c.Port = [int]$v }
            'hostkeyalias' { if ($v -and $v -ne 'none') { $c.HostKeyAlias = $v } }
            'userknownhostsfile' {
                $first = ($v -split ' ')[0]
                if ($first.StartsWith('~')) { $first = Join-Path $HOME $first.Substring(1).TrimStart('/', '\') }
                $c.KnownHosts = [IO.Path]::GetFullPath($first)
            }
        }
    }
    if (-not $c.HostName) { return $null }
    return $c
}

function Get-SshKeyFingerprint {
    <#
    .SYNOPSIS
        'SHA256:<base64, no padding>' of a public key blob, as ssh-keygen -l
        and the bootstrap print it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Blob)
    $hash = [Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($Blob))
    return 'SHA256:' + [Convert]::ToBase64String($hash).TrimEnd('=')
}

function Read-ScannedHostKey {
    <#
    .SYNOPSIS
        The host keys in ssh-keyscan's output ('<host> <type> <blob>'), each
        with its fingerprint. Comment lines are ignored.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][string[]]$Line = @())
    foreach ($l in $Line) {
        $parts = ([string]$l).Trim() -split '\s+', 2
        if ($parts.Count -ne 2 -or $parts[0].StartsWith('#')) { continue }
        if ($parts[1] -notmatch $script:KeyLine) { continue }
        try { $fp = Get-SshKeyFingerprint -Blob $Matches['blob'] } catch { continue }
        [pscustomobject]@{ Type = $Matches['type']; Blob = $Matches['blob']; Fingerprint = $fp }
    }
}

function Get-KnownHostToken {
    <#
    .SYNOPSIS
        The name ssh files a host's keys under: the HostKeyAlias when there is
        one, otherwise the host name, as [name]:port off port 22.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config)
    if ($Config.HostKeyAlias) { return $Config.HostKeyAlias }
    if ($Config.Port -ne 22) { return "[$($Config.HostName)]:$($Config.Port)" }
    return $Config.HostName
}

function Test-KnownHostMatch([string]$Hosts, [string]$Token) {
    foreach ($h in ($Hosts -split ',')) {
        if ($h -match '^\|1\|([A-Za-z0-9+/=]+)\|([A-Za-z0-9+/=]+)$') {
            $hmac = [Security.Cryptography.HMACSHA1]::new([Convert]::FromBase64String($Matches[1]))
            try { $mac = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::ASCII.GetBytes($Token.ToLowerInvariant()))) }
            finally { $hmac.Dispose() }
            if ($mac -eq $Matches[2]) { return $true }
        }
        elseif ($h.ToLowerInvariant() -eq $Token.ToLowerInvariant()) { return $true }
    }
    return $false
}

function Get-KnownHostKey {
    <#
    .SYNOPSIS
        The keys filed under -Token in the known_hosts text -Text (marker
        lines such as @cert-authority are not host keys and are skipped).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Token)
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith('@')) { continue }
        $parts = $t -split '\s+', 2
        if ($parts.Count -ne 2 -or -not (Test-KnownHostMatch $parts[0] $Token)) { continue }
        if ($parts[1] -notmatch $script:KeyLine) { continue }
        [pscustomobject]@{ Type = $Matches['type']; Blob = $Matches['blob']; Fingerprint = (Get-SshKeyFingerprint -Blob $Matches['blob']); Line = $line }
    }
}

function Update-KnownHostFile {
    <#
    .SYNOPSIS
        Makes -Path hold exactly -Key under -Token: lines filed under -Token
        with any other key are removed (the old server's), missing keys are
        added at the end, every other line is kept as it is. A changed file
        is written beside it first and swapped in, with the old one kept as
        -BackupPath. Returns how many keys it removed and added. With
        -WhatIf it only counts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][object[]]$Key,
        [Parameter(Mandatory)][string]$BackupPath
    )
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $text = if ($exists) { [IO.File]::ReadAllText($Path) } else { '' }
    $newline = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $wanted = @($Key | ForEach-Object { "$($_.Type) $($_.Blob)" })
    $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $stale = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in @(Get-KnownHostKey -Text $text -Token $Token)) {
        if ($wanted -contains "$($k.Type) $($k.Blob)") { [void]$present.Add("$($k.Type) $($k.Blob)") } else { [void]$stale.Add($k.Line) }
    }
    $missing = @($wanted | Where-Object { -not $present.Contains($_) })
    $result = [pscustomobject]@{ Removed = $stale.Count; Added = $missing.Count; Changed = ($stale.Count + $missing.Count) -gt 0; Created = -not $exists }
    if (-not $result.Changed -or -not $PSCmdlet.ShouldProcess($Path, 'Update known_hosts')) { return $result }

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`r?`n")) { if (-not $stale.Contains($line)) { $lines.Add($line) } }
    while ($lines.Count -and -not $lines[$lines.Count - 1]) { $lines.RemoveAt($lines.Count - 1) }
    foreach ($m in $missing) { $lines.Add("$Token $m") }
    $body = [Text.UTF8Encoding]::new($false).GetBytes(($lines -join $newline) + $newline)
    $temp = "$Path.cria-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $stream = RecoveryHost\Open-NewOwnerOnlyFile -Path $temp
    try { $stream.Write($body, 0, $body.Length) } finally { $stream.Dispose() }
    if ($exists) { [IO.File]::Replace($temp, $Path, $BackupPath) }
    else { [IO.File]::Move($temp, $Path, $false) }
    return $result
}

Export-ModuleMember -Function Invoke-VpsScript, Add-VpsOutput, Get-SshHostConfig, Get-SshKeyFingerprint, Read-ScannedHostKey,
Get-KnownHostToken, Get-KnownHostKey, Update-KnownHostFile
