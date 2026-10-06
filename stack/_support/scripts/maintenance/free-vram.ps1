<#
.SYNOPSIS
    Releases ComfyUI's retained VRAM so LLM work gets the GPU back.

.DESCRIPTION
    ComfyUI's "smart memory" keeps model weights resident in VRAM after a render
    so the next one starts fast. Measured 2026-07-30: it was holding 8,204 MB
    with nothing queued, leaving only 5.4 GB free and forcing the 27B daily
    driver into heavy CPU offload.

    This calls ComfyUI's /free endpoint, which unloads models and frees cache.
    It is NON-DESTRUCTIVE: the queue, workflows and outputs are untouched. The
    only cost is that the next render reloads its model (~10-30s).

    Safe to run any time. If ComfyUI is not running it just reports that.

.EXAMPLE
    .\free-vram.ps1
    Frees ComfyUI VRAM and shows before/after.

.EXAMPLE
    .\free-vram.ps1 -Quiet
    Same, no output. Useful from other scripts.

.NOTES
    Add to your pwsh profile for a one-word command:
        function Free-VRAM { & 'E:\ai\ollama\free-vram.ps1' @args }
        Set-Alias fv Free-VRAM
#>
[CmdletBinding()]
param(
    [string]$ComfyUrl = 'http://127.0.0.1:8188',
    [switch]$Quiet
)

function Write-Info { param($m) if (-not $Quiet) { Write-Host $m } }

function Get-VramUsed {
    try {
        $out = & nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $parts = ($out -split ',') | ForEach-Object { [int]$_.Trim() }
            return @{ Used = $parts[0]; Free = $parts[1] }
        }
    } catch { }
    return $null
}

# --- Is ComfyUI actually up? -------------------------------------------------
try {
    $stats = Invoke-RestMethod -Uri "$ComfyUrl/system_stats" -TimeoutSec 8 -ErrorAction Stop
} catch {
    Write-Info "ComfyUI not reachable at $ComfyUrl - nothing to free."
    return
}

$held = 0
foreach ($d in $stats.devices) {
    $held += [math]::Round((($d.torch_vram_total - $d.torch_vram_free) / 1MB), 0)
}

$before = Get-VramUsed
Write-Info ""
Write-Info "ComfyUI $($stats.system.comfyui_version)  |  torch holding: $held MB"
if ($before) { Write-Info "GPU before : $($before.Used) MB used / $($before.Free) MB free" }

if ($held -lt 64) {
    Write-Info "Nothing meaningful loaded - no action needed."
    Write-Info ""
    return
}

# --- Ask ComfyUI to release --------------------------------------------------
try {
    $body = @{ unload_models = $true; free_memory = $true } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$ComfyUrl/free" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 60 -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "ComfyUI /free failed: $($_.Exception.Message)"
    return
}

Start-Sleep -Seconds 5

$after = Get-VramUsed
if ($before -and $after) {
    $freed = $before.Used - $after.Used
    Write-Info "GPU after  : $($after.Used) MB used / $($after.Free) MB free"
    Write-Info ""
    Write-Info ("  --> reclaimed {0} MB   ({1} MB now free for Ollama)" -f $freed, $after.Free)
} else {
    Write-Info "Freed (nvidia-smi unavailable for before/after comparison)."
}
Write-Info ""
