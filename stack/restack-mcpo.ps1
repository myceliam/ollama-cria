# ============================================================
#  restack-mcpo.ps1  —  full rebuild + recreate of the stack
#  Built to run from an SSH session (where 'docker' is often
#  not on PATH — this script finds docker.exe for you).
# ============================================================
$ErrorActionPreference = 'Stop'

# 1) Always operate from the project folder (SSH may drop you elsewhere)
Set-Location 'E:\ai\ollama'

# 2) Ensure docker.exe is reachable. SSH sessions usually don't inherit
#    Docker Desktop's PATH, so add its bin dir if 'docker' isn't found.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $bin = 'C:\Program Files\Docker\Docker\resources\bin'
    if (Test-Path (Join-Path $bin 'docker.exe')) {
        $env:Path = "$bin;$env:Path"
        Write-Host "[i] Added Docker bin to PATH for this session." -ForegroundColor DarkGray
    } else {
        Write-Error "docker.exe not found. Is Docker Desktop installed and running?"
        exit 1
    }
}

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

Step "docker compose down";                          docker compose down
Step "docker compose build";                         docker compose build
Step "docker compose up -d --force-recreate";        docker compose up -d --force-recreate
Step "waiting 45s for MCP servers to connect...";    Start-Sleep -Seconds 45
Step "mcpo-core logs (last 120 lines)";              docker compose logs mcpo-core --tail 120

Write-Host "`n[done] stack restacked." -ForegroundColor Green
