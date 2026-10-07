#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 4: render the stack files for the new tailnet and place the
    remaining secrets (docs/RESTORE.md Stage 4).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context. Needs Stage 2 (the VPS on the tailnet under its
    old name) and Stage 3.

    Run:

      4a  Reads the new nodes from 'tailscale status --json'
          (Get-TailnetEndpoint; the values stay in memory, never in state or
          evidence). Then, for every source in manifests/stack-files.json:
          PC sources are written to their folder on this PC (the stack to
          E:\ai\ollama, the dashboard to E:\ai\ag-startuip\cline-dashboard);
          VPS sources are written under <state root>\rendered\<source> for
          Stage 5 to copy; windows/ sources wait for Stage 8. A file listed
          in manifests/endpoints.json has its placeholders filled
          (ConvertFrom-StackTemplate, which stops on a placeholder with no
          value); any other file must hold none and is copied as it is.
          Every path passes tools/Test-RecoveryPath.ps1. A file is written
          under a temporary name created new, then moved into place without
          replacing anything. A file already there is left alone when it
          holds the same bytes, replaced only when this stage wrote it and
          nobody changed it since, and refused otherwise (never
          overwritten).
      4b  tools/Restore-StackSecrets.ps1 places bundle folders 01 and 02 on
          this PC and 05 on the VPS, from the bundle Stage 1 checked.

    Check is checkpoint 4: every rendered file is there, holds no endpoint
    placeholder and no tailnet address but the new nodes' own; every placed
    secret on this PC matches the map and is owner-only; every placed secret
    on the VPS matches the map, with its mode and owner.
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
Import-Module $Context.Tools.StackCapture

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
$machine = $Context.Machine
$repo = $Context.RepoRoot
$act = $Mode -eq 'Run'
$alias = $Context.Topology['hosts']['vps']['sshAlias']
$renderRoot = Join-Path $Context.StateRoot 'rendered'
$sources = @((Get-Content -LiteralPath (Join-Path $repo 'manifests/stack-files.json') -Raw | ConvertFrom-Json -AsHashtable)['sources'])
$templated = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($f in @((Get-Content -LiteralPath (Join-Path $repo 'manifests/endpoints.json') -Raw | ConvertFrom-Json -AsHashtable)['files'])) { [void]$templated.Add($f['file']) }
$stage1 = $Context.State['stages']['1']
$bundleData = if ($stage1 -is [hashtable] -and $stage1['data'] -is [hashtable]) { $stage1['data'] } else { @{} }
$secretFolders = @('01', '02', '05')
$written = @{}
foreach ($k in @(if ($Context.Data['Written'] -is [hashtable]) { $Context.Data['Written'].Keys })) { $written[$k] = $Context.Data['Written'][$k] }

function Get-ByteSha256([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-Endpoint {
    try { return Get-TailnetEndpoint -SshHost $alias -TailscaleCommand $machine.Commands['tailscale'] }
    catch {
        $text = "tailnet: $($_.Exception.Message)"
        if ($Mode -eq 'Plan') { $result.Steps.Add("would render the stack files once the tailnet answers ($text)") } else { $result.Problems.Add($text) }
        return $null
    }
}

function Get-SourceTarget($Source) {
    # Where a source is written by this stage, or $null when another stage
    # places it.
    if ($Source['repoFolder'] -like 'windows/*') { return $null }
    if ($Source['host'] -eq 'vps') { return [IO.Path]::GetFullPath((Join-Path $renderRoot $Source['name'])) }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Source['root']))
}

function Split-Text([byte[]]$Bytes) {
    # A UTF-8 text and whether it had a byte order mark, or $null.
    $bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
    $start = if ($bom) { 3 } else { 0 }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $start, $Bytes.Length - $start) }
    catch { return $null }
    return @{ Text = $text; Bom = $bom }
}

function Get-RenderedByte([string]$RepoFile, $Endpoint) {
    # The file as it goes to the machine. Returns $null after a problem.
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $RepoFile))
    $parts = Split-Text $bytes
    if (-not $templated.Contains($RepoFile)) {
        if ($parts -and (Get-StackPlaceholder -Text $parts.Text).Count) {
            $result.Problems.Add("$($RepoFile): holds endpoint placeholders but is not in manifests/endpoints.json")
            return $null
        }
        return , $bytes
    }
    if (-not $parts) { $result.Problems.Add("$($RepoFile): listed in manifests/endpoints.json but not UTF-8 text"); return $null }
    try { $text = ConvertFrom-StackTemplate -Text $parts.Text -Endpoint $Endpoint }
    catch { $result.Problems.Add("$($RepoFile): $($_.Exception.Message)"); return $null }
    $body = [Text.UTF8Encoding]::new($false).GetBytes($text)
    if ($parts.Bom) { $body = [byte[]](0xEF, 0xBB, 0xBF) + $body }
    return , [byte[]]$body
}

function Write-Rendered([string]$Target, [string]$Relative, [byte[]]$Bytes) {
    # 'new', 'changed', 'unchanged', 'would write' or $null after a problem.
    $check = & $Context.PathCheck -Path $Relative -Root $Target -Relative -Detailed
    if (-not $check.IsValid) { $result.Problems.Add("$($Relative): $($check.Reason)"); return $null }
    $dest = $check.FullPath
    $sha = Get-ByteSha256 $Bytes
    $replace = $false
    if (Test-Path -LiteralPath $dest) {
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { $result.Problems.Add("$($dest): a folder is already there"); return $null }
        $now = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($now -eq $sha) { return 'unchanged' }
        if (-not ((& $Context.IsOwned $dest) -and $written[$dest] -eq $now)) {
            $result.Problems.Add("$($dest): a different file is already there; move it away and run again")
            return $null
        }
        $replace = $true
    }
    if (-not $act) { return 'would write' }
    foreach ($made in @(New-FolderChain -Path ([IO.Path]::GetDirectoryName($dest)))) { & $Context.Own 'folder' $made $Target 'wipe' }
    $temp = "$dest.cria-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
    if ($replace) { & $Context.RemoveOwned $dest | Out-Null }
    [IO.File]::Move($temp, $dest, $false)
    & $Context.Own 'file' $dest $Target 'wipe'
    $written[$dest] = $sha
    return $(if ($replace) { 'changed' } else { 'new' })
}

function Invoke-Render($Endpoint) {
    $files = [Collections.Generic.List[string]]::new()
    foreach ($source in $sources) {
        $target = Get-SourceTarget $source
        if (-not $target) { $result.Steps.Add("$($source['name']): placed in Stage 8"); continue }
        if ($source['host'] -eq 'pc' -and -not (Test-Path -LiteralPath $target -PathType Container)) {
            $result.Problems.Add("$($source['name']): $target is missing; Stage 1 creates it")
            continue
        }
        $counts = [ordered]@{}
        foreach ($file in @($source['files'])) {
            $repoFile = "$($source['repoFolder'])/$file"
            if (-not (Test-Path -LiteralPath (Join-Path $repo $repoFile) -PathType Leaf)) { $result.Problems.Add("$($repoFile): missing from the repo"); continue }
            $bytes = Get-RenderedByte $repoFile $Endpoint
            if ($null -eq $bytes) { continue }
            $status = Write-Rendered $target $file $bytes
            if (-not $status) { continue }
            $counts[$status] = 1 + $(if ($counts.Contains($status)) { $counts[$status] } else { 0 })
            $files.Add([IO.Path]::GetFullPath((Join-Path $target $file)))
        }
        $summary = ($counts.Keys | ForEach-Object { "$($counts[$_]) $_" }) -join ', '
        $result.Steps.Add("$($source['name']) -> $($target): $(if ($summary) { $summary } else { 'nothing' })")
    }
    $result.Data['Rendered'] = [string[]]$files.ToArray()
    $result.Data['Written'] = $written
}

function Restore-Secret {
    $zip = $bundleData['BundlePath']
    $sha = $bundleData['BundleSha256']
    if (-not $zip -or -not $sha) { $result.Problems.Add('Stage 1 has not recorded the bundle'); return }
    if (-not $act) { $result.Steps.Add("would place bundle folders $($secretFolders -join ', ') (01 and 02 on this PC, 05 on the VPS)"); return }
    $r = & $Context.Tools.RestoreSecrets -ZipPath $zip -Sha256 $sha -Folder $secretFolders -Execute -PassThru -SshHost $alias `
        -SshCommand $machine.Commands['ssh'] -DockerCommand $machine.Commands['docker']
    foreach ($w in @($r.Warnings)) { $result.Warnings.Add("secrets: $w") }
    foreach ($p in @($r.Problems)) { $result.Problems.Add("secrets: $p") }
    $placed = @($r.Rows | Where-Object { $_.Folder -in $secretFolders -and $_.Status -in 'placed', 'already in place' })
    $result.Data['Placed'] = [string[]]@($placed | ForEach-Object Id)
    $result.Steps.Add("secrets: $($placed.Count) files in place from bundle folders $($secretFolders -join ', ')")
}

function Resolve-Location([string]$Location) {
    $roots = (Get-Content -LiteralPath $Context.RootsPath -Raw | ConvertFrom-Json -AsHashtable)['roots']
    $name, $rel = $Location -split ':', 2
    $root = $roots[$name]
    if (-not $root -or $root['kind'] -ne 'path') { return $null }
    if ($root['host'] -eq 'vps') { return @{ Host = 'vps'; Path = ($root['path'].TrimEnd('/') + '/' + $rel) } }
    return @{ Host = 'pc'; Path = [IO.Path]::GetFullPath((Join-Path ([Environment]::ExpandEnvironmentVariables($root['path'])) $rel)) }
}

function Test-Checkpoint {
    $endpoint = Get-Endpoint
    $files = @($Context.Data['Rendered'])
    $bad = [Collections.Generic.List[string]]::new()
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($endpoint) { foreach ($v in $endpoint.Values) { [void]$allowed.Add([string]$v) } }
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $bad.Add("$($f): missing"); continue }
        $parts = Split-Text ([IO.File]::ReadAllBytes($f))
        if (-not $parts) { continue }
        $left = Get-StackPlaceholder -Text $parts.Text
        if ($left.Count) { $bad.Add("$($f): still holds {{$($left[0])}}"); continue }
        $stray = @((Find-TailnetAddress -Text $parts.Text) | Where-Object { -not $allowed.Contains($_) })
        if ($stray.Count) { $bad.Add("$($f): holds $($stray.Count) tailnet address(es) that no new node has") }
    }
    foreach ($b in $bad) { $result.Problems.Add($b) }
    Add-StageCheck $result 'rendered files: no placeholders, only the new tailnet addresses' "$($files.Count) of $($files.Count)" "$($files.Count - $bad.Count) of $($files.Count)" ($files.Count -gt 0 -and $bad.Count -eq 0 -and $null -ne $endpoint)

    $mapPath = if ($bundleData['BundleRoot']) { Join-Path $bundleData['BundleRoot'] '00-RESTORE-MAP.json' } else { $null }
    if (-not $mapPath -or -not (Test-Path -LiteralPath $mapPath -PathType Leaf)) { Add-StageCheck $result 'placed secrets match the map' 'the map' 'map missing' $false; return }
    $entries = @((Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json -AsHashtable)['entries'])
    $ids = @($Context.Data['Placed'])
    $pcBad = 0; $pcCount = 0; $vpsBad = 0; $vpsCount = 0
    foreach ($e in @($entries | Where-Object { $_['id'] -in $ids })) {
        $where = Resolve-Location $e['destination']
        if (-not $where) { continue }
        if ($where.Host -eq 'pc') {
            $pcCount++
            $ok = (Test-Path -LiteralPath $where.Path -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $where.Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $e['sha256']) -and
            -not (Get-ProtectionProblem -Path $where.Path)
            if (-not $ok) { $pcBad++; $result.Problems.Add("$($e['destination']): missing, changed or not owner-only") }
            continue
        }
        $vpsCount++
        if ($where.Path -notmatch '^/[A-Za-z0-9._/-]+$') { $vpsBad++; $result.Problems.Add("$($e['destination']): not a plain VPS path"); continue }
        $mode = if ($e['mode']) { $e['mode'].TrimStart('0') } else { '600' }
        $owner = if ($e['owner']) { $e['owner'] } else { $Context.Topology['hosts']['vps']['user'] }
        $r = & $machine.Exec 'ssh' @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20', $alias,
            "stat -c '%a %U' -- '$($where.Path)' && sha256sum -- '$($where.Path)'")
        $lines = @($r.Output)
        $ok = $r.ExitCode -eq 0 -and $lines.Count -ge 2 -and $lines[0] -eq "$mode $owner" -and ($lines[1] -split '\s+')[0] -eq $e['sha256']
        if (-not $ok) { $vpsBad++; $result.Problems.Add("$($e['destination']): on the VPS, missing, changed, or not mode $mode owner $owner") }
    }
    Add-StageCheck $result 'secrets on this PC match the map, owner-only' "$pcCount of $pcCount" "$($pcCount - $pcBad) of $pcCount" ($pcBad -eq 0)
    Add-StageCheck $result 'secrets on the VPS match the map, mode and owner' "$vpsCount of $vpsCount" "$($vpsCount - $vpsBad) of $vpsCount" ($vpsBad -eq 0)
}

if ($Mode -eq 'Check') {
    Test-Checkpoint
    if ($result.Problems.Count -and $result.Status -eq 'passed') { $result.Status = 'failed' }
    return $result
}

$endpoint = Get-Endpoint
if ($endpoint) {
    if ($act -and -not (Test-Path -LiteralPath $renderRoot -PathType Container)) {
        foreach ($made in @(New-FolderChain -Path $renderRoot)) { & $Context.Own 'folder' $made $made 'wipe' }
    }
    Invoke-Render $endpoint
}
if ($result.Problems.Count -eq 0 -and ($endpoint -or $Mode -eq 'Plan')) { Restore-Secret }

if ($Mode -eq 'Plan') { $result.Status = 'planned' }
elseif ($result.Problems.Count) { $result.Status = 'failed' }
return $result
