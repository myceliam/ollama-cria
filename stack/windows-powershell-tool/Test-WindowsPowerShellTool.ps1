[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSCommandPath
$stackRoot = Split-Path -Parent $toolRoot
$config = Get-Content -LiteralPath (Join-Path $toolRoot 'config.json') -Raw | ConvertFrom-Json
$variableName = [string]$config.token_environment_variable
$envLine = Get-Content -LiteralPath (Join-Path $stackRoot '.env') | Where-Object { $_ -match "^$([regex]::Escape($variableName))=" } | Select-Object -Last 1
if (-not $envLine) { throw "$variableName not found" }
$token = $envLine.Substring($variableName.Length + 1).Trim()
$baseUrl = "http://$($config.bind_host):$($config.port)"
$headers = @{ Authorization = "Bearer $token" }

$health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 10
if ($health.status -ne 'ok') { throw 'Health endpoint failed.' }

$read = Invoke-RestMethod -Method Post -Uri "$baseUrl/execute" -Headers $headers -ContentType 'application/json' -Body (@{
    mode = 'read'; requested_access = 'read'; reason = 'installation smoke test'
    command = 'Get-Date | Select-Object -Property DateTime'; timeout_seconds = 20
} | ConvertTo-Json) -TimeoutSec 30
if ($read.status -ne 'ok' -or $read.exit_code -ne 0) { throw "Read smoke test failed: $($read.status)" }

$sentinel = Join-Path $toolRoot 'state\read-mode-must-not-create.txt'
Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
$denied = Invoke-RestMethod -Method Post -Uri "$baseUrl/execute" -Headers $headers -ContentType 'application/json' -Body (@{
    mode = 'read'; requested_access = 'read'; reason = 'prove read fence'
    command = "Set-Content -LiteralPath '$sentinel' -Value forbidden"; timeout_seconds = 20
} | ConvertTo-Json) -TimeoutSec 30
if ($denied.status -ne 'read_policy_denied' -or (Test-Path -LiteralPath $sentinel)) { throw 'Read fence failed.' }

$unrequestedElevation = Invoke-RestMethod -Method Post -Uri "$baseUrl/execute" -Headers $headers -ContentType 'application/json' -Body (@{
    mode = 'read_write_elevated'; requested_access = 'read'; reason = 'prove broker elevation invariant'
    command = 'Get-Date'; timeout_seconds = 20
} | ConvertTo-Json) -TimeoutSec 30
if ($unrequestedElevation.status -ne 'elevation_not_requested') { throw 'Broker accepted elevation without an explicit elevated request.' }

$writeSentinel = Join-Path $toolRoot 'state\read-write-smoke.txt'
Remove-Item -LiteralPath $writeSentinel -Force -ErrorAction SilentlyContinue
$write = Invoke-RestMethod -Method Post -Uri "$baseUrl/execute" -Headers $headers -ContentType 'application/json' -Body (@{
    mode = 'read_write'; requested_access = 'read_write'; reason = 'installation smoke test'
    command = "Set-Content -LiteralPath '$writeSentinel' -Value ok"; timeout_seconds = 20
} | ConvertTo-Json) -TimeoutSec 30
if ($write.status -ne 'ok' -or -not (Test-Path -LiteralPath $writeSentinel)) { throw 'Read/write smoke test failed.' }
Remove-Item -LiteralPath $writeSentinel -Force

[pscustomobject]@{
    Health = 'PASS'
    Read = 'PASS'
    ReadPolicyDenial = 'PASS'
    ReadWrite = 'PASS'
    ExplicitElevationRequest = 'PASS - lower-privilege request cannot be upgraded'
    Elevated = 'NOT FIRED - requires an explicit popup choice plus Windows UAC'
} | Format-List
