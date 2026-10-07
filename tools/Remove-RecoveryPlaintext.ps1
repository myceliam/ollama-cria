#Requires -Version 7.4
<#
.SYNOPSIS
    Removes the plaintext secrets the controller created or was handed: the
    unpacked bundle, the bundle ZIP, download tokens and their header files
    (docs/RESTORE.md Stage 11).

.DESCRIPTION
    Reads the controller's state.json. Every item recorded there as
    plaintext is handled deepest first:

      - its path must still pass tools/Test-RecoveryPath.ps1 against the
        root it was recorded with;
      - it must still be the object the controller recorded (the same
        identity); a link or junction is never followed, on the way or
        inside a folder;
      - then it is removed and its record dropped.

    A recorded folder that is itself a root (the staging folder) is removed
    last, and only when nothing is left in it. Anything else in it was not
    created by the controller: it is listed by name, never removed.

    Two modes:

      Plan (the default). Lists what would be removed. Changes nothing.

      -Execute. Removes, under the controller's lock.

    Exit code 0 when nothing plaintext is left, 1 when something is.

.PARAMETER StateRoot
    The controller's state folder. Default: E:\recovery-state.

.PARAMETER Execute
    Remove. Without it the script only lists.

.PARAMETER PassThru
    Return the rows instead of printing them and setting the exit code.

.EXAMPLE
    ./tools/Remove-RecoveryPlaintext.ps1

.EXAMPLE
    ./tools/Remove-RecoveryPlaintext.ps1 -Execute
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$StateRoot = 'E:\recovery-state',

    [switch]$Execute,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RecoveryState.psm1')

$rows = [Collections.Generic.List[object]]::new()
$problems = [Collections.Generic.List[string]]::new()
$statePath = Join-Path $StateRoot 'state.json'
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Add-Row([string]$Path, [string]$Status) {
    $rows.Add([pscustomobject]@{ Path = $Path; Status = $Status })
}

function Invoke-Removal {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { $problems.Add("no controller state at $statePath"); return }
    $state = Read-RecoveryState -Path $statePath
    $items = @(Get-OwnedItem -State $state -Plaintext | Sort-Object { $_['path'].Length } -Descending)
    # Roots (the staging folder) last, and only when empty.
    $containers = @($items | Where-Object { $_['kind'] -eq 'folder' -and $_['path'].Equals($_['root'], $comparison) })
    $trees = @($items | Where-Object { $_ -notin $containers })
    foreach ($item in $trees) {
        if (-not $state['owned'].Contains($item)) { continue }
        if (-not $Execute) {
            $identity = Get-ItemIdentity $item['path']
            Add-Row $item['path'] $(if ($null -eq $identity) { 'already gone' } elseif ($identity -ne $item['identity']) { 'changed since it was recorded; would be left' } else { 'would remove' })
            continue
        }
        $r = Remove-OwnedItem -State $state -StatePath $statePath -Item $item
        Add-Row $item['path'] $(switch ($r) {
                'removed' { 'removed' }
                'gone' { 'already gone' }
                'changed' { 'left: another item is there now' }
                'link' { 'left: a link or junction is on the way or inside' }
                'path' { 'left: it fails the path check now' }
                default { "left: $r" }
            })
    }
    foreach ($item in $containers) {
        $path = $item['path']
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { Add-Row $path 'already gone'; continue }
        # In plan, what this run would remove does not count.
        $left = @(Get-ChildItem -LiteralPath $path -Force | Where-Object {
                $full = $_.FullName
                $Execute -or -not @($trees | Where-Object { $_['path'].Equals($full, $comparison) }).Count
            } | ForEach-Object Name)
        if ($left.Count) { Add-Row $path "left: not empty ($($left.Count) items the controller did not create: $($left -join ', '))"; continue }
        if (-not $Execute) { Add-Row $path 'would remove once empty'; continue }
        $r = Remove-OwnedItem -State $state -StatePath $statePath -Item $item
        Add-Row $path $(if ($r -eq 'removed') { 'removed' } else { "left: $r" })
    }
}

try {
    if ($Execute) {
        $lockId = Enter-RecoveryLock -StateRoot $StateRoot
        try { Invoke-Removal } finally { Exit-RecoveryLock -StateRoot $StateRoot -Token $lockId }
    }
    else { Invoke-Removal }
}
catch {
    $problems.Add("stopped: $($_.Exception.Message)")
}

$leftOver = @($rows | Where-Object { $_.Status -like 'left*' }).Count
$result = [pscustomobject]@{
    Mode     = if ($Execute) { 'Execute' } else { 'Plan' }
    IsClean  = ($problems.Count -eq 0 -and $leftOver -eq 0)
    Rows     = $rows.ToArray()
    Problems = $problems.ToArray()
}
if ($PassThru) { return $result }

Write-Output "Remove-RecoveryPlaintext  [$($result.Mode.ToUpperInvariant())]  state: $statePath"
foreach ($r in $rows) { Write-Output "  $($r.Status.PadRight(14))  $($r.Path)" }
foreach ($p in $problems) { Write-Output "  PROBLEM  $p" }
if (-not $result.IsClean) { Write-Output 'Result: something plaintext is left; see above.'; exit 1 }
Write-Output $(if ($Execute) { 'Result: every plaintext item the controller recorded is gone.' } else { 'Result: plan only. Run again with -Execute to remove.' })
exit 0
