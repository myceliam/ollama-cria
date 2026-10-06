# ============================================================
#  start-stack.ps1  —  idempotent "everything comes online" boot
#  Run this after a reboot (or any time) to bring the whole
#  OWUI / Ollama stack up cleanly. Safe to run repeatedly.
#
#  What it does, in order:
#    1. Make docker.exe reachable (SSH/Task-Scheduler safe)
#    2. Wait for the Docker engine to actually be ready
#    3. Make sure NATIVE Windows Ollama is serving on :11434
#    4. docker compose up -d --build   (builds mcpo/gcal/Discord bridge if missing)
#    5. Health-check the key endpoints and report
#
#  For a *full* rebuild after changing Dockerfile.mcpo or the
#  pinned config, use restack-mcpo.ps1 instead (down+build+recreate).
# ============================================================
$ErrorActionPreference = 'Stop'
Set-Location 'E:\ai\ollama'

# --- Logging: keep a transcript so scheduled (headless) runs are debuggable ---
$logDir = 'E:\ai\ollama\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("start-stack-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $logFile -Append | Out-Null } catch {}
# Prune logs older than 14 days
Get-ChildItem $logDir -Filter 'start-stack-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [ok]  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!!]  $msg" -ForegroundColor Yellow }

# --- 1) Ensure docker.exe is on PATH -------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $bin = 'C:\Program Files\Docker\Docker\resources\bin'
    if (Test-Path (Join-Path $bin 'docker.exe')) {
        $env:Path = "$bin;$env:Path"
        Write-Host "[i] Added Docker bin to PATH for this session." -ForegroundColor DarkGray
    } else {
        Write-Error "docker.exe not found. Is Docker Desktop installed?"; exit 1
    }
}

# --- 2) Wait for the Docker engine to be ready ---------------------------
#     Cold boot: Docker Desktop can take 1-3 min to expose the engine.
#     We OWN the wait here (up to ~6 min) instead of failing fast and
#     relying on Task Scheduler retries.
Step "Waiting for Docker engine (up to 6 min on a cold boot)..."
$dockerReady = $false
for ($i = 0; $i -lt 120; $i++) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { $dockerReady = $true; break }
    if ($i -eq 0) {
        # Engine not up yet — nudge Docker Desktop to launch.
        $dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
        if (Test-Path $dd) { Start-Process $dd; Write-Host "    starting Docker Desktop..." -ForegroundColor DarkGray }
    }
    if ($i % 10 -eq 0 -and $i -gt 0) { Write-Host "    still waiting... ($($i*3)s)" -ForegroundColor DarkGray }
    Start-Sleep -Seconds 3
}
if (-not $dockerReady) { Write-Error "Docker engine never became ready (~6 min)."; try { Stop-Transcript | Out-Null } catch {}; exit 1 }
Ok "Docker engine is up."

# --- 3) Ensure NATIVE Windows Ollama is serving --------------------------
#     Ollama runs on the host (host.docker.internal:11434), NOT in compose,
#     so OWUI sees zero models until it's running.
Step "Checking native Ollama on :11434..."
function Test-Ollama {
    try { Invoke-WebRequest 'http://127.0.0.1:11434/api/tags' -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true }
    catch { return $false }
}
if (Test-Ollama) {
    Ok "Ollama already serving."
} else {
    Warn "Ollama not responding — starting it."
    $ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollama) { $ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" }
    if (Test-Path $ollama) {
        Start-Process $ollama -ArgumentList 'serve' -WindowStyle Hidden
        for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Seconds 2; if (Test-Ollama) { break } }
        if (Test-Ollama) { Ok "Ollama is now serving." } else { Warn "Ollama still not up — check the app manually." }
    } else {
        Warn "ollama.exe not found — install/launch the Ollama app manually."
    }
}

# --- 4) Bring the Compose stack up ---------------------------------------
#     --build guarantees the locally-built images (mcpo-core-baked:pinned,
#     gcal-owui-bridge, discord-owui-bridge) exist; it is a cached no-op when
#     nothing changed.
Step "docker compose up -d --build"
docker compose up -d --build

# --- 4b) Gmail bridge (SEPARATE compose project in .\gmail-owui-bridge) ---
#     It lives in its own subfolder = its own compose project, so the
#     'ollama' project up above never touches it. That's exactly how it got
#     orphaned once (manually stopped during an outage, unless-stopped kept
#     it down). Bring it up from its own file so it can't silently vanish.
#     --build is a cached no-op after the first build.
Step "Gmail bridge (docker compose up -d)"
$gmailCompose = 'E:\ai\ollama\gmail-owui-bridge\docker-compose.yml'
if (Test-Path $gmailCompose) {
    docker compose -f $gmailCompose up -d --build
    Ok "gmail-owui-bridge requested"
} else {
    Warn "Gmail bridge compose not found ($gmailCompose) — skipped"
}

# --- 4c) cline-dashboard (SEPARATE compose project, DIFFERENT folder) -----
#     Tailnet monitor, container name 'homelab-dashboard', listens on :6080.
#     Tailscale serves it at https://{{PC_TS_NAME}}:2000 -> 127.0.0.1:6080.
#     Lives in E:\ai\ag-startuip (not under E:\ai\ollama), so neither the
#     'ollama' compose project nor this script used to touch it. Found stopped
#     for 7 days on 2026-07-28 while :2000 was still being proxied — exactly
#     the orphaning the gmail bridge hit above. Added 2026-07-28.
#     Needs the Tailscale daemon (it bind-mounts tailscaled.sock).
Step "cline-dashboard (docker compose up -d)"
$clineCompose = 'E:\ai\ag-startuip\cline-dashboard\docker-compose.yml'
if (Test-Path $clineCompose) {
    docker compose -f $clineCompose up -d
    Ok "cline-dashboard requested"
} else {
    Warn "cline-dashboard compose not found ($clineCompose) — skipped"
}

# --- 5) Health checks ----------------------------------------------------
#     Poll each endpoint until it answers. mcpo-core + gcal get recreated by
#     --build, so they boot fresh and need longer than a single-shot check.
#     Any HTTP response (even 401/404/"invalid request") means the port is
#     listening = service alive.
function Wait-Http {
    param([string]$Name, [string]$Url, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            Ok "$Name"; return
        } catch {
            if ($_.Exception.Response) { Ok "$Name (responding)"; return }  # listening, non-200
            Start-Sleep -Seconds 3
        }
    }
    Warn "$Name — not reachable after ${TimeoutSec}s ($Url)"
}

# --- 4b) X server -- REMOVED 2026-09-20 -----------------------------------
#     Was: launch an X server on :0 so browser_stealth could render headed.
#     Dropped because ordinary web_research calls were opening real Chromium
#     windows across the desktop. browser_stealth is headless again, DISPLAY
#     is gone from docker-compose.yml, and the X server is uninstalled.
#     To restore: reinstall it, re-add DISPLAY, and put this step back from
#     git history. See AICL-0088.

Step "Endpoint health (polling)"
Wait-Http 'bolt (security_tools)' 'http://{{PC_TS_IP}}:3001/'            60
Wait-Http 'open-terminal'         'http://{{PC_TS_IP}}:18019/openapi.json' 60
Wait-Http 'Open WebUI'            'http://127.0.0.1:3000/health'             120
Wait-Http 'mcpo-core'             'http://127.0.0.1:18000/openapi.json'      120
Wait-Http 'VPS SearXNG via Tailscale relay' 'http://127.0.0.1:8080/config'     60
Wait-Http 'VPS Jina Reader via Tailscale relay' 'http://127.0.0.1:3001/'       60
# Wait-Http 'Discord-OWUI bridge'   'http://127.0.0.1:18102/health'             60   # retired 2026-10-05, Discord bridge removed
Wait-Http 'cline-dashboard'       'http://127.0.0.1:6080/'                    60   # tailnet monitor, served at :2000

Step "Container status"
docker compose ps

Write-Host "`n[done] Stack startup complete." -ForegroundColor Green
Write-Host "Open WebUI: http://127.0.0.1:3000  |  logs: docker compose logs -f <service>" -ForegroundColor DarkGray
try { Stop-Transcript | Out-Null } catch {}
exit 0
