<#
.SYNOPSIS
    Show which processes are ACTUALLY holding GPU dedicated memory (VRAM).

.DESCRIPTION
    Task Manager lies about this. Its Details tab under-reports dedicated GPU
    memory for processes in Session 0 - which is everything launched by a
    service, including ComfyUI when it is started over SSH.

    Measured 2026-07-31 on this machine:
        Task Manager  -> python.exe (ComfyUI):     80 KB
        Actual        -> python.exe (ComfyUI):  6,087 MB

    nvidia-smi is no help either. On Windows the WDDM driver model does not
    expose per-process memory, so `nvidia-smi --query-compute-apps` returns
    [N/A] for every row, and Session 0 processes additionally come back as
    "[Insufficient Permissions]".

    The one reliable source is the Windows performance counter
    "\GPU Process Memory(*)\Dedicated Usage". A process can have several
    counter instances (one per adapter/segment), so this sums them per PID.

.PARAMETER MinMB
    Hide processes holding less than this. Default 50.

.PARAMETER All
    Show everything, no matter how small.

.PARAMETER Raw
    Emit objects instead of a formatted table (for piping / scripting).

.EXAMPLE
    .\gpu-who.ps1
    Table of VRAM holders, largest first, with the GPU total for cross-check.

.EXAMPLE
    .\gpu-who.ps1 -Raw | Where-Object Name -eq 'python'
    Script against the numbers.

.NOTES
    Part of the AI stack toolkit. Exposed as:  owuihelp who   (alias: gpuwho)
    Companion: free-vram.ps1 releases what this script exposes.
#>
[CmdletBinding()]
param(
    [int]$MinMB = 50,
    [switch]$All,
    [switch]$Raw
)

$counterPath = '\GPU Process Memory(*)\Dedicated Usage'

try {
    $samples = (Get-Counter $counterPath -ErrorAction Stop).CounterSamples
} catch {
    Write-Warning "Could not read '$counterPath': $($_.Exception.Message)"
    Write-Warning "This counter needs a WDDM display driver. On a headless/RDP-only session it may be absent."
    return
}

# One PID can own several instances (pid_1234_luid_..._phys_0, _phys_1, ...).
# Sum them, or you will under-report multi-segment allocations.
$byPid = @{}
foreach ($s in $samples) {
    if ("$($s.InstanceName)" -notmatch '^pid_(\d+)_') { continue }
    $procId = [int]$Matches[1]
    if (-not $byPid.ContainsKey($procId)) { $byPid[$procId] = [double]0 }
    $byPid[$procId] += [double]$s.CookedValue
}

$rows = @()
foreach ($procId in $byPid.Keys) {
    $mb = [int][math]::Round($byPid[$procId] / 1MB, 0)
    if (-not $All -and $mb -lt $MinMB) { continue }

    $p       = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $name    = '<exited>'
    $session = ''
    $ramMb   = 0
    if ($p) {
        $name    = $p.ProcessName
        $session = $p.SessionId
        $ramMb   = [int][math]::Round($p.WorkingSet64 / 1MB, 0)
    }

    # Session 0 == launched by a service (sshd, task scheduler, etc).
    # That is precisely the case Task Manager gets wrong, so flag it.
    $note = ''
    if ($session -eq 0) { $note = 'session 0 - Task Manager under-reports this' }

    $rows += [pscustomobject]@{
        PID     = $procId
        Name    = $name
        Session = $session
        VRAM_MB = $mb
        RAM_MB  = $ramMb
        Note    = $note
    }
}

$rows = $rows | Sort-Object VRAM_MB -Descending

if ($Raw) { return $rows }

Write-Host ''
Write-Host '  VRAM holders (perf counter, not Task Manager)' -ForegroundColor Cyan
Write-Host '  ---------------------------------------------' -ForegroundColor DarkCyan

if (-not $rows) {
    Write-Host "    (nothing above $MinMB MB)" -ForegroundColor DarkGray
} else {
    $rows | Format-Table -AutoSize @(
        @{ n='PID';     e={ $_.PID };     w=8 }
        @{ n='Name';    e={ $_.Name };    w=22 }
        @{ n='Sess';    e={ $_.Session }; w=5 }
        @{ n='VRAM MB'; e={ $_.VRAM_MB }; w=9; align='right' }
        @{ n='RAM MB';  e={ $_.RAM_MB };  w=9; align='right' }
        @{ n='Note';    e={ $_.Note } }
    ) | Out-String -Width 200 | Write-Host
}

# Cross-check against the adapter total. Do not expect these to match exactly:
# "Dedicated Usage" counts memory a process has committed, which can include
# pages the driver has since evicted, so the per-process sum can land either
# side of nvidia-smi's resident figure. Use it for "who", not for accounting.
$sum = ($rows | Measure-Object VRAM_MB -Sum).Sum
if (-not $sum) { $sum = 0 }

try {
    $gpu = & nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $gpu) {
        $f = ($gpu -split ',') | ForEach-Object { [int]$_.Trim() }
        Write-Host ("    per-process   : {0,6} MB committed across {1} process(es)" -f [int]$sum, $rows.Count) -ForegroundColor Gray
        Write-Host ("    adapter       : {0,6} MB resident / {1} MB" -f $f[0], $f[1]) -ForegroundColor Gray
        $free = $f[1] - $f[0]
        $col  = if ($free -lt 3000) { 'Red' } elseif ($free -lt 6000) { 'Yellow' } else { 'Green' }
        Write-Host ("    free          : {0,6} MB" -f $free) -ForegroundColor $col
        if ($free -lt 4000) {
            Write-Host "    tip: 'owuihelp ai' releases ComfyUI's held VRAM" -ForegroundColor DarkYellow
        }
    }
} catch { }

Write-Host ''
