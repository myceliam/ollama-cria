# ============================================================================
#  prune-vps.ps1  —  age-based cleanup of the OFFSITE backup copies on the VPS
#
#  push-vps.ps1 already prunes by COUNT (-KeepRemote, default 8). This prunes by
#  AGE, which is what you actually want when pushes are irregular: eight copies
#  taken in one busy week is not eight weeks of history.
#
#  Usage:
#    pwsh -File E:\ai\ollama\prune-vps.ps1                 # DRY RUN - shows only
#    pwsh -File E:\ai\ollama\prune-vps.ps1 -Execute        # actually deletes
#    pwsh -File E:\ai\ollama\prune-vps.ps1 -KeepDays 30 -Execute
#
#  RETENTION IS THE UNION OF TWO RULES - a backup survives if EITHER holds:
#      * it is among the newest -KeepCount (default 10), OR
#      * it is newer than -KeepDays (default 10 days)
#  It is only deleted when it fails BOTH. Count is the important one: if
#  something breaks and you do not notice for a week, an age-only rule could
#  delete the last known-good copy. Depth of history beats tidiness.
#
#  SAFETY:
#    * Dry run by DEFAULT. Nothing is deleted unless you pass -Execute.
#    * Only touches files matching owui-brains-*.zip in -RemoteDir. Nothing else
#      on the VPS is considered.
#    * Age comes from the TIMESTAMP IN THE FILENAME (owui-brains-yyyyMMdd-HHmmss),
#      not mtime - an scp copy resets mtime and would make everything look new.
# ============================================================================
param(
    [string]$SshHost   = 'vps',
    [string]$RemoteDir = '~/owuibackup',
    [int]$KeepCount    = 10,
    [int]$KeepDays     = 10,
    [switch]$Execute
)

$ErrorActionPreference = 'Continue'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ""
Say "=== VPS backup prune ===" Magenta
Say ("  host        : {0}:{1}" -f $SshHost, $RemoteDir)
Say ("  keep newest : {0} backups  (regardless of age)" -f $KeepCount)
Say ("  keep newer  : {0} days     (regardless of count)" -f $KeepDays)
Say  "  a backup is deleted only if it fails BOTH rules"
Say ("  mode        : {0}" -f $(if ($Execute) { 'EXECUTE - will delete' } else { 'DRY RUN - nothing will be deleted' })) `
    $(if ($Execute) { 'Yellow' } else { 'Cyan' })
Say ""

# --- fetch the remote listing -----------------------------------------------
$listing = ssh $SshHost "ls -1 $RemoteDir/owui-brains-*.zip 2>/dev/null" 2>&1
if ($LASTEXITCODE -ne 0) {
    Say "[x] ssh to '$SshHost' failed (exit $LASTEXITCODE)." Red
    Say "    Check 'ssh $SshHost' works and the key is loaded (ssh-add -l)." DarkGray
    exit 1
}

$files = @($listing | Where-Object { $_ -match 'owui-brains-\d{8}-\d{6}\.zip$' })
if (-not $files) { Say "  No backups found in $RemoteDir - nothing to do." DarkGray; exit 0 }

# --- parse timestamps out of the filenames ----------------------------------
$items = foreach ($f in $files) {
    if ($f -match 'owui-brains-(\d{8}-\d{6})\.zip$') {
        try { $when = [datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', $null) } catch { continue }
        [pscustomobject]@{ Path = $f.Trim(); Name = Split-Path $f.Trim() -Leaf; When = $when }
    }
}
$items = $items | Sort-Object When -Descending
$cutoff = (Get-Date).AddDays(-$KeepDays)

# Union of the two rules. A backup is deleted ONLY if it is outside the newest
# $KeepCount AND older than $KeepDays. Either rule alone is enough to save it.
$byCount = $items | Select-Object -First $KeepCount
$candidates = @()

Say ("  {0} backup(s) on the VPS:" -f $items.Count)
foreach ($i in $items) {
    $age      = [int]((Get-Date) - $i.When).TotalDays
    $inCount  = $byCount -contains $i
    $inDays   = $i.When -ge $cutoff

    if ($inCount -and $inDays) { $tag = 'keep  (recent, in newest 10)'; $col = 'Gray' }
    elseif ($inCount)          { $tag = "KEEP  (old, but in newest $KeepCount)"; $col = 'Green' }
    elseif ($inDays)           { $tag = "KEEP  (beyond $KeepCount, but under $KeepDays days)"; $col = 'Green' }
    else                       { $tag = 'DELETE'; $col = 'Red'; $candidates += $i }

    Say ("    {0}  {1,4}d  {2}" -f $i.Name, $age, $tag) $col
}

Say ""
if (-not $candidates) { Say "  Every backup is protected by one of the two rules. Nothing to do." Green; exit 0 }

Say ("  {0} file(s) to delete." -f $candidates.Count) Yellow
if (-not $Execute) {
    Say ""
    Say "  DRY RUN - nothing was deleted. Re-run with -Execute to apply." Cyan
    exit 0
}

# --- delete ------------------------------------------------------------------
$quoted = ($candidates | ForEach-Object { "'" + $_.Path + "'" }) -join ' '
ssh $SshHost "rm -f $quoted"
if ($LASTEXITCODE -ne 0) { Say "[x] remote rm failed (exit $LASTEXITCODE)" Red; exit 1 }

$remaining = @(ssh $SshHost "ls -1 $RemoteDir/owui-brains-*.zip 2>/dev/null" | Where-Object { $_ -match '\.zip$' })
Say ("  Deleted {0}. {1} backup(s) remain." -f $candidates.Count, $remaining.Count) Green
ssh $SshHost "du -sh $RemoteDir 2>/dev/null" | ForEach-Object { Say ("  offsite total: " + $_) DarkGray }
