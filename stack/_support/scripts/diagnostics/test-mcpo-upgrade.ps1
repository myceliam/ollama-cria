# ============================================================
#  test-mcpo-upgrade.ps1
#  Safely test whether a NEWER mcpo image fixes the wedged-session
#  bug (500 "MCP session is not available" after a cancelled call)
#  WITHOUT touching your pinned production image.
#
#  What it does:
#    1. Reads your current pinned digest from Dockerfile.mcpo.
#    2. `docker pull ghcr.io/open-webui/mcpo:main` -> new digest.
#       (Note: upstream mcpo CODE rarely changes; the real lever is a
#        newer `mcp` Python SDK dep, where the cancel-scope bug lives.
#        That's exactly what this rebuild pulls in.)
#    3. Builds a throwaway image `mcpo-core-baked:test` from the new
#       digest (reusing your Dockerfile.mcpo, FROM line swapped).
#    4. Runs a throwaway container `mcpo-core-test` on :18001 with a
#       MINIMAL config (cve_nvd + time only) so boot is fast & quiet.
#    5. Reproduces the wedge: fires a slow search_cves and aborts it
#       client-side (= the cancellation that poisons the session),
#       then probes an offline tool.
#         - probe ALIVE  -> newer image looks FIXED.
#         - probe 500 "session not available" -> still broken.
#    6. Cleans up the test container/image and prints exact re-pin
#       steps if you want to adopt the new digest.
#
#  Run from E:\ai\ollama in PowerShell (Docker reachable). Read-only
#  to production: never stops/rebuilds mcpo-core.
# ============================================================
$ErrorActionPreference = 'Stop'
$root        = $PSScriptRoot
$dockerfile  = Join-Path $root 'Dockerfile.mcpo'
$envFile     = Join-Path $root '.env'
$testTag     = 'mcpo-core-baked:test'
$testName    = 'mcpo-core-test'
$testPort    = 18001
$buildDir    = Join-Path $env:TEMP 'mcpo-upgrade-test'

function Info($m){ Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[ok] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

# ---- read MCPO_API_KEY + current FROM digest ---------------
$apiKey = (Select-String -Path $envFile -Pattern '^\s*MCPO_API_KEY\s*=\s*(.+)$').Matches.Groups[1].Value.Trim().Trim('"')
if (-not $apiKey) { Write-Error 'MCPO_API_KEY not found in .env'; exit 2 }

$fromLine = (Select-String -Path $dockerfile -Pattern '^FROM\s+ghcr\.io/open-webui/mcpo').Line
$curDigest = ($fromLine -split '@')[1]
Info "Current pinned base: $curDigest"

# ---- pull latest :main and read its digest -----------------
Info 'Pulling ghcr.io/open-webui/mcpo:main ...'
docker pull ghcr.io/open-webui/mcpo:main | Out-Null
$newDigest = (docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/open-webui/mcpo:main)
$newDigest = ($newDigest -split '@')[1]
Info "Latest :main digest:  $newDigest"

if ($newDigest -eq $curDigest) {
  Warn 'Latest :main is the SAME digest you already run. Nothing newer to test.'
  Warn 'The wedge is an mcpo/mcp-SDK limitation, not a stale image -> rely on the watchdog.'
  exit 0
}

$hdr = @{ Authorization = "Bearer $apiKey" }
$probeBody  = '{"timezone":"Europe/London"}'   # local/instant 'time' tool (always exists)
$slowBody   = '{"query":"linux kernel privilege escalation","severity":"","limit":20}'

function Probe([int]$port){
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/time/get_current_time" -Method Post `
           -Headers $hdr -Body $probeBody -ContentType 'application/json' -TimeoutSec 15 -SkipHttpErrorCheck
    if ([int]$r.StatusCode -eq 500 -and "$($r.Content)" -match '(?i)session is not available') { return 'wedged' }
    if ([int]$r.StatusCode -lt 500) { return 'alive' }
    return 'wedged'
  } catch { return 'unreachable' }
}

try {
  # ---- build throwaway image from the new digest -----------
  Info "Staging build in $buildDir"
  if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
  Copy-Item (Join-Path $root 'mcpo-entrypoint.sh') $buildDir
  # Copy Dockerfile with the FROM digest swapped to the new one.
  (Get-Content $dockerfile) -replace [regex]::Escape($curDigest), $newDigest |
    Set-Content (Join-Path $buildDir 'Dockerfile.mcpo')
  # Minimal config: only the servers we need to test.
  # cve_nvd spawned EXACTLY like production (don't introduce a new variable).
  @'
{
  "mcpServers": {
    "cve_nvd": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/mukul975/cve-mcp-server@809953e04c1db4eaa3b808747e16711d23964af4", "cve-mcp"]
    },
    "time": { "command": "uvx", "args": ["mcp-server-time@2026.6.4", "--local-timezone=Europe/London"] }
  }
}
'@ | Set-Content (Join-Path $buildDir 'mcpo-core-config.test.json')

  Info 'Building mcpo-core-baked:test (this can take a few minutes the first time)...'
  docker build -f (Join-Path $buildDir 'Dockerfile.mcpo') -t $testTag $buildDir | Out-Null
  Ok 'Test image built.'

  # ---- run throwaway container ----------------------------
  docker rm -f $testName 2>$null | Out-Null
  Info "Starting $testName on :$testPort"
  docker run -d --name $testName --env-file $envFile `
    -p "127.0.0.1:${testPort}:8000" `
    -v "${buildDir}\mcpo-core-config.test.json:/app/config.json:ro" `
    $testTag `
    mcpo --host 0.0.0.0 --port 8000 --api-key $apiKey --config /app/data/config.runtime.json | Out-Null

  Info 'Waiting for boot (mcpo brings up all MCP servers; allow ~200s)...'
  $alive = $false
  for ($i=0; $i -lt 26; $i++) {        # up to ~260s
    Start-Sleep -Seconds 10
    if ((Probe $testPort) -eq 'alive') { $alive = $true; break }
  }
  if (-not $alive) {
    Warn 'Test container never became healthy. Inspect:  docker logs mcpo-core-test --tail 80'
    exit 1
  }
  Ok 'Test container healthy. Baseline probe = alive.'

  # ---- reproduce the wedge: cancel a slow call ------------
  Info 'Firing a slow search_cves and aborting it mid-flight (forces the cancellation)...'
  try {
    Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/cve_nvd/search_cves" -Method Post `
      -Headers $hdr -Body $slowBody -ContentType 'application/json' -TimeoutSec 2 -SkipHttpErrorCheck | Out-Null
  } catch { }   # the client-side timeout IS the cancellation we want
  Start-Sleep -Seconds 2

  $verdict = Probe $testPort
  Write-Host ''
  Write-Host '====================  RESULT  ====================' -ForegroundColor Magenta
  switch ($verdict) {
    'alive'       { Ok    "Session SURVIVED the cancelled call -> the newer image looks FIXED. :)" }
    'wedged'      { Warn  "Session WEDGED after cancel (same bug). Newer image does NOT fix it -> keep the watchdog." }
    'unreachable' { Warn  "Container unreachable after the test (it may have crashed). Inconclusive -> check docker logs." }
  }
  Write-Host '=================================================' -ForegroundColor Magenta

  if ($verdict -eq 'alive') {
    Write-Host ''
    Info 'To ADOPT the new image, edit Dockerfile.mcpo line ~21 FROM ... to:'
    Write-Host "    FROM ghcr.io/open-webui/mcpo:main@$newDigest" -ForegroundColor White
    Info 'Then rebuild + roll just mcpo-core:'
    Write-Host '    docker compose build mcpo-core; docker compose up -d mcpo-core' -ForegroundColor White
  }
}
finally {
  # ---- always clean up the throwaway resources ------------
  Info 'Cleaning up test container/image...'
  docker rm -f $testName 2>$null | Out-Null
  docker image rm $testTag 2>$null | Out-Null
  if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
  Ok 'Done. Production mcpo-core was never touched.'
}
