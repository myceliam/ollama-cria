#Requires -Version 7.4
<#
.SYNOPSIS
    The rebuild menu: one window that takes you from a fresh Windows to the
    whole stack, one step at a time (docs/FULL-REBUILD-HUMAN.md).

.DESCRIPTION
    Start it with Start-Recovery.cmd, which runs this in PowerShell 7
    (Install-PowerShell7.cmd installs that first).

    Steps 1a, 1b, 2 and 3 get the PC ready; steps 4 to 14 run the
    controller's Stages 1 to 11 (Invoke-StackRecovery.ps1). In every step
    the menu checks what it can, does what it can for you once you say yes,
    and asks about the rest one question at a time until the step passes.
    It saves after every answer, so a restart only pauses it.

    Its records are menu.json and menu-log.txt in the controller's state
    root (E:\recovery-state). tools/RecoveryMenu.psm1 holds the logic.

.PARAMETER Status
    Print where the rebuild is up to, then stop. Reads the records and
    changes nothing: for an assistant helping when a step fails
    (docs/MENU-HELP-FOR-AI.md).

.PARAMETER Step
    Open this step straight away: 1a, 1b, 2, 3 ... 14.

.PARAMETER Plain
    Plain ASCII marks instead of emoji. Automatic outside Windows Terminal,
    where the old console window shows emoji as boxes.

.PARAMETER StateRoot
    Default: controller.stateRoot from the topology (tests).

.PARAMETER TopologyPath
    Default: manifests/topology.json in this repo (tests).

.EXAMPLE
    Start-Recovery.cmd

    Double-click it in E:\recovery: the menu opens.

.EXAMPLE
    pwsh -File E:\recovery\Start-Recovery.ps1 -Status

    Where the rebuild is up to, as plain text.
#>
[CmdletBinding()]
param(
    [switch]$Status,

    [ValidatePattern('^(1a|1b|[2-9]|1[0-4])$')]
    [string]$Step,

    [switch]$Plain,

    [string]$StateRoot,

    [string]$TopologyPath = (Join-Path $PSScriptRoot 'manifests/topology.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'tools/RecoveryMenu.psm1') -Force

if ($Status) {
    $ctx = New-MenuContext -RepoRoot $PSScriptRoot -TopologyPath $TopologyPath -StateRoot $StateRoot -ReadOnly -Plain
    Get-MenuStatusText -Ctx $ctx | Write-Output
    return
}

try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $Host.UI.RawUI.WindowTitle = 'ollama-cria rebuild menu'
}
catch { Write-Verbose "The console keeps its own encoding and title: $($_.Exception.Message)" }

$ctx = New-MenuContext -RepoRoot $PSScriptRoot -TopologyPath $TopologyPath -StateRoot $StateRoot -Plain:($Plain -or -not $env:WT_SESSION)
Start-RecoveryMenu -Ctx $ctx -Step $Step
