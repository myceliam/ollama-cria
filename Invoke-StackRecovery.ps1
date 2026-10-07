#Requires -Version 7.4
<#
.SYNOPSIS
    Rebuilds the stack on new machines, one stage at a time
    (docs/RESTORE.md, The controller).

.DESCRIPTION
    Two modes:

      Plan (the default). Lists every stage with its state from state.json,
      and what each stage that is not done yet would do now. Changes
      nothing: it does not even create the state folder.

      -Execute. Runs one stage, the next one that is ready (or the one given
      with -Stage), then its checkpoint, records the result and stops. Run
      the same command again for the next stage. Each run ends at one
      checkpoint, which is where a person (or an assistant) reads the
      evidence before going on.

    Rules it keeps:

      - State. state.json in the state root (topology.json,
        controller.stateRoot, E:\recovery-state) records each stage, its
        result, the release commit and the manifest hashes, and every file
        and folder the controller created. Never a secret.
      - One run at a time: a lock file in the state root. A lock left by a
        run whose process is gone is taken over.
      - A stage is ready when every stage it needs is done. Before a stage
        runs, each of those is checked again (its checkpoint, which is
        cheap); one that no longer passes stops the run.
      - The repo must still be at the commit Stage 1 checked, with the same
        manifests, or nothing after Stage 1 runs.
      - Interrupted. A stage still marked running was cut off: the items it
        created and marked 'wipe' are removed (only those, and only while
        they are still the objects it created), then it runs again (C-45).
        A stage that asked for a restart runs again without wiping.
      - Elevation. A stage that needs admin rights (Stage 3) runs in an
        elevated child of this script, which holds the same lock and returns
        its exit code. Everything else runs as the signed-in user, so files,
        Docker Desktop and Ollama never end up belonging to the
        administrators group.
      - Evidence. One JSON and one text file per stage attempt in
        <state root>\evidence: names, counts, hashes, statuses and exit
        codes. After a stage that reads the secrets bundle (1, 4, 7), every
        evidence file and state.json are matched against the bundle's
        values; a match deletes that evidence file and fails the stage.
      - Questions. A stage that needs a person stops with 'needs-user' and
        lists what it needs. A question with an id is answered with -Accept
        <id>; the answer is kept in state.json.

    Exit codes: 0 done (or plan), 1 failed, 2 needs a person, 3 restart the
    PC and run again.

.PARAMETER Execute
    Run a stage. Without it the controller only plans.

.PARAMETER Stage
    The stage to run (1 to 11). Default: the next one that is ready. A done
    stage given here runs again; its steps skip what is already in place.

.PARAMETER Accept
    Answers to a stage's questions, by the id it printed, for example
    -Accept gpu or -Accept 'model:gemma3:12b'.

.PARAMETER BundleSha256
    Stage 1: the bundle ZIP's SHA-256, as stored with it in Bitwarden. Kept
    in state.json (a hash, not a secret).

.PARAMETER HostKeyFingerprint
    Stage 2: the new VPS's SSH host key fingerprint (SHA256:...), as the
    bootstrap printed it in the provider's console. Kept in state.json (a
    fingerprint, not a secret).

.PARAMETER BundlePath
    Stage 1: the bundle ZIP inside the staging folder. Default: the only
    stack-secrets-*.zip there.

.PARAMETER TopologyPath
    Default: manifests/topology.json in this repo.

.PARAMETER RepoRoot
    The recovery repo. Default: the folder this script is in.

.PARAMETER StateRoot
    Default: controller.stateRoot from the topology.

.PARAMETER StageRoot
    The stage scripts. Default: windows/stages in this repo.

.PARAMETER Command
    Programs to run instead of git, winget, wsl, nvidia-smi, docker, ollama,
    curl, py, tailscale, ssh or ssh-keyscan, by name (tests and unusual
    installs).

.PARAMETER LockToken
    Internal: passed to the elevated child.

.PARAMETER PassThru
    Return a result object instead of printing and setting the exit code.

.EXAMPLE
    pwsh -File .\Invoke-StackRecovery.ps1

    Shows every stage and what would happen next.

.EXAMPLE
    pwsh -File .\Invoke-StackRecovery.ps1 -Execute -BundleSha256 <from Bitwarden>

    Runs Stage 1 on a new machine.

.EXAMPLE
    pwsh -File .\Invoke-StackRecovery.ps1 -Execute

    Runs the next stage that is ready.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are read inside the helper functions.')]
[CmdletBinding()]
param(
    [switch]$Execute,

    [ValidateRange(1, 11)]
    [int]$Stage,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9:._/-]{0,127}$')]
    [string[]]$Accept = @(),

    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$BundleSha256,

    [string]$BundlePath,

    [ValidatePattern('^SHA256:[A-Za-z0-9+/]{43}$')]
    [string]$HostKeyFingerprint,

    [string]$TopologyPath = (Join-Path $PSScriptRoot 'manifests/topology.json'),

    [string]$RepoRoot = $PSScriptRoot,

    [string]$StateRoot,

    [string]$StageRoot = (Join-Path $PSScriptRoot 'windows/stages'),

    [hashtable]$Command = @{},

    [ValidatePattern('^[0-9a-f]{32}$')]
    [string]$LockToken,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'tools/RecoveryState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tools/RecoveryHost.psm1') -Force
$pathCheck = Join-Path $PSScriptRoot 'tools/Test-RecoveryPath.ps1'

# What RESTORE.md defines. Script is found in -StageRoot by its number;
# a stage with no script yet is reported as not built. A plain table: an
# [ordered] one would read $catalogue[1] as its second entry.
$catalogue = @{
    1  = @{ Title = 'Recovery release, manifests and the secrets bundle'; Needs = @(); Elevated = $false; Bundle = $true; Module = 7 }
    2  = @{ Title = 'VPS base and both hosts on the tailnet'; Needs = @(1); Elevated = $false; Bundle = $false; Module = 8 }
    3  = @{ Title = 'Windows runtime: virtualisation, WSL, apps, Ollama profile'; Needs = @(1); Elevated = $true; Bundle = $false; Module = 7 }
    4  = @{ Title = 'Render endpoints and place the remaining secrets'; Needs = @(2, 3); Elevated = $false; Bundle = $true; Module = 7 }
    5  = @{ Title = 'VPS guard, web egress, Kokoro and the STT relay'; Needs = @(4); Elevated = $false; Bundle = $false; Module = 8 }
    6  = @{ Title = 'Fetch ComfyUI, models and weights'; Needs = @(1, 3); Elevated = $false; Bundle = $false; Module = 7 }
    7  = @{ Title = 'Images, volumes, service state and the OWUI seed'; Needs = @(5, 6); Elevated = $false; Bundle = $true; Module = 9 }
    8  = @{ Title = 'Start services, Tailscale Serve and automation'; Needs = @(7); Elevated = $true; Bundle = $false; Module = 9 }
    9  = @{ Title = 'Functional tests'; Needs = @(8); Elevated = $false; Bundle = $false; Module = 9 }
    10 = @{ Title = 'Reboot, rerun and the backup routine'; Needs = @(9); Elevated = $false; Bundle = $false; Module = 9 }
    11 = @{ Title = 'Log and clean up'; Needs = @(10); Elevated = $false; Bundle = $false; Module = 9 }
}

$stageNumbers = 1..11
$exitCodes = @{ done = 0; planned = 0; failed = 1; 'needs-user' = 2; reboot = 3 }
$machine = New-RecoveryHost -Command $Command
$onWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)

function Say([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }

function Read-Topology {
    if (-not (Test-Path -LiteralPath $TopologyPath -PathType Leaf)) { throw [InvalidOperationException]::new("the topology file is missing: $TopologyPath") }
    $schema = Join-Path (Split-Path -Parent $TopologyPath) 'schemas/topology.schema.json'
    if (-not (Test-Path -LiteralPath $schema -PathType Leaf)) { $schema = Join-Path $RepoRoot 'manifests/schemas/topology.schema.json' }
    if (-not (Test-Json -Path $TopologyPath -SchemaFile $schema -ErrorAction SilentlyContinue)) {
        throw [InvalidOperationException]::new('the topology file does not match its schema')
    }
    return (Get-Content -LiteralPath $TopologyPath -Raw | ConvertFrom-Json -AsHashtable)
}

function Get-StageScript([int]$Number) {
    $found = @(Get-ChildItem -LiteralPath $StageRoot -Filter ('{0:D2}-*.ps1' -f $Number) -File -ErrorAction SilentlyContinue)
    if ($found.Count -gt 1) { throw [InvalidOperationException]::new("more than one script for Stage $Number in $StageRoot") }
    if ($found.Count -eq 1) { return $found[0].FullName }
    return $null
}

function Get-StageStatus($State, [int]$Number) {
    $s = $State['stages']["$Number"]
    if ($s -is [hashtable] -and $s['status']) { return [string]$s['status'] }
    return 'not started'
}

function Get-Release {
    # The repo's commit and the SHA-256 of every file under manifests/.
    $r = & $machine.Exec 'git' @('-C', $RepoRoot, 'rev-parse', 'HEAD')
    if ($r.ExitCode -ne 0 -or -not $r.Output -or $r.Output[0] -notmatch '^[0-9a-f]{40}$') {
        throw [InvalidOperationException]::new("the repo's commit cannot be read with git in $RepoRoot")
    }
    $manifests = [ordered]@{}
    $root = Join-Path $RepoRoot 'manifests'
    foreach ($f in Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName) {
        $rel = [IO.Path]::GetRelativePath($root, $f.FullName) -replace '\\', '/'
        $manifests[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return @{ commit = $r.Output[0]; manifests = $manifests }
}

function Get-ReleaseProblem($State) {
    # $null when the repo is still what Stage 1 checked.
    $recorded = $State['release']
    if (-not $recorded -or -not $recorded['commit']) { return 'Stage 1 has not recorded the release yet' }
    $now = Get-Release
    if ($now.commit -ne $recorded['commit']) { return "the repo is at $($now.commit.Substring(0, 12)), not $($recorded['commit'].Substring(0, 12)) as Stage 1 checked" }
    $old = $recorded['manifests']
    foreach ($k in $now.manifests.Keys) { if (-not $old.ContainsKey($k) -or $old[$k] -ne $now.manifests[$k]) { return "manifests/$k changed since Stage 1 checked it" } }
    foreach ($k in $old.Keys) { if (-not $now.manifests.Contains($k)) { return "manifests/$k is gone since Stage 1 checked it" } }
    return $null
}

function Get-NextStage($State) {
    foreach ($n in $stageNumbers) {
        if ((Get-StageStatus $State $n) -eq 'done') { continue }
        if (-not (Get-StageScript $n)) { continue }
        if (@($catalogue[$n].Needs | Where-Object { (Get-StageStatus $State $_) -ne 'done' }).Count) { continue }
        return [int]$n
    }
    return $null
}

function Get-StageContext([int]$Number, $State, [string]$StatePath, [string]$Mode) {
    # Only Run may record or remove what the controller owns.
    $planOnly = $Mode -ne 'Run'
    $key = "$Number"
    $entry = $State['stages'][$key]
    $accepted = @(if ($entry -is [hashtable] -and $entry['accepted']) { $entry['accepted'] }) + @($Accept) | Select-Object -Unique
    $data = if ($entry -is [hashtable] -and $entry['data'] -is [hashtable]) { $entry['data'] } else { @{} }
    $ownership = Get-OwnershipCallback -State $State -StatePath $StatePath -Stage $Number -PlanOnly:$planOnly
    return @{
        Stage       = $Number
        Mode        = $Mode
        RepoRoot    = [IO.Path]::GetFullPath($RepoRoot)
        StateRoot   = $script:StateRoot
        StagingRoot = $topology['controller']['stagingRoot']
        Topology    = $topology
        Machine     = $machine
        State       = $State
        Accepted    = [string[]]@($accepted)
        Data        = $data
        Bundle      = @{ Path = $BundlePath; Sha256 = $(if ($BundleSha256) { $BundleSha256.ToLowerInvariant() } else { $null }) }
        HostKey     = $HostKeyFingerprint
        PathCheck   = $pathCheck
        RootsPath   = Join-Path $RepoRoot 'manifests/recovery-roots.json'
        Tools       = @{
            RestoreSecrets = Join-Path $PSScriptRoot 'tools/Restore-StackSecrets.ps1'
            StackCapture   = Join-Path $PSScriptRoot 'tools/StackCapture.psm1'
        }
        Own         = $ownership.Own
        Keep        = $ownership.Keep
        IsOwned     = $ownership.IsOwned
        RemoveOwned = $ownership.RemoveOwned
        Say         = { param([string]$Text) Write-Information -MessageData "    $Text" -InformationAction Continue }
    }
}

function Invoke-StageScript([string]$Script, [string]$Mode, [hashtable]$Context) {
    try {
        $r = & $Script -Mode $Mode -Context $Context
        $r = @($r | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Status'] }) | Select-Object -Last 1
        if ($null -eq $r) { throw [InvalidOperationException]::new('the stage script returned no result') }
        return $r
    }
    catch {
        $r = New-StageResult -Status 'failed'
        $r.Problems.Add("stopped: $($_.Exception.Message)")
        return $r
    }
}

function Format-StageReport([int]$Number, [string]$Label, $Run, $Check, [string]$Final) {
    "Stage $Number  $($catalogue[$Number].Title)  [$Label]"
    foreach ($r in @($Run, $Check)) {
        if ($null -eq $r) { continue }
        foreach ($s in $r.Steps) { "  - $s" }
        foreach ($c in $r.Checks) {
            $mark = if ($c.Ok) { 'CHECK ok  ' } else { 'CHECK FAIL' }
            "  $mark $($c.What): $($c.Actual)" + $(if (-not $c.Ok) { " (expected $($c.Expected))" } else { '' })
        }
        foreach ($a in $r.Asks) { if ($a.Id) { "  ASK      [$($a.Id)] $($a.Text)" } else { "  ASK      $($a.Text)" } }
        foreach ($w in $r.Warnings) { "  WARN     $w" }
        foreach ($p in $r.Problems) { "  PROBLEM  $p" }
    }
    if ($Final) { "  Result: $Final" }
}

function Write-Evidence([int]$Number, [int]$Attempt, $Run, $Check, [string]$Final, [string[]]$Report) {
    $folder = Join-Path $StateRoot 'evidence'
    $base = Join-Path $folder ('stage-{0:D2}-attempt-{1}' -f $Number, $Attempt)
    if (-not (& $pathCheck -Path "$base.json", "$base.txt" -Root $StateRoot)) { throw [InvalidOperationException]::new("the evidence folder fails the path check: $folder") }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { $null = New-FolderChain -Path $folder }
    $body = [ordered]@{
        stage    = $Number
        attempt  = $Attempt
        finished = [DateTime]::UtcNow.ToString('o')
        status   = $Final
        run      = $Run
        check    = $Check
    }
    [IO.File]::WriteAllText("$base.json", ($body | ConvertTo-Json -Depth 12) + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines("$base.txt", [string[]]$Report, [Text.UTF8Encoding]::new($false))
    return "$base.json"
}

function Invoke-Plan {
    $statePath = Join-Path $StateRoot 'state.json'
    $state = Read-RecoveryState -Path $statePath
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("Invoke-StackRecovery  [PLAN]  state: $statePath$(if (-not (Test-Path -LiteralPath $statePath)) { ' (none yet)' })")
    foreach ($n in $stageNumbers) {
        $status = Get-StageStatus $state $n
        $script = Get-StageScript $n
        $suffix = if ($catalogue[$n].Elevated) { '; needs admin' } else { '' }
        if (-not $script) { $lines.Add("Stage $n  $($catalogue[$n].Title)  [not built yet: Module $($catalogue[$n].Module)]"); continue }
        if ($status -eq 'done') { $lines.Add("Stage $n  $($catalogue[$n].Title)  [done$suffix]"); continue }
        $waiting = @($catalogue[$n].Needs | Where-Object { (Get-StageStatus $state $_) -ne 'done' })
        if ($waiting) {
            $lines.Add("Stage $n  $($catalogue[$n].Title)  [$status; waits for Stage $($waiting -join ', ')$suffix]")
            continue
        }
        $context = Get-StageContext $n $state $statePath 'Plan'
        $plan = Invoke-StageScript $script 'Plan' $context
        foreach ($l in (Format-StageReport $n "$status$suffix" $plan $null $null)) { $lines.Add($l) }
    }
    $next = Get-NextStage $state
    $lines.Add($(if ($next) { "Next: Stage $next. Run again with -Execute." } else { 'Next: nothing is ready to run.' }))
    return @{ Mode = 'Plan'; Stage = $next; Status = 'planned'; Lines = $lines.ToArray() }
}

function Invoke-ElevatedChild([int]$Number, [string]$Token) {
    $quote = { param($v) '"' + $v + '"' }
    # -Accept answers are already in state.json, where the child reads them.
    $arguments = @('-NoProfile', '-File', (& $quote $PSCommandPath), '-Execute', '-Stage', $Number, '-LockToken', $Token,
        '-TopologyPath', (& $quote $TopologyPath), '-RepoRoot', (& $quote $RepoRoot), '-StateRoot', (& $quote $StateRoot),
        '-StageRoot', (& $quote $StageRoot))
    Say "Stage $Number needs admin rights: answer the Windows prompt. It runs in its own window."
    try { $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -Verb RunAs -Wait -PassThru }
    catch { throw [InvalidOperationException]::new("Stage $Number needs admin rights, and the elevated window could not start (was the prompt declined?)") }
    return $child.ExitCode
}

function Invoke-Execute {
    # Everything the controller writes is under the state root.
    if (-not (& $pathCheck -Path $StateRoot -Root $StateRoot -AllowRoot)) { throw [InvalidOperationException]::new("the state root fails the path check: $StateRoot") }
    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) { $null = New-FolderChain -Path $StateRoot }
    $statePath = Join-Path $StateRoot 'state.json'
    $lockId = Enter-RecoveryLock -StateRoot $StateRoot -Token $LockToken
    try {
        $state = Read-RecoveryState -Path $statePath
        $number = if ($Stage) { $Stage } else { Get-NextStage $state }
        if (-not $number) {
            $unbuilt = @($stageNumbers | Where-Object { -not (Get-StageScript $_) })
            if (@($stageNumbers | Where-Object { (Get-StageStatus $state $_) -ne 'done' }).Count -eq 0) {
                return @{ Stage = $null; Status = 'done'; Lines = @('Every stage is done.') }
            }
            $text = if ($unbuilt) { "No stage is ready. Not built yet: Stage $($unbuilt -join ', ')." } else { 'No stage is ready.' }
            return @{ Stage = $null; Status = 'needs-user'; Lines = @($text) }
        }
        $info = $catalogue[$number]
        $script = Get-StageScript $number
        if (-not $script) { return @{ Stage = $number; Status = 'failed'; Lines = @("Stage $number is not built yet (Module $($info.Module)).") } }

        # Everything this stage needs must be done and still pass.
        foreach ($need in $info.Needs) {
            if ((Get-StageStatus $state $need) -ne 'done') { return @{ Stage = $number; Status = 'failed'; Lines = @("Stage $number needs Stage $need first.") } }
            $needScript = Get-StageScript $need
            $recheck = Invoke-StageScript $needScript 'Check' (Get-StageContext $need $state $statePath 'Check')
            if ($recheck.Status -ne 'passed') {
                $lines = @("Stage $need's checkpoint no longer passes, so Stage $number does not run. Run -Stage $need -Execute to redo it.") +
                @(Format-StageReport $need 'CHECK AGAIN' $null $recheck $null)
                return @{ Stage = $number; Status = 'failed'; Lines = $lines }
            }
        }
        if ($number -ne 1) {
            $why = Get-ReleaseProblem $state
            if ($why) { return @{ Stage = $number; Status = 'failed'; Lines = @("Stage $number does not run: $why. Check out the release, or run -Stage 1 -Execute again.") } }
        }

        $key = "$number"
        if ($state['stages'][$key] -isnot [hashtable]) { $state['stages'][$key] = @{ status = 'not started'; attempts = 0; accepted = @(); data = @{} } }
        $entry = $state['stages'][$key]
        $entry['accepted'] = [string[]]@(@($entry['accepted']) + @($Accept) | Where-Object { $_ } | Select-Object -Unique)
        Save-RecoveryState -State $state -Path $statePath

        if ($info.Elevated -and -not (& $machine.IsElevated)) {
            if (-not $onWindows) { return @{ Stage = $number; Status = 'failed'; Lines = @("Stage $number needs admin rights.") } }
            $code = Invoke-ElevatedChild $number $lockId
            $state = Read-RecoveryState -Path $statePath
            $entry = $state['stages']["$number"]
            $report = if ($entry -is [hashtable] -and $entry['evidence']) { [IO.Path]::ChangeExtension($entry['evidence'], '.txt') } else { $null }
            $lines = if ($report -and (Test-Path -LiteralPath $report)) { @(Get-Content -LiteralPath $report) } else { @("The elevated window ended with exit code $code and left no report.") }
            $status = ($exitCodes.GetEnumerator() | Where-Object { $_.Value -eq $code -and $_.Key -ne 'planned' } | Select-Object -First 1).Key
            return @{ Stage = $number; Status = $(if ($status) { $status } else { 'failed' }); Lines = $lines }
        }
        if (-not $info.Elevated -and (& $machine.IsElevated) -and $onWindows) {
            Say "WARN: this window is elevated. Stage $number does not need it, and what it creates would belong to the administrators group; a normal window is better."
        }

        $wiped = @()
        if ($entry['status'] -eq 'running') {
            Say "Stage $number was interrupted last time; removing what it created and starting it again."
            $wiped = @(Clear-StageOwned -State $state -StatePath $statePath -Stage $number)
        }
        $entry['attempts'] = [int]$entry['attempts'] + 1
        $entry['status'] = 'running'
        $entry['started'] = [DateTime]::UtcNow.ToString('o')
        Save-RecoveryState -State $state -Path $statePath

        Say "Stage $number  $($info.Title): running (attempt $($entry['attempts']))"
        $context = Get-StageContext $number $state $statePath 'Run'
        $run = Invoke-StageScript $script 'Run' $context
        foreach ($w in $wiped) { $run.Warnings.Add("after the interruption: $w") }
        foreach ($k in $run.Data.Keys) { $entry['data'][$k] = $run.Data[$k] }
        $check = $null
        $final = $run.Status
        if ($run.Status -eq 'done') {
            $check = Invoke-StageScript $script 'Check' (Get-StageContext $number $state $statePath 'Check')
            $final = switch ($check.Status) { 'passed' { 'done' } 'needs-user' { 'needs-user' } default { 'failed' } }
        }
        if ($final -notin 'done', 'failed', 'needs-user', 'reboot') { $final = 'failed' }
        if ($final -eq 'done') {
            # A finished stage's output is never wiped by a later attempt.
            foreach ($o in @(Get-OwnedItem -State $state -Stage $number -Retry 'wipe')) { $o['retry'] = 'keep' }
            if ($number -eq 1) { $state['release'] = Get-Release }
        }

        $report = @(Format-StageReport $number 'EXECUTE' $run $check $null)
        $evidence = Write-Evidence $number $entry['attempts'] $run $check $final $report
        if ($info.Bundle) {
            $bundleRoot = $null
            if ($state['stages']['1'] -is [hashtable] -and $state['stages']['1']['data'] -is [hashtable]) { $bundleRoot = $state['stages']['1']['data']['BundleRoot'] }
            if ($bundleRoot -and (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
                $files = @(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'evidence') -File | ForEach-Object FullName) + @($statePath)
                $hits = @(Test-EvidenceSecretFree -EvidencePath $files -BundleRoot $bundleRoot)
                if ($hits) {
                    # The report itself may hold the value: keep only its title.
                    $final = 'failed'
                    $run = $null
                    $check = $null
                    $report = @($report[0])
                    foreach ($hit in $hits) {
                        if ($hit -eq $statePath) { $report += '  PROBLEM  state.json holds a value from the secrets bundle; delete it by hand and start again from Stage 1' }
                        else { Remove-Item -LiteralPath $hit -Force; $report += "  PROBLEM  $([IO.Path]::GetFileName($hit)) held a value from the secrets bundle and was deleted" }
                    }
                }
            }
        }
        $entry['status'] = $final
        $entry['finished'] = [DateTime]::UtcNow.ToString('o')
        $entry['evidence'] = $evidence
        Save-RecoveryState -State $state -Path $statePath

        $next = Get-NextStage $state
        $report += switch ($final) {
            'done' { "  Result: done. Checkpoint $number passed.$(if ($next) { " Next: Stage $next; run the same command again." } else { '' })" }
            'needs-user' { '  Result: needs you. Do what the ASK lines say, then run the same command again.' }
            'reboot' { "  Result: restart the PC, then run the same command again; Stage $number carries on." }
            default { '  Result: failed. Fix the problems above and run the same command again.' }
        }
        [IO.File]::WriteAllLines([IO.Path]::ChangeExtension($evidence, '.txt'), [string[]]$report, [Text.UTF8Encoding]::new($false))
        return @{ Stage = $number; Status = $final; Lines = $report; Run = $run; Check = $check }
    }
    finally {
        if (-not $LockToken) { Exit-RecoveryLock -StateRoot $StateRoot -Token $lockId }
    }
}

# ---------- Main ----------
try {
    $topology = Read-Topology
    if (-not $StateRoot) { $StateRoot = $topology['controller']['stateRoot'] }
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    $outcome = if ($Execute) { Invoke-Execute } else { Invoke-Plan }
}
catch {
    $outcome = @{ Stage = $Stage; Status = 'failed'; Lines = @("PROBLEM  $($_.Exception.Message)") }
}

if ($PassThru) {
    return [pscustomobject]@{
        Mode   = $(if ($Execute) { 'Execute' } else { 'Plan' })
        Stage  = $outcome['Stage']
        Status = $outcome['Status']
        Lines  = [string[]]$outcome['Lines']
        Run    = $(if ($outcome.ContainsKey('Run')) { $outcome['Run'] } else { $null })
        Check  = $(if ($outcome.ContainsKey('Check')) { $outcome['Check'] } else { $null })
    }
}
$outcome['Lines'] | ForEach-Object { Write-Output $_ }
exit $exitCodes[$outcome['Status']]
