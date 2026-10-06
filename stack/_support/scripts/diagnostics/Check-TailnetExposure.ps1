<#
.SYNOPSIS
    Tailnet / LAN exposure auditor for Windows.
    Answers the real question your nmap scan couldn't: "What is actually
    reachable over Tailscale (100.x) and the LAN, vs safely on loopback?"

.WHAT IT DOES
    1. Finds your Tailscale IP + LAN IP.
    2. Lists every LISTENING TCP/UDP socket with its bind address + owning process.
    3. Classifies each as LOOPBACK (safe), ALL-INTERFACES (exposed to tailnet+LAN),
       or SPECIFIC (bound to one non-loopback IP).
    4. Dumps Tailscale peer + advertised-route status.
    5. Reports Windows Firewall profile state.

.HOW TO RUN
    Open PowerShell *as Administrator* (needed to see process names for every socket):
        cd E:\  (or wherever you saved this)
        Set-ExecutionPolicy -Scope Process Bypass -Force
        .\Check-TailnetExposure.ps1

    Optional: append  | Tee-Object exposure-report.txt  to save a copy.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-Head($t) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}

# --- 1. Identify this host's addresses ------------------------------------
Write-Head "1. This host's addresses"

$tailscaleIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '100.*' } |
    Select-Object -First 1).IPAddress

$lanIPs = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '100.*' } |
    Select-Object -ExpandProperty IPAddress)

Write-Host ("Tailscale IP : {0}" -f ($(if ($tailscaleIP) { $tailscaleIP } else { 'not found' }))) -ForegroundColor Yellow
Write-Host ("LAN / other  : {0}" -f ($lanIPs -join ', ')) -ForegroundColor Yellow

# --- 2. Listening sockets with bind address + process ---------------------
Write-Head "2. Listening sockets (bind address is what matters)"

$procCache = @{}
function Get-ProcName($procId) {
    if (-not $procId) { return '?' }
    if (-not $procCache.ContainsKey($procId)) {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $procCache[$procId] = if ($p) { $p.ProcessName } else { "PID $procId" }
    }
    return $procCache[$procId]
}

function Classify($addr) {
    switch -Regex ($addr) {
        '^(127\.|::1$|::ffff:127\.)' { 'LOOPBACK  (safe)';                 break }
        '^(0\.0\.0\.0|::|\[::\])$'   { 'ALL-IFACES (tailnet+LAN EXPOSED)'; break }
        default                      { 'SPECIFIC  (check reachability)' }
    }
}

$rows = @()

foreach ($c in (Get-NetTCPConnection -State Listen)) {
    $rows += [pscustomobject]@{
        Proto   = 'TCP'
        Bind    = $c.LocalAddress
        Port    = $c.LocalPort
        Process = Get-ProcName $c.OwningProcess
        Class   = Classify $c.LocalAddress
    }
}
foreach ($u in (Get-NetUDPEndpoint)) {
    $rows += [pscustomobject]@{
        Proto   = 'UDP'
        Bind    = $u.LocalAddress
        Port    = $u.LocalPort
        Process = Get-ProcName $u.OwningProcess
        Class   = Classify $u.LocalAddress
    }
}

$rows = $rows | Sort-Object Class, Port -Unique

# Highlight the exposed ones first
Write-Host ""
Write-Host ">>> EXPOSED on all interfaces (reachable over Tailscale 100.x AND your LAN):" -ForegroundColor Red
$exposed = $rows | Where-Object { $_.Class -like 'ALL-IFACES*' }
if ($exposed) {
    $exposed | Format-Table Proto, @{L='Bind';E={$_.Bind};Width=18}, Port, Process -AutoSize
} else {
    Write-Host "  (none - everything is on loopback or a specific interface)" -ForegroundColor Green
}

Write-Host ""
Write-Host ">>> Bound to a specific non-loopback IP (verify who can reach it):" -ForegroundColor Yellow
($rows | Where-Object { $_.Class -like 'SPECIFIC*' }) |
    Format-Table Proto, @{L='Bind';E={$_.Bind};Width=18}, Port, Process -AutoSize

Write-Host ""
Write-Host ">>> Loopback only (safe - not reachable from any other device):" -ForegroundColor Green
($rows | Where-Object { $_.Class -like 'LOOPBACK*' }) |
    Format-Table Proto, @{L='Bind';E={$_.Bind};Width=18}, Port, Process -AutoSize

# --- 3. Tailscale status + advertised routes ------------------------------
Write-Head "3. Tailscale peers + advertised routes"

$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $ts) {
    $tsGuess = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path $tsGuess) { $ts = $tsGuess }
}
if ($ts) {
    Write-Host "-- tailscale status --" -ForegroundColor Yellow
    & $ts.Source status 2>&1 | Out-Host

    Write-Host ""
    Write-Host "-- Advertised routes on THIS node (subnet-router exposure) --" -ForegroundColor Yellow
    $json = & $ts.Source status --json 2>&1 | Out-String
    try {
        $obj = $json | ConvertFrom-Json
        $adv = $obj.Self.AllowedIPs | Where-Object { $_ -notmatch '/32$|/128$' }
        if ($adv) {
            Write-Host "  This node advertises subnet routes: $($adv -join ', ')" -ForegroundColor Red
            Write-Host "  -> Any tailnet peer allowed by ACL can reach those subnets THROUGH this box." -ForegroundColor Red
        } else {
            Write-Host "  No subnet routes advertised by this node. Good." -ForegroundColor Green
        }
    } catch {
        Write-Host "  (could not parse tailscale --json; run 'tailscale status --json' manually)" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "tailscale.exe not found on PATH. Skipping." -ForegroundColor DarkYellow
}

# --- 4. Windows Firewall state --------------------------------------------
Write-Head "4. Windows Firewall profiles"
Get-NetFirewallProfile |
    Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
    Format-Table -AutoSize

Write-Head "DONE"
Write-Host @"
How to read this:
  * ALL-IFACES rows are the ones to care about. Cross-reference the Port
    against your Docker/MCP/OWUI services. Anything you intended to be
    'local only' that shows here is reachable over Tailscale.
  * Ollama should NOT appear in ALL-IFACES (you set 127.0.0.1 - this verifies it).
  * If a service must be tailnet-reachable, that's fine - just make it a
    conscious decision, and lock it down with Tailscale ACLs, not luck.
"@ -ForegroundColor Gray
