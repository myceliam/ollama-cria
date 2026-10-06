[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunnerPath,
    [Parameter(Mandatory)] [string] $CommandBase64,
    [Parameter(Mandatory)] [string] $WorkingDirectoryBase64,
    [Parameter(Mandatory)] [int] $TimeoutSeconds,
    [Parameter(Mandatory)] [int] $MaxOutputChars,
    [Parameter(Mandatory)] [string] $ResultPath
)

$ErrorActionPreference = 'Stop'

function Write-FailureResult {
    param([string] $Status, [string] $Message)
    $result = [ordered]@{
        status = $Status
        exit_code = $null
        stdout = ''
        stderr = $Message
        timed_out = $false
        output_truncated = $false
    }
    $result | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding utf8
}

try {
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-File', $RunnerPath,
        '-CommandBase64', $CommandBase64,
        '-WorkingDirectoryBase64', $WorkingDirectoryBase64,
        '-TimeoutSeconds', [string]$TimeoutSeconds,
        '-MaxOutputChars', [string]$MaxOutputChars,
        '-ResultPath', $ResultPath
    )
    $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if (-not (Test-Path -LiteralPath $ResultPath)) {
        Write-FailureResult -Status 'elevation_failed' -Message "Elevated runner exited $($process.ExitCode) without a result."
    }
}
catch [System.ComponentModel.Win32Exception] {
    Write-FailureResult -Status 'elevation_cancelled' -Message 'Windows UAC elevation was cancelled or denied.'
}
catch {
    Write-FailureResult -Status 'elevation_failed' -Message "Elevation failed: $($_.Exception.GetType().Name)"
}
