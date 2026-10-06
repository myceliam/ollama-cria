#Requires -Version 7.4
<#
.SYNOPSIS
    Checks the secrets bundle against its SHA-256, unpacks it into a protected
    folder, checks it against the inventory, and puts each chosen row back in
    its place (docs/RESTORE.md Stage 1 step 5, Stage 4b and Stage 7).

.DESCRIPTION
    The other half of tools/Collect-StackSecrets.ps1. Both ends share one
    versioned format, 00-RESTORE-MAP.json, checked by tools/Test-RestoreMap.ps1
    (C-08).

    Two modes:

      Plan (the default). Checks the ZIP's SHA-256 against -Sha256 (the value
      stored with the bundle in Bitwarden), checks every member name with
      tools/Test-RecoveryPath.ps1, unpacks it next to the ZIP into a new
      protected folder named after it (or re-checks that folder when it is
      already there), runs Test-RestoreMap.ps1 with the inventory from this
      repo, and lists what would happen to each row. It places nothing and
      never calls ssh or docker.

      -Execute. The same, then places every row of the folders given with
      -Folder. A run can be repeated: a file that is already in place with
      the same bytes is left alone.

    Rules it keeps:

      - The ZIP must sit in a folder only the current user can reach (Stage 1
        creates E:\recovery-secrets that way), and the unpacked bundle is
        created the same way. Members that are links, climb out with '..', are
        named twice, or are not in the map stop the run before anything is
        placed (C-49).
      - Fails closed. A required row that cannot be placed stops the run with
        exit code 1; an optional row only warns (C-07).
      - Never overwrites. A destination that already holds different bytes is
        refused and left as it is: move it away, then run again.
      - PC rows. The destination is '<root>:<path>' from the map, resolved
        through manifests/recovery-roots.json and checked with
        Test-RecoveryPath.ps1, so no junction or link is followed. The file is
        written under a temporary name created new (never through an existing
        name or link), owner-only from birth (an ACL granting only the current
        user on Windows, mode 0600 elsewhere), checked, then moved into place
        without replacing anything, and checked again.
      - VPS rows. One ssh call per row runs a fixed script that refuses links
        on the way, writes the file under a temporary name with umask 077,
        checks its SHA-256, sets the mode (and the owner and group, with sudo
        -n when needed) and links it into place without replacing anything.
        The file travels as base64 on ssh's input, never on a command line.
        Host keys are never accepted automatically.
      - Docker volume rows. The volume must exist and no running container may
        use it. A throw-away helper container (no network, a read-only
        filesystem, no log driver, removed on exit, ended by its own alarm)
        receives the file on its input, refuses links, writes it under a
        temporary name, checks it, sets the mode, owner and group recorded
        when it was collected, and links it into place without replacing
        anything. The helper image must already be on this machine.
      - Folder 03 is not placed: the OWUI seed importer reads it from the
        unpacked bundle in Stage 7d.
      - Output. Ids, logical destinations, statuses and counts. Never a secret
        value, a hash, or native error text.

.PARAMETER ZipPath
    The bundle, stack-secrets-<time>.zip, saved straight into the protected
    staging folder.

.PARAMETER Sha256
    The ZIP's SHA-256, as stored with it in Bitwarden.

.PARAMETER Folder
    The bundle folders to place: 04 in Stage 1, 01, 02 and 05 in Stage 4, 07
    in Stage 7. 03 is accepted and reported as read in place.

.PARAMETER Execute
    Place the rows. Without it the script only checks and plans.

.PARAMETER ManifestPath
    The secret inventory the bundle must have been collected from. Defaults to
    manifests/secrets.json in this repo.

.PARAMETER RootsPath
    The logical roots, which say where each destination is on this machine.
    Defaults to manifests/recovery-roots.json.

.PARAMETER FoldersPath
    The bundle-folder rules. Defaults to manifests/bundle-folders.json.

.PARAMETER SshHost
    The SSH alias of the VPS, from the current user's SSH config.

.PARAMETER HelperImage
    The image for the throw-away volume writer. It must already be on this
    machine and must have python3; it is never pulled.

.PARAMETER PassThru
    Return the result object instead of printing a summary and setting the
    exit code.

.OUTPUTS
    With -PassThru: [pscustomobject] with Mode, IsValid, BundleRoot, Rows,
    Problems and Warnings.

.EXAMPLE
    ./tools/Restore-StackSecrets.ps1 -ZipPath E:\recovery-secrets\stack-secrets-20261006T210000Z.zip -Sha256 <from Bitwarden> -Folder 04

    Checks and unpacks the bundle and shows what Stage 1 would place.

.EXAMPLE
    ./tools/Restore-StackSecrets.ps1 -ZipPath E:\recovery-secrets\stack-secrets-20261006T210000Z.zip -Sha256 <from Bitwarden> -Folder 01, 02, 05 -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are read inside the helper functions.')]
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [string]$ZipPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$Sha256,

    # 01 and 1 both work: PowerShell reads a bare 01 as the number 1.
    [Parameter(Mandatory)]
    [ValidatePattern('^0?[1-57]$')]
    [string[]]$Folder,

    [switch]$Execute,

    [string]$ManifestPath = (Join-Path $PSScriptRoot '../manifests/secrets.json'),

    [string]$RootsPath = (Join-Path $PSScriptRoot '../manifests/recovery-roots.json'),

    [string]$FoldersPath = (Join-Path $PSScriptRoot '../manifests/bundle-folders.json'),

    [string]$SshHost = 'vps',

    [string]$HelperImage = 'python:3.12-slim',

    [switch]$PassThru,

    # Test seams: the programs used to reach the VPS and Docker.
    [Parameter(DontShow)]
    [string]$SshCommand = 'ssh',

    [Parameter(DontShow)]
    [string]$DockerCommand = 'docker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$restorerVersion = '1.0.1'
$Folder = @($Folder | ForEach-Object { ([int]$_).ToString('00') } | Sort-Object -Unique)
$testPath = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
$testMap = Join-Path $PSScriptRoot 'Test-RestoreMap.ps1'
$mapFileName = '00-RESTORE-MAP.json'
$onWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
if ($onWindows) { Add-Type -AssemblyName System.IO.FileSystem.AccessControl }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# The bundle is a few files of a few MB at most; anything far bigger is not
# a bundle this collector wrote.
$maxBundleBytes = 256MB
$plainPath = '^[A-Za-z0-9._/-]+$'
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20')
$helperSeconds = 120

$problems = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$rowResults = [Collections.Generic.List[object]]::new()
$state = [pscustomobject]@{ BundleRoot = $null }

# Runs on the VPS through ssh, from a private temporary file: bash SCRIPT
# <path b64> <mode> <owner> <group> <sha256>, with the file as base64 on its
# input (with CRLF line ends when PowerShell on Windows sends it). Prints
# one word: placed, same, differs, link, notfile, or why it failed. Never
# prints content.
$remotePlace = @'
set -u
drain() { cat > /dev/null; }
p=$(printf '%s' "$1" | base64 -d 2>/dev/null) || { drain; echo bad; exit 0; }
mode=$2; owner=$3; group=$4; want=$5
d=${p%/*}
case "$p" in /*) ;; *) drain; echo bad; exit 0;; esac
q=''
for s in $(printf '%s' "${d#/}" | tr '/' ' '); do
  q="$q/$s"
  if [ -L "$q" ]; then drain; echo link; exit 0; fi
done
umask 077
mkdir -p -- "$d" 2>/dev/null || { drain; echo mkdir; exit 0; }
r=$(realpath -e -- "$d" 2>/dev/null) || { drain; echo mkdir; exit 0; }
[ "$r" = "$d" ] || { drain; echo link; exit 0; }
if [ -L "$p" ]; then drain; echo link; exit 0; fi
if [ -e "$p" ]; then
  drain
  [ -f "$p" ] || { echo notfile; exit 0; }
  h=$(sha256sum -- "$p" 2>/dev/null) || { echo unreadable; exit 0; }
  if [ "${h%% *}" = "$want" ]; then echo same; else echo differs; fi
  exit 0
fi
t=$(mktemp -- "$d/.cria-restore.XXXXXXXX" 2>/dev/null) || { drain; echo tempfile; exit 0; }
tr -d '\r' | base64 -d > "$t" 2>/dev/null || { rm -f -- "$t"; echo decode; exit 0; }
h=$(sha256sum -- "$t" 2>/dev/null) || { rm -f -- "$t"; echo unreadable; exit 0; }
[ "${h%% *}" = "$want" ] || { rm -f -- "$t"; echo mismatch; exit 0; }
chmod "$mode" -- "$t" 2>/dev/null || { rm -f -- "$t"; echo chmod; exit 0; }
if [ -n "$owner" ] && { [ "$owner" != "$(id -un)" ] || [ -n "$group" ]; }; then
  spec=$owner${group:+:$group}
  chown -- "$spec" "$t" 2>/dev/null || sudo -n chown -- "$spec" "$t" 2>/dev/null || { rm -f -- "$t"; echo chown; exit 0; }
fi
if ln -- "$t" "$p" 2>/dev/null; then rm -f -- "$t"; else rm -f -- "$t"; echo appeared; exit 0; fi
h=$(sha256sum -- "$p" 2>/dev/null) || { echo unreadable; exit 0; }
[ "${h%% *}" = "$want" ] || { echo mismatch; exit 0; }
echo placed
'@

# Runs inside the helper container: argv is the path inside the volume, the
# mode, uid, gid, SHA-256 and the most seconds it may run; the file arrives
# as base64 on stdin. Prints one JSON line with a status. Every step below
# the volume opens with O_NOFOLLOW against the folder it came from, so no
# link is followed.
$volumePlace = @'
import base64, hashlib, json, os, signal, stat, sys
rel, mode, uid, gid, want, seconds = sys.argv[1:7]
signal.alarm(int(seconds))
mode, uid, gid = int(mode, 8), int(uid), int(gid)
def say(status):
    print(json.dumps({'status': status}))
    sys.exit(0)
data = base64.b64decode(sys.stdin.read())
parts = rel.split('/')
if any(p in ('', '.', '..') for p in parts):
    say('bad')
fd = os.open('/dst', os.O_RDONLY | os.O_DIRECTORY)
for part in parts[:-1]:
    try:
        st = os.stat(part, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        os.mkdir(part, 0o755, dir_fd=fd)
        os.chown(part, uid, gid, dir_fd=fd, follow_symlinks=False)
        st = os.stat(part, dir_fd=fd, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode):
        say('link')
    nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
    os.close(fd)
    fd = nfd
leaf = parts[-1]
try:
    st = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
except FileNotFoundError:
    st = None
if st is not None:
    if stat.S_ISLNK(st.st_mode):
        say('link')
    if not stat.S_ISREG(st.st_mode):
        say('notfile')
    with os.fdopen(os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd), 'rb') as f:
        say('same' if hashlib.sha256(f.read()).hexdigest() == want else 'differs')
if hashlib.sha256(data).hexdigest() != want:
    say('mismatch')
tmp = '.cria-restore-' + os.urandom(6).hex()
tfd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
with os.fdopen(tfd, 'wb') as f:
    f.write(data)
    f.flush()
    os.fsync(f.fileno())
os.chown(tmp, uid, gid, dir_fd=fd, follow_symlinks=False)
os.chmod(tmp, mode, dir_fd=fd)
try:
    os.link(tmp, leaf, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
except FileExistsError:
    os.unlink(tmp, dir_fd=fd)
    say('appeared')
os.unlink(tmp, dir_fd=fd)
say('placed')
'@

# ---------- Small helpers ----------

function Get-RunResult {
    [pscustomobject]@{
        Mode       = if ($Execute) { 'Execute' } else { 'Plan' }
        IsValid    = ($problems.Count -eq 0)
        BundleRoot = $state.BundleRoot
        Rows       = $rowResults.ToArray()
        Problems   = $problems.ToArray()
        Warnings   = $warnings.ToArray()
    }
}

function Get-OptionalProperty($Object, [string]$Name) {
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CurrentUserSid {
    [Security.Principal.WindowsIdentity]::GetCurrent().User
}

function Test-IsLink([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-ProtectionProblem([string]$Path, [switch]$OwnFolder) {
    # Returns $null when only the current user can reach $Path, or the reason.
    # With -OwnFolder the item must also be owned by the current user and, on
    # Windows, not inherit permissions from its parent.
    if ($onWindows) {
        $sid = Get-CurrentUserSid
        $acl = Get-Acl -LiteralPath $Path
        if ($OwnFolder) {
            if (-not $acl.AreAccessRulesProtected) { return 'it inherits permissions from its parent' }
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $sid) { return 'it is owned by another account' }
        }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference -ne $sid) {
                return 'another account has access'
            }
        }
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($OwnFolder -and $item.UnixStat.UserId -ne [int](& id -u)) { return 'it is owned by another account' }
    $others = [IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
    if ($item.UnixFileMode -band $others) { return 'group or others have access' }
    return $null
}

function Initialize-ProtectedFolder([string]$Path) {
    # Created with only the current user from birth: an ACL with inheritance
    # off on Windows, mode 0700 elsewhere.
    if ($onWindows) {
        $sid = Get-CurrentUserSid
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path), $security)
    }
    else {
        $null = [IO.Directory]::CreateDirectory($Path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    }
}

function Initialize-FolderChain([string]$Path, [switch]$Protected) {
    # Creates every missing folder down to $Path, one by one, so each gets
    # the right protection (.NET applies a Unix mode only to the last one).
    $missing = [Collections.Generic.Stack[string]]::new()
    for ($p = $Path; $p -and -not [IO.Directory]::Exists($p); $p = [IO.Path]::GetDirectoryName($p)) { $missing.Push($p) }
    while ($missing.Count -gt 0) {
        $next = $missing.Pop()
        if ($Protected) { Initialize-ProtectedFolder $next }
        elseif ($onWindows) { $null = [IO.Directory]::CreateDirectory($next) }
        else { $null = [IO.Directory]::CreateDirectory($next, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }
}

function Open-NewOwnerOnlyFile([string]$Path) {
    # Creates the file new (CreateNew never opens an existing name or link),
    # readable and writable by the current user only from birth.
    if ($onWindows) {
        $sid = Get-CurrentUserSid
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
        return [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 81920, [IO.FileOptions]::None, $security)
    }
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    $options.UnixCreateMode = [IO.UnixFileMode]'UserRead, UserWrite'
    return [IO.FileStream]::new($Path, $options)
}

function Get-StreamDigest([IO.Stream]$Stream) {
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer = [byte[]]::new(81920)
    $total = [long]0
    try {
        while (($n = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $n); $total += $n }
        return [pscustomobject]@{ Sha256 = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant(); Bytes = $total }
    }
    finally { $hash.Dispose() }
}

function Copy-Bounded([IO.Stream]$From, [IO.Stream]$To, [long]$Limit) {
    # Copies at most $Limit bytes; returns $false when the source holds more.
    $buffer = [byte[]]::new(81920)
    $total = [long]0
    while (($n = $From.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $total += $n
        if ($total -gt $Limit) { return $false }
        $To.Write($buffer, 0, $n)
    }
    return $true
}

function Add-RowResult($Entry, [string]$Status) {
    $rowResults.Add([pscustomobject]@{
            Id          = $Entry.id
            Folder      = $Entry.folder
            Destination = $Entry.destination
            Required    = [bool]$Entry.required
            Status      = $Status
        })
}

function Add-RowFailure($Entry, [string]$Status) {
    if ($Entry.required) { $problems.Add("row '$($Entry.id)': $($Entry.destination) $Status") }
    else { $warnings.Add("row '$($Entry.id)': $($Entry.destination) $Status (optional)") }
    Add-RowResult $Entry $Status
}

# ---------- The ZIP and the unpacked bundle ----------

function Test-Zip([string]$Full) {
    # Returns the ZIP's file members (name -> declared length), or $null after
    # recording problems. Opens nothing for writing.
    $why = Get-ProtectionProblem (Split-Path $Full -Parent)
    if ($why) {
        $problems.Add("zip: its folder is not protected ($why); save the bundle straight into the protected staging folder")
        return $null
    }
    if ((Get-Sha256 $Full) -ne $Sha256.ToLowerInvariant()) {
        $problems.Add('zip: its SHA-256 does not match the value given; download the bundle again and check the value stored with it')
        return $null
    }
    $members = [ordered]@{}
    $seen = @{}
    $total = [long]0
    $syntaxRoot = Join-Path ([IO.Path]::GetTempPath()) 'cria-bundle'
    $zip = [IO.Compression.ZipFile]::OpenRead($Full)
    try {
        foreach ($e in $zip.Entries) {
            $name = $e.FullName
            if ($name.EndsWith('/')) { continue }    # a folder entry; folders come from the file names
            $check = & $testPath -Path $name -Root $syntaxRoot -Relative -SyntaxOnly -Detailed
            if (-not $check.IsValid) { $problems.Add("zip: a member name is refused ($($check.Reason))"); continue }
            if ($name.Contains('\')) { $problems.Add("zip: member '$name' uses '\'; the collector writes '/'"); continue }
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { $problems.Add("zip: member '$name' appears twice"); continue }
            $seen[$key] = $true
            $unixType = ($e.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -ne 0 -and $unixType -ne 0x8000) { $problems.Add("zip: member '$name' is a link or special file"); continue }
            $total += $e.Length
            $members[$name] = $e.Length
        }
    }
    finally { $zip.Dispose() }
    if ($total -gt $maxBundleBytes) { $problems.Add('zip: far larger than any bundle the collector writes') }
    if (-not $members.Contains($mapFileName)) { $problems.Add("zip: it has no $mapFileName") }
    if ($problems.Count -gt 0) { return $null }
    return $members
}

function Expand-Bundle([string]$Full, $Members) {
    # Unpacks into <ZIP folder>/<ZIP name>, created protected, or checks that
    # an earlier unpack there still matches the ZIP. Returns the folder.
    $parent = Split-Path $Full -Parent
    $name = [IO.Path]::GetFileNameWithoutExtension($Full)
    $check = & $testPath -Path $name -Root $parent -Relative -Detailed
    if (-not $check.IsValid) { $problems.Add("bundle: folder refused ($($check.Reason))"); return $null }
    $bundle = $check.FullPath
    $zip = [IO.Compression.ZipFile]::OpenRead($Full)
    try {
        if (Test-Path -LiteralPath $bundle) {
            $why = Get-ProtectionProblem $bundle -OwnFolder
            if ($why) { $problems.Add("bundle: the unpacked folder is not protected ($why)"); return $null }
            # Test-RestoreMap checks every file against the map; the map
            # itself must be the ZIP's own.
            $mapFile = Join-Path $bundle $mapFileName
            if (-not (Test-Path -LiteralPath $mapFile -PathType Leaf) -or (Test-IsLink $mapFile)) {
                $problems.Add("bundle: the unpacked folder has no $mapFileName; move the folder away and run again")
                return $null
            }
            $stream = $zip.GetEntry($mapFileName).Open()
            try { $fromZip = Get-StreamDigest $stream } finally { $stream.Dispose() }
            if ($fromZip.Sha256 -ne (Get-Sha256 $mapFile)) {
                $problems.Add('bundle: the unpacked folder is from another bundle; move it away and run again')
                return $null
            }
            return $bundle
        }
        Initialize-ProtectedFolder $bundle
        $why = Get-ProtectionProblem $bundle -OwnFolder
        if ($why) { $problems.Add("bundle: the new folder is not protected ($why)"); return $null }
        $done = $false
        try {
            foreach ($e in $zip.Entries) {
                if ($e.FullName.EndsWith('/')) { continue }
                $target = & $testPath -Path $e.FullName -Root $bundle -Relative -Detailed
                if (-not $target.IsValid) { $problems.Add("bundle: '$($e.FullName)' refused ($($target.Reason))"); return $null }
                Initialize-FolderChain (Split-Path $target.FullPath -Parent)
                $in = $e.Open()
                try {
                    $out = Open-NewOwnerOnlyFile $target.FullPath
                    try { $fits = Copy-Bounded $in $out ([long]$Members[$e.FullName]) } finally { $out.Dispose() }
                }
                finally { $in.Dispose() }
                if (-not $fits) { $problems.Add("bundle: '$($e.FullName)' is longer than the ZIP says"); return $null }
            }
            $done = $true
        }
        finally {
            # A half-unpacked folder would only stop the next run: this run
            # made it, so this run removes it.
            if (-not $done) { Remove-Item -LiteralPath $bundle -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    finally { $zip.Dispose() }
    return $bundle
}

# ---------- Placing ----------

function Resolve-PcDestination($Entry, $Root, [string]$Relative) {
    # Returns the Test-RecoveryPath result for the destination, or $null after
    # recording the row's failure.
    $rootPath = [Environment]::ExpandEnvironmentVariables([string]$Root.path)
    if ($rootPath.Contains('%') -or -not [IO.Path]::IsPathFullyQualified($rootPath)) {
        Add-RowFailure $Entry 'refused (its root cannot be used on this machine)'
        return $null
    }
    $check = & $testPath -Path $Relative -Root $rootPath -Relative -Detailed
    if (-not $check.IsValid) { Add-RowFailure $Entry "refused ($($check.Reason))"; return $null }
    return [pscustomobject]@{ Root = $rootPath; FullPath = $check.FullPath }
}

function Copy-PcEntry($Entry, [string]$Source, $Root, [string]$Relative) {
    $dest = Resolve-PcDestination $Entry $Root $Relative
    if (-not $dest) { return }
    $want = $Entry.sha256
    if (Test-Path -LiteralPath $dest.FullPath) {
        if (Test-IsLink $dest.FullPath) { Add-RowFailure $Entry 'refused (a link is already there)'; return }
        if (-not (Test-Path -LiteralPath $dest.FullPath -PathType Leaf)) { Add-RowFailure $Entry 'refused (a folder is already there)'; return }
        if ((Get-Sha256 $dest.FullPath) -eq $want) { Add-RowResult $Entry 'already in place'; return }
        Add-RowFailure $Entry 'refused (a different file is already there; move it away and run again)'
        return
    }
    if (-not $Execute) { Add-RowResult $Entry 'would place'; return }

    try { Initialize-FolderChain (Split-Path $dest.FullPath -Parent) }
    catch { Add-RowFailure $Entry "failed (could not create its folder: $($_.Exception.GetType().Name))"; return }
    # Folders created just now are checked again: nothing may have swapped one
    # for a link in between.
    $again = Resolve-PcDestination $Entry $Root $Relative
    if (-not $again) { return }

    $temp = Join-Path (Split-Path $dest.FullPath -Parent) ('.cria-restore-' + [guid]::NewGuid().ToString('n').Substring(0, 12) + '.tmp')
    try {
        $in = [IO.File]::OpenRead($Source)
        try {
            $out = Open-NewOwnerOnlyFile $temp
            try { $null = Copy-Bounded $in $out ([long]$Entry.bytes) } finally { $out.Dispose() }
        }
        finally { $in.Dispose() }
        if ((Get-Sha256 $temp) -ne $want) { throw [IO.InvalidDataException]::new('copy') }
        [IO.File]::Move($temp, $dest.FullPath, $false)
    }
    catch {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        $what = if (Test-Path -LiteralPath $dest.FullPath) { 'another file appeared there during the run' } else { $_.Exception.GetType().Name }
        Add-RowFailure $Entry "failed ($what)"
        return
    }
    $final = Resolve-PcDestination $Entry $Root $Relative
    if (-not $final) { return }
    if ((Get-Sha256 $final.FullPath) -ne $want) { Add-RowFailure $Entry 'failed (the placed file does not match the map)'; return }
    $why = Get-ProtectionProblem $final.FullPath
    if ($why) { Add-RowFailure $Entry "failed (the placed file is not owner-only: $why)"; return }
    Add-RowResult $Entry 'placed'
}

function Copy-VpsEntry($Entry, [string]$Source, $Root, [string]$Relative) {
    $rootPath = [string]$Root.path
    $rel = $Relative -replace '\\', '/'
    if ($rootPath -notmatch '^/' -or $rootPath -notmatch $plainPath -or $rel -notmatch $plainPath) {
        Add-RowFailure $Entry 'refused (VPS paths may only use letters, digits and . _ / -)'
        return
    }
    if (-not $Execute) { Add-RowResult $Entry 'checked when placing'; return }
    $remotePath = $rootPath.TrimEnd('/') + '/' + $rel
    $mode = [string](Get-OptionalProperty $Entry 'mode')
    if (-not $mode) { $mode = '0600' }
    $owner = [string](Get-OptionalProperty $Entry 'owner')
    $group = [string](Get-OptionalProperty $Entry 'group')
    $script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($remotePlace -replace "`r", '')))
    $pathArg = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remotePath))
    # The script goes into a mktemp file (mode 0600) so ssh's input stays free
    # for the file, and the command line needs no double quotes. Empty owner
    # and group travel as '' so the argument count never changes.
    $remote = 't=$(mktemp) && echo ' + $script + ' | base64 -d > $t && bash $t ' + $pathArg + ' ' + $mode + " '$owner' '$group' " +
        $Entry.sha256 + '; r=$?; rm -f $t; exit $r'
    $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Source), [Base64FormattingOptions]::InsertLineBreaks)
    $out = @($payload | & $SshCommand @sshOptions $SshHost $remote 2>$null)
    $code = $LASTEXITCODE
    $word = [string]($out | Select-Object -Last 1)
    if ($code -ne 0) { Add-RowFailure $Entry "failed (ssh exit $code)"; return }
    switch ($word) {
        'placed' { Add-RowResult $Entry 'placed' }
        'same' { Add-RowResult $Entry 'already in place' }
        'differs' { Add-RowFailure $Entry 'refused (a different file is already there; move it away and run again)' }
        'link' { Add-RowFailure $Entry 'refused (a symbolic link on the way)' }
        'notfile' { Add-RowFailure $Entry 'refused (something other than a file is already there)' }
        'chown' { Add-RowFailure $Entry 'failed (could not set the owner; sudo -n chown is not allowed)' }
        default { Add-RowFailure $Entry "failed (VPS step: $(if ($word -match '^[a-z]{2,12}$') { $word } else { 'no answer' }))" }
    }
}

function Test-VolumeReady([string]$Volume) {
    # Returns $null when the volume can be written, or why not.
    if ($Volume -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]+$') { return 'refused (not a plain Docker volume name)' }
    & $DockerCommand image inspect --format '{{.Id}}' $HelperImage *> $null
    if ($LASTEXITCODE -ne 0) { return "refused (the helper image $HelperImage is not on this machine; pull it first)" }
    & $DockerCommand volume inspect --format '{{.Name}}' $Volume *> $null
    if ($LASTEXITCODE -ne 0) { return 'refused (the volume does not exist yet; create it first)' }
    $users = @(& $DockerCommand ps --filter "volume=$Volume" --format '{{.Names}}' 2>$null)
    if ($LASTEXITCODE -ne 0) { return 'failed (docker ps did not answer)' }
    if (@($users | Where-Object { $_ }).Count -gt 0) { return 'refused (a running container uses the volume; stop it first)' }
    return $null
}

function Get-HelperLeft([string]$Name) {
    for ($try = 0; $try -lt 10; $try++) {
        $found = @(& $DockerCommand ps -a --filter "name=^/$Name$" --format '{{.Names}}' 2>$null)
        if ($LASTEXITCODE -ne 0) { return "failed (could not confirm the helper container $Name is gone; check with: docker ps -a)" }
        if (-not ($found -contains $Name)) { return $null }
        & $DockerCommand rm -f $Name 2>$null | Out-Null
        Start-Sleep -Milliseconds 300
    }
    return "failed (the helper container $Name could not be removed; remove it with: docker rm -f $Name)"
}

function Copy-VolumeEntry($Entry, [string]$Source, $Root, [string]$Relative) {
    $rel = $Relative -replace '\\', '/'
    if ($rel -notmatch $plainPath) { Add-RowFailure $Entry 'refused (volume paths may only use letters, digits and . _ / -)'; return }
    $mode = [string](Get-OptionalProperty $Entry 'mode')
    $uid = [string](Get-OptionalProperty $Entry 'owner')
    $gid = [string](Get-OptionalProperty $Entry 'group')
    if ($mode -notmatch '^0[0-7]{3}$' -or $uid -notmatch '^[0-9]{1,10}$' -or $gid -notmatch '^[0-9]{1,10}$') {
        Add-RowFailure $Entry 'refused (the map gives no numeric mode, owner and group for it)'
        return
    }
    if (-not $Execute) { Add-RowResult $Entry 'checked when placing'; return }
    $why = Test-VolumeReady ([string]$Root.volume)
    if ($why) { Add-RowFailure $Entry $why; return }

    $name = 'cria-restore-' + [guid]::NewGuid().ToString('n').Substring(0, 12)
    $program = "import base64; exec(base64.b64decode('" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($volumePlace -replace "`r", ''))) + "').decode())"
    $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Source), [Base64FormattingOptions]::InsertLineBreaks)
    $out = @($payload | & $DockerCommand run --rm -i --name $name --label 'cria.restorer=helper' --network none --pull never --read-only `
            --log-driver none -v "$($Root.volume):/dst" $HelperImage `
            python3 -c $program $rel $mode $uid $gid $Entry.sha256 $helperSeconds 2>$null)
    $code = $LASTEXITCODE
    $left = Get-HelperLeft $name
    if ($left) { Add-RowFailure $Entry $left; return }
    if ($code -ne 0) { Add-RowFailure $Entry "failed (helper exit $code)"; return }
    $status = $null
    try { $status = Get-OptionalProperty ([string]($out | Select-Object -Last 1) | ConvertFrom-Json) 'status' } catch { $status = $null }
    switch ($status) {
        'placed' { Add-RowResult $Entry 'placed' }
        'same' { Add-RowResult $Entry 'already in place' }
        'differs' { Add-RowFailure $Entry 'refused (a different file is already in the volume; move it away and run again)' }
        'link' { Add-RowFailure $Entry 'refused (a symbolic link on the way)' }
        'notfile' { Add-RowFailure $Entry 'refused (something other than a file is already there)' }
        default { Add-RowFailure $Entry "failed (volume step: $(if ($status -match '^[a-z]{2,12}$') { $status } else { 'no answer' }))" }
    }
}

# ---------- The run ----------

function Invoke-Restore {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ZipPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-IsLink $full)) {
        $problems.Add('zip: not found, or not a regular file')
        return
    }
    $members = Test-Zip $full
    if ($null -eq $members) { return }
    $bundle = Expand-Bundle $full $members
    if (-not $bundle) { return }
    $state.BundleRoot = $bundle

    # The inventory and the roots from this repo decide, not the map.
    $check = & $testMap -MapPath (Join-Path $bundle $mapFileName) -RootsPath $RootsPath -FoldersPath $FoldersPath `
        -InventoryPath $ManifestPath -BundleRoot $bundle
    foreach ($w in $check.Warnings) { $warnings.Add("map: $w") }
    if (-not $check.IsValid) {
        foreach ($p in $check.Problems) { $problems.Add("map: $p") }
        return
    }

    $map = Get-Content -LiteralPath (Join-Path $bundle $mapFileName) -Raw | ConvertFrom-Json
    $roots = @{}
    foreach ($r in (Get-Content -LiteralPath $RootsPath -Raw | ConvertFrom-Json).roots.PSObject.Properties) { $roots[$r.Name] = $r.Value }

    foreach ($entry in $map.entries | Where-Object { $Folder -contains $_.folder }) {
        $rootName, $relative = $entry.destination -split ':', 2
        $root = $roots[$rootName]
        $source = Join-Path (Join-Path $bundle $entry.folder) ($entry.file -replace '\\', '/')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            # Test-RestoreMap has already refused a missing required file.
            Add-RowResult $entry 'not in the bundle (optional)'
            continue
        }
        switch ($root.kind) {
            'consumed' { Add-RowResult $entry "read in place by $($root.consumer)" }
            'volume' { Copy-VolumeEntry $entry $source $root $relative }
            default {
                if ($root.host -eq 'vps') { Copy-VpsEntry $entry $source $root $relative }
                else { Copy-PcEntry $entry $source $root $relative }
            }
        }
    }
}

try {
    Invoke-Restore
}
catch {
    # Name the failure by type and line only: a message could echo a value.
    $problems.Add("stopped: unexpected $($_.Exception.GetType().Name) at line $($_.InvocationInfo.ScriptLineNumber)")
}

$result = Get-RunResult
if ($PassThru) { return $result }

$modeLabel = if ($Execute) { 'EXECUTE' } else { 'PLAN' }
Write-Output "Restore-StackSecrets $restorerVersion  [$modeLabel]  folders $($Folder -join ', ')"
if ($rowResults.Count -gt 0) {
    $idWidth = ($rowResults | ForEach-Object { $_.Id.Length } | Measure-Object -Maximum).Maximum
    $destWidth = ($rowResults | ForEach-Object { $_.Destination.Length } | Measure-Object -Maximum).Maximum
    foreach ($r in $rowResults) {
        Write-Output ('  {0}  {1}  {2}  {3}' -f $r.Folder, $r.Id.PadRight($idWidth), $r.Destination.PadRight($destWidth), $r.Status)
    }
    $groups = $rowResults | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }
    Write-Output "  Rows: $($rowResults.Count) ($($groups -join ', '))"
}
if ($state.BundleRoot) { Write-Output "  Bundle unpacked in: $($state.BundleRoot)" }
foreach ($w in $warnings) { Write-Output "  WARN     $w" }
foreach ($p in $problems) { Write-Output "  PROBLEM  $p" }

if (-not $result.IsValid) {
    Write-Output 'Result: NOT COMPLETE. Fix the problems above and run again; files already placed stay in place.'
    exit 1
}
if (-not $Execute) {
    Write-Output 'Result: plan only. The bundle is checked and unpacked; nothing was placed, and ssh and docker were not called. Run again with -Execute to place.'
    exit 0
}
Write-Output 'Result: COMPLETE. Every chosen row is in place.'
Write-Output 'The unpacked bundle holds plaintext secrets: it stays in the protected folder until the restore is accepted (Stage 9), then it is deleted.'
exit 0
