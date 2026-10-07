#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 2: the VPS base and both hosts on the tailnet (docs/RESTORE.md
    Stage 2).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context. Needs Stage 1 (the SSH key pair and config are in
    place).

    Run, in two visits:

      2a  Until the question 'vps-bootstrap' is answered: writes
          vps-bootstrap.sh into the staging folder (linux/stages/
          02-bootstrap.sh with the PC's public key from bundle folder 04 and
          the account filled in; owner-only; removed with the other
          plaintext in Stage 11) and asks a person to rebuild the VPS, paste
          it into the provider's console, put the new server on the tailnet
          under the old name and note the host key fingerprint it prints.
          The key is never in the evidence, only the file's path.
      2c  Once answered, with -HostKeyFingerprint: finds the node named after
          the SSH alias in the tailnet; checks the alias points at it
          ('ssh -G'); fetches the server's host keys with ssh-keyscan and
          stops unless one matches the fingerprint from the console; then
          files the matching keys in known_hosts in place of the old
          server's (the old file is kept beside it as known_hosts.cria-<time>)
          and checks that 'ssh <alias>' logs in.
      2d  Runs linux/stages/02-base.sh on the VPS as root: Docker from
          Docker's apt repository, the base packages, unattended upgrades,
          the firewall and sshd as on the live VPS.

    Check is checkpoint 2: the node is in the tailnet, the alias points at
    it, known_hosts holds the key with the recorded fingerprint, and on the
    VPS (02-base.sh check) Docker answers, the packages are there, ufw is on
    with only tailscale0 and 41641/udp let in, and sshd takes keys only, no
    root, on the tailnet address only; 'tailscale ping' gets a reply.
    Tailnet addresses and names stay in memory, never in state or evidence.
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
$machine = $Context.Machine
$repo = $Context.RepoRoot
$act = $Mode -eq 'Run'
$alias = $Context.Topology['hosts']['vps']['sshAlias']
$account = $Context.Topology['hosts']['vps']['user']
$base = Join-Path $repo 'linux/stages/02-base.sh'
$bootstrapPath = Join-Path $Context.StagingRoot 'vps-bootstrap.sh'
$fingerprint = if ($Context['HostKey']) { [string]$Context['HostKey'] } elseif ($Context.Data['HostKeyFingerprint']) { [string]$Context.Data['HostKeyFingerprint'] } else { $null }
$retry = 'Invoke-StackRecovery.ps1 -Execute -Accept vps-bootstrap -HostKeyFingerprint SHA256:<the fingerprint it printed>'

function Get-SshRoot {
    $roots = (Get-Content -LiteralPath $Context.RootsPath -Raw | ConvertFrom-Json -AsHashtable)['roots']
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($roots['ssh']['path']))
}

function Get-PublicKey {
    # The vps alias's public key from bundle folder 04, as '<type> <blob>', or
    # $null after a problem. Its comment is dropped.
    $row = @((Get-Content -LiteralPath (Join-Path $repo 'manifests/secrets.json') -Raw | ConvertFrom-Json -AsHashtable)['rows'] |
            Where-Object { $_['id'] -eq 'ssh-vps-key-public' })[0]
    $path = Join-Path (Get-SshRoot) ($row['location'] -replace '^ssh:', '')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $result.Problems.Add("the vps alias's public key is not in place ($path); Stage 1 places it"); return $null }
    $line = @(Get-Content -LiteralPath $path | Where-Object { $_.Trim() })[0]
    $key = @(Read-ScannedHostKey -Line @("key $line"))[0]
    if (-not $key) { $result.Problems.Add("$($path): not an SSH public key"); return $null }
    return "$($key.Type) $($key.Blob)"
}

function Get-BootstrapText([string]$PublicKey) {
    $t = [IO.File]::ReadAllText((Join-Path $repo 'linux/stages/02-bootstrap.sh')) -replace "`r", ''
    return $t.Replace('{{USER}}', $account).Replace('{{NODE}}', $alias).Replace('{{PUBLIC_KEY}}', "$PublicKey ollama-cria")
}

function Write-Bootstrap([string]$Text) {
    # True when the file holds $Text now (or would, in plan mode).
    $check = & $Context.PathCheck -Path $bootstrapPath -Root $Context.StagingRoot -Detailed
    if (-not $check.IsValid) { $result.Problems.Add("$($bootstrapPath): $($check.Reason)"); return $false }
    if (-not (Test-Path -LiteralPath $Context.StagingRoot -PathType Container)) { $result.Problems.Add("$($Context.StagingRoot) is missing; Stage 1 creates it"); return $false }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    if (Test-Path -LiteralPath $bootstrapPath) {
        if ([Convert]::ToHexString([IO.File]::ReadAllBytes($bootstrapPath)) -eq [Convert]::ToHexString($bytes)) { return $true }
        if (-not (& $Context.IsOwned $bootstrapPath)) { $result.Problems.Add("$($bootstrapPath): a different file is already there; move it away and run again"); return $false }
        if (-not $act) { return $true }
        if ((& $Context.RemoveOwned $bootstrapPath) -notin 'removed', 'gone') { $result.Problems.Add("$($bootstrapPath): could not replace the older copy"); return $false }
    }
    if (-not $act) { return $true }
    $stream = Open-NewOwnerOnlyFile -Path $bootstrapPath
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    & $Context.Own 'file' $bootstrapPath $Context.StagingRoot 'keep' -Plaintext
    return $true
}

function Get-Endpoint {
    try { return Get-TailnetEndpoint -SshHost $alias -TailscaleCommand $machine.Commands['tailscale'] }
    catch {
        Add-StageAsk $result "The VPS is not in the tailnet as '$alias' yet ($($_.Exception.Message)). On the VPS, run 'tailscale up --hostname=$alias' and approve the node; delete the old node first so the name stays '$alias'. Then run the same command again."
        return $null
    }
}

function Test-AliasTarget($Config, $Endpoint) {
    # Does the alias point at the node? Compared in memory only.
    $names = @($Endpoint['VPS_TS_NAME'], $Endpoint['VPS_TS_IP'], $alias) | Where-Object { $_ }
    return [bool](@($names | Where-Object { $_ -ieq $Config.HostName }).Count)
}

function Invoke-Trust($Endpoint) {
    # 2c. True when the alias is trusted and logs in.
    $config = Get-SshHostConfig -Machine $machine -Alias $alias
    if (-not $config) { $result.Problems.Add("'ssh -G $alias' failed; is ~/.ssh/config in place (Stage 1)?"); return $false }
    if (-not (Test-AliasTarget $config $Endpoint)) {
        Add-StageAsk $result "In ~/.ssh/config, the '$alias' alias points somewhere other than the new node. Set its HostName to the node's MagicDNS name (tailscale status shows it), then run the same command again."
        return $false
    }
    $scan = & $machine.Exec 'ssh-keyscan' @('-T', '15', '-p', "$($config.Port)", '-t', 'ed25519,ecdsa,rsa', $config.HostName)
    $keys = @(Read-ScannedHostKey -Line $scan.Output)
    if (-not $keys) { $result.Problems.Add("ssh-keyscan got no host key from the VPS (exit $($scan.ExitCode)); is it up and on the tailnet?"); return $false }
    $match = @($keys | Where-Object Fingerprint -CEQ $fingerprint)
    if (-not $match) {
        $result.Problems.Add("none of the $($keys.Count) host keys the VPS offers has the fingerprint from the console. Stopped: do not trust this server until you know why.")
        return $false
    }
    $result.Steps.Add("host key: the VPS offers the $($match[0].Type) key with the fingerprint from the console")

    $sshRoot = Get-SshRoot
    $known = $config.KnownHosts
    if (-not $known) { $result.Problems.Add("'ssh -G $alias' names no known_hosts file"); return $false }
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $backup = "$known.cria-$stamp"
    $check = & $Context.PathCheck -Path $known, $backup -Root $sshRoot -Detailed
    if (-not @($check)[0].IsValid -or -not @($check)[1].IsValid) { $result.Problems.Add("$($known): known_hosts must be in $sshRoot and pass the path check"); return $false }
    $hostEntry = Get-KnownHostToken -Config $config
    $u = Update-KnownHostFile -Path $known -Token $hostEntry -Key $match -BackupPath $backup -WhatIf:(-not $act)
    if ($u.Changed) {
        $verb = if ($act) { '' } else { 'would ' }
        $result.Steps.Add("known_hosts: ${verb}remove $($u.Removed) old key(s) filed under the vps host and ${verb}add $($u.Added)$(if ($u.Removed -and $act) { "; the old file is kept as $([IO.Path]::GetFileName($backup))" })")
        if ($act) {
            if ($u.Created) { & $Context.Own 'file' $known $sshRoot 'keep' }
            elseif ($u.Removed) { & $Context.Own 'file' $backup $sshRoot 'keep' }
        }
    }
    else { $result.Steps.Add('known_hosts: already holds the verified key') }
    if (-not $act) { return $true }

    $login = & $machine.Exec 'ssh' @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20', $alias, 'true')
    if ($login.ExitCode -ne 0) {
        $result.Problems.Add("'ssh $alias' does not log in (exit $($login.ExitCode)), with the host key trusted. Did the bootstrap run as root, with the PC's key?")
        return $false
    }
    $result.Steps.Add("'ssh $alias' logs in with the key from the bundle")
    return $true
}

function Test-Checkpoint {
    $endpoint = Get-Endpoint
    Add-StageCheck $result "the tailnet has a node named '$alias'" 'yes' $(if ($endpoint) { 'yes' } else { 'no' }) ($null -ne $endpoint)
    if (-not $endpoint) { return }
    $config = Get-SshHostConfig -Machine $machine -Alias $alias
    $points = $config -and (Test-AliasTarget $config $endpoint)
    Add-StageCheck $result "the '$alias' alias points at that node" 'yes' $(if ($points) { 'yes' } else { 'no' }) $points
    if (-not $points) { return }
    $text = if ($config.KnownHosts -and (Test-Path -LiteralPath $config.KnownHosts -PathType Leaf)) { [IO.File]::ReadAllText($config.KnownHosts) } else { '' }
    $filed = @(Get-KnownHostKey -Text $text -Token (Get-KnownHostToken -Config $config))
    $ok = $fingerprint -and $filed.Count -gt 0 -and @($filed | Where-Object Fingerprint -CNE $fingerprint).Count -eq 0
    Add-StageCheck $result 'known_hosts holds only the key with the fingerprint from the console' 'yes' "$($filed.Count) key(s) filed$(if ($fingerprint) { '' } else { '; no fingerprint recorded' })" $ok

    $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path $base -Arguments @('check', $account, $endpoint['VPS_TS_IP'])
    $f = Add-VpsOutput -Result $result -Run $run -Label '02-base.sh'
    if ($run.ExitCode -ne 0) { Add-StageCheck $result 'the VPS answers over ssh as root (sudo -n)' 'yes' "exit $($run.ExitCode)" $false; return }
    $get = { param($Name) if ($f.ContainsKey($Name)) { $f[$Name] } else { 'not reported' } }
    Add-StageCheck $result 'Docker engine on the VPS' 'a version' (& $get 'docker') ((& $get 'docker') -match '^[0-9]')
    Add-StageCheck $result 'Docker Compose plugin' 'a version' (& $get 'compose') ((& $get 'compose') -match '^v?[0-9]')
    $missing = @($run.Output | Where-Object { $_ -match '^FACT missing ' } | ForEach-Object { ($_ -split ' ')[2] })
    Add-StageCheck $result 'base packages' 'all installed' $(if ($missing) { "missing: $($missing -join ', ')" } else { 'all installed' }) ($missing.Count -eq 0)
    Add-StageCheck $result 'net.ipv4.ip_nonlocal_bind' '1' (& $get 'nonlocal-bind') ((& $get 'nonlocal-bind') -eq '1')
    Add-StageCheck $result 'ufw' 'active' (& $get 'ufw') ((& $get 'ufw') -eq 'active')
    Add-StageCheck $result 'ufw defaults' 'deny incoming and routed, allow outgoing' (& $get 'ufw-defaults') ((& $get 'ufw-defaults') -eq 'yes')
    Add-StageCheck $result 'ufw lets in everything on tailscale0' 'yes' (& $get 'ufw-tailscale0') ((& $get 'ufw-tailscale0') -eq 'yes')
    Add-StageCheck $result 'ufw lets in 41641/udp (Tailscale direct connections)' 'yes' (& $get 'ufw-41641') ((& $get 'ufw-41641') -eq 'yes')
    Add-StageCheck $result 'ufw lets in nothing else' '0 other rules' "$(& $get 'ufw-other-allow') other rules" ((& $get 'ufw-other-allow') -eq '0')
    Add-StageCheck $result 'sshd listens on the tailnet address only' 'tailnet-only' (& $get 'ssh-listen') ((& $get 'ssh-listen') -eq 'tailnet-only')
    Add-StageCheck $result 'sshd refuses passwords' 'yes' (& $get 'ssh-password-off') ((& $get 'ssh-password-off') -eq 'yes')
    Add-StageCheck $result 'sshd refuses root' 'yes' (& $get 'ssh-root-off') ((& $get 'ssh-root-off') -eq 'yes')

    $ping = & $machine.Exec 'tailscale' @('ping', '-c', '1', '--timeout', '10s', $alias)
    $pong = $ping.ExitCode -eq 0 -and [bool](@($ping.Output) -match 'pong')
    Add-StageCheck $result "tailscale ping $alias" 'a reply' $(if ($pong) { 'a reply' } else { 'no reply' }) $pong
}

if ($Mode -eq 'Check') {
    Test-Checkpoint
    if ($result.Problems.Count -and $result.Status -eq 'passed') { $result.Status = 'failed' }
    return $result
}

if ($Context['HostKey']) { $result.Data['HostKeyFingerprint'] = [string]$Context['HostKey'] }
$key = Get-PublicKey
if ($key) {
    if ($Context.Accepted -notcontains 'vps-bootstrap') {
        if (Write-Bootstrap (Get-BootstrapText $key)) {
            $result.Steps.Add("$(if ($act) { 'wrote' } else { 'would write' }) the VPS bootstrap: $bootstrapPath")
            Add-StageAsk $result ("Rebuild the VPS with Ubuntu 24.04 in the provider's console. Paste $bootstrapPath into its console as root; it prints the server's host key fingerprint. " +
                "Delete the old '$alias' node in the Tailscale admin console, run 'tailscale up --hostname=$alias' on the VPS and approve it, and check the tailnet rules still let the PC and the VPS reach each other. " +
                "Then run: $retry") -Id 'vps-bootstrap'
        }
    }
    elseif (-not $fingerprint) {
        Add-StageAsk $result "Give the VPS's host key fingerprint, as the bootstrap printed it in the console: $retry"
    }
    else {
        $endpoint = Get-Endpoint
        if ($endpoint -and (Invoke-Trust $endpoint)) {
            if ($act) {
                $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path $base -Arguments @('run', $account, $endpoint['VPS_TS_IP'])
                $null = Add-VpsOutput -Result $result -Run $run -Label '02-base.sh'
            }
            else { $result.Steps.Add('would run linux/stages/02-base.sh on the VPS as root: Docker, base packages, unattended upgrades, ufw, sshd') }
        }
    }
}

if ($Mode -eq 'Plan') { $result.Status = 'planned' }
elseif ($result.Problems.Count) { $result.Status = 'failed' }
return $result
