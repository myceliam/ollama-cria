# ============================================================
#  sync-now.ps1  —  manually force a Google -> OWUI grid sync
#  Run anytime you don't want to wait for the 5-minute loop.
#  Double-click a shortcut to this, or run:  .\sync-now.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
Set-Location 'E:\ai\ollama\gcal-owui-bridge'

# Read the bridge API key straight from .env (never hard-code it)
$line = Get-Content .env | Where-Object { $_ -match '^GCAL_BRIDGE_API_KEY=' } | Select-Object -First 1
if (-not $line) { Write-Error 'GCAL_BRIDGE_API_KEY not found in .env'; exit 1 }
$key = ($line -replace '^GCAL_BRIDGE_API_KEY=', '').Trim().Trim('"')

$base = 'http://127.0.0.1:18100'
$h = @{ 'X-API-Key' = $key }

function Hit($label, $method, $path, $body) {
    Write-Host "==> $label" -ForegroundColor Cyan
    try {
        if ($body) {
            return Invoke-RestMethod -Uri "$base$path" -Method $method -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 120
        } else {
            return Invoke-RestMethod -Uri "$base$path" -Method $method -Headers $h -TimeoutSec 120
        }
    } catch {
        Write-Host "    ! $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# 1) freshen the local Google cache, 2) push Google -> OWUI grid, 3) show status
Hit 'Refreshing Google cache (incremental)' 'POST' '/sync/incremental' '{}' | Out-Null
$sync = Hit 'Pushing Google -> OWUI grid' 'POST' '/owui/sync'
if ($sync) { $sync | ConvertTo-Json -Depth 6 }
$status = Hit 'Grid sync status' 'GET' '/owui/status'
if ($status) { $status | ConvertTo-Json -Depth 6 }

Write-Host "`nDone. Reload OWUI -> User Menu -> Calendar to see the latest." -ForegroundColor Green
