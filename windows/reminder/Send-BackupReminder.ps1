#Requires -Version 7.0
<#
.SYNOPSIS
    The monthly backup check (docs/RESTORE.md Stage 10, C-47): one ntfy
    notification to pc-info saying what to do.

.DESCRIPTION
    Stage 10 of the recovery copies this file next to NtfyCore.psm1 in the
    stack's _support\scripts\scheduled folder and registers the task
    OWUI-ntfy-BackupReminder (windows\reminder\OWUI-ntfy-BackupReminder.xml),
    which runs it at 10:00 on the 1st of every month, or at the next sign-in
    after that. It replaces the retired backup tasks: the secrets bundle
    lives in Bitwarden only, so a person collects and uploads it.

    It sends one notification and writes its run to ntfy-monitor.log, like
    the other ntfy scripts. Exit code 1 when ntfy did not take it.
#>
[CmdletBinding()]
param()

Import-Module (Join-Path $PSScriptRoot 'NtfyCore.psm1') -Force
Write-NtfyLog '=== Send-BackupReminder run ==='

$message = @(
    '1. git -C E:\recovery switch main, git -C E:\recovery pull, then: pwsh -File E:\recovery\tools\Collect-StackSecrets.ps1 -Execute'
    '2. Upload the new stack-secrets ZIP to its Bitwarden item; put the SHA-256 it printed in the notes.'
    '3. Download it again into E:\recovery-secrets and check Get-FileHash gives the same SHA-256 (the round trip).'
    '4. Delete the run folder and the download with Shift+Delete. Commit the new seed in manifests\owui-seed\seed and push.'
    'Do the same after changing any key, token, tool, function or model preset.'
) -join "`n"

$sent = Send-Ntfy -Title 'Monthly backup check' -Message $message -Topic 'pc-info' -Priority 3 -Tags @('floppy_disk')
if (-not $sent) { exit 1 }
