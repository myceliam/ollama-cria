[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSCommandPath
$stackRoot = Split-Path -Parent $toolRoot
$envFile = Join-Path $stackRoot '.env'
$config = Get-Content -LiteralPath (Join-Path $toolRoot 'config.json') -Raw | ConvertFrom-Json
$variableName = [string]$config.token_environment_variable

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Stack .env file not found: $envFile"
}

$match = Get-Content -LiteralPath $envFile | Where-Object { $_ -match "^$([regex]::Escape($variableName))=" } | Select-Object -Last 1
if (-not $match) {
    throw "$variableName is absent from $envFile. Run Install-WindowsPowerShellTool.ps1."
}
$tokenValue = $match.Substring($variableName.Length + 1).Trim()
if (-not $tokenValue) {
    throw "$variableName is empty in $envFile."
}
[Environment]::SetEnvironmentVariable($variableName, $tokenValue, [EnvironmentVariableTarget]::Process)

$bindHost = [string]$config.bind_host
$deadline = [DateTime]::UtcNow.AddMinutes(2)
while ([DateTime]::UtcNow -lt $deadline) {
    if (Get-NetIPAddress -IPAddress $bindHost -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Seconds 2
}
if (-not (Get-NetIPAddress -IPAddress $bindHost -ErrorAction SilentlyContinue)) {
    throw "Bind address $bindHost is not present after waiting two minutes."
}

& 'C:\Python313\python.exe' (Join-Path $toolRoot 'server.py')
exit $LASTEXITCODE
