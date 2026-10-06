# ============================================================================
#  backup-owui.ps1  —  "brains" backup of the OWUI / ComfyUI stack (NO weights)
#
#  Captures everything hard to recreate — the live OWUI database (all pipes,
#  tools, functions, config, chats), secrets, compose/config, bridges, scripts,
#  ComfyUI code + workflows — but SKIPS re-downloadable model weights and venvs.
#  Writes model MANIFESTS so weights can be re-pulled on restore.
#
#  Two independent streams (never prune each other):
#     -Mode nightly  -> D:\owuibackups\nightly\  (rolling, keeps -Keep newest)
#     -Mode manual   -> D:\owuibackups\manual\    (kept forever; owuihelp backup)
#
#  Usage:  pwsh -File E:\ai\ollama\backup-owui.ps1 -Mode manual
# ============================================================================
param(
    [ValidateSet('nightly','manual')] [string]$Mode = 'nightly',
    [int]$Keep = 7,
    [string]$Root = 'D:\owuibackups'
)

$ErrorActionPreference = 'Continue'
$ts       = Get-Date -Format 'yyyyMMdd-HHmmss'
$streamDir= Join-Path $Root $Mode
$dest     = Join-Path $streamDir "owui-brains-$ts"
$owuiDir  = Join-Path $dest 'owui-data'
$manDir   = Join-Path $dest 'manifests'
New-Item -ItemType Directory -Force -Path $owuiDir,$manDir | Out-Null
$log = Join-Path $streamDir "backup-$ts.log"

function Log($m){ $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; Add-Content -Path $log -Value $l }

Log "=== OWUI brains backup ($Mode) -> $dest ==="

# --- docker on PATH (Task Scheduler safe) -----------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $bin = 'C:\Program Files\Docker\Docker\resources\bin'
    if (Test-Path (Join-Path $bin 'docker.exe')) { $env:Path = "$bin;$env:Path" }
}

# --- 1) LIVE webui.db — consistent ONLINE snapshot from the running container
Log "1/6 Snapshotting live webui.db (online, crash-safe)..."
$bkpy = @"
import sqlite3
s = sqlite3.connect('/app/backend/data/webui.db')
d = sqlite3.connect('/tmp/webui_backup.db')
d.execute('PRAGMA busy_timeout=15000')
with d: s.backup(d)
s.close(); d.close(); print('db-backup-ok')
"@
$enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bkpy))
$r = docker exec open-webui sh -lc "echo $enc | base64 -d | python3 -" 2>&1
Log "   $r"
docker cp open-webui:/tmp/webui_backup.db "$owuiDir\webui.db" 2>&1 | Out-Null
docker exec open-webui sh -lc "rm -f /tmp/webui_backup.db" 2>&1 | Out-Null
if (Test-Path "$owuiDir\webui.db") {
    Log ("   webui.db OK ({0:N1} MB)" -f ((Get-Item "$owuiDir\webui.db").Length/1MB))
} else { Log "   !! webui.db FAILED — check that the open-webui container is running" }

# --- 2) OWUI uploads + vector_db (knowledge/embeddings); skip regen cache ----
Log "2/6 Copying OWUI uploads + vector_db..."
foreach ($sub in 'uploads','vector_db') {
    docker cp "open-webui:/app/backend/data/$sub" "$owuiDir\$sub" 2>&1 | Out-Null
}

# --- 3) E:\ai\ollama config (compose, secrets, scripts, bridges) -------------
#     Exclude: .git history, old backups, the stale on-disk open-webui data
#     copy (live DB already captured above), open-terminal build caches, venvs.
Log "3/6 Copying ollama config tree (no bulk/stale)..."
robocopy "E:\ai\ollama" "$dest\ollama" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 `
    /XD "E:\ai\ollama\.git" "E:\ai\ollama\backups" "E:\ai\ollama\open-webui" `
        "E:\ai\ollama\open-terminal\.local" "E:\ai\ollama\open-terminal\.cache" `
        "E:\ai\ollama\open-terminal\.venv" "E:\ai\ollama\logs" `
        "__pycache__" "node_modules" ".venv" `
    /XF "*.log" | Out-Null
Log "   ollama config copied"

# --- 4) ComfyUI code + workflows (NO models, NO venv) ------------------------
Log "4/6 Copying ComfyUI (code/workflows/nodes, no models/venv)..."
robocopy "E:\ai\comfyui\ComfyUI" "$dest\comfyui" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 `
    /XD "E:\ai\comfyui\ComfyUI\models" "E:\ai\comfyui\ComfyUI\.venv" `
        "E:\ai\comfyui\ComfyUI\output" "E:\ai\comfyui\ComfyUI\temp" `
        "E:\ai\comfyui\ComfyUI\.git" "__pycache__" `
    /XF "*.pyc" | Out-Null
Log "   ComfyUI copied"

# --- 5) Manifests so weights + envs are reproducible on restore --------------
Log "5/6 Writing manifests (models to re-pull, pip freeze, docker state)..."
try { & ollama list 2>&1 | Out-File "$manDir\ollama-models.txt" -Encoding utf8 } catch { Log "   (ollama list skipped: $_)" }
docker images 2>&1 | Out-File "$manDir\docker-images.txt" -Encoding utf8
docker ps -a  2>&1 | Out-File "$manDir\docker-containers.txt" -Encoding utf8
Get-ChildItem "E:\ai\comfyui\ComfyUI\models" -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object @{n='SizeMB';e={[math]::Round($_.Length/1MB,1)}}, FullName |
    Sort-Object FullName | Format-Table -AutoSize | Out-File "$manDir\comfyui-models.txt" -Encoding utf8
$cpy = "E:\ai\comfyui\ComfyUI\.venv\Scripts\python.exe"
if (Test-Path $cpy) { & $cpy -m pip freeze 2>&1 | Out-File "$manDir\comfyui-pip-freeze.txt" -Encoding utf8 }

# --- 5b) WINDOWS-SIDE STATE (added 2026-07-30) -------------------------------
#     None of this lives in E:\ai\ollama, so a Windows rebuild would silently
#     lose it: the WSL memory cap, the ComfyUI/Ollama startup shims, every
#     scheduled task, the Ollama env vars, and the named-volume topology.
Log "5b/6 Capturing Windows-side state (wslconfig, startup, tasks, env, volumes)..."
$winDir = Join-Path $dest 'windows'
New-Item -ItemType Directory -Force -Path $winDir | Out-Null

# .wslconfig — controls the Docker VM memory cap (8GB as of 2026-07-30)
$wsl = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $wsl) { Copy-Item $wsl (Join-Path $winDir 'wslconfig.txt') -Force }

# Startup folder — start_comfyui_hidden.vbs + Ollama.lnk live here
$startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
if (Test-Path $startup) {
    New-Item -ItemType Directory -Force -Path (Join-Path $winDir 'Startup') | Out-Null
    Copy-Item "$startup\*" (Join-Path $winDir 'Startup') -Recurse -Force -EA SilentlyContinue
}

# Scheduled tasks — export XML so they can be re-registered verbatim
$taskDir = Join-Path $winDir 'scheduled-tasks'
New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
Get-ScheduledTask -EA SilentlyContinue |
  Where-Object { $_.TaskName -match 'owui|mcpo|ollama|comfy|watchdog|stack' } |
  ForEach-Object {
      $safe = $_.TaskName -replace '[\\/:*?"<>|]', '_'
      try {
          Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath |
              Out-File (Join-Path $taskDir "$safe.xml") -Encoding utf8
      } catch { Log "   (task export skipped: $($_.TaskName))" }
  }
Get-ScheduledTask -EA SilentlyContinue |
  Where-Object { $_.TaskName -match 'owui|mcpo|ollama|comfy|watchdog|stack' } |
  Select-Object TaskName, State |
  Format-Table -AutoSize | Out-File (Join-Path $taskDir '_task-states.txt') -Encoding utf8

# Ollama environment variables as actually set on this machine
'OLLAMA_HOST','OLLAMA_FLASH_ATTENTION','OLLAMA_KV_CACHE_TYPE','OLLAMA_NUM_PARALLEL',
'OLLAMA_MAX_LOADED_MODELS','OLLAMA_KEEP_ALIVE','OLLAMA_GPU_OVERHEAD','OLLAMA_CONTEXT_LENGTH' |
  ForEach-Object {
      "{0}={1}" -f $_, [Environment]::GetEnvironmentVariable($_, 'Machine')
  } | Out-File "$manDir\ollama-env-vars.txt" -Encoding utf8

# Docker volume topology — owui-data is a NAMED VOLUME, not a bind mount
docker volume ls 2>&1 | Out-File "$manDir\docker-volumes.txt" -Encoding utf8
docker volume inspect owui-data 2>&1 | Out-File "$manDir\docker-volume-owui-data.json" -Encoding utf8

# Tailscale serve routes (443->OWUI, 444->ComfyUI, 9000->Dozzle, 2000->docker site)
try { & tailscale serve status 2>&1 | Out-File "$manDir\tailscale-serve.txt" -Encoding utf8 } catch { }

# Effective OWUI RAG/audio config, human-readable. The DB is the source of
# truth (ENABLE_PERSISTENT_CONFIG=true) so this is the only place these are
# visible without opening SQLite.
$cfgpy = @"
import sqlite3
con = sqlite3.connect('file:/app/backend/data/webui.db?mode=ro', uri=True)
for k, v in con.execute("select key,value from config where key like 'rag%' or key like 'audio%' or key like 'code_%' order by key"):
    s = str(v)
    print('%-50s = %s' % (k, s[:200] + ('...' if len(s) > 200 else '')))
con.close()
"@
$encc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cfgpy))
docker exec open-webui sh -lc "echo $encc | base64 -d | python3 -" 2>&1 |
    Out-File "$manDir\owui-effective-config.txt" -Encoding utf8

Log "   Windows-side state captured"

# --- 6) RESTORE runbook ------------------------------------------------------
$restore = @"
# OWUI / ComfyUI — RESTORE RUNBOOK
Backup type: BRAINS ONLY (no model weights). Taken: $ts ($Mode)

## What's here
- owui-data\webui.db      -> the live OWUI database (ALL pipes, tools, functions, config, chats)
- owui-data\uploads,vector_db -> OWUI files + knowledge embeddings
- ollama\                 -> docker-compose, pinned configs, secrets, .env, bridges, all *.ps1 scripts
- comfyui\                -> ComfyUI code, custom_nodes, workflows (user\), owui tool sources
- manifests\              -> model lists to re-download, pip freeze, docker image/container state

## Restore the OWUI database (the crown jewel)
1. Stop OWUI:            docker stop open-webui
2. Copy the DB back:     docker cp "<thisfolder>\owui-data\webui.db" open-webui:/app/backend/data/webui.db
   (also uploads/vector_db the same way if needed)
3. Start OWUI:           docker start open-webui
   Tools/functions/pipes/tool-servers all return exactly as they were.

## Restore config + code
- Copy ollama\  back over  E:\ai\ollama   (keep your current .git if you want history)
- Copy comfyui\ back over  E:\ai\comfyui\ComfyUI
- Recreate ComfyUI venv:   python -m venv .venv ; .venv\Scripts\pip install -r manifests\comfyui-pip-freeze.txt

## Re-download the model WEIGHTS (not in this backup)
- Ollama LLMs:   for each line in manifests\ollama-models.txt ->  ollama pull <name>
- ComfyUI models: re-download the files listed in manifests\comfyui-models.txt into E:\ai\comfyui\ComfyUI\models\

## Bring it all back up
- pwsh -File E:\ai\ollama\start-stack.ps1     (or:  owuihelp up)

# =====================================================================
# BARE-METAL REBUILD (Windows died). Follow IN ORDER.
# Written so you can paste this whole file to an LLM and work through it.
# =====================================================================

## 0. Install first (nothing below works otherwise)
Docker Desktop (WSL2 backend) | Ollama for Windows (NATIVE, not Docker)
Python 3.11 | Git | PowerShell 7 (pwsh) | Tailscale | NVIDIA driver

## 1. Windows-side state  -> windows\
- windows\wslconfig.txt      -> copy to  %USERPROFILE%\.wslconfig   THEN: wsl --shutdown
    Sets the Docker VM memory cap. 8GB as of 2026-07-30. Too low = containers OOM-killed.
- windows\Startup\           -> copy to  %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
    Contains start_comfyui_hidden.vbs (the ONLY thing that auto-starts ComfyUI) and Ollama.lnk
- windows\scheduled-tasks\*.xml -> re-register each:
      Register-ScheduledTask -Xml (Get-Content .\NAME.xml -Raw) -TaskName "NAME"
    Check _task-states.txt: anything listed Disabled should STAY disabled.
- manifests\ollama-env-vars.txt -> re-apply, then restart Ollama from the tray:
      [Environment]::SetEnvironmentVariable('NAME','VALUE','Machine')
    Or just run: E:\ai\ollama\set-ollama-envvars.ps1

## 2. Code + config
- ollama\  -> E:\ai\ollama          (contains docker-compose.yml, .env, every script)
- comfyui\ -> E:\ai\comfyui\ComfyUI
- ComfyUI venv: cd E:\ai\comfyui\ComfyUI ; python -m venv .venv
                .venv\Scripts\pip install -r manifests\comfyui-pip-freeze.txt

## 3. CREATE THE NAMED VOLUME BEFORE RESTORING DATA  <-- easy to miss
OWUI data lives in a Docker NAMED VOLUME called owui-data, NOT a folder.
(Migrated 2026-07-05: NTFS bind mounts caused SQLite "database is locked" hangs.
 Do NOT go back to a bind mount.)
      docker volume create owui-data
      cd E:\ai\ollama ; docker compose up -d open-webui
      docker stop open-webui
      docker cp owui-data\webui.db    open-webui:/app/backend/data/webui.db
      docker cp owui-data\uploads     open-webui:/app/backend/data/
      docker cp owui-data\vector_db   open-webui:/app/backend/data/
      docker start open-webui
Restoring webui.db brings back ALL pipes, tools, the 21 MCP tool-server
connections, model definitions and settings. It is the crown jewel.

## 4. Weights (deliberately not in this backup)
- Ollama:  each line of manifests\ollama-models.txt ->  ollama pull NAME
           MUST include the embedding model or RAG breaks:  ollama pull mxbai-embed-large
- ComfyUI: re-download files listed in manifests\comfyui-models.txt into
           E:\ai\comfyui\ComfyUI\models\

## 5. Start and verify
      pwsh -File E:\ai\ollama\start-stack.ps1      (or: owuihelp up)
      owuihelp status
      owuihelp mappings      # tailnet routes vs what is actually up
Compare against manifests\tailscale-serve.txt and docker-containers.txt.

# =====================================================================
# TRAPS THAT WILL WASTE YOUR TIME (learned the hard way 2026-07-30)
# =====================================================================

## The config TABLE beats docker-compose. Always.
ENABLE_PERSISTENT_CONFIG=true, so OWUI reads RAG/audio/code settings from the
config table in webui.db. Environment variables only seed a FRESH database.
  *** docker exec open-webui env  IS MISLEADING ***
It showed ENABLE_RAG_HYBRID_SEARCH=false while the DB said true. Cost hours.
To see the truth, read manifests\owui-effective-config.txt, or query the DB.
Change settings via the Admin UI, or patch the DB with the container STOPPED.
Do NOT set ENABLE_PERSISTENT_CONFIG=false - it discards all UI-configured state.

## Expected RAG config (verify after restore)
  rag.embedding_engine          = ollama
  rag.embedding_model           = mxbai-embed-large   <- changing this forces a FULL re-index
  rag.enable_hybrid_search      = true                <- BM25 + vectors, works with NO reranker
  rag.reranking_model           = ""                  <- MUST stay empty
  rag.content_extraction_engine = tika
  rag.chunk_size / overlap      = 1500 / 250
  rag.top_k                     = 8
NEVER set rag.reranking_model to a HuggingFace name (e.g. BAAI/bge-reranker-v2-m3).
That loads torch INSIDE OWUI and takes its memory from ~1GB to ~8GB. If you want
reranking, run it as a separate container and set rag.reranking_engine=external
plus rag.external_reranker_url.

## ComfyUI shows TWO python.exe - that is ONE instance
A tiny (~4MB) .venv launcher parent and the real (~800MB) child that owns :8188.
Killing the parent kills ComfyUI. Check the process tree before killing anything.

## Do NOT change ComfyUI --listen 0.0.0.0 to 127.0.0.1
Containers reach it via host.docker.internal, which is NOT loopback. Loopback
binding breaks generate_image, generate_video and the ComfyUI Studio pipe.
It is not exposed anyway: Windows Firewall default-denies inbound and no allow
rule exists for 8188.

## ComfyUI silently holds VRAM
It keeps models resident after a render - measured 8.2GB with nothing queued,
which starves the 27B LLM. Run  owuihelp freevram  before LLM work.

## Ollama tray auto-updater can break the install
It has previously deleted lib\ollama mid-update, causing CPU-only inference.
Keep auto-update disabled.
"@
$restore | Out-File "$dest\RESTORE.md" -Encoding utf8

# --- size + prune (nightly only) --------------------------------------------
$sizeGB = [math]::Round(((Get-ChildItem $dest -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum)/1GB, 2)
Log "6/6 Backup complete: $sizeGB GB"

if ($Mode -eq 'nightly') {
    $old = Get-ChildItem $streamDir -Directory -Filter 'owui-brains-*' -EA SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -Skip $Keep
    foreach ($o in $old) { Log "Pruning old nightly: $($o.Name)"; Remove-Item $o.FullName -Recurse -Force -EA SilentlyContinue }
    Get-ChildItem $streamDir -File -Filter 'backup-*.log' -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip $Keep | Remove-Item -Force -EA SilentlyContinue
}

Log "=== DONE ($Mode) -> $dest ==="
Write-Host ""
Write-Host ("  Backup OK: {0} GB  ->  {1}" -f $sizeGB, $dest) -ForegroundColor Green
