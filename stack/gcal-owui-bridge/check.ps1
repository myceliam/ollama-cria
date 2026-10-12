# Quick diagnostic for the gcal-owui-bridge. Run:  .\check.ps1
$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:18100"

# pull the API key straight from .env so you don't have to type it
$envFile = Join-Path $PSScriptRoot ".env"
$key = (Select-String -Path $envFile -Pattern 'GCAL_BRIDGE_API_KEY="?([^"]+)"?').Matches.Groups[1].Value
$hdr = @{ "X-API-Key" = $key }

Write-Host "`n==== 1. Service health ====" -ForegroundColor Cyan
try {
  $h = Invoke-RestMethod "$base/health"
  Write-Host ("ok={0}  authenticated={1}  client_secret_present={2}" -f $h.ok, $h.authenticated, $h.client_secret_present)
} catch { Write-Host "BRIDGE UNREACHABLE: $($_.Exception.Message)" -ForegroundColor Red; return }

Write-Host "`n==== 2. Auth status ====" -ForegroundColor Cyan
try { (Invoke-RestMethod "$base/auth/status" -Headers $hdr) | Format-List authenticated, token_path }
catch { Write-Host "auth/status error: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n==== 3. Calendars known ====" -ForegroundColor Cyan
try {
  $c = Invoke-RestMethod "$base/calendars" -Headers $hdr
  Write-Host ("count = {0}" -f $c.count)
  $c.calendars | ForEach-Object { Write-Host (" - {0}  (selected={1}, role={2})" -f $_.summary, $_.selected, $_.access_role) }
} catch { Write-Host "calendars error: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n==== 4. Sync status (the cache) ====" -ForegroundColor Cyan
try {
  $s = Invoke-RestMethod "$base/sync/status" -Headers $hdr
  Write-Host ("rows = {0}" -f $s.count)
  $s.sync_state | ForEach-Object { Write-Host (" - {0}: full={1} incr={2} err={3}" -f $_.summary, $_.last_full_sync, $_.last_incremental_sync, $_.last_error) }
} catch { Write-Host "sync/status error: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n==== 5. LIVE events (next 180 days) ====" -ForegroundColor Cyan
try {
  $e = Invoke-RestMethod "$base/events/live" -Headers $hdr
  Write-Host ("live count = {0}" -f $e.count) -ForegroundColor Green
  $e.events | Select-Object -First 15 | ForEach-Object { Write-Host (" - {0}  [{1}]" -f $_.title, $_.start) }
} catch { Write-Host "events/live error: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n==== 6. Forcing a fresh full sync now ====" -ForegroundColor Cyan
try {
  $f = Invoke-RestMethod -Method POST "$base/sync/full" -Headers $hdr -ContentType "application/json" -Body "{}"
  Write-Host ("full sync: calendars={0}" -f $f.calendar_count)
  $f.results | ForEach-Object { Write-Host (" - {0}: events_synced={1} err={2}" -f $_.calendar_id, $_.events_synced, $_.error) }
} catch { Write-Host "sync/full error: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`nDone.`n" -ForegroundColor Cyan
