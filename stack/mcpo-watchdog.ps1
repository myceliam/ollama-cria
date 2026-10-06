# ============================================================
#  mcpo-watchdog.ps1  —  auto-heal a wedged mcpo session
#
#  WHY: a cancelled/timed-out tool call (NVD keyword searches are
#  slow, and hitting "Stop" mid-call cancels the in-flight request)
#  poisons mcpo's persistent stdio MCP session. mcpo's own
#  reconnect logic can't repair the corrupted anyio task group, so
#  the route returns:
#      500 {'message': 'MCP session is not available'}
#  for EVERY later call until the whole mcpo-core process restarts.
#  cve_nvd is the usual victim (slowest upstream); web_search too.
#
#  This watchdog POSTs a cheap, OFFLINE tool call to mcpo. If it
#  sees the "session is not available" 500 (or mcpo is unreachable),
#  it runs `docker restart mcpo-core` and confirms recovery.
#
#  Register it to run every 5 min with install-mcpo-watchdog-task.ps1
#  (or the schtasks one-liner at the bottom of that file).
#
#  Safe by design:
#   * Restarts ONLY on the exact wedge signal or unreachability.
#   * A 200/400/422 (input validation) means the session is ALIVE
#     -> never restarts on those.
#   * 5-minute cooldown via a state file prevents restart thrash.
# ============================================================
$ErrorActionPreference = 'Stop'

# ---- config ------------------------------------------------
$base        = 'http://127.0.0.1:18000'           # mcpo-core host mapping
$container   = 'mcpo-core'
$envFile     = Join-Path $PSScriptRoot '.env'
$log         = Join-Path $PSScriptRoot 'logs\mcpo-watchdog.log'
$stateFile   = Join-Path $PSScriptRoot 'logs\mcpo-watchdog.state'
$probeTimeout = 20                                 # seconds per probe
$cooldownMin  = 6                                  # min minutes between restarts (>= boot window)
$bootGraceSec = 210                                # mcpo needs ~200s to bring ALL MCP servers up.
                                                   # Never restart (or judge failed) inside this window.
$alertOnFail  = $true                              # popup if it can't recover

New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

function Log($msg) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $log -Value $line
  Write-Host $line
}

# ============================================================
#  STACK CHECKS (added 2026-07-16) — remote-access chain + OWUI
#  Runs BEFORE the mcpo probe so mcpo's early exits can't skip it.
#  Heals: Tailscale service stopped, tailnet offline, missing
#  serve config, dead OWUI container. Emails lrooney234@gmail.com
#  via the gmail bridge ON STATE TRANSITIONS ONLY, so an outage is
#  visible from the phone even when the tailnet path itself is down
#  (email rides normal internet). If the email says the PC side is
#  healthy, the problem is the phone's Tailscale.
# ============================================================
$stackState = Join-Path $PSScriptRoot 'logs\stack-watchdog.state.json'
$alertTo    = 'lrooney234@gmail.com'

function Send-StackAlert([string]$subject, [string]$body) {
  try {
    $gk = (& docker exec gmail-owui-bridge printenv GMAIL_BRIDGE_API_KEY 2>$null)
    if (-not $gk) { Log 'alert: gmail bridge key unavailable (container down?) - email skipped'; return }
    $payload = @{ to = @($alertTo); subject = $subject; body = $body; confirm = $true } | ConvertTo-Json
    Invoke-WebRequest -Uri 'http://127.0.0.1:18101/messages/send' -Method Post `
      -Headers @{ 'X-API-Key' = ("$gk").Trim() } -Body $payload -ContentType 'application/json' `
      -TimeoutSec 20 | Out-Null
    Log ("alert emailed: {0}" -f $subject)
  } catch { Log ("alert email FAILED: {0}" -f $_.Exception.Message) }
}

function Test-StackHealth([string]$url) {
  try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing).StatusCode -eq 200) } catch { return $false }
}

$checks = [ordered]@{}   # component -> 'ok' | 'healed' | 'down'

# -- 1) Tailscale Windows service ------------------------------
try {
  $svc = Get-Service -Name 'Tailscale' -ErrorAction Stop
  if ($svc.Status -ne 'Running') {
    Log 'TAILSCALE: service not running -> starting'
    Start-Service -Name 'Tailscale'; Start-Sleep 10
    $checks['tailscale-service'] = 'healed'
  } else { $checks['tailscale-service'] = 'ok' }
} catch { Log 'TAILSCALE: service not found - skipping service check'; $checks['tailscale-service'] = 'ok' }

# -- 2) tailnet online ------------------------------------------
try {
  $ts = (& tailscale status --json 2>$null | ConvertFrom-Json)
  if ($ts -and -not $ts.Self.Online) {
    Log 'TAILSCALE: self reports OFFLINE -> restarting service'
    Restart-Service -Name 'Tailscale' -ErrorAction SilentlyContinue; Start-Sleep 15
    $ts2 = (& tailscale status --json 2>$null | ConvertFrom-Json)
    $checks['tailscale-online'] = $(if ($ts2 -and $ts2.Self.Online) { 'healed' } else { 'down' })
  } else { $checks['tailscale-online'] = 'ok' }
} catch { $checks['tailscale-online'] = 'down' }

# -- 3) serve config (443->OWUI is the one that matters) --------
$serveOut = (& tailscale serve status 2>$null) -join "`n"
if ($serveOut -match '127\.0\.0\.1:3000') {
  $checks['tailscale-serve'] = 'ok'
} else {
  Log 'TAILSCALE: serve config missing -> re-applying (443->OWUI, 444->ComfyUI, 9000->Dozzle, 2000->docker site, 8443->ntfy)'
  & tailscale serve --bg --https=443 http://127.0.0.1:3000   2>&1 | ForEach-Object { Log "  serve: $_" }
  & tailscale serve --bg --https=444 http://127.0.0.1:8188   2>&1 | ForEach-Object { Log "  serve: $_" }
  & tailscale serve --bg --https=9000 http://127.0.0.1:18088 2>&1 | ForEach-Object { Log "  serve: $_" }
  & tailscale serve --bg --https=2000 http://127.0.0.1:6080  2>&1 | ForEach-Object { Log "  serve: $_" }
  # 8443 -> ntfy. Without this the phone silently stops receiving push after any
  # serve-config loss, with nothing else in the stack looking broken.
  & tailscale serve --bg --https=8443 http://127.0.0.1:8090  2>&1 | ForEach-Object { Log "  serve: $_" }
  $serveOut2 = (& tailscale serve status 2>$null) -join "`n"
  $checks['tailscale-serve'] = $(if ($serveOut2 -match '127\.0\.0\.1:3000') { 'healed' } else { 'down' })
}

# -- 4) OWUI local health (restart container if dead) -----------
if (Test-StackHealth 'http://127.0.0.1:3000/health') {
  $checks['open-webui'] = 'ok'
} else {
  $owuiUp = $null
  try {
    $sa = (& docker inspect -f '{{.State.StartedAt}}' open-webui 2>$null)
    if ($sa) { $owuiUp = ((Get-Date).ToUniversalTime() - ([datetime]$sa).ToUniversalTime()).TotalSeconds }
  } catch { }
  if ($null -ne $owuiUp -and $owuiUp -ge 0 -and $owuiUp -lt 120) {
    Log 'OWUI: unhealthy but container started <120s ago - boot grace, leaving it.'
    $checks['open-webui'] = 'down'
  } else {
    Log 'OWUI: local /health FAILED -> docker restart open-webui'
    & docker restart -t 30 open-webui 2>&1 | ForEach-Object { Log "  docker: $_" }
    Start-Sleep 45
    $checks['open-webui'] = $(if (Test-StackHealth 'http://127.0.0.1:3000/health') { 'healed' } else { 'down' })
  }
}

# -- 5) end-to-end tailnet URL (informational: proves the whole PC-side chain)
$checks['tailnet-url'] = $(if (Test-StackHealth 'https://{{PC_TS_NAME}}/health') { 'ok' } else { 'down' })

# -- alert on transitions only ----------------------------------
$prevState = $null
if (Test-Path $stackState) { try { $prevState = Get-Content $stackState -Raw | ConvertFrom-Json } catch { } }
$transitions = @()
foreach ($k in @($checks.Keys)) {
  $now = $checks[$k]
  $was = if ($prevState -and $prevState.PSObject.Properties[$k]) { $prevState.$k } else { 'ok' }
  if ($now -eq 'healed') { $transitions += "[HEALED] $k - auto-repaired this cycle" }
  elseif ($now -eq 'down' -and $was -ne 'down') { $transitions += "[DOWN] $k - auto-heal failed or not possible from the PC" }
  elseif ($now -ne 'down' -and $was -eq 'down') { $transitions += "[RECOVERED] $k - healthy again" }
}
$checks | ConvertTo-Json | Set-Content $stackState
Log ('stack: ' + (($checks.Keys | ForEach-Object { "$_=$($checks[$_])" }) -join ' '))
if ($transitions.Count -gt 0) {
  $alertBody = @("Stack watchdog on PC - state change at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'):", '') + $transitions + @('',
    ('Current: ' + (($checks.Keys | ForEach-Object { "$_=$($checks[$_])" }) -join ', ')), '',
    "If you cannot reach OWUI from your phone but everything above is ok/healed, the problem is the PHONE's Tailscale - open the app, reconnect, and check Always-on VPN + battery optimisation.") -join "`n"
  Send-StackAlert 'Stack watchdog: state change on PC' $alertBody
}
# ================== end stack checks ==========================

# ---- get the EXACT key mcpo enforces: read it from the RUNNING container.
#      mcpo checks  Authorization: Bearer <token>  where token == its --api-key
#      (== MCPO_API_KEY in the container env). Reading it from the container
#      avoids .env CRLF / quote / rotation drift — the cause of the earlier 401s.
$apiKey = $null
try {
  $k = (& docker exec $container printenv MCPO_API_KEY 2>$null)
  if ($k) { $apiKey = ("$k").Trim() }
} catch { }
if (-not $apiKey) {
  # container down or exec blocked -> fall back to a HARDENED .env parse
  if (Test-Path $envFile) {
    foreach ($l in Get-Content $envFile) {
      if ($l -match '^\s*MCPO_API_KEY\s*=\s*(.+?)\s*$') {
        $apiKey = $matches[1].Trim().Trim('"').Trim("'").TrimEnd([char]13); break   # strip quotes + stray CR
      }
    }
    if ($apiKey) { Log 'NOTE: read key from .env (container exec unavailable).' }
  }
}
if (-not $apiKey) { Log 'FATAL: could not obtain MCPO_API_KEY (container down AND no .env).'; exit 2 }
$hdr = @{ Authorization = "Bearer $apiKey" }

# ---- one probe -> 'alive' | 'wedged' | 'unreachable' | 'authfail' | 'skip'
function Test-Route([string]$path, [string]$jsonBody) {
  $url = "$base/$path"
  try {
    $r = Invoke-WebRequest -Uri $url -Method Post -Headers $hdr `
           -Body $jsonBody -ContentType 'application/json' `
           -TimeoutSec $probeTimeout -SkipHttpErrorCheck
    $code = [int]$r.StatusCode
    $body = "$($r.Content)"
    if ($code -eq 401) { return 'authfail' }                   # key mismatch -> a restart can't fix this
    if ($code -eq 404) { return 'skip' }                       # tool/route name mismatch
    if ($code -eq 500 -and $body -match '(?i)session is not available') { return 'wedged' }
    if ($code -ge 200 -and $code -lt 500) { return 'alive' }   # 200/400/422 = session reachable
    return 'wedged'                                            # any other 5xx -> recover
  }
  catch {
    return 'unreachable'                                       # timeout / refused / DNS = down or hung
  }
}

# ---- run the probe ----------------------------------------
# time/get_current_time: local + instant, exercises the stdio session, and
# detects the GLOBAL wedge (the cancel-scope bug drops ALL sessions at once,
# so one healthy probe is enough — no need to hammer NVD via cve_nvd).
$probe = Test-Route 'time/get_current_time' '{"timezone":"Europe/London"}'
Log ("probe time/get_current_time -> {0}" -f $probe)

if ($probe -eq 'authfail') {
  Log 'AUTH FAIL (401): watchdog key != container --api-key. NOT restarting (a restart cannot fix auth).'
  Log '  Fix: align MCPO_API_KEY in .env with the running container, then: docker compose up -d --force-recreate mcpo-core'
  if ($alertOnFail) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("mcpo watchdog: 401 auth mismatch.`nWatchdog key != running container --api-key.`nAlign MCPO_API_KEY in .env, then recreate mcpo-core.", 'mcpo watchdog', 'OK', 'Warning') | Out-Null
  }
  exit 0
}
if ($probe -eq 'alive' -or $probe -eq 'skip') { Log 'OK: mcpo session healthy.'; exit 0 }

$reason = if ($probe -eq 'wedged') { 'wedged session detected' } else { 'mcpo unreachable' }

# ---- boot-grace guard --------------------------------------
# mcpo spawns ALL its MCP servers on startup (~200s). During that window
# routes legitimately 500/refuse — restarting now would kill a healthy
# boot and could loop forever. If the container started < $bootGraceSec
# ago, assume it's still warming up and DO NOT touch it.
function Get-ContainerUptimeSec($name) {
  try {
    $startedAt = (& docker inspect -f '{{.State.StartedAt}}' $name 2>$null)
    if (-not $startedAt) { return $null }                 # not created / not found
    $running = (& docker inspect -f '{{.State.Running}}' $name 2>$null)
    if ($running -ne 'true') { return -1 }                # exists but stopped -> definitely needs a start
    return ((Get-Date).ToUniversalTime() - ([datetime]$startedAt).ToUniversalTime()).TotalSeconds
  } catch { return $null }
}
$uptime = Get-ContainerUptimeSec $container
if ($null -ne $uptime -and $uptime -ge 0 -and $uptime -lt $bootGraceSec) {
  Log ("WARMING UP: {0}, but mcpo only started {1:N0}s ago (< {2}s boot grace). Leaving it to finish booting." -f $reason, $uptime, $bootGraceSec)
  exit 0
}

# ---- cooldown: don't thrash --------------------------------
if (Test-Path $stateFile) {
  $last = Get-Content $stateFile -Raw
  try {
    $lastDt = [datetime]::ParseExact($last.Trim(), 'yyyy-MM-dd HH:mm:ss', $null)
    $mins = ((Get-Date) - $lastDt).TotalMinutes
    if ($mins -lt $cooldownMin) {
      Log ("HOLD: {0}, but last restart was {1:N1} min ago (< {2} cooldown). Skipping." -f $reason, $mins, $cooldownMin)
      exit 0
    }
  } catch { }
}

# ---- restart ----------------------------------------------
Log ("RESTART: {0} -> docker restart {1}" -f $reason, $container)
(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Set-Content $stateFile
try {
  $out = & docker restart -t 30 $container 2>&1
  Log ("docker: {0}" -f ($out -join ' '))
} catch {
  Log ("ERROR running docker restart: {0}" -f $_.Exception.Message)
}

# ---- confirm recovery ---------------------------------------
# mcpo needs the full boot window (~200s) to bring every MCP server back.
# Poll past $bootGraceSec before declaring failure, so we never false-alarm
# on a server that's simply still starting.
Log ("Waiting up to {0}s for mcpo to finish bringing all MCP servers back up..." -f $bootGraceSec)
$deadline = (Get-Date).AddSeconds($bootGraceSec + 30)
$recovered = $false
Start-Sleep -Seconds 30                              # let the process actually come back first
while ((Get-Date) -lt $deadline) {
  $recheck = Test-Route 'time/get_current_time' '{"timezone":"Europe/London"}'
  if ($recheck -eq 'alive') { $recovered = $true; break }
  Start-Sleep -Seconds 15
}
if ($recovered) {
  Log 'RECOVERED: mcpo responding after restart.'
  Send-StackAlert 'Stack watchdog: mcpo auto-healed' ("mcpo-core was $reason and was restarted at $(Get-Date -Format 'HH:mm:ss'). It has recovered and is answering probes again. No action needed.")
} else {
  Log ("STILL UNHEALTHY after restart + {0}s. Deeper look needed: docker logs {1} --tail 120" -f $bootGraceSec, $container)
  Send-StackAlert 'Stack watchdog: mcpo restart did NOT recover' ("mcpo-core was $reason, was restarted, and is still unhealthy after ~$bootGraceSec s. Check: docker logs $container --tail 120")
  if ($alertOnFail) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      "mcpo-core was $reason and did not recover within ~$bootGraceSec s of a restart.`nCheck: docker logs $container --tail 120",
      'mcpo watchdog', 'OK', 'Warning') | Out-Null
  }
}
