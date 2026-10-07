#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 11: remove the plaintext and log the rebuild (docs/RESTORE.md
    Stage 11).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context, as the signed-in user. Needs Stage 10, so the new
    bundle is already in Bitwarden and its round trip matched before
    anything here removes the old one.

      11a  Removes every item state.json records as plaintext, as
           tools/Remove-RecoveryPlaintext.ps1 does (Invoke-PlaintextRemoval,
           on the controller's own copy of the state): the bundle ZIP and
           its unpacked folder, the VPS bootstrap, the download tokens, the
           OWUI API key file, and Stage 10's collector run folder and
           round-trip folder. Then the staging folder, once nothing else is
           in it. Anything it may not remove is named, never removed, and
           fails the stage.
      11b  Writes <state root>\rebuild-record.json: the release commit and
           tag, the manifest hashes, the bundle the rebuild started from and
           the one Stage 10 made (file names and SHA-256 only), each stage's
           status, attempts and interruptions, the stages that took more
           than one attempt, and what 11a removed. No secret and no address.
           It replaces only a record the controller wrote.
      11c  Scans <state root>\owui-seed-new (Stage 10's seed export) with
           tools/Test-NoSecrets.ps1, then says what is left for a person:
           the ledger row (an assistant writes every AI-CHANGELOG.csv row,
           with Add-AIChange.ps1, from the record), committing the new seed,
           and fixing docs/RESTORE.md. They are steps, not questions:
           committing the seed changes manifests/, after which no stage
           after Stage 1 runs until Stage 1 runs again, so this stage must be
           done first.

    Running it again is safe: what is gone stays gone and the record is
    written again.

    Check is checkpoint 11: state.json records no plaintext, the staging
    folder is gone (or empty, when the controller did not create it), and
    the record is there. It changes nothing.
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

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
$machine = $Context.Machine
$repo = $Context.RepoRoot
$stateRoot = [IO.Path]::GetFullPath($Context.StateRoot)
$staging = [IO.Path]::GetFullPath($Context.StagingRoot)
$stackRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['stack']['path']))
$dashboardRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['dashboard']['path']))
$account = $Context.Topology['hosts']['vps']['user']
$recordPath = Join-Path $stateRoot 'rebuild-record.json'
$seedNew = Join-Path $stateRoot 'owui-seed-new'
$ledger = Join-Path $stackRoot 'AI-CHANGELOG.csv'
$protocol = Join-Path $stackRoot 'AI-CHANGELOG-PROTOCOL.md'
$ledgerTool = [IO.Path]::GetFullPath((Join-Path $stackRoot '_support/scripts/maintenance/Add-AIChange.ps1'))

# ---------- helpers ----------

function Get-Entry([int]$Number) {
    $e = $Context.State['stages']["$Number"]
    if ($e -is [hashtable]) { return $e }
    return @{}
}

function Get-EntryData([int]$Number) {
    $d = (Get-Entry $Number)['data']
    if ($d -is [Collections.IDictionary]) { return $d }
    return @{}
}

function Get-Part($Table, [string]$Key) {
    if ($Table -is [Collections.IDictionary] -and $Table[$Key] -is [Collections.IDictionary]) { return $Table[$Key] }
    return @{}
}

function Format-Argument([string]$Text) { return "'" + ($Text -replace "'", "''") + "'" }

function Get-ReleaseTag {
    $r = & $machine.Exec 'git' @('-C', $repo, 'describe', '--tags', '--exact-match', 'HEAD')
    if ($r.ExitCode -eq 0 -and @($r.Output).Count -and "$($r.Output[0])".Trim()) { return "$($r.Output[0])".Trim() }
    return $null
}

function Get-StageRow {
    # Stages 1 to 10 as state.json has them.
    $rows = foreach ($n in 1..10) {
        $e = Get-Entry $n
        [ordered]@{
            stage         = $n
            status        = $(if ($e['status']) { [string]$e['status'] } else { 'not started' })
            attempts      = [int]$e['attempts']
            interruptions = [int]$e['interruptions']
            finished      = $(if ($e['finished']) { [string]$e['finished'] } else { $null })
        }
    }
    return , @($rows)
}

function Get-Retried($Rows) {
    # One line per stage that took more than one attempt.
    $out = foreach ($s in $Rows) {
        if ($s.attempts -le 1 -and $s.interruptions -eq 0) { continue }
        $text = "Stage $($s.stage): $($s.attempts) attempts"
        if ($s.interruptions) { $text += ", $($s.interruptions) interrupted" }
        $text
    }
    return , @($out)
}

# ---------- 11a: the plaintext ----------

function Invoke-Removal([switch]$Execute) {
    # Rows from Invoke-PlaintextRemoval; problems for anything left.
    $rows = @(Invoke-PlaintextRemoval -State $Context.State -StatePath $Context.StatePath -Execute:$Execute)
    if (-not $rows.Count) { $result.Steps.Add('plaintext: state.json records none') }
    foreach ($r in $rows) {
        if ($r.Status -like 'left:*') {
            $result.Problems.Add("plaintext not removed: $($r.Path) ($($r.Status.Substring(6))). Look at it; remove it yourself only if you put it there, then run again")
        }
        else { $result.Steps.Add("plaintext: $($r.Status): $($r.Path)") }
    }
    return , $rows
}

# ---------- 11b: the record ----------

function Get-Record($Rows) {
    $release = $Context.State['release']
    $manifests = Get-Part $release 'manifests'
    $s1 = Get-EntryData 1
    $s10 = Get-EntryData 10
    $backup = Get-Part $s10 'Backup'
    $stages = Get-StageRow
    return [ordered]@{
        formatVersion = 1
        written       = [DateTime]::UtcNow.ToString('o')
        release       = [ordered]@{
            commit        = $(if ($release -is [Collections.IDictionary]) { [string]$release['commit'] } else { $null })
            tag           = Get-ReleaseTag
            manifestCount = $manifests.Count
            manifests     = $manifests
        }
        restoredFrom  = [ordered]@{
            bundle = $(if ($s1['BundlePath']) { [IO.Path]::GetFileName([string]$s1['BundlePath']) } else { $null })
            sha256 = $(if ($s1['BundleSha256']) { [string]$s1['BundleSha256'] } else { $null })
        }
        newBundle     = [ordered]@{
            bundle    = $(if ($backup['Zip']) { [string]$backup['Zip'] } else { $null })
            sha256    = $(if ($backup['Sha256']) { [string]$backup['Sha256'] } else { $null })
            roundTrip = $(if ((Get-Part $s10 'RoundTrip')['Ok']) { 'match' } else { 'not checked' })
            seedFiles = [int]$backup['SeedFiles']
        }
        stages        = $stages
        retried       = Get-Retried $stages
        plaintext     = [ordered]@{
            removed = @($Rows | Where-Object Status -EQ 'removed').Count
            left    = @($Rows | Where-Object { $_.Status -like 'left:*' } | ForEach-Object Path)
        }
        evidence      = Join-Path $stateRoot 'evidence'
    }
}

function Write-Record($Record) {
    # Written under a new temporary name, then moved into place. A record
    # the controller did not write is never replaced.
    $tmp = "$recordPath.tmp-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    foreach ($p in $recordPath, $tmp) {
        $c = @(& $Context.PathCheck -Path $p -Root $stateRoot -Detailed)[0]
        if (-not $c.IsValid) { $result.Problems.Add("the rebuild record $p fails the path check: $($c.Reason)"); return }
    }
    if ((Test-Path -LiteralPath $recordPath) -and -not (& $Context.IsOwned $recordPath)) {
        $result.Problems.Add("$recordPath is there and the controller did not write it; move it away, then run again")
        return
    }
    try {
        $stream = [IO.FileStream]::new($tmp, 'CreateNew', 'Write', 'None')
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 8) + "`n")
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
        [IO.File]::Move($tmp, $recordPath, $true)
    }
    finally { if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) } }
    & $Context.Own 'file' $recordPath $stateRoot 'keep'
    $result.Data['Record'] = $recordPath
    $result.Steps.Add("rebuild record written: $recordPath")
}

# ---------- 11c: what is left for a person ----------

function Test-NewSeed {
    # $true when the new seed is there and Test-NoSecrets finds nothing.
    if (-not (Test-Path -LiteralPath $seedNew -PathType Container)) {
        $result.Warnings.Add("no new OWUI seed at $($seedNew): Stage 10's backup left none, so there is nothing to commit")
        return $false
    }
    $files = @(Get-ChildItem -LiteralPath $seedNew -File -Recurse -Force)
    try { $found = @(& (Join-Path $repo 'tools/Test-NoSecrets.ps1') -Path $seedNew -PassThru) }
    catch {
        $result.Warnings.Add("the new OWUI seed could not be scanned ($($_.Exception.Message)); run tools/Test-NoSecrets.ps1 on it before committing it")
        return $false
    }
    if ($found.Count) {
        $where = @($found | Select-Object -First 3 | ForEach-Object { "$($_.File) line $($_.Line): $($_.Rule)" }) -join '; '
        $result.Warnings.Add("the new OWUI seed in $seedNew fails tools/Test-NoSecrets.ps1 ($($found.Count) finding(s): $where). Do not commit it; the next capture must export a clean one")
        return $false
    }
    $result.Steps.Add("new OWUI seed: $($files.Count) files in $seedNew, and tools/Test-NoSecrets.ps1 finds nothing in them")
    return $true
}

function Get-LedgerCommand($Record) {
    $release = $Record.release
    $at = if ($release.tag) { "$($release.tag) ($($release.commit))" } else { "commit $($release.commit)" }
    $retried = if ($Record.retried.Count) { "; more than one attempt: $($Record.retried -join ', ')" } else { '; every stage passed at its first attempt' }
    $arguments = [ordered]@{
        Author       = 'Liam'
        LoggedBy     = 'Claude'
        Model        = '<your model>'
        Request      = 'Rebuild the stack on new machines with ollama-cria (docs/RESTORE.md)'
        Summary      = "Rebuilt the PC and the VPS from ollama-cria $at; restored from $($Record.restoredFrom.bundle); first new bundle $($Record.newBundle.bundle) (round trip: $($Record.newBundle.roundTrip))"
        Files        = "$stackRoot; $dashboardRoot; VPS /home/$account"
        Steps        = "Stages 1 to 11 of docs/RESTORE.md$retried"
        Completed    = 'Y'
        Verification = "checkpoints 1 to 11 passed; evidence in $($Record.evidence); record $recordPath"
        Tier         = 'material'
        Provenance   = 'verified-live'
        Path         = $ledger
    }
    $text = @(foreach ($k in $arguments.Keys) { "-$k $(Format-Argument $arguments[$k])" }) -join ' '
    return "& $(Format-Argument $ledgerTool) $text"
}

function Add-NextStep($Record, [bool]$SeedReady) {
    if (-not (Test-Path -LiteralPath $ledgerTool -PathType Leaf)) {
        $result.Warnings.Add("Add-AIChange.ps1 is not at $ledgerTool, where Stage 4 writes it from the repo")
    }
    $missing = @(foreach ($f in $ledger, $protocol) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { [IO.Path]::GetFileName($f) } })
    if ($missing.Count) {
        $them = if ($missing.Count -gt 1) { 'them' } else { 'it' }
        $result.Warnings.Add(("$($missing -join ' and ') not in $($stackRoot): neither the bundle nor the repo carries $them, and Add-AIChange.ps1 never creates " +
                "the ledger. Copy $them from the old PC or a backup before the ledger row"))
    }
    $result.Steps.Add("next: log the rebuild. An assistant writes every AI-CHANGELOG.csv row: ask Claude or ChatGPT to add one from $recordPath, for example:")
    $result.Steps.Add((Get-LedgerCommand $Record))
    if ($SeedReady) {
        $result.Steps.Add(("next: commit the new OWUI seed. In $repo (switch to main and pull) or another clone of ollama-cria, replace manifests/owui-seed/seed " +
                "with the files in $seedNew, run ./tools/Test-NoSecrets.ps1 and Invoke-Pester ./tests, then commit, push and tag the next release. " +
                'From then on, a stage after Stage 1 runs again only once Stage 1 has run again and recorded the new commit'))
    }
    $result.Steps.Add("next: fix docs/RESTORE.md wherever this rebuild went differently; the evidence for every attempt is in $($Record.evidence)")
    $result.Steps.Add(("later: Stages 1 to 7 read the bundle or need checkpoint 1, which needs it. To run one of them again, download the bundle from Bitwarden into " +
            "$staging and start with -Stage 1"))
}

# ---------- checkpoint 11 ----------

function Invoke-Checkpoint {
    $left = @(Get-OwnedItem -State $Context.State -Plaintext | ForEach-Object { $_['path'] })
    Add-StageCheck $result 'plaintext recorded in state.json' 'none' $(if ($left.Count) { "$($left.Count): $($left -join ', ')" } else { 'none' }) ($left.Count -eq 0)

    $actual = 'gone'
    if (Test-Path -LiteralPath $staging -PathType Container) {
        $inside = @(Get-ChildItem -LiteralPath $staging -Force | ForEach-Object Name)
        $actual = if ($inside.Count) { "$($inside.Count) items: $(@($inside | Select-Object -First 5) -join ', ')" } else { 'empty' }
    }
    elseif (Test-Path -LiteralPath $staging) { $actual = 'a file is there' }
    Add-StageCheck $result "staging folder $staging" 'gone, or empty' $actual ($actual -in 'gone', 'empty')

    $record = $null
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        try { $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable } catch { $record = $null }
    }
    $ok = $record -is [Collections.IDictionary] -and $record['formatVersion'] -eq 1 -and $record['release'] -is [Collections.IDictionary] -and
    "$($record['release']['commit'])" -match '^[0-9a-f]{40}$'
    Add-StageCheck $result 'rebuild record' 'written, with the release commit' $(if ($ok) { $recordPath } elseif ($record) { 'unreadable or incomplete' } else { 'missing' }) $ok

    $result.Status = if (@($result.Checks | Where-Object { -not $_.Ok }).Count -or $result.Problems.Count) { 'failed' } else { 'passed' }
}

# ---------- main ----------

if ($Mode -eq 'Check') {
    Invoke-Checkpoint
    return $result
}

if ($Mode -eq 'Plan') {
    $rows = @(Invoke-PlaintextRemoval -State $Context.State -StatePath $Context.StatePath)
    if (-not $rows.Count) { $result.Steps.Add('plaintext: state.json records none') }
    foreach ($r in $rows) { $result.Steps.Add("plaintext: $($r.Status): $($r.Path)") }
    $result.Steps.Add("would write the rebuild record $recordPath")
    $result.Steps.Add("would scan the new OWUI seed in $seedNew with tools/Test-NoSecrets.ps1, then list what is left for you: the ledger row, the seed commit and RESTORE.md")
    $result.Status = 'planned'
    return $result
}

$rows = Invoke-Removal -Execute
$record = Get-Record $rows
Write-Record $record
$seedReady = Test-NewSeed
Add-NextStep $record $seedReady

if ($result.Problems.Count) { $result.Status = 'failed' }
return $result
