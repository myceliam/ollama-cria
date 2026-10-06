# ============================================================================
#  owui-toolkit.ps1  —  one command to drive the whole AI stack
#  Author: built for Liam.  PowerShell 7+ (pwsh).
#
#  INSTALL (one line, run once):
#     Add-Content $PROFILE "`n. 'E:\ai\ollama\owui-toolkit.ps1'"
#  then reopen PowerShell (or run:  . $PROFILE ).
#
#  USE:
#     owuihelp              -> the menu (grouped list of every command)
#     owuihelp <cmd>        -> run that command      e.g.  owuihelp art
#     owuihelp --<cmd>      -> same, dashes are fine  e.g.  owuihelp --status
#     owuihelp <cmd> ?      -> explain it WITHOUT running (dry run)
#     owuihelp find <text>  -> search commands by name or description
#     owui                  -> short alias for owuihelp
#     art | ai | aistatus   -> thin shortcuts for the 3 you'll type most
#     aiupdate              -> update every model listed by 'ollama ls'
#     gpuwho                -> who is really holding VRAM (Task Manager lies)
#     autofree on|off       -> auto-release ComfyUI VRAM after it goes idle
#
#  STRUCTURE (reorganised 2026-07-31):
#     helpers -> inline command bodies -> $OWUI_GROUPS (menu order)
#     -> $OWUI_CMDS (registry) -> $OWUI_TASKS (scheduled tasks) -> dispatcher
#     Commands support an 'alias' field, so synonyms never need a duplicate row.
# ============================================================================

# ---- paths / constants (edit here if anything ever moves) ------------------
$Global:OWUI = [ordered]@{
    ComfyRoot  = 'E:\ai\comfyui'
    ComfyApp   = 'E:\ai\comfyui\ComfyUI'
    OllamaRoot = 'E:\ai\ollama'
    SupportScripts = 'E:\ai\ollama\_support\scripts'
    OllamaExe  = 'C:\Users\lroon\AppData\Local\Programs\Ollama\ollama.exe'
    ComfyLog   = 'E:\ai\comfyui\ComfyUI\user\comfyui_8188.log'
    Ports      = @{ ComfyUI = 8188; OWUI = 3000; Ollama = 11434; Mcpo = 18000; Gmail = 18101; Calendar = 18100 }
    GmailCompose = 'E:\ai\ollama\gmail-owui-bridge\docker-compose.yml'
    AutoFreeLog  = 'E:\ai\ollama\logs\autofree.log'
    # GB of VRAM ComfyUI must leave untouched, so Ollama always has somewhere to
    # land. autofree only reclaims AFTER a render finishes; this is the guard
    # DURING one. Set 0 to disable. Drop to 1.5 if big models (Chroma1-HD,
    # Wan 2.2) start tipping into CPU offload.
    ReserveVramGB = 0
}

# ---- little helpers --------------------------------------------------------
function _owui_admin { ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()`
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }

function _owui_port ([int]$Port) {
    try {
        $c   = [System.Net.Sockets.TcpClient]::new()
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(1500)
        $res = $ok -and $c.Connected
        if ($res) { $c.EndConnect($iar) }
        $c.Close()
        return $res
    } catch { return $false }
}

function _owui_head ($t) {
    Write-Host ''
    Write-Host ('  ' + $t) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $t.Length)) -ForegroundColor DarkCyan
}

# Run a .ps1 in-process; relaunch elevated if it needs admin and we aren't.
function _owui_runps ([string]$Path, [switch]$NeedsAdmin) {
    # Self-healing lookup. The 2026-08-28 _support reorg silently broke five rows
    # (ai/freevram, testmcpo, exposure, install-startup, install-watchdog) because
    # the paths here still pointed at the old flat layout. If a script is not where
    # a row says it is, look for it by name under _support\scripts before giving up,
    # and say so loudly rather than healing in silence.
    if (-not (Test-Path $Path)) {
        $leaf = Split-Path $Path -Leaf
        $alt  = Get-ChildItem $OWUI.SupportScripts -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($alt) {
            Write-Host "  [!] stale path in the toolkit: $Path" -ForegroundColor Yellow
            Write-Host "      found it at: $($alt.FullName) - using that. Fix the row." -ForegroundColor DarkYellow
            $Path = $alt.FullName
        } else {
            Write-Host "  [x] not found: $Path" -ForegroundColor Red
            return
        }
    }
    if ($NeedsAdmin -and -not (_owui_admin)) {
        Write-Host "  [!] needs admin - relaunching elevated..." -ForegroundColor Yellow
        Start-Process pwsh -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$Path`"") | Out-Null
        return
    }
    & $Path
}

# Unload every resident Ollama model (server stays up). Shared by art/stopllm/reset.
function _owui_stop_models {
    $exe = $OWUI.OllamaExe
    if (-not (Test-Path $exe)) { $exe = 'ollama' }
    $lines = & $exe ps 2>&1 | Select-Object -Skip 1
    foreach ($l in $lines) {
        $name = ($l -split '\s+')[0]
        if ($name) { Write-Host "  ollama stop $name" -ForegroundColor DarkGray; & $exe stop $name 2>&1 | Out-Null }
    }
    Get-Process 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Start the OWUI helper bridges (Gmail + Calendar). Idempotent — safe to re-run.
# Gmail is its OWN compose project (subfolder), so 'up'/start-stack recreate it
# from its file; Calendar rides in the main 'ollama' project so a plain start
# is enough. This is the guard against Gmail silently vanishing again.
function _owui_start_bridges {
    _owui_head 'OWUI bridges (Gmail + Calendar)'
    # Calendar: part of the main compose project — just make sure it's running.
    docker start gcal-owui-bridge 2>$null | Out-Null
    # Gmail: standalone project — prefer compose up (recreates if removed),
    # fall back to a plain start if the compose file ever moves.
    if (Test-Path $OWUI.GmailCompose) {
        docker compose -f $OWUI.GmailCompose up -d 2>&1 | Out-Null
    } else {
        docker start gmail-owui-bridge 2>$null | Out-Null
    }
    Start-Sleep 2
    foreach ($b in @(@{ n='Gmail'; p=$OWUI.Ports.Gmail }, @{ n='Calendar'; p=$OWUI.Ports.Calendar })) {
        $up = _owui_port $b.p
        $c  = if ($up) { 'Green' } else { 'Red' }
        $s  = if ($up) { 'UP  ' } else { 'DOWN' }
        Write-Host ("    {0,-10} :{1,-6} {2}" -f $b.n, $b.p, $s) -ForegroundColor $c
    }
}

# Manual, on-demand backup. Writes to the SEPARATE 'manual' stream
# (D:\owuibackups\manual\) so it never interferes with — or gets pruned by —
# the nightly 7-day rolling backups in D:\owuibackups\nightly\.
function _owui_backup {
    $script = "$($OWUI.OllamaRoot)\backup-owui.ps1"
    if (-not (Test-Path $script)) { Write-Host "  [x] backup-owui.ps1 not found at $script" -ForegroundColor Red; return }
    & $script -Mode manual
}

# Take a manual backup, then ship THAT ONE offsite. Added 2026-08-06.
# Why -Manual and not bare pushvps: bare pushvps picks the newest across BOTH
# streams, which is *normally* the one just taken - but if the 03:00 nightly ever
# lands between the two steps, the wrong folder goes. Forcing the manual stream
# removes the ambiguity entirely.
function _owui_backup_push {
    $script = "$($OWUI.OllamaRoot)\backup-owui.ps1"
    if (-not (Test-Path $script)) { Write-Host "  [x] backup-owui.ps1 not found at $script" -ForegroundColor Red; return }

    _owui_head 'Step 1/2 - manual backup'
    & $script -Mode manual
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        Write-Host "  [x] Backup failed (exit $LASTEXITCODE) - NOT pushing." -ForegroundColor Red
        return
    }

    # Confirm a manual backup actually landed before shipping anything.
    $newest = Get-ChildItem 'D:\owuibackups\manual' -Directory -Filter 'owui-brains-*' -EA SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { Write-Host '  [x] No manual backup found after the run - NOT pushing.' -ForegroundColor Red; return }
    Write-Host ("    newest manual: {0}" -f $newest.Name) -ForegroundColor DarkGray

    _owui_head 'Step 2/2 - offsite push (manual stream)'
    & "$($OWUI.OllamaRoot)\push-vps.ps1" -Manual
}

# ---- inline command bodies (the ones that aren't just a .ps1 file) ---------
function _owui_status {
    _owui_head 'Endpoints'
    $map = @(
        @{ n='ComfyUI'; p=$OWUI.Ports.ComfyUI },
        @{ n='OpenWebUI'; p=$OWUI.Ports.OWUI },
        @{ n='Ollama'; p=$OWUI.Ports.Ollama },
        @{ n='mcpo-core'; p=$OWUI.Ports.Mcpo },
        @{ n='Gmail'; p=$OWUI.Ports.Gmail },
        @{ n='Calendar'; p=$OWUI.Ports.Calendar }
    )
    foreach ($m in $map) {
        $up = _owui_port $m.p
        $c  = if ($up) { 'Green' } else { 'Red' }
        $s  = if ($up) { 'UP  ' } else { 'DOWN' }
        Write-Host ("    {0,-10} :{1,-6} {2}" -f $m.n, $m.p, $s) -ForegroundColor $c
    }

    _owui_head 'GPU'
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu `
            --format=csv,noheader,nounits | ForEach-Object {
            $f = $_ -split ',\s*'
            Write-Host ("    VRAM {0} / {1} MB   GPU {2}%" -f $f[0], $f[1], $f[2]) -ForegroundColor Gray
        }
    } else { Write-Host '    nvidia-smi not on PATH' -ForegroundColor DarkYellow }

    # 2026-07-31: the total alone was the blind spot that cost an afternoon.
    # "7.4 GB used" tells you nothing about WHO. ComfyUI's torch reservation is
    # the usual culprit and Task Manager cannot see it (session 0), so show it
    # here explicitly rather than making you go digging.
    $comfyHeld = $null
    try {
        $st = Invoke-RestMethod -Uri 'http://127.0.0.1:8188/system_stats' -TimeoutSec 4 -ErrorAction Stop
        $comfyHeld = 0
        foreach ($d in $st.devices) {
            $comfyHeld += [int][math]::Round((($d.torch_vram_total - $d.torch_vram_free) / 1MB), 0)
        }
    } catch { }

    if ($null -ne $comfyHeld) {
        $col = if ($comfyHeld -gt 2048) { 'Yellow' } else { 'Gray' }
        Write-Host ("    ComfyUI torch holding: {0} MB" -f $comfyHeld) -ForegroundColor $col
        if ($comfyHeld -gt 2048) {
            Write-Host "    tip: 'owuihelp ai' releases it now, 'owuihelp autofree on' does it automatically" -ForegroundColor DarkYellow
        }
    }

    $af = @(_owui_autofree_running)
    if ($af.Count) {
        Write-Host '    AutoFree watchdog: on' -ForegroundColor Green
    } else {
        Write-Host '    AutoFree watchdog: off  (owuihelp autofree on)' -ForegroundColor DarkYellow
    }
    Write-Host "    who holds VRAM: 'owuihelp who'" -ForegroundColor DarkGray

    _owui_head 'Resident LLM models (ollama ps)'
    $exe = if (Test-Path $OWUI.OllamaExe) { $OWUI.OllamaExe } else { 'ollama' }
    & $exe ps 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

    _owui_head 'OLLAMA_KEEP_ALIVE (non-zero since 2026-09-20)'
    $machine = [Environment]::GetEnvironmentVariable('OLLAMA_KEEP_ALIVE','Machine')
    $proc    = $env:OLLAMA_KEEP_ALIVE
    # 2026-09-20: policy REVERSED. 0 unloaded the model after every single
    # reply - including the reply that IS a tool call - so ordinary chatting
    # reloaded the LLM constantly. Non-zero is now correct; 0 is the warning.
    $col = if ($machine -eq '0' -or -not $machine) { 'Yellow' } else { 'Green' }
    Write-Host ("    Machine: {0,-6}  This session: {1}" -f ($machine ?? '<unset>'), ($proc ?? '<unset>')) -ForegroundColor $col
    if ($machine -eq '0' -or -not $machine) {
        Write-Host "    tip: 'owuihelp keepalive 2m' - at 0 the model reloads after EVERY reply" -ForegroundColor DarkYellow
    } else {
        Write-Host "    note: the model stays in VRAM this long after a reply. If a ComfyUI" -ForegroundColor DarkGray
        Write-Host "          render OOMs, 'owuihelp stopmodels' frees it immediately." -ForegroundColor DarkGray
    }
}

# Show every tailnet URL, what it proxies to, and whether that target answers.
# Added 2026-07-29 — the serve table is easy to lose track of, and a mapping
# pointing at a dead local port looks identical to a working one until you try it.
function _owui_mappings {
    $ts = 'C:\Program Files\Tailscale\tailscale.exe'

    _owui_head 'Tailnet mappings (tailscale serve)'
    if (-not (Test-Path $ts)) {
        Write-Host '    [x] tailscale.exe not found' -ForegroundColor Red
        return
    }

    $lines = & $ts serve status 2>&1
    if ($lines -match 'No serve config') {
        Write-Host '    (nothing served)' -ForegroundColor DarkGray
        return
    }

    # Parse "https://host:port" followed by "|-- / proxy http://127.0.0.1:NNNN"
    $url = $null
    $map = @()
    foreach ($l in $lines) {
        $s = "$l".Trim()
        if ($s -match '^(https?://[^\s]+)') { $url = $Matches[1].TrimEnd('/') }
        elseif ($s -match 'proxy\s+(https?://[^\s]+)' -and $url) {
            $map += [pscustomobject]@{ Tailnet = $url; Target = $Matches[1] }
            $url = $null
        }
    }

    # Friendly names for the local ports we know about.
    $known = @{
        '3000'  = 'Open WebUI'; '8188' = 'ComfyUI';    '6080'  = 'Homelab dashboard'
        '18088' = 'Dozzle';     '18000' = 'mcpo';      '8080'  = 'SearXNG'
        '18100' = 'gcal bridge';'18101' = 'gmail bridge'; '8880' = 'Kokoro TTS'
        '11434' = 'Ollama';     '18019' = 'open-terminal'; '8931' = 'Playwright MCP'
    }

    foreach ($m in $map) {
        $port = if ($m.Target -match ':(\d+)') { $Matches[1] } else { '' }
        $name = if ($known.ContainsKey($port)) { $known[$port] } else { '?' }
        $up   = if ($port) { _owui_port ([int]$port) } else { $false }
        $mark = if ($up) { 'up  ' } else { 'DOWN' }
        $col  = if ($up) { 'Green' } else { 'Red' }

        Write-Host ('    {0,-42}' -f $m.Tailnet) -ForegroundColor Yellow -NoNewline
        Write-Host ('-> {0,-24}' -f $m.Target)   -ForegroundColor Gray   -NoNewline
        Write-Host ('{0}  ' -f $mark)            -ForegroundColor $col   -NoNewline
        Write-Host $name                          -ForegroundColor DarkGray
    }

    # Local services that are listening but NOT exposed on the tailnet.
    _owui_head 'Local only (not served on the tailnet)'
    $served = $map.Target -join ' '
    $any = $false
    foreach ($p in ($known.Keys | Sort-Object { [int]$_ })) {
        if ($served -match ":$p(\b|/)") { continue }
        if (_owui_port ([int]$p)) {
            $any = $true
            Write-Host ('    127.0.0.1:{0,-8}' -f $p) -ForegroundColor DarkYellow -NoNewline
            Write-Host $known[$p] -ForegroundColor DarkGray
        }
    }
    if (-not $any) { Write-Host '    (none)' -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '    add:    tailscale serve --bg --https <port> http://127.0.0.1:<local>' -ForegroundColor DarkGray
    Write-Host '    remove: tailscale serve --https=<port> off' -ForegroundColor DarkGray
}

function _owui_keepalive ([string]$Value) {
    if (-not $Value) {
        $m = [Environment]::GetEnvironmentVariable('OLLAMA_KEEP_ALIVE','Machine')
        Write-Host "  OLLAMA_KEEP_ALIVE (Machine) = $($m ?? '<unset>')" -ForegroundColor Cyan
        Write-Host "  Set with:  owuihelp keepalive 0   (then it restarts Ollama for you)" -ForegroundColor DarkGray
        return
    }
    [Environment]::SetEnvironmentVariable('OLLAMA_KEEP_ALIVE', $Value, 'Machine')
    $env:OLLAMA_KEEP_ALIVE = $Value
    Write-Host "  Set OLLAMA_KEEP_ALIVE = $Value (Machine)." -ForegroundColor Green
    Write-Host "  Restarting Ollama so it picks up the new value..." -ForegroundColor Cyan
    Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Start-Process $OWUI.OllamaExe -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
    Write-Host "  Done. Verify with: ollama ps  (UNTIL should be seconds, not minutes)" -ForegroundColor Green
}

# ---- autofree watchdog -----------------------------------------------------
# Added 2026-07-31. ComfyUI holds model weights in VRAM after a render; on a
# 16 GB card shared with Ollama that caused repeated OOM crashes. 'owuihelp ai'
# fixes it manually, but only if you remember. This runs it for you.
function _owui_autofree_running {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*autofree-watchdog.ps1*' -and $_.CommandLine -notlike '*-Once*' }
}

# Persistence deliberately uses the per-user Startup folder, NOT schtasks.
# schtasks /SC ONLOGON requires elevation even with /RL LIMITED ("Access is
# denied" as a normal user). A Startup shortcut gives the same at-logon
# behaviour for a user-level helper with no UAC prompt, ever.
function _owui_autofree_lnk {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'OWUI ComfyUI AutoFree.lnk'
}

function _owui_autofree ([string]$Action) {
    $script = "$($OWUI.OllamaRoot)\autofree-watchdog.ps1"
    $lnk    = _owui_autofree_lnk
    if (-not (Test-Path $script)) { Write-Host "  [x] not found: $script" -ForegroundColor Red; return }

    switch ("$Action".TrimStart('-').ToLower()) {

        'on' {
            _owui_head 'AutoFree: enabling'
            # Persist across logons...
            try {
                $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
                $sh = New-Object -ComObject WScript.Shell
                $sc = $sh.CreateShortcut($lnk)
                $sc.TargetPath       = $pwshExe
                $sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
                $sc.WorkingDirectory = $OWUI.OllamaRoot
                $sc.WindowStyle      = 7   # minimised
                $sc.Description      = 'Release ComfyUI VRAM once it has been idle'
                $sc.Save()
                Write-Host '    registered at logon (Startup folder, no admin needed)' -ForegroundColor Green
            } catch {
                Write-Host "    [!] could not create startup shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host '        (it will still run for this session)' -ForegroundColor DarkGray
            }
            # ...and start it right now so you do not have to log out to get it.
            if (_owui_autofree_running) {
                Write-Host '    already running in this session' -ForegroundColor Green
            } else {
                Start-Process pwsh -ArgumentList @('-NoProfile','-WindowStyle','Hidden',
                    '-ExecutionPolicy','Bypass','-File', $script) -WindowStyle Hidden | Out-Null
                Start-Sleep 2
                Write-Host '    started' -ForegroundColor Green
            }
            Write-Host "    ComfyUI VRAM will now be released after 90s idle." -ForegroundColor Gray
            Write-Host "    Check with: owuihelp autofree status" -ForegroundColor DarkGray
        }

        'off' {
            _owui_head 'AutoFree: disabling'
            if (Test-Path $lnk) {
                Remove-Item $lnk -Force -ErrorAction SilentlyContinue
                Write-Host '    removed from Startup' -ForegroundColor Green
            } else { Write-Host '    not registered at logon' -ForegroundColor DarkGray }
            $procs = _owui_autofree_running
            if ($procs) {
                $procs | ForEach-Object {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    Write-Host "    stopped pid $($_.ProcessId)" -ForegroundColor Green
                }
            } else { Write-Host '    nothing running' -ForegroundColor DarkGray }
            Write-Host "    Manual release is still available: owuihelp ai" -ForegroundColor DarkGray
        }

        default {
            _owui_head 'AutoFree status'
            $procs = @(_owui_autofree_running)
            if ($procs.Count) {
                Write-Host ("    watchdog  : RUNNING (pid {0})" -f ($procs.ProcessId -join ', ')) -ForegroundColor Green
            } else {
                Write-Host '    watchdog  : not running' -ForegroundColor Yellow
            }

            if (Test-Path $lnk) {
                Write-Host '    at logon  : registered' -ForegroundColor Green
            } else {
                Write-Host '    at logon  : NOT registered  (owuihelp autofree on)' -ForegroundColor Yellow
            }

            if (Test-Path $OWUI.AutoFreeLog) {
                Write-Host ''
                Write-Host '    recent activity:' -ForegroundColor DarkCyan
                Get-Content $OWUI.AutoFreeLog -Tail 8 |
                    ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            } else {
                Write-Host '    (no log yet)' -ForegroundColor DarkGray
            }
            Write-Host ''
            Write-Host '    on | off | status' -ForegroundColor DarkGray
        }
    }
}

function _owui_logs {
    if (-not (Test-Path $OWUI.ComfyLog)) { Write-Host "  log not found: $($OWUI.ComfyLog)" -ForegroundColor Red; return }
    Write-Host "  Tailing $($OWUI.ComfyLog)  (Ctrl+C to stop)" -ForegroundColor Cyan
    Get-Content $OWUI.ComfyLog -Tail 40 -Wait
}

function _owui_start_comfy ([switch]$Visible) {
    $running = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*main.py*8188*' }
    if ($running) { Write-Host "  ComfyUI already running on :8188" -ForegroundColor Green; return }
    $py = Join-Path $OWUI.ComfyApp '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { Write-Host "  [x] python not found: $py" -ForegroundColor Red; return }
    $style = if ($Visible) { 'Normal' } else { 'Hidden' }

    # Built as an array so the reservation can be tuned or switched off from
    # $OWUI.ReserveVramGB without editing the call site.
    $argv = @('main.py','--listen','0.0.0.0','--port','8188')
    if ($OWUI.ReserveVramGB -and [double]$OWUI.ReserveVramGB -gt 0) {
        $argv += @('--reserve-vram', ([string]$OWUI.ReserveVramGB))
    }

    Start-Process -FilePath $py -ArgumentList $argv `
        -WorkingDirectory $OWUI.ComfyApp -WindowStyle $style | Out-Null
    if ($OWUI.ReserveVramGB -and [double]$OWUI.ReserveVramGB -gt 0) {
        Write-Host ("  reserving {0} GB VRAM for Ollama (--reserve-vram)" -f $OWUI.ReserveVramGB) -ForegroundColor DarkGray
    }
    Write-Host "  ComfyUI starting on :8188 (takes ~15-20s to bind the port)" -ForegroundColor Yellow
}

function _owui_kill_comfy {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*main.py*8188*' } |
        ForEach-Object { Write-Host "  killing ComfyUI pid $($_.ProcessId)" -ForegroundColor DarkGray; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ---- ComfyUI output housekeeping ------------------------------------------
#  Renders pile up and nothing prunes them (542 files / 792 MB when this was
#  written). Operates on output\ recursively, plus temp\ for 'all'.
#
#  input\ is SOURCE material you fed in, not generated output, so it is NEVER
#  touched unless you explicitly pass -IncludeInput.
#
#  CLASSIFICATION GOTCHA: .webp is both a still-image AND a video container,
#  and this stack emits ANIMATED .webp for video previews (OWUI_vid_00001_.webp).
#  Splitting on file extension alone would leave every animated preview behind
#  on a 'videos' clean, and silently destroy them on an 'images' clean. So .webp
#  is probed for a WebP ANIM/ANMF chunk and routed on what it actually IS.
#  Filename prefixes are deliberately NOT used - they change the moment a
#  workflow's SaveImage node gets renamed.

# $true = animated, $false = still, $null = could not read (treated as unknown
# and left alone unless the mode is 'all'). Never guess on an unreadable file.
function _owui_webp_is_animated {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf  = New-Object byte[] 64
            $read = $fs.Read($buf, 0, 64)
            if ($read -lt 16) { return $false }
            $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
            return ($head.Contains('ANIM') -or $head.Contains('ANMF'))
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function _owui_classify_media {
    param([System.IO.FileInfo]$File)
    $ext = $File.Extension.ToLower()
    # .gif counts as video: ComfyUI's animation nodes emit it, nobody renders
    # a still gif on purpose here.
    if ($ext -in '.mp4','.webm','.mkv','.mov','.avi','.m4v','.mpg','.mpeg','.gif') { return 'video' }
    if ($ext -in '.png','.jpg','.jpeg','.bmp','.tif','.tiff','.avif')              { return 'image' }
    if ($ext -eq '.webp') {
        $anim = _owui_webp_is_animated $File.FullName
        if ($null -eq $anim) { return 'unknown' }
        return $(if ($anim) { 'video' } else { 'image' })
    }
    return 'other'   # workflow .json sidecars, stray .txt, etc.
}

function _owui_comfy_clean {
    param(
        [ValidateSet('videos','images','all')]
        [string]$Mode = 'all',
        [switch]$DryRun,
        [switch]$IncludeInput
    )

    _owui_head "ComfyUI cleanup - $Mode$(if ($DryRun) { ' (DRY RUN)' })"

    $app = $OWUI.ComfyApp
    if (-not (Test-Path $app)) { Write-Host "  [x] ComfyUI not found at $app" -ForegroundColor Red; return }

    $roots  = @()
    $outDir = Join-Path $app 'output'
    if (-not (Test-Path $outDir)) { Write-Host "  [x] no output folder at $outDir" -ForegroundColor Red; return }
    $roots += $outDir
    if ($Mode -eq 'all') {
        $tmpDir = Join-Path $app 'temp'
        if (Test-Path $tmpDir) { $roots += $tmpDir }
    }
    if ($IncludeInput) {
        $inDir = Join-Path $app 'input'
        if (Test-Path $inDir) {
            $roots += $inDir
            Write-Host '  [!] -IncludeInput: your SOURCE images in input\ will be deleted too.' -ForegroundColor Yellow
        }
    }

    # A render in flight holds file handles and will keep writing after we scan.
    $busy = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*main.py*8188*' }
    if ($busy) {
        Write-Host '  [!] ComfyUI is RUNNING. Files from an in-progress render may be locked or re-created.' -ForegroundColor Yellow
        Write-Host "      Stop it first with 'owuihelp comfy-stop' for a clean sweep." -ForegroundColor DarkGray
    }

    Write-Host '  scanning ...' -ForegroundColor DarkGray
    $files = foreach ($r in $roots) { Get-ChildItem $r -File -Recurse -ErrorAction SilentlyContinue }
    if (-not $files) { Write-Host '  nothing to delete - already clean.' -ForegroundColor Green; return }

    $buckets = @{ video = @(); image = @(); unknown = @(); other = @() }
    foreach ($f in $files) { $buckets[(_owui_classify_media $f)] += $f }

    $targets = switch ($Mode) {
        'videos' { $buckets.video }
        'images' { $buckets.image }
        'all'    { $files }
    }

    # Belt and braces: never delete anything that isn't under the ComfyUI tree.
    # A typo'd $OWUI.ComfyApp should fail loudly, not eat an unrelated folder.
    $targets = @($targets | Where-Object {
        $_.FullName.StartsWith($app, [System.StringComparison]::OrdinalIgnoreCase)
    })

    $fmt = {
        param($label, $set, $colour)
        $mb = if ($set.Count) { (($set | Measure-Object Length -Sum).Sum / 1MB) } else { 0 }
        Write-Host ("    {0,-10} {1,5} files  {2,9:N1} MB" -f $label, $set.Count, $mb) -ForegroundColor $colour
    }

    Write-Host ''
    Write-Host '  found in scope:' -ForegroundColor Cyan
    & $fmt 'videos'  $buckets.video   $(if ($Mode -in 'videos','all') { 'Yellow' } else { 'DarkGray' })
    & $fmt 'images'  $buckets.image   $(if ($Mode -in 'images','all') { 'Yellow' } else { 'DarkGray' })
    & $fmt 'other'   $buckets.other   $(if ($Mode -eq 'all')          { 'Yellow' } else { 'DarkGray' })
    if ($buckets.unknown.Count) {
        & $fmt 'unknown' $buckets.unknown $(if ($Mode -eq 'all') { 'Yellow' } else { 'DarkGray' })
        Write-Host '      (unreadable .webp - left alone unless mode is "all")' -ForegroundColor DarkGray
    }

    $totalMb = if ($targets.Count) { (($targets | Measure-Object Length -Sum).Sum / 1MB) } else { 0 }
    Write-Host ''
    Write-Host ("  WILL DELETE: {0} files, {1:N1} MB" -f $targets.Count, $totalMb) -ForegroundColor $(if ($targets.Count) { 'Red' } else { 'Green' })

    if (-not $targets.Count) { Write-Host '  nothing matched - nothing done.' -ForegroundColor Green; return }
    if ($DryRun) {
        Write-Host '  DRY RUN - nothing was deleted. Re-run without -DryRun to commit.' -ForegroundColor Cyan
        return
    }

    $ok = 0; $failed = @()
    foreach ($f in $targets) {
        try { Remove-Item $f.FullName -Force -ErrorAction Stop; $ok++ }
        catch { $failed += $f.FullName }
    }

    # Tidy up folders ComfyUI created (output\video etc). Keep the roots.
    foreach ($r in $roots) {
        Get-ChildItem $r -Directory -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
    }

    Write-Host ("  deleted {0} files, freed {1:N1} MB" -f $ok, $totalMb) -ForegroundColor Green
    if ($failed.Count) {
        Write-Host ("  [!] {0} file(s) could not be deleted (locked by a running render?):" -f $failed.Count) -ForegroundColor Yellow
        $failed | Select-Object -First 5 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        if ($failed.Count -gt 5) { Write-Host ("      ... and {0} more" -f ($failed.Count - 5)) -ForegroundColor DarkGray }
    }
}

# Turn a raw $args array into a hashtable for SPLATTING. Array splatting binds
# POSITIONALLY, so '@args' containing '-DryRun' would drop the literal string
# '-DryRun' into -Mode and trip its ValidateSet. Hashtable splatting binds by
# name. Exactly the bug documented on the 'pushvps' row. Switches only - none of
# the clean flags take a value.
function _owui_flag_ht {
    param([object[]]$Tokens)
    $ht = @{}
    foreach ($t in @($Tokens)) {
        $s = "$t"
        if (-not $s) { continue }
        if ($s -match '^-{1,2}(.+)$') { $ht[$Matches[1]] = $true }
        else { Write-Host "  [!] ignoring unrecognised argument: $s" -ForegroundColor Yellow }
    }
    return $ht
}

# Long-form help shared by all three comfy-clean rows.
$Global:OWUI_COMFY_CLEAN_DETAILS = @(
    'SCOPE:'
    '  output\ (recursively, including output\video) is always in scope.'
    '  temp\ is added for "all".'
    '  input\ is your SOURCE material and is NEVER touched without -IncludeInput.'
    ''
    'HOW FILES ARE CLASSIFIED:'
    '  .mp4 .webm .mkv .mov .avi .m4v .mpg .mpeg .gif -> video'
    '  .png .jpg .jpeg .bmp .tif .tiff .avif          -> image'
    '  .webp -> PROBED, not assumed. This stack writes ANIMATED webp for video'
    '           previews (OWUI_vid_*.webp), so the extension alone is not enough.'
    '           Files carrying a WebP ANIM chunk count as VIDEO, not image.'
    '  anything else (workflow .json etc) -> "other", removed only by "all".'
    ''
    'FLAGS:'
    '  -DryRun        list what would go, delete nothing. Use this first.'
    '  -IncludeInput  also wipe input\. Rarely what you want.'
    '  -y | -Force    skip the "are you sure" prompt.'
    ''
    'EXAMPLES:'
    '    owuihelp comfy-clean-all -DryRun        see the damage before doing it'
    '    owuihelp comfy-clean-videos             drop renders, keep stills'
    '    owuihelp comfy-clean-all -y             no prompt, no mercy'
    ''
    '! Deletion is PERMANENT - these bypass the Recycle Bin.'
    '! Stop ComfyUI first (owuihelp comfy-stop). A live render holds file handles'
    '! and can re-create files a moment after they are removed.'
)

# ---- headed (visible) Playwright MCP -- REMOVED 2026-09-20 ----------------
#     Was: browser-headed / browser-headed-stop, which started a host-side
#     Playwright MCP on :8932 with a VISIBLE Chromium and repointed mcpo's
#     `browser` route at it. Removed with the rest of headed browsing.
#     Recover from git history if ever wanted back. See AICL-0088.

# Graceful full restart: models down -> comfy down -> docker recycle -> back up
function _owui_reset {
    _owui_head 'RESET - graceful full-stack restart'
    Write-Host '  1/5 unloading LLM models' -ForegroundColor Cyan;      _owui_stop_models
    Write-Host '  2/5 stopping ComfyUI' -ForegroundColor Cyan;          _owui_kill_comfy
    Write-Host '  3/5 docker compose up -d (idempotent, incl. bridges via start-stack)' -ForegroundColor Cyan
    Push-Location $OWUI.OllamaRoot; & "$($OWUI.OllamaRoot)\start-stack.ps1"; Pop-Location
    Write-Host '  4/5 starting ComfyUI' -ForegroundColor Cyan;          _owui_start_comfy
    Write-Host '  5/5 waiting 20s then status' -ForegroundColor Cyan;   Start-Sleep 20
    _owui_status
}

# Nuclear option: kill hard, clear the port reservation, rebuild, verify.
function _owui_hardreset {
    if (-not (_owui_admin)) {
        Write-Host "  [!] hardreset needs admin (it touches WinNAT + Docker) - relaunching elevated..." -ForegroundColor Yellow
        Start-Process pwsh -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass',
            '-Command', ". 'E:\ai\ollama\owui-toolkit.ps1'; owuihelp hardreset -Force") | Out-Null
        return
    }
    _owui_head 'HARD RESET - full teardown + clean rebuild (elevated)'
    Write-Host '  1/7 unload LLM models + kill runner' -ForegroundColor Cyan; _owui_stop_models
    Write-Host '  2/7 kill ComfyUI' -ForegroundColor Cyan;                     _owui_kill_comfy
    Write-Host '  3/7 stop Ollama server' -ForegroundColor Cyan
    Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '  4/7 free + reserve port 8188 (WinNAT fix)' -ForegroundColor Cyan
    & "$($OWUI.ComfyApp)\fix_port_8188.ps1"
    Write-Host '  5/7 docker compose down + up --force-recreate' -ForegroundColor Cyan
    Push-Location $OWUI.OllamaRoot; & "$($OWUI.OllamaRoot)\restack-mcpo.ps1"; Pop-Location
    Write-Host '  6/7 restart Ollama + ComfyUI' -ForegroundColor Cyan
    Start-Process $OWUI.OllamaExe -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
    Start-Sleep 3; _owui_start_comfy
    Write-Host '  7/7 waiting 25s then status' -ForegroundColor Cyan; Start-Sleep 25
    _owui_status
    Write-Host "`n  Hard reset complete." -ForegroundColor Green
}

# ---- model updater ---------------------------------------------------------
# Snapshot of what `ollama ls` currently holds:  @{ name = id }
function _owui_model_map {
    param([string]$Exe)
    $map = [ordered]@{}
    $raw = & $Exe ls 2>$null | Select-Object -Skip 1
    foreach ($l in $raw) {
        if (-not ("$l").Trim()) { continue }
        $p = ("$l").Trim() -split '\s+'
        if ($p[0]) { $map[$p[0]] = $p[1] }
    }
    return $map
}

# Update EVERY model reported by `ollama ls`.
#   -Filter  wildcard to narrow it down   e.g.  owuihelp updateall qwen*
#   -List    preview only, pull nothing
# Compares the model ID (digest) before/after so it can tell you what ACTUALLY
# changed rather than just claiming success. Models that fail to pull are almost
# always local Modelfile builds - they have no upstream to pull from.
function _owui_update_models {
    [CmdletBinding()]
    param([string]$Filter = '*', [switch]$List)

    if (-not $Filter) { $Filter = '*' }
    $exe = if (Test-Path $OWUI.OllamaExe) { $OWUI.OllamaExe } else { 'ollama' }
    if (-not (Test-Path $exe) -and -not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        Write-Host '  [x] ollama executable not found (checked $OWUI.OllamaExe and PATH)' -ForegroundColor Red
        return
    }

    # `ollama ls` needs the API up, otherwise it returns an empty list and we
    # would cheerfully "update" nothing and call it a win.
    if (-not (_owui_port $OWUI.Ports.Ollama)) {
        Write-Host ("  Ollama not answering on :{0} - starting it..." -f $OWUI.Ports.Ollama) -ForegroundColor Yellow
        Start-Process $exe -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Sleep 4
        if (-not (_owui_port $OWUI.Ports.Ollama)) {
            Write-Host '  [x] Ollama still down - aborting.' -ForegroundColor Red; return
        }
    }

    $before = _owui_model_map $exe
    if ($before.Count -eq 0) { Write-Host '  [x] `ollama ls` returned no models.' -ForegroundColor Red; return }

    $names = @($before.Keys | Where-Object { $_ -like $Filter })
    if ($names.Count -eq 0) {
        Write-Host ("  no installed model matches '{0}'. Installed: {1}" -f $Filter, ($before.Keys -join ', ')) -ForegroundColor Yellow
        return
    }

    if ($List) {
        _owui_head ("Would update {0} of {1} model(s)" -f $names.Count, $before.Count)
        foreach ($n in $names) { Write-Host ("    {0,-46} {1}" -f $n, $before[$n]) -ForegroundColor Gray }
        Write-Host ''
        Write-Host '  run without "list" to actually pull.' -ForegroundColor DarkGray
        return
    }

    _owui_head ("Updating {0} model(s) from 'ollama ls'" -f $names.Count)
    $failed = @(); $ok = @(); $i = 0
    foreach ($n in $names) {
        $i++
        Write-Host ''
        Write-Host ("  [{0}/{1}] ollama pull {2}" -f $i, $names.Count, $n) -ForegroundColor Cyan
        & $exe pull $n
        if ($LASTEXITCODE -ne 0) {
            $failed += $n
            Write-Host "    [x] pull failed - local Modelfile build, renamed, or gone from the registry" -ForegroundColor Red
        } else { $ok += $n }
    }

    # Digest diff = the honest answer to "did anything actually change?"
    $after   = _owui_model_map $exe
    $changed = @($ok | Where-Object { $after[$_] -and $before[$_] -ne $after[$_] })
    $same    = @($ok | Where-Object { $_ -notin $changed })

    _owui_head 'Summary'
    Write-Host ("    updated   : {0}" -f $changed.Count) -ForegroundColor Green
    foreach ($n in $changed) { Write-Host ("        {0,-46} {1} -> {2}" -f $n, $before[$n], $after[$n]) -ForegroundColor DarkGreen }
    Write-Host ("    unchanged : {0}  (already newest)" -f $same.Count) -ForegroundColor Gray
    Write-Host ("    failed    : {0}" -f $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Gray' })
    foreach ($n in $failed) { Write-Host ("        {0}" -f $n) -ForegroundColor DarkRed }
    if ($failed.Count) {
        Write-Host ''
        Write-Host '    Failures are usually models you built locally from a Modelfile.' -ForegroundColor DarkYellow
        Write-Host '    Check with:  ollama show <name> --modelfile' -ForegroundColor DarkYellow
    }
    Write-Host ''
    if ($changed.Count) { Write-Host '    Tip: run "owuihelp stopllm" so OWUI reloads the new weights.' -ForegroundColor DarkGray }
}

# ---- VPS passthrough -------------------------------------------------------
# Added 2026-08-19. The far half of this toolkit is a bash twin living at
# ~/bin/owuihelp on the VPS; its SOURCE OF TRUTH is E:\ai\ollama\vps\owuihelp
# (same pattern as the owui_*.py tools - edit on the PC, deploy to the box).
#
# Deliberately a single passthrough row rather than one mirrored row per remote
# command: the tail is forwarded verbatim, so a command added over there works
# from here with no edit to this file. The cost is that remote commands do not
# appear individually in this menu - 'owuihelp vps' prints the remote menu.
$Global:OWUI_VPS_HOST   = 'vps'                 # the alias in ~\.ssh\config
$Global:OWUI_VPS_REMOTE = '$HOME/bin/owuihelp'  # single-quoted: $HOME expands ON THE VPS

# Every argument is single-quoted for the remote shell. Without it a bare '?'
# (the dry-run token) is a glob to bash, and anything with a space silently
# splits into two arguments somewhere over the wire.
function _owui_vps_quote ([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }

function _owui_vps {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Write-Host '  [x] ssh is not on PATH.' -ForegroundColor Red; return
    }
    $tail = @($args | ForEach-Object { _owui_vps_quote "$_" })
    $cmd  = (@($OWUI_VPS_REMOTE) + $tail) -join ' '

    # -t forces a TTY on the far side. That is what makes the remote script's
    # colours, its (y/N) prompts and 'logs -f' behave exactly as they do when
    # you are sat in an SSH session, instead of degrading to plain piped output.
    ssh -t $OWUI_VPS_HOST $cmd
    $rc = $LASTEXITCODE

    if ($rc -eq 255) {
        Write-Host ''
        Write-Host "  [x] ssh could not reach '$OWUI_VPS_HOST'." -ForegroundColor Red
        Write-Host '      Tailscale down, VPS off, or key auth broken. Try:  ssh vps true' -ForegroundColor DarkGray
    } elseif ($rc -eq 127) {
        Write-Host ''
        Write-Host '  [x] owuihelp is not installed on the VPS (or not executable).' -ForegroundColor Red
        Write-Host '      Fix it with:  owuihelp vps-install' -ForegroundColor Yellow
    }
}

# Push E:\ai\ollama\vps\owuihelp to ~/bin/owuihelp on the VPS and verify it runs.
# Idempotent - safe to re-run after every edit, and that is the intended workflow.
function _owui_vps_install {
    $src = "$($OWUI.OllamaRoot)\vps\owuihelp"
    if (-not (Test-Path $src)) {
        Write-Host "  [x] source not found: $src" -ForegroundColor Red; return
    }

    _owui_head 'Step 1/4 - can we reach the VPS'
    ssh -o BatchMode=yes -o ConnectTimeout=10 $OWUI_VPS_HOST 'true' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    [x] 'ssh $OWUI_VPS_HOST' failed (exit $LASTEXITCODE)." -ForegroundColor Red
        Write-Host '        Check Tailscale is up and key auth still works, then re-run.' -ForegroundColor DarkGray
        return
    }
    Write-Host '    ok' -ForegroundColor Green

    _owui_head 'Step 2/4 - copy'
    ssh $OWUI_VPS_HOST 'mkdir -p $HOME/bin'
    scp $src ("{0}:bin/owuihelp" -f $OWUI_VPS_HOST)
    if ($LASTEXITCODE -ne 0) { Write-Host '    [x] scp failed.' -ForegroundColor Red; return }
    Write-Host '    copied to ~/bin/owuihelp' -ForegroundColor Green

    _owui_head 'Step 3/4 - strip CR, make executable'
    # A single stray CR on the shebang line makes bash report the whole script
    # as "/usr/bin/env: bash\r: No such file or directory", which reads like a
    # missing interpreter and sends you hunting in completely the wrong place.
    ssh $OWUI_VPS_HOST 'sed -i ''s/\r$//'' $HOME/bin/owuihelp && chmod 755 $HOME/bin/owuihelp'
    if ($LASTEXITCODE -ne 0) { Write-Host '    [x] chmod/sed failed.' -ForegroundColor Red; return }
    Write-Host '    ok' -ForegroundColor Green

    _owui_head 'Step 4/4 - verify'
    ssh $OWUI_VPS_HOST '$HOME/bin/owuihelp version'
    if ($LASTEXITCODE -eq 0) {
        Write-Host ''
        Write-Host '    Installed. Try:  owuihelp vps status' -ForegroundColor Green
        Write-Host '    On the VPS itself, ~/bin is on PATH after your next login;' -ForegroundColor DarkGray
        Write-Host '    until then use  ~/bin/owuihelp  or  export PATH="$HOME/bin:$PATH"' -ForegroundColor DarkGray
    } else {
        Write-Host '    [x] the remote script did not run. Check with: ssh vps ~/bin/owuihelp' -ForegroundColor Red
    }
}

# ============================================================================
#  COMMAND REGISTRY
#  Add a row here to add a command. Columns:
#    cmd    - canonical name (what the menu shows)
#    alias  - other names that resolve to this row. Use these instead of
#             duplicating a row; 2026-07-31 this file had two byte-identical
#             rows for 'ai'/'freevram' and a 'pullall' row that just re-entered
#             the dispatcher to reach 'updateall'.
#    grp    - menu heading. Order is set by $OWUI_GROUPS below, not by
#             declaration order, so rows can live wherever reads best.
#    admin  - auto-elevates
#    destructive - prompts before running
#    blurb  - one-line explanation (shown in the menu AND by 'owuihelp <cmd> ?')
#    details- OPTIONAL array of lines = long-form help, shown by 'owuihelp <cmd> ?'
#             underneath the blurb. Printed verbatim, so keep your own indenting.
#             Formatting conventions the renderer understands:
#               "ALL CAPS ENDING IN COLON:"  -> cyan sub-heading
#               "! line starts with a bang"  -> yellow warning (bang is stripped)
#               anything else                -> plain grey body text
#             Use it for any command where the consequences aren't obvious from
#             one line: which stream, which copy, what gets pruned, what's in the
#             archive. Added 2026-08-05.
#    act    - scriptblock
# ============================================================================

# Explicit menu order. Anything with a group not listed here is appended last,
# so a typo in 'grp' shows up as a stray heading rather than vanishing.
$Global:OWUI_GROUPS = @(
    'GPU / VRAM'
    'Models'
    'Environment'
    'ComfyUI'
    'Stack (Docker)'
    'Host packages'
    'VPS (remote)'
    'Browser (Playwright)'
    'Health & logs'
    'Backups'
    'Master resets'
    'Change ledger'
    'Setup (one-time)'
)

# ---- env profile manager ---------------------------------------------------
# Kept in its own file so this one stays navigable. Must load AFTER $OWUI is
# defined - the module reads $OWUI.OllamaRoot at load time to find its store.
$_owuiEnvModule = Join-Path $OWUI.OllamaRoot 'owui-env-profiles.ps1'
if (Test-Path $_owuiEnvModule) { . $_owuiEnvModule }
else { Write-Host "  [!] env profile module missing: $_owuiEnvModule" -ForegroundColor DarkYellow }

# ---- AI change ledger ------------------------------------------------------
# Added 2026-09-04. Front-end for _support\scripts\maintenance\Add-AIChange.ps1,
# the append-only handover record between Claude and ChatGPT. Rules and the
# controlled vocabularies live in AI-CHANGELOG-PROTOCOL.md - read it before
# writing a row. NOTE: 'changelog' is NOT 'logs' (that tails the ComfyUI log).
function _owui_changelog {
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)

    $script = Join-Path $OWUI.OllamaRoot '_support\scripts\maintenance\Add-AIChange.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Host "  [!] ledger helper missing: $script" -ForegroundColor Red
        Write-Host '      Do not hand-edit the CSV - find out why the helper is gone.' -ForegroundColor DarkGray
        return
    }

    # No args, or an explicit read verb -> show the tail.
    if (-not $Rest -or @($Rest).Count -eq 0) { & $script -Tail 10; return }
    if ([string]$Rest[0] -in 'tail','last','recent','read') {
        $n = 10
        if (@($Rest).Count -ge 2 -and "$($Rest[1])" -match '^\d+$') { $n = [int]$Rest[1] }
        & $script -Tail $n
        return
    }

    # Otherwise translate "-Name value -Name value" into a splat hashtable.
    # An array splat would pass everything positionally, which the helper's
    # named parameters would reject.
    $ht = @{}
    $i  = 0
    $arr = @($Rest)
    while ($i -lt $arr.Count) {
        $k = "$($arr[$i])"
        if ($k.StartsWith('-')) {
            $name = $k.TrimStart('-')
            if (($i + 1) -lt $arr.Count -and -not "$($arr[$i+1])".StartsWith('-')) {
                $ht[$name] = $arr[$i+1]; $i += 2
            } else {
                $ht[$name] = $true;     $i += 1
            }
        } else {
            Write-Host "  [!] ignoring stray argument '$k' - use -Name value pairs." -ForegroundColor DarkYellow
            $i += 1
        }
    }
    # ! A value that itself begins with '-' will be misread as a parameter name.
    #   Call Add-AIChange.ps1 directly if you need one.
    & $script @ht
}

# ---- OWUI / open-terminal upgrade -------------------------------------------
# Added 2026-09-04. Both services run floating ':latest' by owner decision, and
# start-stack.ps1 does 'compose up -d --build' at every boot. That recreates
# from the LOCAL ':latest' tag, so an out-of-date local tag downgrades the
# service on the next reboot - which is exactly what nearly happened on
# 4 September (local ':latest' was still v0.11.0, five weeks behind the running
# v0.11.1). This command is the supported way to move them: back up, pull BOTH,
# recreate, verify, and print the digests to record in docker-compose.yml.
function _owui_update_owui {
    param([switch]$SkipBackup)

    $compose = $OWUI.OllamaRoot
    Write-Host ''
    _owui_head 'Update open-webui + open-terminal (floating :latest)'

    if (-not $SkipBackup) {
        Write-Host '  1/5 backup first (skip with -SkipBackup)' -ForegroundColor Cyan
        _owui_backup
    } else {
        Write-Host '  1/5 backup SKIPPED by request' -ForegroundColor DarkYellow
    }

    Push-Location $compose
    try {
        Write-Host '  2/5 pulling both images (several GB - this is the slow part)' -ForegroundColor Cyan
        docker compose pull open-webui open-terminal

        Write-Host '  3/5 recreating containers' -ForegroundColor Cyan
        docker compose up -d open-webui open-terminal

        Write-Host '  4/5 verifying' -ForegroundColor Cyan
        Start-Sleep -Seconds 20
        docker ps --filter name=open-webui --filter name=open-terminal --format "    {{.Names}}`t{{.Status}}"

        $owuiVer = (docker exec open-webui sh -c 'grep -m1 version /app/package.json' 2>$null)
        $otVer   = (docker exec open-terminal sh -c 'grep -m1 version /app/pyproject.toml' 2>$null)
        Write-Host "    open-webui   $owuiVer" -ForegroundColor Gray
        Write-Host "    open-terminal $otVer"  -ForegroundColor Gray

        try {
            $h = Invoke-WebRequest -Uri 'http://127.0.0.1:3000/health' -UseBasicParsing -TimeoutSec 15
            Write-Host "    OWUI /health: $($h.StatusCode)" -ForegroundColor Green
        } catch {
            Write-Host '    [!] OWUI /health did not answer - check "owuihelp status" and the logs.' -ForegroundColor Red
        }

        # Ch. 10.5: a recreated OWUI that booted before mcpo was serving silently
        # drops every mcpo-backed tool server and never looks again.
        Write-Host '    checking mcpo tool servers (Ch. 10.5 trap)' -ForegroundColor DarkGray
        try {
            $cfg   = Get-Content (Join-Path $compose 'mcpo-core-config.pinned.json') -Raw | ConvertFrom-Json
            $names = $cfg.mcpServers.PSObject.Properties.Name
            $ok = 0; $tools = 0
            foreach ($n in $names) {
                try {
                    $o = Invoke-RestMethod -Uri "http://127.0.0.1:18000/$n/openapi.json" -TimeoutSec 8
                    $ok++; $tools += $o.paths.PSObject.Properties.Name.Count
                } catch { }
            }
            $colour = if ($ok -eq $names.Count) { 'Green' } else { 'Red' }
            Write-Host "    mcpo servers answering: $ok/$($names.Count)   tools: $tools" -ForegroundColor $colour
            if ($ok -ne $names.Count) {
                Write-Host '    [!] restart open-webui once mcpo is fully up, or the tool menu will be short.' -ForegroundColor Red
            }
        } catch {
            Write-Host '    [!] could not probe mcpo - check it manually.' -ForegroundColor DarkYellow
        }

        Write-Host '  5/5 RECORD THESE - paste into docker-compose.yml and log a ledger row' -ForegroundColor Yellow
        docker inspect --format '    open-webui    {{index .RepoDigests 0}}' ghcr.io/open-webui/open-webui:latest
        docker inspect --format '    open-terminal {{index .RepoDigests 0}}' ghcr.io/open-webui/open-terminal:latest
        Write-Host '    then: owuihelp changelog -Author ... (see AI-CHANGELOG-PROTOCOL.md)' -ForegroundColor DarkGray
    }
    finally { Pop-Location }
    Write-Host ''
}

# ---- pull every floating-tag image -----------------------------------------
# Added 2026-09-04. 'docker restart' reuses the existing container and changes
# NOTHING; 'docker compose up -d' recreates from the tag AS IT EXISTS ON DISK.
# Neither consults the registry. So a floating ':latest' only moves when
# something pulls - and a stale local tag DOWNGRADES the service at the next
# boot (Ch. 20.18). This finds every pullable floating tag in the compose file,
# pulls it, and reports which images actually changed.
function _owui_pull_latest {
    param([switch]$Recreate, [string[]]$Only)

    Push-Location $OWUI.OllamaRoot
    try {
        _owui_head 'Pull floating-tag images'

        $cfg = docker compose config --format json | ConvertFrom-Json
        $targets = @()
        foreach ($name in $cfg.services.PSObject.Properties.Name) {
            $svc = $cfg.services.$name
            $img = [string]$svc.image
            if (-not $img)               { continue }   # built, no image name
            if ($svc.build)              { continue }   # locally built
            if ($img -like '*@sha256:*') { continue }   # digest-pinned on purpose

            # Tag = text after the last ':' that follows the last '/'.
            $slash = $img.LastIndexOf('/')
            $colon = $img.LastIndexOf(':')
            $tag   = if ($colon -gt $slash) { $img.Substring($colon + 1) } else { 'latest' }

            if ($tag -eq 'pinned')   { continue }       # locally built image
            if ($tag -match '^v?\d') { continue }       # version-pinned

            if ($Only -and ($name -notin $Only)) { continue }
            $targets += [pscustomobject]@{ Service = $name; Image = $img; Before = $null; After = $null }
        }

        if (-not $targets) { Write-Host '  nothing floating to pull.' -ForegroundColor DarkGray; return }

        Write-Host ('  floating services: {0}' -f (($targets.Service) -join ', ')) -ForegroundColor Gray
        foreach ($t in $targets) {
            $t.Before = (docker image inspect $t.Image --format '{{.Id}}' 2>$null)
        }

        Write-Host '  pulling (several GB - this is the slow part)' -ForegroundColor Cyan
        docker compose pull @($targets.Service)

        foreach ($t in $targets) {
            $t.After = (docker image inspect $t.Image --format '{{.Id}}' 2>$null)
        }

        $changed = @($targets | Where-Object { $_.Before -ne $_.After })
        Write-Host ''
        foreach ($t in $targets) {
            $mark = if ($t.Before -ne $t.After) { 'UPDATED ' } else { 'no change' }
            $col  = if ($t.Before -ne $t.After) { 'Yellow' } else { 'DarkGray' }
            Write-Host ("    {0,-9} {1,-16} {2}" -f $mark, $t.Service, $t.Image) -ForegroundColor $col
        }

        if (-not $changed) {
            Write-Host "`n  Everything already current. Nothing to recreate." -ForegroundColor Green
            return
        }

        Write-Host ("`n  {0} image(s) changed. They are NOT live until the container is recreated:" -f $changed.Count) -ForegroundColor Yellow
        Write-Host ('    docker compose up -d {0}' -f (($changed.Service) -join ' ')) -ForegroundColor Gray
        Write-Host '    (a plain restart will NOT pick these up - it reuses the existing container)' -ForegroundColor DarkGray

        if ($Recreate) {
            Write-Host "`n  recreating changed services" -ForegroundColor Cyan
            docker compose up -d @($changed.Service)
            Start-Sleep -Seconds 15
            docker ps --format "    {{.Names}}`t{{.Status}}" | Select-String ($changed.Service -join '|')
        }

        Write-Host "`n  RECORD THESE - paste into docker-compose.yml, then log a ledger row" -ForegroundColor Yellow
        foreach ($t in $changed) {
            docker inspect --format ("    {0} {{{{index .RepoDigests 0}}}}" -f $t.Service) $t.Image
        }
        Write-Host '    owuihelp changelog -Tier routine ...   (see AI-CHANGELOG-PROTOCOL.md)' -ForegroundColor DarkGray
    }
    finally { Pop-Location }
    Write-Host ''
}

# ---- host package updates (winget) ----------------------------------------
# `winget upgrade --all` on THIS box would also upgrade Ollama and Docker
# Desktop: both are winget-managed here, and both can take the stack down.
# Ollama is the bad one - the tray updater racing start-stack.ps1 has already
# deleted lib\ollama once and left Ollama running CPU-only.
#
# winget 1.29 has NO --exclude on `upgrade`, so the only way to hold a package
# back is a pin, and it must be a BLOCKING pin: --include-pinned (which we do
# want, so ordinary pins don't stop the sweep) overrides non-blocking pins but
# never blocking ones.
$Global:OWUI_WINGET_HOLD = @(
    @{ Id  = 'Ollama.Ollama'
       Why = 'update race has deleted lib\ollama before -> CPU-only Ollama' }
    @{ Id  = 'Docker.DockerDesktop'
       Why = 'restarts the engine and drops every stack container mid-flight' }
)

function _owui_winget_held {
    $held = @{}
    try {
        $txt = (winget pin list 2>$null | Out-String)
        foreach ($h in $Global:OWUI_WINGET_HOLD) {
            if ($txt -match [regex]::Escape($h.Id)) { $held[$h.Id] = $true }
        }
    } catch { }
    return $held
}

function _owui_winget_upgrade_all {
    [CmdletBinding()]
    param([switch]$DryRun, [switch]$IgnoreHash, [switch]$NoGuard)

    _owui_head 'winget upgrade - every host package'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host '  [x] winget not found on PATH.' -ForegroundColor Red
        Write-Host ''
        return
    }

    if ($DryRun) {
        Write-Host '  pending upgrades - nothing will be installed:' -ForegroundColor Cyan
        Write-Host ''
        winget upgrade --include-unknown --accept-source-agreements
        Write-Host ''
        return
    }

    # winget needs elevation for machine-scope packages.
    if (-not (_owui_admin)) {
        Write-Host '  [!] needs admin - relaunching elevated...' -ForegroundColor Yellow
        $call = '_owui_winget_upgrade_all'
        if ($IgnoreHash) { $call += ' -IgnoreHash' }
        if ($NoGuard)    { $call += ' -NoGuard' }
        $inner = ". '{0}\owui-toolkit.ps1'; {1}" -f $OWUI.OllamaRoot, $call
        Start-Process pwsh -Verb RunAs -ArgumentList @(
            '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-Command', $inner) | Out-Null
        Write-Host '      (continues in the elevated window)' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    if ($NoGuard) {
        Write-Host '  [!] -NoGuard: Ollama and Docker Desktop are NOT held back.' -ForegroundColor Red
        Write-Host '      That is how the stack broke last time. You asked for it.' -ForegroundColor DarkGray
    }
    else {
        $held = _owui_winget_held
        foreach ($h in $Global:OWUI_WINGET_HOLD) {
            $listed = (winget list --id $h.Id -e --accept-source-agreements 2>$null | Out-String)
            if ($listed -notmatch [regex]::Escape($h.Id)) { continue }
            if ($held[$h.Id]) {
                Write-Host ('  [ok]  held   : {0}' -f $h.Id) -ForegroundColor Green
            } else {
                winget pin add --id $h.Id -e --blocking --accept-source-agreements 2>&1 | Out-Null
                Write-Host ('  [+]   pinned : {0}  (blocking)' -f $h.Id) -ForegroundColor Yellow
            }
            Write-Host ('        reason : {0}' -f $h.Why) -ForegroundColor DarkGray
        }
    }

    $flags = @(
        '--all'
        '--include-unknown'
        '--include-pinned'
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--silent'
        '--disable-interactivity'
        '--force'
        '--nowarn'
    )
    if ($IgnoreHash) {
        $flags += '--ignore-security-hash'
        Write-Host '  [!] --ignore-security-hash: installer hash checks are OFF this run.' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host ('  winget upgrade ' + ($flags -join ' ')) -ForegroundColor DarkGray
    Write-Host ''
    winget upgrade @flags
    $rc = $LASTEXITCODE

    Write-Host ''
    Write-Host ('  winget exit code: {0}' -f $rc) -ForegroundColor DarkGray
    Write-Host '  still pending (held pins and unknowns show here):' -ForegroundColor Cyan
    winget upgrade --include-unknown --accept-source-agreements

    # Ollama is pinned so this should never trip - but it is the exact failure
    # that made the guard necessary, and the check is free.
    $libs = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\lib\ollama'
    Write-Host ''
    if (Test-Path $libs) {
        Write-Host '  [ok] Ollama GPU libs intact' -ForegroundColor Green
    } else {
        Write-Host '  [x] lib\ollama MISSING - Ollama will run CPU-only. Reinstall it.' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  to move a held package DELIBERATELY:' -ForegroundColor Yellow
    foreach ($h in $Global:OWUI_WINGET_HOLD) {
        Write-Host ('    winget pin remove --id {0} -e' -f $h.Id) -ForegroundColor DarkGray
        Write-Host ('    winget upgrade --id {0} -e --silent --accept-package-agreements --accept-source-agreements' -f $h.Id) -ForegroundColor DarkGray
        Write-Host ('    winget pin add --id {0} -e --blocking' -f $h.Id) -ForegroundColor DarkGray
    }
    Write-Host '    verify: ollama ps (PROCESSOR must say GPU), then owuihelp status' -ForegroundColor DarkGray
    Write-Host '    then log it: owuihelp changelog ...' -ForegroundColor DarkGray
    Write-Host ''
}

# ---- "update" signpost -----------------------------------------------------
# Four different things on this stack are called "update" and they are not
# interchangeable. This row does nothing except point at the right one.
function _owui_update_menu {
    _owui_head 'update - which lane did you mean?'
    Write-Host '  This updates NOTHING by itself. Four commands update four different' -ForegroundColor DarkGray
    Write-Host '  things and the wrong one has a cost, so here they are side by side.' -ForegroundColor DarkGray
    Write-Host ''
    $lanes = @(
        @{ c = 'owuihelp update-owui'
           w = 'open-webui + open-terminal containers'
           g = 'guarded: backs up first, verifies all 20 mcpo tool servers after' }
        @{ c = 'owuihelp pull-latest'
           w = 'every floating-tag image (also tika, playwright-mcp)'
           g = 'pull only - add -Recreate to actually swap the containers' }
        @{ c = 'owuihelp updateall'
           w = 'every model in "ollama ls"'
           g = 'owuihelp updateall list  previews without pulling' }
        @{ c = 'owuihelp winget-upgrade-all'
           w = 'host packages via winget (unattended)'
           g = 'Ollama + Docker Desktop held back by blocking pins' }
    )
    foreach ($l in $lanes) {
        Write-Host ('    {0,-30}' -f $l.c) -ForegroundColor Yellow -NoNewline
        Write-Host $l.w -ForegroundColor Gray
        Write-Host ('    {0,-30}{1}' -f '', $l.g) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  NOT covered by any of the above:' -ForegroundColor Cyan
    Write-Host '    ComfyUI is not a container. It is a bare venv + git checkout at' -ForegroundColor DarkGray
    Write-Host ('    {0}\ComfyUI, currently on a DETACHED HEAD, so "git pull" there is a' -f $OWUI.ComfyRoot) -ForegroundColor DarkGray
    Write-Host '    no-op. No updater is wired up on purpose: a ComfyUI bump can change' -ForegroundColor DarkGray
    Write-Host '    node signatures and break the LTX/Wan workflows. Update it by hand.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Anything that moves a version -> record it:  owuihelp changelog' -ForegroundColor DarkGray
    Write-Host ''
}

# ---- model feature controller ----------------------------------------------
# Chat and PowerShell intentionally share the same Python Tools class. The
# wrapper only transports arguments safely into the container; all authz,
# validation, preview tokens, snapshots and verification live in one place.
function _owui_modelctrl {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)

    $guide = Join-Path $OWUI.OllamaRoot 'docs\OWUI-MODEL-FEATURE-MANAGER.md'
    if (-not $Rest -or "$($Rest[0])".ToLower() -in 'help','?','guide') {
        _owui_head 'modelctrl - Open WebUI model feature control'
        Write-Host '  viewall' -ForegroundColor Yellow -NoNewline
        Write-Host '                     list every stored model ID and display name' -ForegroundColor Gray
        Write-Host '  view <model>' -ForegroundColor Yellow -NoNewline
        Write-Host '                full effective feature inventory for one model' -ForegroundColor Gray
        Write-Host '  catalog <model>' -ForegroundColor Yellow -NoNewline
        Write-Host '             same view plus attachable native tools and skills' -ForegroundColor Gray
        Write-Host '  preview <model> ''<json>''' -ForegroundColor Yellow -NoNewline
        Write-Host '   validate and show an exact diff; changes nothing' -ForegroundColor Gray
        Write-Host '  apply <model> ''<json>'' <token>' -ForegroundColor Yellow -NoNewline
        Write-Host ' apply the identical approved preview' -ForegroundColor Gray
        Write-Host '  backups <model>' -ForegroundColor Yellow -NoNewline
        Write-Host '             list rollback snapshots' -ForegroundColor Gray
        Write-Host '  rollback-preview <model> <backup>' -ForegroundColor Yellow -NoNewline
        Write-Host ' show the restore diff' -ForegroundColor Gray
        Write-Host '  rollback <model> <backup> <token>' -ForegroundColor Yellow -NoNewline
        Write-Host ' restore after approval' -ForegroundColor Gray
        Write-Host ''
        Write-Host ('  Full guide: {0}' -f $guide) -ForegroundColor DarkGray
        Write-Host '  Detailed command help: owuihelp modelctrl ?' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    if (-not (docker ps --filter 'name=^/open-webui$' --filter 'status=running' -q)) {
        Write-Host '  [x] open-webui is not running.' -ForegroundColor Red
        return
    }

    $source = Join-Path $OWUI.OllamaRoot 'owui-tools\model_feature_manager.py'
    $cli    = Join-Path $OWUI.OllamaRoot 'owui-tools\_model_feature_manager_cli.py'
    if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $cli)) {
        Write-Host '  [x] model controller source/helper is missing under owui-tools\.' -ForegroundColor Red
        return
    }

    docker cp $source 'open-webui:/tmp/model_feature_manager.py' | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host '  [x] could not stage model_feature_manager.py' -ForegroundColor Red; return }
    docker cp $cli 'open-webui:/tmp/model_feature_manager_cli.py' | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host '  [x] could not stage model_feature_manager_cli.py' -ForegroundColor Red; return }

    $op = "$($Rest[0])".ToLower()
    $target = if ($Rest.Count -gt 1) { "$($Rest[1])" } else { '' }
    $base = @('exec','-e','PYTHONPATH=/app/backend','open-webui','python','/tmp/model_feature_manager_cli.py')

    switch ($op) {
        'viewall' { & docker @base 'viewall'; return }
        'view' {
            if (-not $target) { Write-Host '  usage: owuihelp modelctrl view <model-id-or-name>' -ForegroundColor Yellow; return }
            & docker @base 'view' $target
            return
        }
        'catalog' {
            if (-not $target) { Write-Host '  usage: owuihelp modelctrl catalog <model-id-or-name>' -ForegroundColor Yellow; return }
            & docker @base 'view' $target '--catalogs'
            return
        }
        'preview' {
            if ($Rest.Count -lt 3) { Write-Host '  usage: owuihelp modelctrl preview <model> ''<changes-json>''' -ForegroundColor Yellow; return }
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Rest[2])"))
            & docker @base 'preview' $target $encoded
            return
        }
        'apply' {
            if ($Rest.Count -lt 4) { Write-Host '  usage: owuihelp modelctrl apply <model> ''<changes-json>'' <preview-token>' -ForegroundColor Yellow; return }
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Rest[2])"))
            & docker @base 'apply' $target $encoded "$($Rest[3])"
            return
        }
        'backups' {
            if (-not $target) { Write-Host '  usage: owuihelp modelctrl backups <model>' -ForegroundColor Yellow; return }
            & docker @base 'backups' $target
            return
        }
        'rollback-preview' {
            if ($Rest.Count -lt 3) { Write-Host '  usage: owuihelp modelctrl rollback-preview <model> <backup-id>' -ForegroundColor Yellow; return }
            & docker @base 'rollback-preview' $target "$($Rest[2])"
            return
        }
        'rollback' {
            if ($Rest.Count -lt 4) { Write-Host '  usage: owuihelp modelctrl rollback <model> <backup-id> <preview-token>' -ForegroundColor Yellow; return }
            & docker @base 'rollback' $target "$($Rest[2])" "$($Rest[3])"
            return
        }
        default {
            Write-Host "  [x] unknown modelctrl action '$op'. Run: owuihelp modelctrl" -ForegroundColor Red
            return
        }
    }
}

$Global:OWUI_CMDS = @(

    # ---------------- GPU / VRAM ----------------
    @{ cmd='art';       grp='GPU / VRAM'; blurb='Free the GPU for ComfyUI/FLUX (unload LLM, ensure ComfyUI up)';
       act={ _owui_runps "$($OWUI.ComfyRoot)\art-mode.ps1" } }

    @{ cmd='ai';        grp='GPU / VRAM'; alias=@('freevram'); blurb='Give the GPU back to the LLM - ComfyUI releases its VRAM now (pairs with "art")';
       act={ _owui_runps "$($OWUI.SupportScripts)\maintenance\free-vram.ps1" } }

    @{ cmd='autofree';  grp='GPU / VRAM'; blurb='Auto-release ComfyUI VRAM once idle, so you never have to remember "ai" (on | off | status)';
       act={ param($a) _owui_autofree $a } }

    @{ cmd='who';       grp='GPU / VRAM'; alias=@('gpuwho','vram'); blurb='Who is ACTUALLY holding VRAM - Task Manager under-reports session 0 (arg: min MB)';
       act={ param($a) if ($a) { & "$($OWUI.OllamaRoot)\gpu-who.ps1" -MinMB ([int]$a) } else { & "$($OWUI.OllamaRoot)\gpu-who.ps1" } } }

    @{ cmd='stopllm';   grp='GPU / VRAM'; blurb='Unload all Ollama models from VRAM (server stays online)';
       act={ _owui_stop_models; Write-Host '  models unloaded.' -ForegroundColor Green } }

    @{ cmd='keepalive'; grp='GPU / VRAM'; blurb='Show/set OLLAMA_KEEP_ALIVE (needs elevation). "keepalive 2m" = model stays warm 2 min; "0" = unload after every reply';
       act={ param($a) _owui_keepalive $a } }

    # ---------------- Models ----------------
    @{ cmd='updateall'; grp='Models'; alias=@('pullall'); blurb='Update EVERY model in "ollama ls" (args: wildcard filter, or "list" to preview)';
       act={ param($a,$b)
             $f = '*'; $preview = $false
             foreach ($x in @($a,$b)) {
                 if (-not $x) { continue }
                 if ("$x".TrimStart('-') -in 'list','preview','dry','n') { $preview = $true } else { $f = "$x" }
             }
             if ($preview) { _owui_update_models -Filter $f -List } else { _owui_update_models -Filter $f } } }

    @{ cmd='modelctrl'; grp='Models'; alias=@('model-control','model-features');
       blurb='Inspect, preview, change and roll back every OWUI model feature/tool gate';
       details=@(
         'PURPOSE:'
         '  Gives both PowerShell and the dedicated OWUI Model Feature Administrator'
         '  the same complete model inventory and reversible change engine.'
         ''
         'READ-ONLY:'
         '  owuihelp modelctrl viewall'
         '      Every stored model ID, display name, kind, active state and protection.'
         '  owuihelp modelctrl view <model>'
         '      Capabilities (vision, files, terminal, memory), every builtin category'
         '      (notifications, sub-agents, notes, channels, tasks, calendar, etc.),'
         '      native/MCP tools, skills, defaults, function calling and global gates.'
         '  owuihelp modelctrl catalog <model>'
         '      The same inventory plus every native tool and skill available to attach.'
         '  owuihelp modelctrl backups <model>'
         '      Rollback snapshots made before each applied change or restore.'
         ''
         'CHANGE FLOW:'
         '  1. view the model first'
         '  2. preview <model> ''<json>''       -> exact diff + preview_token'
         '  3. show/approve that diff'
         '  4. apply <model> ''<same json>'' <token>'
         '  The token becomes stale if either the model or JSON changes.'
         ''
         'ROLLBACK FLOW:'
         '  backups <model>'
         '  rollback-preview <model> <backup-id>  -> restore diff + token'
         '  rollback <model> <backup-id> <token>  -> verified restore'
         '  A rollback snapshots the state it replaces, so rollback is reversible too.'
         ''
         'EXAMPLES:'
         '  owuihelp modelctrl preview q_read-aloud:3b ''{"capabilities":{"vision":false}}'''
         '  owuihelp modelctrl preview claude-sonnet-5 ''{"builtin_tools":{"notifications":true}}'''
         '  owuihelp modelctrl preview huihui_ai/huihui-4:8b ''{"builtin_tools":{"subagents":true}}'''
         '  owuihelp modelctrl preview deepseek-r1:14b ''{"native_tools":{"run_python":false}}'''
         ''
         'JSON SECTIONS:'
         '  capabilities     vision/files/search/generation/code/terminal/memory/etc.'
         '  builtin_tools   time/files/chats/subagents/notifications/tasks/etc.'
         '  native_tools    installed Workspace > Tools IDs, true=attach false=remove'
         '  skills          installed skill IDs, true=attach false=remove'
         '  default_features web_search/image_generation/code_interpreter defaults'
         '  terminal_id     e.g. OpenTerminal, or null to remove'
         '  function_calling native, legacy, or null to inherit'
         '  is_active       show/hide the stored model entry'
         ''
         '! Enabling a model gate cannot override a disabled global switch, missing'
         '! user permission, or chat-level feature switch. "view" reports those gates.'
         '! Apply and rollback require the exact token from a fresh preview.'
         '! Full guide: E:\ai\ollama\docs\OWUI-MODEL-FEATURE-MANAGER.md'
       );
       act={ param([Parameter(ValueFromRemainingArguments=$true)]$a) _owui_modelctrl @a } }

    # ---------------- ComfyUI ----------------
    @{ cmd='comfy';      grp='ComfyUI'; blurb='Start ComfyUI hidden (background) on :8188';
       act={ _owui_start_comfy } }
    @{ cmd='comfy-show'; grp='ComfyUI'; blurb='Start ComfyUI in a visible console window';
       act={ _owui_start_comfy -Visible } }
    @{ cmd='comfy-stop'; grp='ComfyUI'; blurb='Kill the running ComfyUI process';
       act={ _owui_kill_comfy; Write-Host '  ComfyUI stopped.' -ForegroundColor Green } }

    # Cleanup. All three share _owui_comfy_clean; only -Mode differs. Flags are
    # forwarded via _owui_flag_ht (hashtable splat) - NOT '@args', which splats
    # an array POSITIONALLY and would drop '-DryRun' straight into -Mode. Same
    # footgun as push-vps.ps1, see the note on the 'pushvps' row below.
    @{ cmd='comfy-clean-videos'; grp='ComfyUI'; destructive=$true; alias=@('comfy-clean-vid')
       blurb='Delete ComfyUI VIDEO output (incl. animated .webp previews)'
       details=$Global:OWUI_COMFY_CLEAN_DETAILS
       act={ $ht = _owui_flag_ht $args; $ht['Mode'] = 'videos'; _owui_comfy_clean @ht } }

    @{ cmd='comfy-clean-images'; grp='ComfyUI'; destructive=$true; alias=@('comfy-clean-img')
       blurb='Delete ComfyUI STILL-IMAGE output (animated .webp are kept)'
       details=$Global:OWUI_COMFY_CLEAN_DETAILS
       act={ $ht = _owui_flag_ht $args; $ht['Mode'] = 'images'; _owui_comfy_clean @ht } }

    @{ cmd='comfy-clean-all';    grp='ComfyUI'; destructive=$true; alias=@('comfy-clean')
       blurb='Delete EVERYTHING in ComfyUI output\ and temp\ (not input\)'
       details=$Global:OWUI_COMFY_CLEAN_DETAILS
       act={ $ht = _owui_flag_ht $args; $ht['Mode'] = 'all'; _owui_comfy_clean @ht } }

    # ---------------- Stack (Docker) ----------------
    @{ cmd='up';        grp='Stack (Docker)'; blurb='Bring the whole OWUI/Ollama/mcpo stack online (idempotent)';
       act={ _owui_runps "$($OWUI.OllamaRoot)\start-stack.ps1" } }
    @{ cmd='bridges';   grp='Stack (Docker)'; blurb='Start the Gmail + Calendar OWUI bridges (revive if a bridge dropped out)';
       act={ _owui_start_bridges } }
    # Renamed 2026-07-31: 'watchdog' became ambiguous once 'autofree' arrived
    # (two different watchdogs). Old name kept as an alias.
    @{ cmd='mcpo-heal'; grp='Stack (Docker)'; alias=@('watchdog'); blurb='Heal a wedged mcpo session (restarts mcpo-core if stuck)';
       act={ _owui_runps "$($OWUI.OllamaRoot)\mcpo-watchdog.ps1" } }
    @{ cmd='testmcpo';  grp='Stack (Docker)'; blurb='Safely test if a newer mcpo image fixes the wedge bug (no prod touch)';
       act={ _owui_runps "$($OWUI.SupportScripts)\diagnostics\test-mcpo-upgrade.ps1" } }
    @{ cmd='tidy';      grp='Stack (Docker)'; blurb='Move OWUI automation chats into the "automatons" folder';
       act={ _owui_runps "$($OWUI.OllamaRoot)\kais_chat_tidy.ps1" } }
    @{ cmd='restack';   grp='Stack (Docker)'; destructive=$true; blurb='Full rebuild+recreate of the Docker stack (down/build/up)';
       act={ _owui_runps "$($OWUI.OllamaRoot)\restack-mcpo.ps1" } }

    # ---------------- VPS (remote) ----------------
    # One row, not twenty. Everything after 'vps' is forwarded verbatim to the
    # bash twin on the box, so the two halves cannot drift out of sync.
    @{ cmd='vps'; grp='VPS (remote)'; alias=@('remote')
       blurb='Run the VPS-side owuihelp over SSH. No args = its menu   e.g. owuihelp vps status'
       details=@(
         'HOW IT WORKS:'
         '  Everything after "vps" is forwarded verbatim to ~/bin/owuihelp on'
         '  {{VPS_TS_NAME}}, with a TTY - so colours, (y/N) prompts and'
         '  "logs -f" behave exactly as they do when you SSH in by hand.'
         '  Add a command to the VPS script and it works from here immediately;'
         '  there is nothing to mirror in this file.'
         ''
         'THE ONES YOU WILL ACTUALLY TYPE:'
         '  owuihelp vps status      containers, ports, the PC link, disk and RAM'
         '  owuihelp vps exposure    is anything published beyond loopback'
         '  owuihelp vps tools       how many tools mcpo is really serving'
         '  owuihelp vps mcpo-heal   fix a short tool list in OWUI'
         '  owuihelp vps logs open-webui 200'
         '  owuihelp vps <cmd> ?     explain a remote command without running it'
         ''
         'GUARD RAILS:'
         '! Destructive remote commands (down, recreate, prune) refuse over SSH'
         '! unless you add -y. That is the VPS script protecting itself - a typo'
         '! from here cannot take the front end offline.'
         '  Nothing on the VPS side ever passes -v or --volumes.'
         ''
         'SOURCE OF TRUTH:'
         '  E:\ai\ollama\vps\owuihelp on THIS machine. Edit there, then run'
         '  "owuihelp vps-install" to redeploy. Editing the copy on the VPS'
         '  works until the next install silently reverts it.'
       )
       act={ _owui_vps @args } }

    @{ cmd='vps-install'; grp='VPS (remote)'; alias=@('vpsinstall')
       blurb='Deploy or update the VPS-side owuihelp from E:\ai\ollama\vps\owuihelp (idempotent)'
       details=@(
         'WHAT IT DOES:'
         '  scp the script to ~/bin/owuihelp on the VPS, strip any CR line'
         '  endings Windows added, chmod 755, then run it once to prove it works.'
         '  Safe to re-run after every edit - that is the intended workflow.'
       )
       act={ _owui_vps_install } }

    @{ cmd='vpsssh'; grp='VPS (remote)'; alias=@('vps-shell','sshvps')
       blurb='Open an interactive shell on the VPS (plain ssh, nothing clever)'
       act={ ssh $OWUI_VPS_HOST } }

    # ---------------- Health & logs ----------------
    @{ cmd='status';   grp='Health & logs'; blurb='One-glance health: ports, VRAM + who holds it, resident models, KEEP_ALIVE';
       act={ _owui_status } }
    @{ cmd='mappings'; grp='Health & logs'; blurb='Tailnet URL map: every tailscale serve route, its local target, and whether that target is up';
       act={ _owui_mappings } }
    @{ cmd='logs';     grp='Health & logs'; blurb='Live-tail the ComfyUI log (Ctrl+C to stop)';
       act={ _owui_logs } }
    @{ cmd='exposure'; grp='Health & logs'; blurb='Audit what is reachable over Tailscale/LAN vs loopback';
       act={ _owui_runps "$($OWUI.SupportScripts)\diagnostics\Check-TailnetExposure.ps1" } }
    @{ cmd='tasks';    grp='Health & logs'; blurb='List the OWUI scheduled tasks and whether each is registered';
       act={ _owui_tasks } }
    @{ cmd='rename-tasks'; grp='Setup (one-time)'; admin=$true; blurb='Migrate the two legacy-named scheduled tasks onto the OWUI-Kebab-Case convention';
       act={ _owui_rename_tasks } }
    @{ cmd='find';     grp='Health & logs'; blurb='Search commands by name or description   e.g. owuihelp find vram';
       act={ param($a) _owui_find $a } }

    @{ cmd='update-owui'; grp='Stack (Docker)'; destructive=$true; alias=@('updateowui','upgrade-owui');
       blurb='Upgrade open-webui + open-terminal to the current :latest (backup, pull, recreate, verify, print digests)';
       details=@(
         'WHY THIS EXISTS:'
         'Both services run a floating :latest tag. start-stack.ps1 runs'
         '"docker compose up -d --build" at every boot, which recreates from the'
         'LOCAL :latest tag - whatever was last pulled, not what is newest'
         'upstream. Let the local tag go stale and the next REBOOT downgrades'
         'you. This command keeps the local tag current, in one step.'
         ''
         'WHAT IT DOES:'
         '  1. owuihelp backup            (skip with -SkipBackup)'
         '  2. docker compose pull open-webui open-terminal'
         '  3. docker compose up -d open-webui open-terminal'
         '  4. verifies health, versions, and all 20 mcpo tool servers (Ch. 10.5)'
         '  5. prints the new digests to record'
         ''
         'AFTER IT FINISHES:'
         '  Paste the digests into docker-compose.yml, update master doc 5.2'
         '  and 23, and append a ledger row with "owuihelp changelog".'
         ''
         '! Brief OWUI downtime while the container is recreated.'
         '! Deliberately does NOT touch tika or playwright-mcp, which also float.'
         '! Read Ch. 14 (config DB beats compose) before a MAJOR version jump.'
       );
       act={ param([switch]$SkipBackup) _owui_update_owui -SkipBackup:$SkipBackup } }

    @{ cmd='pull-latest'; grp='Stack (Docker)'; destructive=$true; alias=@('pulllatest','pull');
       blurb='Pull EVERY floating-tag image (open-webui, open-terminal, tika, playwright-mcp), report what changed, optionally recreate';
       details=@(
         'WHY THIS EXISTS:'
         '"docker restart" reuses the existing container and changes NOTHING.'
         '"docker compose up -d" recreates from the tag AS IT EXISTS ON DISK.'
         'Neither one asks the registry. A floating :latest therefore only moves'
         'when something PULLS - and a stale local tag downgrades the service at'
         'the next boot, because start-stack.ps1 runs "up -d --build". Ch. 20.18.'
         ''
         'USE:'
         '  owuihelp pull-latest              pull all floating tags, report changes'
         '  owuihelp pull-latest -Recreate    ...and recreate the ones that moved'
         '  owuihelp pull-latest -Only tika   just that service'
         ''
         'WHAT COUNTS AS FLOATING:'
         'Detected from the compose file, not hardcoded. Skips digest-pinned'
         'images, version-pinned tags, and locally built ones (:pinned, build:).'
         'Today that means open-webui, open-terminal, tika, playwright-mcp.'
         ''
         '! Pull alone is SAFE - running containers are untouched until recreate.'
         '! For open-webui/open-terminal prefer "owuihelp update-owui": it backs'
         '! up first and verifies the 20 mcpo tool servers afterwards (Ch. 10.5).'
         '! Record the printed digests and log a ledger row.'
       );
       act={ param([switch]$Recreate, [string[]]$Only) _owui_pull_latest -Recreate:$Recreate -Only $Only } }

    # ---------------- Host packages (winget) ----------------
    @{ cmd='update'; grp='Host packages'; alias=@('updates','what-update');
       blurb='Signpost: shows the four update lanes and what each one actually touches (updates nothing itself)';
       details=@(
         'WHY THIS EXISTS:'
         'Four things on this stack are called "update" and they are not'
         'interchangeable: two containers, all floating images, every Ollama'
         'model, and every host package. Reaching for the wrong one is how you'
         'bounce Docker when you meant winget.'
         ''
         'This row performs NO action. It prints the lanes and exits.'
         ''
         'THE LANES:'
         '  update-owui          open-webui + open-terminal containers (guarded)'
         '  pull-latest          all floating-tag images, incl. tika/playwright'
         '  updateall            every Ollama model'
         '  winget-upgrade-all   host packages via winget'
         ''
         '! ComfyUI is in NONE of them - it is a bare git checkout, not a'
         '! container, and it is deliberately updated by hand.'
       );
       act={ _owui_update_menu } }

    @{ cmd='winget-upgrade-all'; grp='Host packages'; destructive=$true; alias=@('winget','wga');
       blurb='winget upgrade --all, fully unattended, with Ollama + Docker Desktop held back by blocking pins';
       details=@(
         'WHAT IT RUNS:'
         '  winget upgrade --all --include-unknown --include-pinned'
         '                 --accept-package-agreements --accept-source-agreements'
         '                 --silent --disable-interactivity --force --nowarn'
         ''
         'There is no -y in winget. The two --accept-* flags plus'
         '--disable-interactivity are the equivalent.'
         ''
         'THE GUARD (this is the point of the command):'
         'Ollama.Ollama and Docker.DockerDesktop are BOTH winget-managed on this'
         'box. Ollama is the dangerous one - the tray updater racing'
         'start-stack.ps1 has deleted lib\ollama before and left Ollama CPU-only.'
         'winget 1.29 has no --exclude on upgrade, so this adds a BLOCKING pin to'
         'each before sweeping. A blocking pin survives --include-pinned; an'
         'ordinary one does not. Pins are added once, then just reported.'
         ''
         'FLAGS:'
         '  -DryRun      list what WOULD upgrade, install nothing. Use this first.'
         '  -IgnoreHash  add --ignore-security-hash. See the warning below.'
         '  -NoGuard     do not hold Ollama/Docker Desktop back. Rarely wise.'
         ''
         'EXAMPLES:'
         '    owuihelp winget-upgrade-all -DryRun     see the damage first'
         '    owuihelp winget-upgrade-all             sweep, guarded'
         '    owuihelp wga -IgnoreHash                one stubborn hash mismatch'
         ''
         'AFTERWARDS it re-lists whatever is still pending, confirms the Ollama'
         'GPU libs are intact, and prints the exact three lines to move a held'
         'package deliberately.'
         ''
         '! Elevates itself if needed - the sweep continues in a new admin window.'
         '! -IgnoreHash disables installer integrity checking. A hash mismatch is'
         '! usually a corrupt download, but it is also what a tampered mirror'
         '! looks like. Targeted use only, never a default.'
         '! --allow-reboot and --uninstall-previous are deliberately NOT included.'
         '! Log anything that moved:  owuihelp changelog'
       );
       act={ param($a,$b,$c)
             $ht = _owui_flag_ht @($a,$b,$c)
             $ok = @{}
             foreach ($k in $ht.get_Keys()) {
                 switch -Regex ("$k".ToLower()) {
                     '^(dryrun|dry|n|list|preview)$' { $ok['DryRun']     = $true }
                     '^(ignorehash|hash|nohash)$'    { $ok['IgnoreHash'] = $true }
                     '^(noguard|unsafe)$'            { $ok['NoGuard']    = $true }
                     default { Write-Host "  [!] unknown flag: -$k" -ForegroundColor Yellow }
                 }
             }
             _owui_winget_upgrade_all @ok } }

    # ---------------- Change ledger ----------------
    @{ cmd='changelog'; grp='Change ledger'; alias=@('log','ledger','aichange');
       blurb='Read or append the AI change ledger (AI-CHANGELOG.csv) - the handover record between assistants';
       details=@(
         'WHAT IT IS:'
         'AI-CHANGELOG.csv is the append-only record of every change an assistant'
         'makes to this stack. It exists so Liam never has to relay a change from'
         'one assistant to the other by hand. Rules: AI-CHANGELOG-PROTOCOL.md.'
         ''
         'READ:'
         '  owuihelp changelog                    last 10 rows'
         '  owuihelp changelog tail 25            last 25 rows'
         '  owuihelp changelog find open-terminal every row touching a component'
         ''
         '! Ten rows is orientation, not history. SEARCH for any component you'
         '! are about to change before you change it.'
         ''
         'WRITE (assistants, in the same session as the change):'
         '  owuihelp changelog -Author Claude -LoggedBy Claude -Model claude-opus-5 `'
         '     -Request <the ask> -Summary <one line> -Files <a; b> -Steps <a; b> `'
         '     -Completed Y -Verification "live: ... | trust: ..." `'
         '     -Sections "5.2; 22" -Rollback <how to undo> -Risk <what could bite> `'
         '     -Provenance verified-live -Tier routine|material'
         ''
         'TIERS (protocol 5.2):'
         '  routine  = ledger row only. Comments, tidying, digest re-records,'
         '             a helper added. This is the default.'
         '  material = also update the chapter, Ch. 21 and Ch. 22. Behaviour,'
         '             security, exposure, versions, a new trap or policy.'
         '             If unsure, choose material.'
         ''
         '  Add -WhatIf to see the row without writing it.'
         ''
         '! This is NOT "owuihelp logs" - that live-tails the ComfyUI log.'
         '! Never hand-edit or delete a row. Correct a bad row with a new row.'
         '! A value starting with "-" must go through Add-AIChange.ps1 directly.'
         '! Quote the row id it prints in your handoff to Liam.'
       );
       act={ param([Parameter(ValueFromRemainingArguments=$true)]$a) _owui_changelog @a } }

    # ---------------- Backups ----------------
    @{ cmd='backup';   grp='Backups'; alias=@('backup-manual','backupmanual','manual-backup','bm');
       blurb='Manual brains-backup NOW -> D:\owuibackups\manual (own stream; never touches the nightly 7-day set)';
       details=@(
         'Takes a "brains" backup immediately and writes it to the MANUAL stream:'
         '    D:\owuibackups\manual\owui-brains-<yyyyMMdd-HHmmss>\'
         ''
         'TWO STREAMS, AND WHY IT MATTERS:'
         '    nightly  D:\owuibackups\nightly\  rolling - keeps only the newest 7'
         '    manual   D:\owuibackups\manual\   kept FOREVER, never pruned'
         '  This command only ever writes to manual, so a backup you take by hand'
         '  can never be deleted by the nightly rotation. Run it after any session'
         '  where you changed compose, the pinned config or the Dockerfile.'
         ''
         'WHAT IT CAPTURES:'
         '    webui.db          live OWUI database - pipes, tools, functions, config, chats'
         '    uploads/vector_db OWUI files + knowledge embeddings'
         '    ollama\           compose, Dockerfile.mcpo, pinned configs, .env, secrets,'
         '                      bridges, every *.ps1, docs\   (excludes .git, logs, backups)'
         '    comfyui\          code, custom_nodes, workflows  (NO model weights)'
         '    windows\          .wslconfig, Startup folder, scheduled-task XML'
         '    manifests\        model lists to re-pull, pip freeze, docker/volume state'
         '    RESTORE.md        step-by-step runbook to rebuild from scratch'
         ''
         'SAFE WHILE YOU ARE USING OWUI:'
         '  The database is captured with SQLite''s online .backup() API and a'
         '  15s busy timeout, from inside the running container. Nothing is stopped,'
         '  no chat is interrupted. Run it mid-conversation if you like.'
         ''
         'NOT INCLUDED:'
         '  Model weights (Ollama + ComfyUI). Manifests list them for re-download.'
         '  Expect ~1-2 GB per backup rather than hundreds.'
         ''
         '! The backup contains .env and secrets\ IN THE CLEAR - API keys, PATs,'
         '! WEBUI_SECRET_KEY, MCP_ADMIN_TOKEN, Google OAuth keys. Make sure D:\ is'
         '! encrypted, and think before copying a backup folder anywhere else.'
         ''
         'RELATED:'
         '    owuihelp backups        list both streams, newest first, with ages'
         '    owuihelp pushvps        send the newest backup offsite to the VPS'
       );
       act={ _owui_backup } }
    @{ cmd='backup-push'; grp='Backups'; alias=@('backuppush','bp');
       blurb='Manual backup THEN push that exact one offsite to the VPS (one command, no ambiguity)';
       details=@(
         'Runs the two-step you almost always want:'
         '    1. backup-owui.ps1 -Mode manual   ->  D:\owuibackups\manual\'
         '    2. push-vps.ps1 -Manual           ->  ships THAT backup to the VPS'
         ''
         'WHY IT FORCES -Manual:'
         '  A bare "pushvps" picks the newest across BOTH streams. That is normally the'
         '  one you just took - but if the 03:00 nightly happens to land between the two'
         '  steps, the wrong folder goes offsite. Forcing the manual stream removes the'
         '  ambiguity completely.'
         ''
         'IT STOPS IF THE BACKUP FAILS:'
         '  The push only runs after the backup exits cleanly AND a manual folder is'
         '  confirmed on disk. You will never ship a stale copy believing it is fresh.'
         ''
         'SAFE WHILE YOU ARE USING OWUI:'
         '  The database is captured with SQLite''s online .backup() API from inside the'
         '  running container. Nothing is stopped, no chat is interrupted.'
         ''
         '! The archive contains .env and secrets\ IN THE CLEAR, and uploads them to the'
         '! VPS. Transit is over the tailnet, but live credentials then exist in two'
         '! places - make sure that disk is encrypted too.'
         ''
         'RELATED:'
         '    owuihelp backup     backup only, no push'
         '    owuihelp pushvps    push only, without taking a new backup'
         '    owuihelp backups    list both streams with ages'
       );
       act={ _owui_backup_push } }
    @{ cmd='prunevps'; grp='Backups'; alias=@('prune-vps');
       blurb='Delete OFFSITE backups older than N days on the VPS (DRY RUN by default; -Execute to apply)';
       details=@(
         'Age-based cleanup of the offsite copies. push-vps.ps1 already prunes by COUNT'
         '(-KeepRemote, default 8); this prunes by AGE, which is what you want when'
         'pushes are irregular - eight copies from one busy week is not eight weeks of'
         'history.'
         ''
         'RETENTION IS THE UNION OF TWO RULES - a backup survives if EITHER holds:'
         '    * it is among the newest -KeepCount   (default 10), OR'
         '    * it is newer than -KeepDays          (default 10 days)'
         '  It is deleted only when it fails BOTH. Count is the important one: if'
         '  something breaks and you do not notice for a week, an age-only rule could'
         '  delete the last known-good copy.'
         ''
         'USAGE:'
         '    owuihelp prunevps                          DRY RUN - shows what would go'
         '    owuihelp prunevps -Execute                 actually deletes'
         '    owuihelp prunevps -KeepCount 20 -Execute   deeper history'
         '    owuihelp prunevps -KeepDays 30 -Execute    longer window'
         ''
         'SAFETY:'
         '  ! DRY RUN BY DEFAULT. Nothing is deleted without -Execute.'
         '  ! Only touches owui-brains-*.zip in the remote directory.'
         ''
         'WHY FILENAME TIMESTAMPS, NOT mtime:'
         '  An scp copy resets mtime, which would make every file look brand new. Age is'
         '  read from owui-brains-<yyyyMMdd-HHmmss>.zip instead.'
         ''
         'WHY ONLY MANUAL BACKUPS REACH THE VPS:'
         '  A bare "pushvps" picks the newest across BOTH streams. If you always push'
         '  right after taking a manual backup, manual always wins and the 03:00 nightly'
         '  never gets selected. Use "owuihelp pushvps -Nightly" to ship one deliberately.'
         ''
         'RELATED:'
         '    owuihelp pushvps        send a backup offsite'
         '    owuihelp backup-push    backup + push in one command'
       );
       act={ param($a) & "$($OWUI.OllamaRoot)\prune-vps.ps1" @args } }
    @{ cmd='backups';  grp='Backups'; blurb='List nightly + manual backups: size, timestamp, age, and which one is NEWEST';
       details=@(
         'Lists every backup in BOTH streams, newest first, showing size, when it'
         'was taken, and how long ago. The newest across both streams is marked'
         'green with "<-- NEWEST OVERALL".'
         ''
         'ANSWERS THE QUESTION "WHICH COPY AM I LOOKING AT?":'
         '  Folder names are owui-brains-<yyyyMMdd-HHmmss>, so the timestamp IS the'
         '  identity. The age column ("2m ago" vs "19h ago") tells you instantly'
         '  whether you are looking at the backup you just generated or last'
         '  night''s scheduled one.'
         ''
         'IT ALSO TELLS YOU WHAT WOULD BE PUSHED:'
         '  The footer names the exact folder "owuihelp pushvps" would ship with no'
         '  arguments, and which stream it came from. Check this BEFORE pushing.'
         ''
         'READ-ONLY. Lists and measures only - never deletes or moves anything.'
         ''
         'RELATED:'
         '    owuihelp backup         take a new manual backup now'
         '    owuihelp pushvps        send the newest one offsite'
       );
       act={ _owui_list_backups } }
    @{ cmd='pushvps';  grp='Backups'; blurb='Push the NEWEST backup OFFSITE to the VPS  (-Manual / -Nightly to force a stream; see "pushvps ?")';
       details=@(
         'Zips the MOST RECENT backup folder and scp''s it to the VPS over the'
         'tailnet. It does NOT create a backup - it ships one that already exists.'
         ''
         'WHICH COPY GETS SENT:'
         '    owuihelp pushvps             newest across BOTH streams   (default)'
         '    owuihelp pushvps -Manual     newest MANUAL backup'
         '    owuihelp pushvps -Nightly    newest NIGHTLY backup'
         ''
         '  Bare words work too and mean the same thing:'
         '    owuihelp pushvps manual      same as -Manual'
         '    owuihelp pushvps nightly     same as -Nightly'
         ''
         '  ALWAYS the newest in whichever stream you picked. There is NO flag to'
         '  push an older, named backup. If you need a specific older one, zip and'
         '  scp it by hand, or ask for a -Name flag to be added.'
         ''
         'EVERY FLAG, IN FULL:'
         '    -Manual              force the manual stream          (switch, off)'
         '    -Nightly             force the nightly stream         (switch, off)'
         '    -KeepRemote <n>      how many copies to keep on the VPS   (default 8)'
         '                         0 = never prune anything remotely'
         '    -SshHost <name>      ssh alias to send to              (default vps)'
         '    -RemoteDir <path>    directory on the VPS  (default ~/owuibackup)'
         '    -Root <path>         where backups live  (default D:\owuibackups)'
         '    -Stream <name>       older spelling: auto | nightly | manual'
         '                         kept so existing scripts keep working'
         ''
         '  PowerShell flags are -Name Value, NOT -Name=Value:'
         '    owuihelp pushvps -KeepRemote 20          correct'
         '    owuihelp pushvps -KeepRemote=20          WRONG'
         ''
         '  Every argument is forwarded to push-vps.ps1 and the exact command line'
         '  is echoed before it runs, so you can see what was actually passed.'
         '  (Before 2026-08-05 anything other than nightly/manual/auto was'
         '  SILENTLY DISCARDED and the script ran with defaults.)'
         ''
         'CHECK BEFORE YOU PUSH:'
         '    owuihelp backups'
         '  Its footer names the exact folder a bare "pushvps" would ship, and'
         '  which stream it came from. No guessing.'
         ''
         'WHY "NEWEST OF EITHER" IS THE DEFAULT (changed 2026-07-30):'
         '  It used to default to nightly. Taking a fresh manual backup and then'
         '  pushing would silently ship LAST NIGHT''S 03:00 copy instead of the one'
         '  you had just made. The default now picks whichever stream holds the'
         '  newest folder, which is nearly always what you meant.'
         ''
         'REMOTE RETENTION:'
         '  Old copies on the VPS are pruned to the newest -KeepRemote (8 by'
         '  default). Offsite is a disaster-recovery tier, not an archive - keep'
         '  anything you truly care about in the local manual stream too.'
         ''
         '! The archive contains .env and secrets\ IN THE CLEAR. Transit is over'
         '! the tailnet so that part is fine, but live credentials then exist on'
         '! the VPS as well - make sure that disk is encrypted too.'
         ''
         'RELATED:'
         '    owuihelp backups        ages, sizes, and which one is newest'
         '    owuihelp backup         take a fresh manual backup first'
       );
       # 2026-08-05: this used to accept ONLY the bare words nightly|manual|auto
       # and SILENTLY DISCARD anything else, so 'owuihelp pushvps -KeepRemote 20'
       # ran with defaults and said nothing. Now every argument is forwarded:
       # bare words are translated to -Stream, real flags pass straight through.
       act={
             $script = "$($OWUI.OllamaRoot)\push-vps.ps1"

             # Build a HASHTABLE and splat that. Splatting a plain ARRAY passes the
             # elements POSITIONALLY, so '-Manual' landed in $SshHost and the push
             # tried 'ssh -Manual'. Hashtable splatting binds by name, always.
             $ht   = @{}
             $toks = @($args)
             for ($i = 0; $i -lt $toks.Count; $i++) {
                 $t = "$($toks[$i])"
                 if ($t -match '^-{1,2}(.+)$') {
                     $name = $Matches[1]
                     $next = if ($i + 1 -lt $toks.Count) { "$($toks[$i+1])" } else { $null }
                     if ($next -and $next -notmatch '^-') {      # -KeepRemote 20
                         $ht[$name] = $next; $i++
                     } else {                                    # -Manual  (a switch)
                         $ht[$name] = $true
                     }
                 } elseif ($t.ToLower() -in 'nightly','manual','auto') {
                     $ht['Stream'] = $t.ToLower()                # bare word shorthand
                 } else {
                     Write-Host "  [!] ignoring unrecognised argument: $t" -ForegroundColor Yellow
                 }
             }
             if ($ht.Count) {
                 $shown = ($ht.GetEnumerator() | Sort-Object Name |
                           ForEach-Object { if ($_.Value -is [bool]) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value)" } }) -join ' '
                 Write-Host "  -> push-vps.ps1 $shown" -ForegroundColor DarkGray
             }
             & $script @ht } }

    # ---------------- Master resets ----------------
    @{ cmd='reset';     grp='Master resets'; destructive=$true; blurb='Graceful full restart: models->comfy->docker->comfy->status';
       act={ _owui_reset } }
    @{ cmd='hardreset'; grp='Master resets'; destructive=$true; admin=$true; blurb='NUCLEAR: kill all, fix port 8188, rebuild docker, restart, verify';
       act={ _owui_hardreset } }

    # ---------------- Setup (one-time) ----------------
    # All four installers live together now. Previously two sat under Backups
    # and two under Setup, so there was no single place to see what was
    # scheduled. 'install-all' registers the lot.
    @{ cmd='install-all';      grp='Setup (one-time)'; blurb='Register EVERY scheduled task below in one go';
       act={ _owui_install_all } }
    @{ cmd='install-backup';   grp='Setup (one-time)'; blurb='Nightly 03:00 rolling brains-backup';
       act={ _owui_install_task 'Backup' } }
    @{ cmd='install-pushvps';  grp='Setup (one-time)'; blurb='Weekly Sunday 04:00 offsite push to the VPS';
       act={ _owui_install_task 'PushVps' } }
    @{ cmd='install-tidy';     grp='Setup (one-time)'; blurb='Daily 05:00 automation-chat tidy (the one installer this toolkit was missing)';
       act={ _owui_install_task 'Tidy' } }
    @{ cmd='install-startup';  grp='Setup (one-time)'; admin=$true; blurb='Register start-stack.ps1 to auto-run at logon';
       act={ _owui_runps "$($OWUI.SupportScripts)\installers\install-startup-task.ps1" -NeedsAdmin } }
    @{ cmd='install-watchdog'; grp='Setup (one-time)'; admin=$true; blurb='Register mcpo-watchdog to run every 5 min';
       act={ _owui_runps "$($OWUI.SupportScripts)\installers\install-mcpo-watchdog-task.ps1" -NeedsAdmin } }
    @{ cmd='fixport';          grp='Setup (one-time)'; admin=$true; blurb='Free+reserve TCP 8188 from WinNAT (fixes WinError 10013)';
       act={ _owui_runps "$($OWUI.ComfyApp)\fix_port_8188.ps1" -NeedsAdmin } }
    @{ cmd='pagefile';         grp='Setup (one-time)'; admin=$true; blurb='Raise Windows pagefile to 32/80 GB (reboot to apply)';
       act={ _owui_runps "$($OWUI.ComfyRoot)\set-pagefile-admin.ps1" -NeedsAdmin } }
)

# ============================================================================
#  SCHEDULED TASKS
#  Single source of truth. Before 2026-07-31 the schtasks lines were inlined in
#  the registry with two naming conventions ("OWUI Nightly Backup" vs
#  "OWUI-mcpo-Watchdog"), which made them impossible to list reliably.
#  Everything is OWUI-Kebab-Case now.
# ============================================================================
$Global:OWUI_TASKS = [ordered]@{
    Backup  = @{ Name='OWUI-Nightly-Backup';  Legacy='OWUI Nightly Backup'
                 Schedule=@('/SC','DAILY','/ST','03:00')
                 Script='backup-owui.ps1'; Args='-Mode nightly'; Desc='Nightly rolling brains-backup' }
    PushVps = @{ Name='OWUI-Weekly-VPS-Push'; Legacy='OWUI Weekly VPS Push'
                 Schedule=@('/SC','WEEKLY','/D','SUN','/ST','04:00')
                 Script='push-vps.ps1';    Args='';               Desc='Weekly offsite push to VPS' }
    Tidy    = @{ Name='OWUI-Automation-Chat-Tidy'; Schedule=@('/SC','DAILY','/ST','05:00')
                 Script='kais_chat_tidy.ps1'; Args='';            Desc='Daily automation-chat tidy' }
}
# Registered by external scripts, listed here so 'tasks' can report on them.
$Global:OWUI_EXTERNAL_TASKS = @('OWUI-Stack-Startup','OWUI-mcpo-Watchdog')

function _owui_task_exists ([string]$Name) {
    $null = schtasks /Query /TN "$Name" 2>&1
    return ($LASTEXITCODE -eq 0)
}

function _owui_install_task ([string]$Key) {
    $t = $OWUI_TASKS[$Key]
    if (-not $t) { Write-Host "  [x] unknown task key '$Key'" -ForegroundColor Red; return }
    $script = Join-Path $OWUI.OllamaRoot $t.Script
    if (-not (Test-Path $script)) { Write-Host "  [x] not found: $script" -ForegroundColor Red; return }

    $run = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if ($t.Args) { $run += " $($t.Args)" }

    $out = schtasks /Create /TN $t.Name /TR $run @($t.Schedule) /F 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("    [ok] {0,-28} {1}" -f $t.Name, $t.Desc) -ForegroundColor Green
    } else {
        Write-Host ("    [x]  {0,-28} {1}" -f $t.Name, ($out -join ' ')) -ForegroundColor Red
    }
}

function _owui_install_all {
    _owui_head 'Registering all OWUI scheduled tasks'
    foreach ($k in $OWUI_TASKS.Keys) { _owui_install_task $k }
    Write-Host ''
    Write-Host '    install-startup / install-watchdog need admin - run them separately.' -ForegroundColor DarkGray
}

function _owui_tasks {
    _owui_head 'OWUI scheduled tasks'
    $anyLegacy = $false
    foreach ($k in $OWUI_TASKS.Keys) {
        $t = $OWUI_TASKS[$k]
        if (_owui_task_exists $t.Name) {
            Write-Host ("    {0,-30} {1}  {2}" -f $t.Name, 'registered', $t.Desc) -ForegroundColor Green
        } elseif ($t.Legacy -and (_owui_task_exists $t.Legacy)) {
            # Registered, just under the pre-2026-07-31 name. Not broken - only
            # inconsistent - so say so precisely rather than crying MISSING.
            $anyLegacy = $true
            Write-Host ("    {0,-30} {1}  {2}" -f $t.Legacy, 'legacy name', $t.Desc) -ForegroundColor Yellow
        } else {
            Write-Host ("    {0,-30} {1}  {2}" -f $t.Name, 'MISSING   ', $t.Desc) -ForegroundColor Red
        }
    }
    foreach ($n in $OWUI_EXTERNAL_TASKS) {
        $ok = _owui_task_exists $n
        $c  = if ($ok) { 'Green' } else { 'Yellow' }
        $s  = if ($ok) { 'registered' } else { 'MISSING   ' }
        Write-Host ("    {0,-30} {1}  (external installer)" -f $n, $s) -ForegroundColor $c
    }

    # The autofree watchdog persists via a Startup shortcut, not a task, because
    # schtasks /SC ONLOGON needs elevation. Report it here anyway so this screen
    # is the honest full picture of "what starts by itself".
    $lnk = _owui_autofree_lnk
    $ok  = Test-Path $lnk
    $c   = if ($ok) { 'Green' } else { 'Yellow' }
    $s   = if ($ok) { 'registered' } else { 'MISSING   ' }
    Write-Host ("    {0,-30} {1}  (Startup shortcut, not a task)" -f 'ComfyUI AutoFree', $s) -ForegroundColor $c
    Write-Host ''
    Write-Host '    register missing ones with: owuihelp install-all' -ForegroundColor DarkGray
    if ($anyLegacy) {
        Write-Host '    normalise the legacy names with: owuihelp rename-tasks   (needs admin)' -ForegroundColor DarkYellow
    }
}

# Migrate the two tasks that predate the naming convention. Separate command
# because deleting a task created by an elevated process needs elevation - a
# non-admin schtasks /Delete returns "Access is denied", and doing the create
# half without the delete half leaves BOTH firing at 03:00.
function _owui_rename_tasks {
    if (-not (_owui_admin)) {
        Write-Host '  [!] renaming scheduled tasks needs admin - relaunching elevated...' -ForegroundColor Yellow
        Start-Process pwsh -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass',
            '-Command', ". 'E:\ai\ollama\owui-toolkit.ps1'; _owui_rename_tasks; Read-Host 'done - press Enter'") | Out-Null
        return
    }
    _owui_head 'Normalising scheduled task names'
    foreach ($k in $OWUI_TASKS.Keys) {
        $t = $OWUI_TASKS[$k]
        if (-not $t.Legacy) { continue }
        $hasNew = _owui_task_exists $t.Name
        $hasOld = _owui_task_exists $t.Legacy
        if ($hasNew -and -not $hasOld) { Write-Host ("    [ok] {0} already normalised" -f $t.Name) -ForegroundColor Green; continue }
        if (-not $hasOld) { Write-Host ("    [--] {0} not present" -f $t.Legacy) -ForegroundColor DarkGray; continue }

        # Create the new one FIRST, verify, and only then remove the old one.
        _owui_install_task $k
        if (-not (_owui_task_exists $t.Name)) {
            Write-Host ("    [x]  could not create {0} - leaving '{1}' alone" -f $t.Name, $t.Legacy) -ForegroundColor Red
            continue
        }
        $out = schtasks /Delete /TN $t.Legacy /F 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("    [ok] removed legacy '{0}'" -f $t.Legacy) -ForegroundColor Green
        } else {
            # Never leave duplicates behind - roll the new one back.
            schtasks /Delete /TN $t.Name /F 2>&1 | Out-Null
            Write-Host ("    [x]  could not remove '{0}' ({1}) - rolled back, no duplicates" -f $t.Legacy, ($out -join ' ')) -ForegroundColor Red
        }
    }
    Write-Host ''
    _owui_tasks
}

# Pulled out of the registry - a 12-line scriptblock inline in a table row was
# the least readable thing in this file.
# Parse the timestamp out of an 'owui-brains-yyyyMMdd-HHmmss' folder name.
# Returns $null if the name doesn't match, so odd folders don't blow this up.
function _owui_backup_stamp ([string]$Name) {
    if ($Name -match 'owui-brains-(\d{8}-\d{6})$') {
        try { return [datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', $null) } catch { return $null }
    }
    return $null
}

function _owui_backup_age ([datetime]$When) {
    $ts = (Get-Date) - $When
    if ($ts.TotalMinutes -lt 60) { return ('{0}m ago'    -f [int]$ts.TotalMinutes) }
    if ($ts.TotalHours   -lt 24) { return ('{0}h ago'    -f [int]$ts.TotalHours) }
    return ('{0}d {1}h ago' -f [int]$ts.TotalDays, ($ts.Hours))
}

# Lists both streams with AGE and an explicit NEWEST marker, then states which
# folder 'pushvps' would actually ship. Added 2026-08-05: the whole point is to
# remove any doubt about whether you're looking at the backup you just took or
# last night's — the same confusion that caused the -Stream auto fix in
# push-vps.ps1 on 2026-07-30.
function _owui_list_backups {
    # Pass 1: collect only. All printing happens in pass 2 so the newest-overall
    # marker can be worked out first and each stream gets exactly one heading.
    $all = @()
    foreach ($s in 'nightly','manual') {
        $d = "D:\owuibackups\$s"
        if (-not (Test-Path $d)) { continue }
        $rows = Get-ChildItem $d -Directory -Filter 'owui-brains-*' -EA SilentlyContinue
        foreach ($r in $rows) {
            $gb = [math]::Round(((Get-ChildItem $r.FullName -Recurse -File -EA SilentlyContinue |
                    Measure-Object Length -Sum).Sum)/1GB, 2)
            $when = _owui_backup_stamp $r.Name
            if (-not $when) { $when = $r.LastWriteTime }
            $all += [pscustomobject]@{ Name=$r.Name; Stream=$s; When=$when; GB=$gb; Path=$r.FullName }
        }
    }

    if (-not $all) { Write-Host ''; Write-Host '    no backups found at all.' -ForegroundColor Yellow; return }

    $newest = $all | Sort-Object When -Descending | Select-Object -First 1

    # Pass 2: display.
    foreach ($s in 'nightly','manual') {
        $note = if ($s -eq 'nightly') { 'rolling - keeps only the newest 7' } else { 'kept forever - never pruned' }
        _owui_head "Backups: $s   ($note)"
        $rows = $all | Where-Object Stream -eq $s | Sort-Object When -Descending
        if (-not $rows) { Write-Host '    (none yet)' -ForegroundColor DarkGray; continue }
        foreach ($r in $rows) {
            $isNewest = ($r.Name -eq $newest.Name -and $r.Stream -eq $newest.Stream)
            $col = if ($isNewest) { 'Green' } else { 'Gray' }
            Write-Host ("    {0}  {1,6} GB  {2}  {3,-12}" -f `
                $r.Name, $r.GB, $r.When.ToString('ddd dd MMM HH:mm'), (_owui_backup_age $r.When)) `
                -ForegroundColor $col -NoNewline
            if ($isNewest) { Write-Host '  <-- NEWEST OVERALL' -ForegroundColor Green } else { Write-Host '' }
        }
    }

    Write-Host ''
    Write-Host ("  'owuihelp pushvps' (no args) would ship:") -ForegroundColor DarkGray
    Write-Host ("    {0}   [stream: {1}]" -f $newest.Name, $newest.Stream) -ForegroundColor Yellow
    Write-Host ("  Force the other stream with:  owuihelp pushvps nightly | manual") -ForegroundColor DarkGray
    Write-Host ''
}

function _owui_find ([string]$Text) {
    if (-not $Text) { Write-Host '  usage: owuihelp find <text>' -ForegroundColor Yellow; return }
    _owui_head "Commands matching '$Text'"
    $hits = $OWUI_CMDS | Where-Object {
        $_.cmd -like "*$Text*" -or $_.blurb -like "*$Text*" -or (@($_.alias) -like "*$Text*")
    }
    if (-not $hits) { Write-Host '    (nothing)' -ForegroundColor DarkGray; return }
    foreach ($h in $hits) {
        Write-Host ("    {0,-20}" -f $h.cmd) -ForegroundColor Yellow -NoNewline
        Write-Host $h.blurb -ForegroundColor Gray
    }
}

# ============================================================================
#  DISPATCHER
# ============================================================================
function _owui_resolve ([string]$Key) {
    $OWUI_CMDS | Where-Object {
        $_.cmd -eq $Key -or (@($_.alias) -contains $Key)
    } | Select-Object -First 1
}

# Levenshtein, so a genuine typo still lands somewhere. Substring matching alone
# was useless for the common case: 'freevam' shares no substring with 'freevram'
# long enough to match, so the old code just shrugged and printed the menu.
function _owui_distance ([string]$a, [string]$b) {
    if (-not $a) { return $b.Length }
    if (-not $b) { return $a.Length }
    $d = New-Object 'int[,]' ($a.Length + 1), ($b.Length + 1)
    for ($i = 0; $i -le $a.Length; $i++) { $d[$i,0] = $i }
    for ($j = 0; $j -le $b.Length; $j++) { $d[0,$j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = if ($a[$i-1] -eq $b[$j-1]) { 0 } else { 1 }
            $d[$i,$j] = [Math]::Min([Math]::Min($d[($i-1),$j] + 1, $d[$i,($j-1)] + 1), $d[($i-1),($j-1)] + $cost)
        }
    }
    return $d[$a.Length, $b.Length]
}

# Every typeable name (canonical + alias) paired with the row it belongs to.
function _owui_suggest ([string]$Key) {
    $cands = foreach ($c in $OWUI_CMDS) {
        $names = @($c.cmd) + @($c.alias | Where-Object { $_ })
        foreach ($n in $names) {
            [pscustomobject]@{ Name = $n; Row = $c; Dist = (_owui_distance $Key $n) }
        }
    }
    # Substring hits first (almost always what was meant), then close typos,
    # then description matches as a last resort.
    $hits = @($cands | Where-Object { $_.Name -like "*$Key*" } | Sort-Object Dist)
    if (-not $hits) {
        $tol  = [Math]::Max(2, [int][Math]::Floor($Key.Length / 3) + 1)
        $hits = @($cands | Where-Object { $_.Dist -le $tol } | Sort-Object Dist)
    }
    $rows = @()
    foreach ($h in $hits) { if ($rows -notcontains $h.Row) { $rows += $h.Row } }
    if (-not $rows) { $rows = @($OWUI_CMDS | Where-Object { $_.blurb -like "*$Key*" }) }
    return @($rows | Select-Object -First 6)
}

function _owui_menu {
    Write-Host ''
    Write-Host '  AI STACK TOOLKIT' -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host '  owuihelp <cmd>   |   owuihelp <cmd> ?  (explain)   |   owuihelp find <text>' -ForegroundColor DarkGray

    # Explicit order first, then any group not in the list (catches grp typos).
    $seen   = @{}
    $order  = @($OWUI_GROUPS) + @($OWUI_CMDS.grp | Where-Object { $_ -notin $OWUI_GROUPS } | Select-Object -Unique)
    foreach ($g in $order) {
        if ($seen[$g]) { continue }
        $seen[$g] = $true
        $rows = @($OWUI_CMDS | Where-Object { $_.grp -eq $g })
        if (-not $rows) { continue }
        _owui_head $g
        foreach ($c in $rows) {
            # hardreset is both - an elseif here hid the (!) on the single
            # most destructive command in the file.
            $tag = ''
            if ($c.destructive) { $tag += ' (!)' }
            if ($c.admin)       { $tag += ' (admin)' }
            Write-Host ("    {0,-20}" -f $c.cmd) -ForegroundColor Yellow -NoNewline
            Write-Host ("{0}{1}" -f $c.blurb, $tag) -ForegroundColor Gray -NoNewline
            if ($c.alias) {
                Write-Host ("  (aka {0})" -f (@($c.alias) -join ', ')) -ForegroundColor DarkGray
            } else { Write-Host '' }
        }
    }
    Write-Host ''
    Write-Host '  (!) = disruptive    (admin) = auto-elevates    (aka ...) = alternative names' -ForegroundColor DarkGray
    Write-Host ''
}

function owuihelp {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)][string]$Command,
        [Parameter(Position=1, ValueFromRemainingArguments=$true)]$Rest
    )

    if (-not $Command) { _owui_menu; return }

    # Normalise: strip leading dashes so --status == status.
    $key   = $Command.TrimStart('-').ToLower()
    $entry = _owui_resolve $key

    if (-not $entry) {
        Write-Host "  unknown command: '$Command'" -ForegroundColor Red
        # Search canonical names AND aliases, so a half-remembered old name
        # still points somewhere useful.
        $near = _owui_suggest $key
        if ($near) {
            Write-Host '  did you mean:' -ForegroundColor Yellow
            foreach ($n in $near) {
                Write-Host ("    {0,-20}" -f $n.cmd) -ForegroundColor Yellow -NoNewline
                Write-Host $n.blurb -ForegroundColor DarkGray
            }
        }
        Write-Host "  run 'owuihelp' for the full menu." -ForegroundColor DarkGray
        return
    }

    # "?" / help / explain as the 2nd token = dry run (describe, don't execute).
    if ($Rest -and ($Rest[0] -in '?','help','explain','what')) {
        Write-Host ''
        Write-Host ("  {0}" -f $entry.cmd) -ForegroundColor Yellow
        Write-Host ("    {0}" -f $entry.blurb) -ForegroundColor Gray
        Write-Host ("    group: {0}" -f $entry.grp) -ForegroundColor DarkGray
        if ($entry.alias)       { Write-Host ("    also:  {0}" -f (@($entry.alias) -join ', ')) -ForegroundColor DarkGray }
        if ($entry.admin)       { Write-Host '    needs: administrator (auto-elevates)' -ForegroundColor DarkYellow }
        if ($entry.destructive) { Write-Host '    note:  disruptive - restarts/rebuilds things' -ForegroundColor DarkYellow }

        # Long-form help. Optional 'details' field = array of lines. Lines are
        # printed verbatim so they can carry their own indentation, blank lines
        # and sub-headings. Added 2026-08-05 so commands with real consequences
        # (which stream? which copy? what gets pruned?) can explain themselves
        # instead of relying on a one-line blurb.
        if ($entry.details) {
            Write-Host ''
            foreach ($line in @($entry.details)) {
                if ($line -match '^[A-Z0-9 /&\-]+:$') {
                    Write-Host ("    {0}" -f $line) -ForegroundColor Cyan      # sub-heading
                } elseif ($line -match '^\s*!') {
                    Write-Host ("    {0}" -f ($line -replace '^\s*!\s?','')) -ForegroundColor DarkYellow  # warning
                } else {
                    Write-Host ("    {0}" -f $line) -ForegroundColor Gray
                }
            }
        }
        Write-Host ''
        return
    }

    # Confirm disruptive commands unless -Force / -y is passed.
    if ($entry.destructive -and ($Rest -notcontains '-Force') -and ($Rest -notcontains '-y')) {
        $ans = Read-Host "  '$($entry.cmd)' is disruptive. Continue? (y/N)"
        if ($ans -notin 'y','Y','yes') { Write-Host '  cancelled.' -ForegroundColor DarkGray; return }
    }

    # Strip our own control flags so they never reach the action.
    $pass = @($Rest | Where-Object { $_ -notin '-Force','-y' })
    & $entry.act @pass
}

# ---- aliases / shortcuts ---------------------------------------------------
Set-Alias owui owuihelp -Scope Global
function art      { owuihelp art @args }
function ai       { owuihelp ai  @args }
function freevram { owuihelp ai  @args }
function aistatus { owuihelp status }
function aiupdate { owuihelp updateall @args }
function gpuwho   { owuihelp who @args }
function autofree { owuihelp autofree @args }
# 'vps status' reads better than 'owuihelp vps status' when you are typing it
# twenty times. Does not shadow 'ssh vps' - that is ssh + an argument.
function vps      { owuihelp vps @args }

# Uncomment for a one-line banner when a new shell opens:
# Write-Host "AI stack toolkit loaded - type 'owuihelp' for commands." -ForegroundColor DarkCyan

# ---- env profile commands (defined in owui-env-profiles.ps1) ---------------
# Appended rather than inlined so the registry above stays one flat literal.
if ($OWUI_ENV_CMDS) { $Global:OWUI_CMDS += $OWUI_ENV_CMDS }
