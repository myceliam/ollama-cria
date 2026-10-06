# ============================================================================
#  push-vps.ps1  —  weekly OFFSITE copy of the latest backup to the VPS
#
#  Zips the newest nightly "brains" backup and scp's it to the VPS over the
#  'vps' ssh alias (Tailscale). Runs in YOUR user context, where `ssh vps`
#  already works with key auth — it does NOT create a new backup, it ships the
#  most recent one, so it's decoupled from the nightly job.
#
#  Usage:  pwsh -File E:\ai\ollama\push-vps.ps1            # newest of EITHER stream
#          pwsh -File E:\ai\ollama\push-vps.ps1 -Manual    # force newest MANUAL
#          pwsh -File E:\ai\ollama\push-vps.ps1 -Nightly   # force newest NIGHTLY
#          pwsh -File E:\ai\ollama\push-vps.ps1 -KeepRemote 20 -KeepDays 30
#
#  Remote retention (applied automatically after every push): a backup is kept if
#  EITHER it is among the newest -KeepRemote (10) OR it is newer than -KeepDays
#  (10). Deleted only if it fails both. prune-vps.ps1 does the same thing on
#  demand, with a dry run by default.
#
#  ALWAYS ships the MOST RECENT backup in the chosen stream. There is no way to
#  push an older, named backup — see the note by the selection block below.
#
#  Older equivalent spellings, still supported:
#          -Stream nightly | -Stream manual | -Stream auto
#
#  2026-07-30: -Stream default changed 'nightly' -> 'auto'. Previously this
#  ALWAYS shipped the newest nightly, so a fresh 'owuihelp backup' followed by
#  'owuihelp pushvps' silently sent yesterday's 03:00 snapshot offsite instead
#  of the one just taken. 'auto' picks whichever stream has the newest backup.
# ============================================================================
param(
    # --- plain-English switches (added 2026-08-05) --------------------------
    # -Stream <name> was the only way to choose, which is easy to forget and
    # not obvious at the prompt. These do the same job and read better:
    #     push-vps.ps1 -Manual       ==  push-vps.ps1 -Stream manual
    #     push-vps.ps1 -Nightly      ==  push-vps.ps1 -Stream nightly
    # -Stream is KEPT so existing scripts and scheduled tasks don't break.
    [switch]$Manual,                     # force the newest MANUAL backup
    [switch]$Nightly,                    # force the newest NIGHTLY backup

    [string]$SshHost   = 'vps',
    [string]$RemoteDir = '~/owuibackup',
    [string]$Root      = 'D:\owuibackups',
    [ValidateSet('auto','nightly','manual')]
    [string]$Stream    = 'auto',         # auto = newest across BOTH streams
    # Retention on the VPS is the UNION of these two. A backup survives if EITHER
    # it is in the newest -KeepRemote, OR it is newer than -KeepDays. Set either
    # to 0 to switch that rule off.
    [int]$KeepRemote   = 10,             # always keep this many, whatever their age
    [int]$KeepDays     = 10              # always keep anything this recent, whatever the count
)

# Switches win over -Stream. Asking for both is a mistake, not a preference.
if ($Manual -and $Nightly) {
    Write-Host "  [x] Use -Manual OR -Nightly, not both. Omit both for 'newest of either'." -ForegroundColor Red
    exit 1
}
if ($Manual)  { $Stream = 'manual' }
if ($Nightly) { $Stream = 'nightly' }

$ErrorActionPreference = 'Continue'
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $Root "push-vps-$ts.log"
function Log($m){ $l="[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$m; Write-Host $l; Add-Content $log $l }

Log "=== VPS offsite push -> ${SshHost}:${RemoteDir} ==="

# --- pick the newest backup folder ------------------------------------------
# 'auto' scans BOTH streams so a manual backup taken minutes ago wins over
# last night's. Folder names are owui-brains-YYYYMMDD-HHMMSS, so a descending
# name sort is a correct chronological sort across streams.
$streams = if ($Stream -eq 'auto') { @('nightly','manual') } else { @($Stream) }
$src = foreach ($s in $streams) {
    Get-ChildItem (Join-Path $Root $s) -Directory -Filter 'owui-brains-*' -EA SilentlyContinue
}
$src = $src | Sort-Object Name -Descending | Select-Object -First 1

if (-not $src) {
    Log "!! No backup found in $Root ($($streams -join ', ')) — run 'owuihelp backup' first."
    exit 1
}
$srcStream = Split-Path (Split-Path $src.FullName -Parent) -Leaf
Log "Source: $($src.Name)   [stream: $srcStream, selection: $Stream]"

# --- zip it (single-file transfer) ------------------------------------------
$zip = Join-Path $Root ("$($src.Name).zip")
if (Test-Path $zip) { Remove-Item $zip -Force -EA SilentlyContinue }
Log "Zipping -> $zip ..."
try {
    Compress-Archive -Path (Join-Path $src.FullName '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $zmb = [math]::Round((Get-Item $zip).Length/1MB,1)
    Log "Zip ready ($zmb MB)"
} catch { Log "!! Zip failed: $_"; exit 1 }

# --- ensure remote dir, then scp -------------------------------------------
# BatchMode=yes so a broken key fails fast (in a scheduled run) instead of hanging.
$sshOpts = @('-n','-o','BatchMode=yes','-o','ConnectTimeout=20')
Log "Ensuring remote dir $RemoteDir ..."
& ssh @sshOpts $SshHost "mkdir -p $RemoteDir" 2>&1 | ForEach-Object { Log "  ssh: $_" }
if ($LASTEXITCODE -ne 0) { Log "!! ssh to '$SshHost' failed (exit $LASTEXITCODE). Check 'ssh $SshHost' works + key has no passphrase (or is in an agent)."; exit 1 }

Log "Uploading (scp)..."
& scp '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=20' $zip "${SshHost}:$RemoteDir/" 2>&1 | ForEach-Object { Log "  scp: $_" }
if ($LASTEXITCODE -ne 0) { Log "!! scp failed (exit $LASTEXITCODE)."; Remove-Item $zip -Force -EA SilentlyContinue; exit 1 }

# --- also ship the rescue guide to the VPS root (readable without unzipping) -
$rescue = 'E:\ai\ollama\RESCUE-WINDOWS.md'
if (Test-Path $rescue) {
    & scp '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=20' $rescue "${SshHost}:$RemoteDir/" 2>&1 | ForEach-Object { Log "  rescue: $_" }
}

# --- verify it landed -------------------------------------------------------
$name = Split-Path $zip -Leaf
$check = & ssh @sshOpts $SshHost "ls -l $RemoteDir/$name 2>/dev/null && echo VERIFIED" 2>&1
$check | ForEach-Object { Log "  verify: $_" }
if ($check -match 'VERIFIED') { Log "OFFSITE COPY CONFIRMED on $SshHost" } else { Log "!! Could not verify remote file." }

# --- prune old remote copies ------------------------------------------------
#  2026-08-06: retention is now the UNION of two rules. A backup survives if
#  EITHER it is among the newest -KeepRemote, OR it is newer than -KeepDays.
#  It is deleted only when it fails BOTH.
#
#  Why the union and not age alone: if something breaks and you do not notice for
#  a week, an age-only rule can delete the last known-good copy. Count guarantees
#  depth of history; days guarantees a recent burst of pushes does not evict
#  everything older. Set either to 0 to disable that rule.
#
#  Age is taken from the FILENAME timestamp (owui-brains-yyyyMMdd-HHmmss.zip),
#  never mtime - scp resets mtime and would make every file look brand new.
#
#  For an ad-hoc prune without pushing, use prune-vps.ps1 (dry run by default).
if ($KeepRemote -gt 0 -or $KeepDays -gt 0) {
    Log "Pruning remote: keep newest $KeepRemote OR newer than $KeepDays days ..."

    # Built remotely in one shell pass: list newest-first, decide per file.
    $remote = @"
cd $RemoteDir 2>/dev/null || exit 0
cutoff=`$(date -d "$KeepDays days ago" +%Y%m%d 2>/dev/null || date -v-${KeepDays}d +%Y%m%d)
n=0
for f in `$(ls -1 owui-brains-*.zip 2>/dev/null | sort -r); do
  n=`$((n+1))
  stamp=`$(echo "`$f" | sed -n 's/^owui-brains-\([0-9]\{8\}\)-[0-9]\{6\}\.zip`$/\1/p')
  [ -z "`$stamp" ] && continue
  if [ "$KeepRemote" -gt 0 ] && [ "`$n" -le "$KeepRemote" ]; then continue; fi
  if [ "$KeepDays" -gt 0 ] && [ "`$stamp" -ge "`$cutoff" ]; then continue; fi
  rm -f "`$f" && echo "removed `$f"
done
echo "remaining: `$(ls -1 owui-brains-*.zip 2>/dev/null | wc -l)"
"@
    & ssh @sshOpts $SshHost $remote 2>&1 | ForEach-Object { Log "  prune: $_" }
}

# --- tidy local zip + old push logs -----------------------------------------
Remove-Item $zip -Force -EA SilentlyContinue
Get-ChildItem $Root -File -Filter 'push-vps-*.log' -EA SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -Skip 8 | Remove-Item -Force -EA SilentlyContinue

Log "=== DONE ==="
Write-Host ""
Write-Host ("  Offsite push finished -> {0}:{1}/{2}" -f $SshHost,$RemoteDir,$name) -ForegroundColor Green
