# Quick health + auth check for the gmail-owui-bridge.
# Reads GMAIL_BRIDGE_API_KEY from .env so you don't paste the key.

$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:18101"

$key = $null
if (Test-Path ".\.env") {
    foreach ($line in Get-Content ".\.env") {
        if ($line -match '^\s*GMAIL_BRIDGE_API_KEY\s*=\s*"?([^"]*)"?\s*$') {
            $key = $Matches[1]
        }
    }
}
$headers = @{}
if ($key) { $headers["X-API-Key"] = $key }

Write-Host "== /health ==" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$base/health" | ConvertTo-Json -Depth 5
} catch {
    Write-Host "health failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Is the container up? -> docker compose ps" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n== /auth/status ==" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$base/auth/status" -Headers $headers | ConvertTo-Json -Depth 5
} catch {
    Write-Host "auth/status failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n== /profile (only works once authorised) ==" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$base/profile" -Headers $headers | ConvertTo-Json -Depth 5
} catch {
    Write-Host "profile not available yet (authorise via /auth/url first)." -ForegroundColor Yellow
}
