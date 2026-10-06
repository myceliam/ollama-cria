# ============================================================
#  restart-stack.ps1  —  full, clean reboot of the OWUI/Ollama Docker stack
#
#  Created 2026-08-05 to apply the tool-server boot-order fix (mcpo-core
#  healthcheck + open-webui depends_on: service_healthy).
#
#  What it does, in order:
#    1. Make docker.exe reachable (Task-Scheduler safe)
#    2. docker compose down          (containers only — NEVER touches volumes)
#    3. Hand off to start-stack.ps1  (owns the Docker/Ollama waits + up -d)
#    4. Verify the fix actually took: mcpo healthy, OWUI started AFTER it,
#       and mcpo's aggregate spec reachable from inside the OWUI container
#
#  Safety notes:
#    - `docker compose down` WITHOUT -v. Named volumes (owui-data, mcpo-core-data,
#      bolt-data) survive. Losing owui-data would mean losing every chat.
#    - Native Windows Ollama is NOT restarted — it lives outside compose and
#      restarting it risks the tray-auto-updater race (see docs). start-stack.ps1
#      will start it only if it is not already serving.
#
#  Usage:  pwsh -File E:\ai\ollama\restart-stack.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
Set-Location 'E:\ai\ollama'

# --- Logging -------------------------------------------------------------
$logDir = 'E:\ai\ollama\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("restart-stack-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $logFile -Append | Out-Null } catch {}
Get-ChildItem $logDir -Filter 'restart-stack-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [ok]  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!!]  $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "    [XX]  $m" -ForegroundColor Red }

Write-Host "=== FULL STACK RESTART  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Magenta

# --- 1) docker on PATH ---------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $bin = 'C:\Program Files\Docker\Docker\resources\bin'
    if (Test-Path (Join-Path $bin 'docker.exe')) {
        $env:Path = "$bin;$env:Path"
    } else {
        Bad "docker.exe not found. Is Docker Desktop installed?"
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }
}

# --- 2) Validate compose BEFORE tearing anything down --------------------
Step "Validating docker-compose.yml..."
docker compose config --quiet
if ($LASTEXITCODE -ne 0) {
    Bad "docker-compose.yml is invalid — ABORTING before shutdown. Nothing was changed."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
Ok "Compose file parses cleanly."

# --- 3) Bring the stack down (containers only) ---------------------------
Step "Stopping the stack (docker compose down — volumes preserved)..."
docker compose down --remove-orphans
if ($LASTEXITCODE -ne 0) { Warn "compose down returned $LASTEXITCODE — continuing anyway." }
else { Ok "Stack stopped." }

Start-Sleep -Seconds 3

# --- 4) Hand off to start-stack.ps1 --------------------------------------
Step "Bringing the stack back up via start-stack.ps1..."
$start = 'E:\ai\ollama\start-stack.ps1'
if (-not (Test-Path $start)) {
    Warn "start-stack.ps1 missing — falling back to a plain 'docker compose up -d --build'."
    docker compose up -d --build
} else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start
    if ($LASTEXITCODE -ne 0) { Warn "start-stack.ps1 exited $LASTEXITCODE — verifying anyway." }
}

# --- 5) Verify the boot-order fix ---------------------------------------
Step "Verifying the tool-server boot-order fix..."

# 5a) mcpo-core must report healthy
$health = ''
for ($i = 0; $i -lt 30; $i++) {
    $health = (docker inspect --format '{{.State.Health.Status}}' mcpo-core 2>$null)
    if ($health -eq 'healthy') { break }
    Start-Sleep -Seconds 5
}
if ($health -eq 'healthy') { Ok "mcpo-core health = healthy" }
else { Bad "mcpo-core health = '$health' (expected 'healthy') — OWUI may have started without it." }

# 5b) open-webui must have started AFTER mcpo went healthy
try {
    $mcpoStart = [datetime](docker inspect --format '{{.State.StartedAt}}' mcpo-core)
    $owuiStart = [datetime](docker inspect --format '{{.State.StartedAt}}' open-webui)
    if ($owuiStart -gt $mcpoStart) {
        Ok ("open-webui started {0:N0}s after mcpo-core — correct order." -f ($owuiStart - $mcpoStart).TotalSeconds)
    } else {
        Bad "open-webui started BEFORE mcpo-core — depends_on is not taking effect."
    }
} catch { Warn "Could not compare container start times: $_" }

# 5c) OWUI must be able to reach mcpo's aggregate spec, and it must list servers
$specOk = docker exec open-webui sh -c 'curl -fsS -o /dev/null -w "%{http_code}" http://mcpo-core:8000/openapi.json' 2>$null
if ($specOk -eq '200') {
    Ok "open-webui -> mcpo-core/openapi.json = 200"
} else {
    Bad "open-webui cannot reach mcpo-core/openapi.json (got '$specOk')."
}

# 5e) Per-server function counts. A server can return 200 with "paths": {} —
#     live endpoint, zero tools, invisible failure. This catches that.
#     (Was an inline `sh -c` one-liner; PowerShell mangled the nested quotes
#     and it died with "Unterminated quoted string". Use a real file instead.)
$chk = 'E:\ai\ollama\check-mcpo-tools.py'
if (Test-Path $chk) {
    docker cp $chk mcpo-core:/tmp/chk.py 2>&1 | Out-Null
    $out = docker exec mcpo-core python3 /tmp/chk.py 2>&1
    $out | ForEach-Object { Write-Host "    $_" }
    if ($out -match 'ZERO-FUNCTION SERVERS') {
        Bad "Some servers are serving ZERO functions — see the list above."
        Warn "One server failing at startup can cancel every server initialised"
        Warn "AFTER it in config order. Fix the FIRST failure in the log:"
        Warn "  docker logs mcpo-core | Select-String 'Failed to establish'"
    } else {
        Ok "All mcpo servers are serving functions."
    }
    docker exec mcpo-core rm -f /tmp/chk.py 2>&1 | Out-Null
} else {
    Warn "check-mcpo-tools.py not found — skipping per-server function count."
}

# 5d) OWUI health endpoint
try {
    $r = Invoke-WebRequest 'http://127.0.0.1:3000/health' -UseBasicParsing -TimeoutSec 10
    if ($r.StatusCode -eq 200) { Ok "open-webui /health = 200" } else { Warn "open-webui /health = $($r.StatusCode)" }
} catch { Bad "open-webui /health unreachable: $_" }

Write-Host "`n=== DONE ===" -ForegroundColor Magenta
Write-Host "Log: $logFile" -ForegroundColor DarkGray
Write-Host "NOTE: after this restart, hard-reload the Open WebUI window once" -ForegroundColor Yellow
Write-Host "      (Ctrl+Shift+R) so the browser drops its cached tool list." -ForegroundColor Yellow

try { Stop-Transcript | Out-Null } catch {}
