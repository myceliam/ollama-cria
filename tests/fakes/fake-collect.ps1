# Test stand-in for tools/Collect-StackSecrets.ps1 -Execute -PassThru, used
# by tests/Stage-10-Rehearsal.Tests.ps1. It makes an owner-only run folder
# in -StagingRoot holding a ZIP of made-up bytes, writes one seed file to
# -SeedOut and returns what the collector's -PassThru returns.
# $global:CriaCollect sets what it does:
#   Fail      a problem to report; the run folder is left, the seed is not
#             written
# Every call is added to $global:CriaCollect.Calls.
[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$StagingRoot,
    [string]$SshHost,
    [string]$SeedOut,
    [string]$HelperImage,
    [string]$DockerCommand,
    [string]$SshCommand,
    [string]$TailscaleCommand,
    [switch]$PassThru
)
$fake = $global:CriaCollect
$fake.Calls.Add([pscustomobject]@{
        Execute = [bool]$Execute; StagingRoot = $StagingRoot; SshHost = $SshHost; SeedOut = $SeedOut; HelperImage = $HelperImage
        DockerCommand = $DockerCommand; SshCommand = $SshCommand; TailscaleCommand = $TailscaleCommand; PassThru = [bool]$PassThru
    })
$stamp = 'stack-secrets-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('n').Substring(0, 6)
$run = Join-Path $StagingRoot $stamp
Initialize-ProtectedFolder -Path $run
$zip = Join-Path $run "$stamp.zip"
[IO.File]::WriteAllBytes($zip, [Security.Cryptography.RandomNumberGenerator]::GetBytes(64))
$sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$ok = -not $fake['Fail']
if ($ok) {
    $null = New-Item -ItemType Directory -Path $SeedOut -Force
    [IO.File]::WriteAllText((Join-Path $SeedOut 'config.json'), '{}')
}
[pscustomobject]@{
    Mode        = 'Execute'
    IsValid     = $ok
    Rows        = @()
    Problems    = @(if (-not $ok) { $fake['Fail'] })
    Warnings    = @()
    BitLocker   = 'On'
    RunFolder   = $run
    ZipPath     = $(if ($ok) { $zip } else { $null })
    ZipSha256   = $(if ($ok) { $sha } else { $null })
    SeedOut     = $(if ($ok) { $SeedOut } else { $null })
    SeedFiles   = $(if ($ok) { 1 } else { 0 })
    SeedSummary = $null
}
