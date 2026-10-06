<#
.SYNOPSIS
    Automatically release ComfyUI's retained VRAM once it has been idle.

.DESCRIPTION
    ComfyUI's "smart memory" keeps model weights resident in VRAM after a render
    so the next one starts fast. With a 16 GB card shared with Ollama that is a
    liability: measured 2026-07-31, ComfyUI held 9,865 MB with an EMPTY queue,
    leaving Ollama 21 MB inside the torch pool and causing OOM crashes.

    free-vram.ps1 already fixes this on demand. The failure mode is human: after
    two renders nobody remembers to type it. This watchdog removes the human.

    Logic per poll:
      1. Is ComfyUI up?                      no  -> reset state, sleep
      2. Anything running or queued?         yes -> reset idle timer, re-arm
      3. Idle long enough AND holding VRAM?  yes -> POST /free, disarm
      4. Already freed, still idle?              -> do nothing (no flapping)

    It only fires ONCE per idle period. New queue activity re-arms it. So a burst
    of ten renders costs you exactly one model reload, not ten.

.PARAMETER IdleSeconds
    How long the queue must be empty before releasing. Default 90.
    Lower = more aggressive reclaim, more model reloads. 60-180 is sensible.

.PARAMETER PollSeconds
    Gap between checks. Default 15.

.PARAMETER MinHeldMB
    Do not bother firing unless torch is holding at least this much. Default 512.

.PARAMETER Once
    Run a single check and exit. For running under a repeating scheduled task
    instead of as a persistent loop.

.PARAMETER ComfyUrl
    Default http://127.0.0.1:8188

.PARAMETER LogPath
    Default E:\ai\ollama\logs\autofree.log  (rotated at 1 MB, one .old kept)

.EXAMPLE
    .\autofree-watchdog.ps1
    Run the loop in the foreground. Ctrl+C to stop.

.EXAMPLE
    .\autofree-watchdog.ps1 -IdleSeconds 45 -Once
    Single check with a tighter idle window.

.NOTES
    Part of the AI stack toolkit. Managed via:  owuihelp autofree on|off|status
    Companions: free-vram.ps1 (manual release), gpu-who.ps1 (who is holding what)
#>
[CmdletBinding()]
param(
    [int]$IdleSeconds  = 90,
    [int]$PollSeconds  = 15,
    [int]$MinHeldMB    = 512,
    [switch]$Once,
    [string]$ComfyUrl  = 'http://127.0.0.1:8188',
    [string]$LogPath   = 'E:\ai\ollama\logs\autofree.log'
)

$ErrorActionPreference = 'Continue'

# --- logging ----------------------------------------------------------------
$logDir = Split-Path $LogPath -Parent
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  {1,-5} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        # Rotate at 1 MB so this never quietly eats the disk.
        $f = Get-Item $LogPath -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt 1MB) {
            Move-Item $LogPath "$LogPath.old" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
    } catch { }
    Write-Verbose $line
    return $line
}

# --- probes -----------------------------------------------------------------
function Get-ComfyState {
    $state = [pscustomobject]@{ Up = $false; Busy = $false; HeldMB = 0 }
    try {
        $stats = Invoke-RestMethod -Uri "$ComfyUrl/system_stats" -TimeoutSec 8 -ErrorAction Stop
    } catch {
        return $state
    }
    $state.Up = $true

    $held = 0
    foreach ($d in $stats.devices) {
        $held += [math]::Round((($d.torch_vram_total - $d.torch_vram_free) / 1MB), 0)
    }
    $state.HeldMB = [int]$held

    try {
        $q = Invoke-RestMethod -Uri "$ComfyUrl/queue" -TimeoutSec 8 -ErrorAction Stop
        $running = @($q.queue_running).Count
        $pending = @($q.queue_pending).Count
        $state.Busy = ($running + $pending) -gt 0
    } catch {
        # Queue unreadable: assume busy. Freeing mid-render is the one genuinely
        # bad outcome here, so fail safe rather than fail fast.
        $state.Busy = $true
    }
    return $state
}

function Get-VramUsedMB {
    try {
        $out = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return [int]("$out".Trim()) }
    } catch { }
    return $null
}

function Invoke-ComfyFree {
    $before = Get-VramUsedMB
    try {
        $body = @{ unload_models = $true; free_memory = $true } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ComfyUrl/free" -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 60 -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "release FAILED: $($_.Exception.Message)" 'WARN'
        return $false
    }
    Start-Sleep -Seconds 4
    $after = Get-VramUsedMB
    if ($null -ne $before -and $null -ne $after) {
        Write-Log ("released - GPU {0} MB -> {1} MB (reclaimed {2} MB)" -f $before, $after, ($before - $after))
    } else {
        Write-Log 'released (nvidia-smi unavailable for before/after)'
    }
    return $true
}

# --- state machine ----------------------------------------------------------
# State is held in memory for the loop, and mirrored to disk so that -Once mode
# (one process per check, under a repeating scheduled task) can accumulate idle
# time across invocations. Without the mirror, -Once could never reach the
# threshold and would silently do nothing forever.
$script:StatePath = Join-Path (Split-Path $LogPath -Parent) 'autofree.state.json'
$script:IdleSince = $null   # when the queue last went empty
$script:Armed     = $true   # false once we have freed for this idle period

function Restore-State {
    if (-not (Test-Path $script:StatePath)) { return }
    try {
        $s = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        if ($s.IdleSince) { $script:IdleSince = [datetime]$s.IdleSince }
        $script:Armed = [bool]$s.Armed
    } catch { }
}

function Save-State {
    try {
        $idle = $null
        if ($null -ne $script:IdleSince) { $idle = $script:IdleSince.ToString('o') }
        [pscustomobject]@{ IdleSince = $idle; Armed = $script:Armed } |
            ConvertTo-Json -Compress |
            Set-Content -Path $script:StatePath -ErrorAction SilentlyContinue
    } catch { }
}

function Invoke-Check {
    $s = Get-ComfyState

    if (-not $s.Up) {
        $script:IdleSince = $null
        $script:Armed     = $true
        return 'comfyui down'
    }

    if ($s.Busy) {
        if ($null -ne $script:IdleSince -or -not $script:Armed) {
            Write-Log 'queue active - re-armed'
        }
        $script:IdleSince = $null
        $script:Armed     = $true
        return 'busy'
    }

    # Queue is empty from here down.
    if ($null -eq $script:IdleSince) {
        $script:IdleSince = Get-Date
        return 'idle timer started'
    }

    if (-not $script:Armed) { return 'idle, already released' }

    $idleFor = [int]((Get-Date) - $script:IdleSince).TotalSeconds
    if ($idleFor -lt $IdleSeconds) {
        return "idle ${idleFor}s / ${IdleSeconds}s"
    }

    if ($s.HeldMB -lt $MinHeldMB) {
        $script:Armed = $false
        return "idle ${idleFor}s but only $($s.HeldMB) MB held - nothing worth freeing"
    }

    Write-Log ("idle {0}s, torch holding {1} MB - releasing" -f $idleFor, $s.HeldMB)
    if (Invoke-ComfyFree) { $script:Armed = $false }
    return 'released'
}

# --- entry point ------------------------------------------------------------
if ($Once) {
    Restore-State
    $r = Invoke-Check
    Save-State
    Write-Output $r
    return
}

Write-Log ("watchdog started (idle=${IdleSeconds}s poll=${PollSeconds}s minheld=${MinHeldMB}MB pid=$PID)")
Restore-State
try {
    while ($true) {
        $null = Invoke-Check
        Save-State
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Write-Log 'watchdog stopped'
}
