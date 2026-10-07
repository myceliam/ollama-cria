#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 1: the recovery release, its manifests, the target folders, the
    protected staging folder and the secrets bundle (docs/RESTORE.md Stage 1).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context.

    Run:

      1. The repo: its commit, its release tag if it has one, and no local
         changes (git status), so what runs is exactly what was released.
      2. Every manifests/*.json against the schema its $schema names.
      3. The folders topology.json marks create on the PC: created when
         missing (and recorded as owned), refused when one is a link,
         junction or file.
      4. The staging folder (E:\recovery-secrets): created owner-only from
         birth, or checked to be owner-only, not inheriting and owned by this
         account (C-04, C-05). BitLocker must be on for its drive (P8).
      5. The bundle: the ZIP must sit directly in the staging folder. With
         its SHA-256 from Bitwarden, tools/Restore-StackSecrets.ps1 checks
         it, checks every member path, unpacks it into a new owner-only
         folder next to it, checks it against the inventory and places
         bundle folder 04: the SSH key pair and config (C-35). The ZIP and
         the unpacked folder are recorded as plaintext for Stage 11.

    Plan does the read-only part of the same (git, schemas, what exists) and
    says what Run would create. Check is checkpoint 1, cheap enough to run
    before every later stage: no local changes, the manifests, the staging
    folder's protection, BitLocker, the bundle's SHA-256, the unpacked
    folder's protection, and the SSH files owner-only.
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

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
$machine = $Context.Machine
$repo = $Context.RepoRoot
$staging = [IO.Path]::GetFullPath($Context.StagingRoot)
$act = $Mode -eq 'Run'

function Test-Release {
    # The commit, the tag and local changes. Returns the commit or $null.
    $head = & $machine.Exec 'git' @('-C', $repo, 'rev-parse', 'HEAD')
    if ($head.ExitCode -ne 0 -or -not $head.Output -or $head.Output[0] -notmatch '^[0-9a-f]{40}$') {
        $result.Problems.Add("repo: git cannot read the commit in $repo")
        return $null
    }
    $commit = $head.Output[0]
    $tag = & $machine.Exec 'git' @('-C', $repo, 'describe', '--tags', '--exact-match', 'HEAD')
    $label = if ($tag.ExitCode -eq 0 -and $tag.Output) { "tag $($tag.Output[0])" } else { 'no release tag' }
    $changes = & $machine.Exec 'git' @('-C', $repo, 'status', '--porcelain', '--untracked-files=normal')
    $dirty = @($changes.Output | Where-Object { $_ -match '\S' }).Count
    if ($Mode -eq 'Check') {
        Add-StageCheck $result 'repo has no local changes' '0 changed files' "$dirty changed files" ($changes.ExitCode -eq 0 -and $dirty -eq 0)
    }
    else {
        $result.Steps.Add("repo at $($commit.Substring(0, 12)) ($label)")
        if ($changes.ExitCode -ne 0) { $result.Problems.Add('repo: git status failed') }
        elseif ($dirty) { $result.Problems.Add("repo: $dirty changed or new files; the controller only runs a clean checkout of a release (commit or stash them)") }
        if ($label -eq 'no release tag') { $result.Warnings.Add('the repo is not at a release tag; the commit is recorded instead') }
    }
    return $commit
}

function Test-Manifest {
    # Every manifests/*.json against the schema its $schema names, in
    # manifests/schemas. Returns the number that failed.
    $folder = Join-Path $repo 'manifests'
    $schemas = [IO.Path]::GetFullPath((Join-Path $folder 'schemas'))
    $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object Name)
    $bad = 0
    foreach ($f in $files) {
        $why = $null
        try { $doc = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { $doc = $null; $why = 'not JSON' }
        if (-not $why) {
            $ref = if ($doc -is [hashtable]) { [string]$doc['$schema'] } else { '' }
            $schema = if ($ref -match '^\./schemas/[a-z0-9-]+\.schema\.json$') { [IO.Path]::GetFullPath((Join-Path $folder $ref)) } else { $null }
            if (-not $schema -or -not $schema.StartsWith($schemas) -or -not (Test-Path -LiteralPath $schema -PathType Leaf)) { $why = 'names no schema in manifests/schemas' }
            elseif (-not (Test-Json -Path $f.FullName -SchemaFile $schema -ErrorAction SilentlyContinue)) { $why = 'does not match its schema' }
        }
        if ($why) { $bad++; $result.Problems.Add("manifests/$($f.Name): $why") }
    }
    if ($Mode -eq 'Check') { Add-StageCheck $result 'manifests match their schemas' "$($files.Count) of $($files.Count)" "$($files.Count - $bad) of $($files.Count)" ($bad -eq 0 -and $files.Count -gt 0) }
    else { $result.Steps.Add("$($files.Count - $bad) of $($files.Count) manifests match their schemas") }
    if ($files.Count -eq 0) { $result.Problems.Add('manifests: none found') }
}

function Initialize-Root {
    # The folders marked create, on the PC.
    foreach ($name in @($Context.Topology['roots'].Keys | Sort-Object)) {
        $root = $Context.Topology['roots'][$name]
        if ($root['host'] -ne 'pc' -or -not $root['create']) { continue }
        $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($root['path']))
        $check = & $Context.PathCheck -Path $path -Root $path -AllowRoot -Detailed
        if (-not $check.IsValid) { $result.Problems.Add("root '$name' ($path): $($check.Reason)"); continue }
        if (Test-Path -LiteralPath $path -PathType Container) { $result.Steps.Add("root '$name': $path is there"); continue }
        if (Test-Path -LiteralPath $path) { $result.Problems.Add("root '$name': $path is a file, not a folder"); continue }
        if (-not $act) { $result.Steps.Add("root '$name': would create $path"); continue }
        foreach ($made in @(New-FolderChain -Path $path)) { & $Context.Own 'folder' $made $made 'keep' }
        $result.Steps.Add("root '$name': created $path")
    }
}

function Initialize-Staging {
    $check = & $Context.PathCheck -Path $staging -Root $staging -AllowRoot -Detailed
    if (-not $check.IsValid) { $result.Problems.Add("staging folder $($staging): $($check.Reason)"); return $false }
    if (Test-Path -LiteralPath $staging -PathType Container) {
        $why = Get-ProtectionProblem -Path $staging -OwnFolder
        if ($why) { $result.Problems.Add("staging folder $($staging): $why; it must be created by this stage, or fixed so only you can reach it"); return $false }
        $result.Steps.Add("staging folder $staging is there and only you can reach it")
    }
    elseif (Test-Path -LiteralPath $staging) { $result.Problems.Add("staging folder $($staging): a file is there"); return $false }
    elseif (-not $act) { $result.Steps.Add("would create the staging folder $staging, owner-only from birth") }
    else {
        $parent = [IO.Path]::GetDirectoryName($staging)
        foreach ($made in @(New-FolderChain -Path $parent)) { & $Context.Own 'folder' $made $made 'keep' }
        Initialize-ProtectedFolder -Path $staging
        & $Context.Own 'folder' $staging $staging 'keep' -Plaintext
        $why = Get-ProtectionProblem -Path $staging -OwnFolder
        if ($why) { $result.Problems.Add("staging folder $($staging): just created, but $why"); return $false }
        $result.Steps.Add("created the staging folder $staging, owner-only from birth")
    }
    $bitlocker = & $machine.BitLocker $staging
    if ($bitlocker -ne 'On') { $result.Problems.Add("BitLocker is not on for the drive of $staging ($bitlocker); turn it on first (prerequisite P8)") }
    else { $result.Steps.Add('BitLocker is on for the staging drive') }
    return $true
}

function Find-Bundle {
    # The ZIP and its SHA-256, from the parameters or the last attempt.
    $zip = if ($Context.Bundle.Path) { $Context.Bundle.Path } elseif ($Context.Data['BundlePath']) { $Context.Data['BundlePath'] } else { $null }
    $sha = if ($Context.Bundle.Sha256) { $Context.Bundle.Sha256 } elseif ($Context.Data['BundleSha256']) { $Context.Data['BundleSha256'] } else { $null }
    if (-not $zip) {
        $found = @(if (Test-Path -LiteralPath $staging -PathType Container) { Get-ChildItem -LiteralPath $staging -Filter 'stack-secrets-*.zip' -File })
        if ($found.Count -gt 1) { Add-StageAsk $result "There is more than one stack-secrets-*.zip in $($staging): name the one to use with -BundlePath."; return $null }
        if ($found.Count -eq 1) { $zip = $found[0].FullName }
    }
    if (-not $zip -or -not (Test-Path -LiteralPath $zip -PathType Leaf)) {
        Add-StageAsk $result "In Bitwarden, save the bundle (stack-secrets-<date>.zip) straight into $staging, not Downloads. Then run again with -BundleSha256 and the SHA-256 stored in the same Bitwarden item."
        return $null
    }
    $zip = [IO.Path]::GetFullPath($zip)
    if (-not [IO.Path]::GetDirectoryName($zip).Equals($staging, [StringComparison]::OrdinalIgnoreCase)) {
        $result.Problems.Add("the bundle must sit directly in $staging, not $([IO.Path]::GetDirectoryName($zip))")
        return $null
    }
    if (-not $sha) {
        Add-StageAsk $result "Run again with -BundleSha256 and the SHA-256 stored with the bundle in Bitwarden, so the bundle can be checked."
        return $null
    }
    return @{ Zip = $zip; Sha256 = $sha.ToLowerInvariant() }
}

function Resolve-Location([string]$Location) {
    # A logical destination such as 'ssh:config' to a path on this PC.
    $roots = Get-Content -LiteralPath $Context.RootsPath -Raw | ConvertFrom-Json -AsHashtable
    $name, $rel = $Location -split ':', 2
    $root = $roots['roots'][$name]
    if (-not $root -or $root['kind'] -ne 'path' -or $root['host'] -ne 'pc') { return $null }
    return [IO.Path]::GetFullPath((Join-Path ([Environment]::ExpandEnvironmentVariables($root['path'])) $rel))
}

function Restore-Bundle($Bundle) {
    if (-not $act) {
        $result.Steps.Add("would check $([IO.Path]::GetFileName($Bundle.Zip)) against its SHA-256, unpack it next to itself and place bundle folder 04 (the SSH key pair and config)")
        return
    }
    $alias = $Context.Topology['hosts']['vps']['sshAlias']
    $r = & $Context.Tools.RestoreSecrets -ZipPath $Bundle.Zip -Sha256 $Bundle.Sha256 -Folder '04' -Execute -PassThru -SshHost $alias
    foreach ($w in @($r.Warnings)) { $result.Warnings.Add("bundle: $w") }
    foreach ($p in @($r.Problems)) { $result.Problems.Add("bundle: $p") }
    $result.Data['BundlePath'] = $Bundle.Zip
    $result.Data['BundleSha256'] = $Bundle.Sha256
    if (-not (& $Context.IsOwned $Bundle.Zip)) { & $Context.Own 'file' $Bundle.Zip $staging 'keep' -Plaintext -Adopted }
    if ($r.BundleRoot) {
        $result.Data['BundleRoot'] = [IO.Path]::GetFullPath($r.BundleRoot)
        if (-not (& $Context.IsOwned $r.BundleRoot)) { & $Context.Own 'folder' $r.BundleRoot $staging 'keep' -Plaintext -Adopted }
    }
    if (-not $r.IsValid) { return }
    $placed = @($r.Rows | Where-Object { $_.Folder -eq '04' -and $_.Status -in 'placed', 'already in place' })
    $result.Data['SshPlaced'] = [string[]]@($placed | ForEach-Object Destination)
    $result.Steps.Add("bundle checked and unpacked; bundle folder 04: $($placed.Count) files in place")
}

function Test-Checkpoint {
    $null = Test-Release
    Test-Manifest
    $why = if (Test-Path -LiteralPath $staging -PathType Container) { Get-ProtectionProblem -Path $staging -OwnFolder } else { 'missing' }
    Add-StageCheck $result 'staging folder: only you can reach it' 'owner-only, not inherited' $(if ($why) { $why } else { 'owner-only, not inherited' }) (-not $why)
    $bitlocker = & $machine.BitLocker $staging
    Add-StageCheck $result 'BitLocker on the staging drive' 'On' $bitlocker ($bitlocker -eq 'On')
    $zip = $Context.Data['BundlePath']
    $sha = $Context.Data['BundleSha256']
    $actual = if ($zip -and (Test-Path -LiteralPath $zip -PathType Leaf)) { (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() } else { 'missing' }
    Add-StageCheck $result 'bundle SHA-256 matches Bitwarden' 'the recorded value' $(if ($actual -eq $sha) { 'matches' } elseif ($actual -eq 'missing') { 'bundle missing' } else { 'differs' }) ($null -ne $sha -and $actual -eq $sha)
    $unpacked = $Context.Data['BundleRoot']
    $why = if ($unpacked -and (Test-Path -LiteralPath $unpacked -PathType Container)) { Get-ProtectionProblem -Path $unpacked -OwnFolder } else { 'missing' }
    if (-not $why -and -not [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($unpacked)).Equals($staging, [StringComparison]::OrdinalIgnoreCase)) { $why = 'outside the staging folder' }
    Add-StageCheck $result 'unpacked bundle: in the staging folder, owner-only' 'yes' $(if ($why) { $why } else { 'yes' }) (-not $why)
    $files = @($Context.Data['SshPlaced'])
    $bad = @(foreach ($location in $files) {
            $path = Resolve-Location $location
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-ProtectionProblem -Path $path)) { $location }
        })
    Add-StageCheck $result 'SSH files from bundle folder 04 are owner-only' "$($files.Count) of $($files.Count)" "$($files.Count - $bad.Count) of $($files.Count)" ($files.Count -gt 0 -and $bad.Count -eq 0)
}

if ($Mode -eq 'Check') {
    Test-Checkpoint
    if ($result.Problems.Count -and $result.Status -eq 'passed') { $result.Status = 'failed' }
    return $result
}

$commit = Test-Release
Test-Manifest
Initialize-Root
$stagingOk = Initialize-Staging
if ($commit -and $stagingOk -and $result.Problems.Count -eq 0) {
    $bundle = Find-Bundle
    if ($bundle) { Restore-Bundle $bundle }
}
elseif ($Mode -eq 'Plan') {
    $result.Steps.Add('the bundle is checked once the problems above are fixed')
}
if ($Mode -eq 'Plan') { $result.Status = 'planned' }
elseif ($result.Problems.Count) { $result.Status = 'failed' }
return $result
