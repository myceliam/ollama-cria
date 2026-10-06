#Requires -Version 7.0
<#
    Start-NotifiedJob.ps1 - item 30. Wrap any slow command so it announces
    itself on ntfy when it lands, instead of you checking a terminal.
    Created 2026-09-11 (see AI-CHANGELOG.csv).

    Success  -> pc-info,  priority 2, only if it took longer than -MinSeconds.
    Failure  -> pc-alert, priority 5, always, with the error text.

    EXAMPLES
      pwsh -File Start-NotifiedJob.ps1 -Name "Model pull" -Command "ollama pull qwen3:32b"
      pwsh -File Start-NotifiedJob.ps1 -Name "Weekly prune" -Command "docker system prune -af" -MinSeconds 30

    Also usable from any script:
      Import-Module "E:\ai\ollama\_support\scripts\scheduled\NtfyCore.psm1"
      Invoke-NtfyJob -Name "Whatever" -Script { ...your code... }
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Command,
    [int]$MinSeconds = 120
)

Import-Module "$PSScriptRoot\NtfyCore.psm1" -Force

Invoke-NtfyJob -Name $Name -MinSeconds $MinSeconds -Script {
    $out = Invoke-Expression $Command 2>&1 | Out-String
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw ("exit code {0}`n{1}" -f $LASTEXITCODE, ($out -split "`r?`n" | Select-Object -Last 5 | Join-String -Separator "`n"))
    }
    Write-Output $out
}
