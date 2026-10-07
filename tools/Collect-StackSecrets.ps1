#Requires -Version 7.4
<#
.SYNOPSIS
    Builds the secrets bundle: every row in manifests/secrets.json, copied into a
    protected folder with a versioned restore map, checked, then zipped.

.DESCRIPTION
    The rewrite of the old collector (docs/RESTORE.md Appendix A; review
    findings C-03 to C-10).

    What it collects: exactly the rows in manifests/secrets.json, which name
    each secret by logical location only (for example 'stack:.env'). There is
    no discovery sweep. Each audit in that file names a folder that must hold
    no file without a row, so a new secret cannot be left out silently (C-06,
    C-10).

    Two modes:

      Plan (the default). Offline. Reads the manifests, checks that each PC
      row exists, runs the folder audits, checks -SeedOut and reads the
      BitLocker state of the staging drive and, when there are volume or
      seed rows, of the drives that can hold paged memory. It never calls
      ssh, scp, docker or tailscale (C-09).

      -Execute. Collects every row into a new folder under -StagingRoot,
      writes 00-RESTORE-MAP.json, re-checks the whole bundle with
      Test-RestoreMap.ps1 against the inventory it came from, writes the ZIP
      inside the same protected folder, reads every member back and checks
      its SHA-256 against the map, checks every item's permissions, writes
      the OWUI seed to -SeedOut, then prints the ZIP's SHA-256 (C-05, C-08).

    Rules it keeps:

      - Protected from birth. The run folder is created with an ACL that grants
        only the current user, inheritance off, and is read back before
        anything is copied. On Linux and macOS it is created with mode 0700.
        Anything else stops the run (C-04).
      - Fails closed. A missing required row, or any failed copy, hash, check
        or permission, stops the run with exit code 1, prints no next steps,
        and deletes the run folder this run created unless -KeepOnFailure is
        given (C-07). If the folder cannot be fully deleted, the run says so
        and names it, so it can be deleted by hand.
      - Staging. -StagingRoot and every folder above it must be a real
        folder, not a junction or link, so the BitLocker state read for its
        drive is the drive the files land on. -StagingRoot itself must be
        changeable only by the current user (it is created that way when it
        does not exist). A folder above it that another account could delete,
        move, empty or re-permission stops the run; on the drive root itself
        DELETE is ignored, and the right to create folders is allowed. A
        -StagingRoot that appears between the check and the run is refused,
        and after it is created the whole check runs again, so a folder
        another account made is never adopted.
      - Paths. Every source and bundle path goes through Test-RecoveryPath.ps1,
        so no junction, symbolic link or path outside its root is followed
        (C-49).
      - VPS rows. One ssh call runs a fixed script that reports, for each
        file, whether it is a regular file with no link on the way, its size
        and its SHA-256. scp then copies it, and the copy's hash must match.
        A file swapped for different bytes after the check is caught; one
        swapped for identical bytes is not, which changes nothing collected.
        Host keys are never accepted automatically: BatchMode and
        StrictHostKeyChecking=yes (C-09, C-10).
      - Volume rows. A throw-away helper container reads the Docker volume:
        no network, a read-only filesystem, no log driver, removed when it
        exits (--rm acts on exit, not when the collector stops). It holds the
        copy in a tmpfs and sends it back on its output with its size,
        SHA-256, mode and owner, so no copy is written to the container's
        writable layer or a log. A tmpfs is memory, and memory can be paged
        out: on Windows every drive that can hold the Docker VM's paged
        memory (the page files, the system drive and the WSL swap file) must
        have BitLocker on, like the staging drive, and the run stops if the
        page files cannot be listed. On Linux the boundary is weaker: active
        swap is only a warning, and whether it is encrypted is not checked.
        'timeout -s KILL' ends the helper after 300 seconds, even while it
        waits inside SQLite, so a killed collector cannot leave one running
        for long, and a helper left from an earlier run stops the next run
        until it is removed. The collector confirms each helper is gone.
        SQLite files are copied with SQLite's backup API, which includes
        changes still in the -wal file, and integrity-checked (C-03). Each
        volume must exist before the run; if one is re-created during the
        run, the row fails.
      - Output. Ids, locations, statuses, counts and the ZIP's SHA-256. Never a
        secret value, and never native error text, which could echo one
        (C-50).

      - The OWUI seed (bundle folder 03 and -SeedOut). The row whose kind is
        'owui-seed' runs tools/Export-OwuiSeed.py inside the running OWUI
        container with 'docker exec -i': the script, the schema and the
        arguments go in on stdin, so nothing is written inside the
        container and no address is on a command line. Every tailnet
        address and MagicDNS name of this tailnet, read from
        'tailscale status --json', is passed as a placeholder (PC_TS_IP,
        VPS_TS_IP, PC_TS_NAME, ...), so the seed carries none of them; the
        image digest is recorded. The export's secrets file goes into the
        bundle like any other row. The seed itself is checked here too: it
        must be the expected set of files, carry no value from the secrets
        file, and name exactly the references the secrets file holds. It is
        written last: first into the run folder, where tools/Test-NoSecrets.ps1
        scans it, then into -SeedOut, replacing an earlier seed. Only the
        exporter's own WARN, PROBLEM and OK lines are passed on; any other
        error output is counted, never shown (C-50).

.PARAMETER Execute
    Collect for real. Without it the script only plans, offline.

.PARAMETER ManifestPath
    The secret inventory. Defaults to manifests/secrets.json in this repo.

.PARAMETER RootsPath
    The logical roots. Defaults to manifests/recovery-roots.json in this repo.

.PARAMETER FoldersPath
    The bundle-folder rules. Defaults to manifests/bundle-folders.json.

.PARAMETER StagingRoot
    Where the run folder is created. It must be on a local fixed drive; on
    Windows that drive must have BitLocker on (see -AllowUnencryptedStaging).

.PARAMETER SshHost
    The SSH alias of the VPS, from the current user's SSH config.

.PARAMETER SeedOut
    Where the OWUI seed is written, for committing to the repo. Defaults to
    manifests/owui-seed/seed in this repo. It must be a new folder or hold
    only the files of an earlier seed, which are replaced.

.PARAMETER OwuiContainer
    The running Open WebUI container the seed is exported from.

.PARAMETER HelperImage
    The image for the throw-away volume reader. It must already be on this
    machine and must have python3 and coreutils' timeout; the collector
    never pulls it.

.PARAMETER AllowUnencryptedStaging
    Accept a staging drive, or a drive that can hold paged memory, whose
    BitLocker state is not 'On'. For tests only.

.PARAMETER KeepOnFailure
    Keep the run folder when the run fails, to inspect it. It holds plaintext
    secrets: delete it afterwards.

.PARAMETER PassThru
    Return the result object instead of printing a summary and setting the
    exit code.

.OUTPUTS
    With -PassThru: [pscustomobject] with Mode, IsValid, Rows, Problems,
    Warnings, BitLocker, RunFolder, ZipPath, ZipSha256, SeedOut, SeedFiles
    and SeedSummary.

.EXAMPLE
    ./tools/Collect-StackSecrets.ps1

    Plans offline and lists every row with its state.

.EXAMPLE
    ./tools/Collect-StackSecrets.ps1 -Execute -StagingRoot 'E:\recovery-secrets'
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are read inside the helper functions.')]
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [switch]$Execute,

    [string]$ManifestPath = (Join-Path $PSScriptRoot '../manifests/secrets.json'),

    [string]$RootsPath = (Join-Path $PSScriptRoot '../manifests/recovery-roots.json'),

    [string]$FoldersPath = (Join-Path $PSScriptRoot '../manifests/bundle-folders.json'),

    [string]$StagingRoot = 'E:\recovery-secrets',

    [string]$SshHost = 'vps',

    [string]$HelperImage = 'python:3.12-slim',

    [string]$SeedOut = (Join-Path $PSScriptRoot '../manifests/owui-seed/seed'),

    [string]$OwuiContainer = 'open-webui',

    [switch]$AllowUnencryptedStaging,

    [switch]$KeepOnFailure,

    [switch]$PassThru,

    # Test seams: the programs used to reach the VPS, Docker and Tailscale.
    [Parameter(DontShow)]
    [string]$SshCommand = 'ssh',

    [Parameter(DontShow)]
    [string]$ScpCommand = 'scp',

    [Parameter(DontShow)]
    [string]$DockerCommand = 'docker',

    [Parameter(DontShow)]
    [string]$TailscaleCommand = 'tailscale'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collectorVersion = '2.1.0'
$repo = Split-Path $PSScriptRoot -Parent
$testPath = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
$testMap = Join-Path $PSScriptRoot 'Test-RestoreMap.ps1'
$scanTool = Join-Path $PSScriptRoot 'Test-NoSecrets.ps1'
$exporter = Join-Path $PSScriptRoot 'Export-OwuiSeed.py'
$seedSchema = Join-Path $repo 'manifests/owui-seed/schema.json'
$schemaDir = Join-Path $repo 'manifests/schemas'
$mapFileName = '00-RESTORE-MAP.json'
$onWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
if ($onWindows) { Add-Type -AssemblyName System.IO.FileSystem.AccessControl }

# Remote paths go through scp and a remote shell; volume paths into a SQLite URI.
# Both are held to a plain character set so no quoting can ever matter.
$plainPath = '^[A-Za-z0-9._/-]+$'
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20')

$problems = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$rowResults = [Collections.Generic.List[object]]::new()
$run = [pscustomobject]@{
    BitLocker   = 'NotChecked'
    RunFolder   = $null
    ZipPath     = $null
    ZipSha256   = $null
    SeedOut     = $null
    SeedFiles   = 0
    SeedSummary = $null
}
# Kept out of the result: tailnet addresses are private, and the seed texts
# are written to -SeedOut only once the whole run has passed.
$owui = @{ Image = $null; Endpoints = $null; Seed = $null; Target = $null }

# Runs on the VPS through one ssh call. For each base64 path argument it prints
# one line: 'ok <bytes> <sha256>', or why the file cannot be collected. It
# never prints content.
$remoteCheck = @'
set -u
for b in "$@"; do
  p=$(printf '%s' "$b" | base64 -d 2>/dev/null) || { echo bad; continue; }
  if [ -L "$p" ]; then echo link; continue; fi
  if [ ! -e "$p" ]; then echo missing; continue; fi
  if [ ! -f "$p" ]; then echo notfile; continue; fi
  r=$(realpath -e -- "$p" 2>/dev/null) || { echo unreadable; continue; }
  if [ "$r" != "$p" ]; then echo link; continue; fi
  if [ ! -r "$p" ]; then echo unreadable; continue; fi
  s=$(stat -c %s -- "$p" 2>/dev/null) || { echo unreadable; continue; }
  h=$(sha256sum -- "$p" 2>/dev/null) || { echo unreadable; continue; }
  echo "ok $s ${h%% *}"
done
'@

# Runs inside the helper container: argv is kind, the path inside the volume,
# then the most seconds it may run. The first output line is JSON: a status ('ok', 'missing', 'link',
# 'notfile', 'integrity') and, when ok, the size, SHA-256, mode, uid and gid.
# The file follows as base64 lines. The only place it is written is /work, a
# tmpfs, so it never reaches the container's writable layer (a tmpfs can still
# be paged to swap). A SQLite copy is switched to rollback-journal mode, so it
# is one self-contained file.
# Three deadlines end the helper even if the collector was killed (R3-04):
# 'timeout -s KILL' kills it from outside after $helperSeconds, which works
# even while Python waits inside SQLite; the backup checks its own deadline
# between steps of 64 pages; and SQLite waits at most 10 seconds for a lock.
# The alarm stays as a fourth. 'docker run --init' puts tini at PID 1, so the
# signals behave as they do outside a container.
$helperSeconds = 300
$volumeCopy = @'
import base64, hashlib, json, os, signal, sqlite3, stat, sys, time
signal.signal(signal.SIGALRM, lambda *_: os._exit(124))
signal.alarm(int(sys.argv[3]))
deadline = time.monotonic() + int(sys.argv[3])
def progress(status, remaining, total):
    if time.monotonic() > deadline:
        os._exit(124)
kind, rel = sys.argv[1], sys.argv[2]
src = os.path.normpath(os.path.join('/src', rel))
def say(**fields):
    print(json.dumps(fields), flush=True)
if not os.path.lexists(src):
    say(status='missing'); sys.exit(0)
if os.path.realpath(src) != src:
    say(status='link'); sys.exit(0)
st = os.lstat(src)
if not stat.S_ISREG(st.st_mode):
    say(status='notfile'); sys.exit(0)
if kind == 'sqlite':
    source = sqlite3.connect('file:' + src + '?mode=ro', uri=True, timeout=10)
    copy = sqlite3.connect('/work/item')
    source.backup(copy, pages=64, progress=progress, sleep=0.25)
    source.close()
    copy.execute('PRAGMA journal_mode=DELETE')
    ok = copy.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    copy.close()
    if not ok:
        say(status='integrity'); sys.exit(0)
    with open('/work/item', 'rb') as f:
        data = f.read()
else:
    fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as f:
        now = os.fstat(f.fileno())
        if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino):
            say(status='link'); sys.exit(0)
        data = f.read()
say(status='ok', bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
    mode='%04o' % (st.st_mode & 0o777), uid=st.st_uid, gid=st.st_gid)
text = base64.b64encode(data).decode()
for i in range(0, len(text), 76):
    print(text[i:i + 76])
'@

# Runs inside the OWUI container as 'python3 -c': reads one JSON document
# from stdin with the exporter's text, the schema's text and its arguments,
# and runs it there. Only double-quote-free Python, so no quoting can matter.
$seedBoot = "import json,sys;e=json.loads(sys.stdin.read());g={'__name__':'owui_seed_export'};" +
    "exec(compile(e['script'],'Export-OwuiSeed.py','exec'),g);" +
    "sys.exit(g['main'](e['argv'],schema_text=e['schema']))"

# The files one export gives, and the name rule for any seed file.
$seedFileNames = @('access_grant', 'config', 'function', 'group', 'group_member', 'model', 'prompt',
    'provenance', 'secret_refs', 'skill', 'tool', 'user_settings') | ForEach-Object { "$_.json" }
$seedFileName = '^[a-z][a-z_]{0,40}\.json$'

# ---------- Helpers ----------

function Get-RunResult {
    [pscustomobject]@{
        Mode        = $(if ($Execute) { 'Execute' } else { 'Plan' })
        IsValid     = ($problems.Count -eq 0)
        Rows        = $rowResults.ToArray()
        Problems    = $problems.ToArray()
        Warnings    = $warnings.ToArray()
        BitLocker   = $run.BitLocker
        RunFolder   = $run.RunFolder
        ZipPath     = $run.ZipPath
        ZipSha256   = $run.ZipSha256
        SeedOut     = $run.SeedOut
        SeedFiles   = $run.SeedFiles
        SeedSummary = $run.SeedSummary
    }
}

function Test-AgainstSchema([string]$File, [string]$Schema, [string]$Label) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        $problems.Add("${Label}: file not found")
        return $false
    }
    $schemaErrors = $null
    $ok = Test-Json -Path $File -SchemaFile $Schema -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    if (-not $ok) {
        foreach ($e in $schemaErrors) {
            $msg = if ($e.ErrorDetails -and $e.ErrorDetails.Message) { $e.ErrorDetails.Message } else { $e.Exception.Message }
            $problems.Add("${Label}: $msg")
        }
        if (-not $schemaErrors) { $problems.Add("${Label}: does not match its schema") }
    }
    return [bool]$ok
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

function Get-BitLockerState([string]$Path) {
    # Reads the shell's BitLocker property, which needs no admin rights.
    # 1 means protection is on; anything else is reported as it is.
    if (-not $onWindows) { return 'NotApplicable' }
    try {
        $drive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        $shell = New-Object -ComObject Shell.Application
        $value = $shell.NameSpace($drive).Self.ExtendedProperty('System.Volume.BitLockerProtection')
    }
    catch {
        return 'Unknown'
    }
    switch ($value) {
        1 { return 'On' }
        2 { return 'Off' }
        $null { return 'Unknown' }
        default { return "Not on (state $value)" }
    }
}

function Initialize-ProtectedFolder([string]$Path) {
    # Creates the folder so that only the current user can reach it from the
    # moment it exists: the ACL is part of the create call, not applied after.
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

function Initialize-BundleFolder([string]$Path) {
    # A folder inside the run folder: it inherits the run folder's ACL on
    # Windows and is created 0700 elsewhere. .NET applies a Unix mode only to
    # the last folder it creates, so missing folders are created one by one.
    if ($onWindows) { $null = [IO.Directory]::CreateDirectory($Path); return }
    $missing = [Collections.Generic.Stack[string]]::new()
    for ($p = $Path; -not [IO.Directory]::Exists($p); $p = [IO.Path]::GetDirectoryName($p)) { $missing.Push($p) }
    while ($missing.Count -gt 0) {
        $null = [IO.Directory]::CreateDirectory($missing.Pop(), [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    }
}

function Protect-BundleFile([string]$Path) {
    # On Windows the file inherits the run folder's ACL. Elsewhere it gets 0600.
    if (-not $onWindows) { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite') }
}

function Get-ProtectionProblem([string]$Path, [switch]$IsRunFolder) {
    # Returns $null when only the current user can reach $Path, or the reason.
    if ($onWindows) {
        $sid = Get-CurrentUserSid
        $acl = Get-Acl -LiteralPath $Path
        if ($IsRunFolder) {
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
    if ($IsRunFolder -and $item.UnixStat.UserId -ne [int](& id -u)) { return 'it is owned by another account' }
    $others = [IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
    if ($item.UnixFileMode -band $others) { return 'group or others have access' }
    return $null
}

function ConvertTo-Base64([string]$Text) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Text -replace "`r", '')))
}

function Add-RowResult($Row, [string]$Status) {
    $rowResults.Add([pscustomobject]@{
            Id       = $Row.Id
            Folder   = $Row.Folder
            Location = $Row.Location
            Required = $Row.Required
            Source   = $Row.Source
            Status   = $Status
        })
}

function Add-MissingRow($Row) {
    if ($Row.Required) { $problems.Add("row '$($Row.Id)': $($Row.Location) is missing (required)") }
    else { $warnings.Add("row '$($Row.Id)': $($Row.Location) is missing (optional, left out of the bundle)") }
    Add-RowResult $Row 'missing'
}

# ---------- Reading and checking the manifests ----------

function Read-Manifest {
    # Returns the rows ready to collect, or $null after recording problems.
    $okManifest = Test-AgainstSchema $ManifestPath (Join-Path $schemaDir 'secrets.schema.json') 'manifest'
    $okRoots = Test-AgainstSchema $RootsPath (Join-Path $schemaDir 'recovery-roots.schema.json') 'roots file'
    $okFolders = Test-AgainstSchema $FoldersPath (Join-Path $schemaDir 'bundle-folders.schema.json') 'folders file'
    if (-not ($okManifest -and $okRoots -and $okFolders)) { return $null }

    # The map records which inventory it came from; the final check compares
    # this hash with the file again, so a change during the run is caught.
    $inventorySha256 = Get-Sha256 $ManifestPath
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $roots = @{}
    foreach ($r in (Get-Content -LiteralPath $RootsPath -Raw | ConvertFrom-Json).roots.PSObject.Properties) { $roots[$r.Name] = $r.Value }
    $folders = @{}
    foreach ($f in (Get-Content -LiteralPath $FoldersPath -Raw | ConvertFrom-Json).folders.PSObject.Properties) { $folders[$f.Name] = $f.Value }

    $syntaxBase = Join-Path ([IO.Path]::GetTempPath()) 'cria-syntax'
    $ids = @{}
    $locations = @{}
    $rows = [Collections.Generic.List[object]]::new()

    foreach ($m in $manifest.rows) {
        $label = "manifest: row '$($m.id)'"
        $rootName, $relative = $m.location -split ':', 2
        $root = $roots[$rootName]
        $rule = $folders[$m.folder]
        $mode = Get-OptionalProperty $m 'mode'
        $owner = Get-OptionalProperty $m 'owner'

        $idKey = $m.id.ToLowerInvariant()
        if ($ids.ContainsKey($idKey)) { $problems.Add("${label}: id already used") } else { $ids[$idKey] = $true }
        $locKey = ($rootName + ':' + ($relative -replace '\\', '/')).ToLowerInvariant()
        if ($locations.ContainsKey($locKey)) { $problems.Add("${label}: location already used by row '$($locations[$locKey])'") } else { $locations[$locKey] = $m.id }

        $check = & $testPath -Path $relative -Root (Join-Path $syntaxBase $rootName) -Relative -SyntaxOnly -Detailed
        if (-not $check.IsValid) { $problems.Add("${label}: location refused ($($check.Reason))") }

        if (-not $root) { $problems.Add("${label}: unknown root '$rootName'"); continue }
        if (-not $rule) { $problems.Add("${label}: folder $($m.folder) is not in the folders file"); continue }
        if ($root.kind -ne $rule.kind -or $root.host -ne $rule.host) {
            $problems.Add("${label}: folder $($m.folder) must come from a $($rule.host) '$($rule.kind)' root, not '$rootName'")
            continue
        }
        if ($root.kind -eq 'consumed' -and $m.kind -ne 'owui-seed') {
            $problems.Add("${label}: '$rootName' is filled by the OWUI seed export, so its row must have kind 'owui-seed'")
            continue
        }
        if ($m.kind -eq 'owui-seed' -and $root.kind -ne 'consumed') {
            $problems.Add("${label}: kind 'owui-seed' is only for a 'consumed' root")
            continue
        }
        if ($m.kind -eq 'sqlite' -and $root.kind -ne 'volume') { $problems.Add("${label}: kind 'sqlite' is only for Docker volume roots") }
        if (($null -ne $mode -or $null -ne $owner) -and $root.host -ne 'vps') { $problems.Add("${label}: mode and owner are only for VPS rows") }

        $source = switch ($root.kind) { 'volume' { 'volume' } 'consumed' { 'owui' } default { $root.host } }
        if ($source -ne 'pc' -and ($relative -replace '\\', '/') -notmatch $plainPath) {
            $problems.Add("${label}: VPS and volume locations may only use letters, digits and . _ / -")
        }
        $rootPath = $null
        $remotePath = $null
        $volume = $null
        if ($source -eq 'pc') {
            $rootPath = [Environment]::ExpandEnvironmentVariables($root.path)
        }
        elseif ($source -eq 'vps') {
            if ($root.path -notmatch '^/' -or $root.path -notmatch $plainPath) { $problems.Add("${label}: root '$rootName' must be an absolute plain Linux path") }
            $remotePath = $root.path.TrimEnd('/') + '/' + ($relative -replace '\\', '/')
        }
        elseif ($source -eq 'volume') {
            $volume = $root.volume
            if ($volume -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]+$') { $problems.Add("${label}: volume name '$volume' is not a plain Docker volume name") }
        }

        $rows.Add([pscustomobject]@{
                Id         = $m.id
                Folder     = $m.folder
                Location   = $m.location
                RootName   = $rootName
                Relative   = $relative
                Kind       = $m.kind
                Required   = $m.required
                Mode       = $mode
                Owner      = $owner
                Source     = $source
                RootPath   = $rootPath
                RemotePath = $remotePath
                Volume     = $volume
                BundleFile = $rootName + '/' + ($relative -replace '\\', '/')
            })
    }

    $audits = @(Get-OptionalProperty $manifest 'audits')
    foreach ($a in $audits | Where-Object { $null -ne $_ }) {
        $rootName, $relative = $a.location -split ':', 2
        $root = $roots[$rootName]
        if (-not $root -or $root.kind -ne 'path' -or $root.host -ne 'pc') {
            $problems.Add("manifest: audit '$($a.location)' must name a PC folder root")
        }
    }

    if (@($rows | Where-Object Source -EQ 'owui').Count -gt 1) { $problems.Add("manifest: only one row may have kind 'owui-seed'") }

    if ($problems.Count -gt 0) { return $null }
    return [pscustomobject]@{
        Rows      = $rows.ToArray()
        Audits    = $audits
        Roots     = $roots
        Locations = $locations
        Inventory = [ordered]@{
            sha256   = $inventorySha256
            required = @($rows | Where-Object Required | ForEach-Object Id)
        }
    }
}

function Invoke-Audit($Manifest) {
    # Every file in an audited folder must have a row. Names only are reported.
    foreach ($a in $Manifest.Audits | Where-Object { $null -ne $_ }) {
        $rootName, $relative = $a.location -split ':', 2
        $rootPath = [Environment]::ExpandEnvironmentVariables($Manifest.Roots[$rootName].path)
        try {
            if ($rootPath.Contains('%')) { throw 'unset variable' }
            # Nothing after the colon audits the whole root.
            $check = if ($relative -eq '') { & $testPath -Path $rootPath -Root $rootPath -AllowRoot -Detailed }
            else { & $testPath -Path $relative -Root $rootPath -Relative -Detailed }
        }
        catch {
            $problems.Add("audit '$($a.location)': root '$rootName' cannot be used on this machine")
            continue
        }
        if (-not $check.IsValid) { $problems.Add("audit '$($a.location)': refused ($($check.Reason))"); continue }
        if (-not (Test-Path -LiteralPath $check.FullPath -PathType Container)) {
            $warnings.Add("audit '$($a.location)': folder not found")
            continue
        }
        foreach ($item in Get-ChildItem -LiteralPath $check.FullPath -Recurse -Force) {
            $below = $item.FullName.Substring($check.FullPath.Length).TrimStart([char[]]@('\', '/')) -replace '\\', '/'
            $prefix = ($relative -replace '\\', '/').TrimEnd('/')
            $logical = $rootName + ':' + $(if ($prefix) { $prefix + '/' + $below } else { $below })
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $problems.Add("audit '$($a.location)': '$logical' is a junction or symbolic link")
                continue
            }
            if ($item.PSIsContainer) { continue }
            if (-not $Manifest.Locations.ContainsKey($logical.ToLowerInvariant())) {
                $problems.Add("audit '$($a.location)': '$logical' has no row in the manifest")
            }
        }
    }
}

function Test-PcRow($Row) {
    # Returns the full source path when the row can be collected, after
    # recording the row's state. Never follows a link.
    try {
        if ($Row.RootPath.Contains('%')) { throw 'unset variable' }
        $check = & $testPath -Path $Row.Relative -Root $Row.RootPath -Relative -Detailed
    }
    catch {
        $problems.Add("row '$($Row.Id)': root '$($Row.RootName)' cannot be used on this machine")
        Add-RowResult $Row 'refused (root)'
        return $null
    }
    if (-not $check.IsValid) {
        $problems.Add("row '$($Row.Id)': $($Row.Location) refused ($($check.Reason))")
        Add-RowResult $Row "refused ($($check.Reason))"
        return $null
    }
    if (-not (Test-Path -LiteralPath $check.FullPath -PathType Leaf)) {
        Add-MissingRow $Row
        return $null
    }
    return $check.FullPath
}

# ---------- Collecting ----------

function Copy-PcRow([string]$Source, [string]$Destination) {
    try { [IO.File]::Copy($Source, $Destination, $false) }
    catch { return "failed (copy: $($_.Exception.GetType().Name))" }
    if ((Get-Sha256 $Source) -ne (Get-Sha256 $Destination)) { return 'failed (the copy does not match its source)' }
    return 'collected'
}

function Copy-VpsRow($Rows, [hashtable]$Destinations) {
    # Returns a hashtable of row id -> status.
    $status = @{}
    $arguments = ($Rows | ForEach-Object { ConvertTo-Base64 $_.RemotePath }) -join ' '
    $remote = 'echo ' + (ConvertTo-Base64 $remoteCheck) + ' | base64 -d | bash -s -- ' + $arguments
    $lines = @(& $SshCommand @sshOptions $SshHost $remote 2>$null)
    $code = $LASTEXITCODE
    if ($code -ne 0 -or $lines.Count -ne @($Rows).Count) {
        foreach ($r in $Rows) { $status[$r.Id] = "failed (VPS check: ssh exit $code)" }
        return $status
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $r = @($Rows)[$i]
        $line = [string]$lines[$i]
        if ($line -eq 'missing') { $status[$r.Id] = 'missing'; continue }
        if ($line -eq 'link') { $status[$r.Id] = 'refused (a symbolic link on the way)'; continue }
        if ($line -eq 'notfile') { $status[$r.Id] = 'refused (not a regular file)'; continue }
        if ($line -notmatch '^ok ([0-9]+) ([0-9a-f]{64})$') { $status[$r.Id] = 'failed (VPS check: unreadable)'; continue }
        $bytes = [long]$Matches[1]
        $hash = $Matches[2]
        $dest = $Destinations[$r.Id]
        & $ScpCommand -q @sshOptions "${SshHost}:$($r.RemotePath)" $dest 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $status[$r.Id] = "failed (scp exit $LASTEXITCODE)"; continue }
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf) -or (Test-IsLink $dest)) { $status[$r.Id] = 'failed (scp wrote no regular file)'; continue }
        if ((Get-Item -LiteralPath $dest -Force).Length -ne $bytes -or (Get-Sha256 $dest) -ne $hash) {
            $status[$r.Id] = 'failed (the copy does not match the VPS file)'
            continue
        }
        $status[$r.Id] = 'collected'
    }
    return $status
}

function Get-HelperLeft([string]$Name) {
    # The helper runs with --rm. Confirm it is gone; if it is not, remove it
    # and look again. Returns $null when it is gone, or the row's failure.
    for ($try = 0; $try -lt 10; $try++) {
        $found = @(& $DockerCommand ps -a --filter "name=^/$Name$" --format '{{.Names}}' 2>$null)
        if ($LASTEXITCODE -ne 0) { return "failed (could not confirm the helper container $Name is gone; check with: docker ps -a)" }
        if (-not ($found -contains $Name)) { return $null }
        & $DockerCommand rm -f $Name 2>$null | Out-Null
        Start-Sleep -Milliseconds 300
    }
    return "failed (the helper container $Name could not be removed; remove it with: docker rm -f $Name)"
}

function Copy-VolumeRow($Row, [string]$Destination) {
    # One 'docker run': read-only filesystem, no network, no log driver,
    # removed on exit, and killed by 'timeout' after $helperSeconds. The
    # copy comes back on the helper's output, not through the container's
    # writable layer, and is checked against the size and hash it reports.
    $name = 'cria-collect-' + [guid]::NewGuid().ToString('n').Substring(0, 12)
    $mount = if ($Row.Kind -eq 'sqlite') { "$($Row.Volume):/src" } else { "$($Row.Volume):/src:ro" }
    $program = "import base64; exec(base64.b64decode('" + (ConvertTo-Base64 $volumeCopy) + "').decode())"
    $inner = $helperSeconds - 20  # Python's own deadline, inside the outer one
    $out = @(& $DockerCommand run --rm --init --name $name --label 'cria.collector=helper' --network none --pull never --read-only `
            --tmpfs '/work:rw,mode=0700,size=512m' --log-driver none -v $mount $HelperImage `
            timeout -s KILL $helperSeconds python3 -c $program $Row.Kind ($Row.Relative -replace '\\', '/') $inner 2>$null)
    $code = $LASTEXITCODE
    $left = Get-HelperLeft $name
    if ($left) { return $left }
    if ($code -in 124, 137) { return "failed (the helper ran out of time after at most $helperSeconds seconds)" }
    if ($code -ne 0) { return "failed (helper exit $code)" }

    $head = $null
    try { $head = [string]$out[0] | ConvertFrom-Json } catch { $head = $null }
    $status = if ($head) { Get-OptionalProperty $head 'status' } else { $null }
    switch ($status) {
        'ok' { }
        'missing' { return 'missing' }
        'link' { return 'refused (a symbolic link on the way)' }
        'notfile' { return 'refused (not a regular file)' }
        'integrity' { return 'failed (SQLite integrity check)' }
        default { return 'failed (the helper gave no usable answer)' }
    }
    $sha = [string](Get-OptionalProperty $head 'sha256')
    $size = Get-OptionalProperty $head 'bytes'
    $mode = [string](Get-OptionalProperty $head 'mode')
    $uid = Get-OptionalProperty $head 'uid'
    $gid = Get-OptionalProperty $head 'gid'
    $usable = ($sha -match '^[0-9a-f]{64}$') -and ($size -is [long] -or $size -is [int]) -and ($mode -match '^0[0-7]{3}$') -and
        ("$uid" -match '^[0-9]{1,10}$') -and ("$gid" -match '^[0-9]{1,10}$')
    if (-not $usable) { return 'failed (the helper gave no usable answer)' }
    try { $bytes = [Convert]::FromBase64String((@($out | Select-Object -Skip 1) -join '')) }
    catch { return 'failed (the helper gave no usable answer)' }
    $got = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($bytes.Length -ne $size -or $got -ne $sha) { return 'failed (the copy does not match the volume file)' }

    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    if ((Get-Sha256 $Destination) -ne $sha) { return 'failed (the copy does not match the volume file)' }

    # A volume is a Linux filesystem: the restorer puts these back.
    $Row | Add-Member -NotePropertyName Mode -NotePropertyValue $mode -Force
    $Row | Add-Member -NotePropertyName Owner -NotePropertyValue "$uid" -Force
    $Row | Add-Member -NotePropertyName Group -NotePropertyValue "$gid" -Force

    # 'docker run -v' would quietly create a volume that vanished after the
    # check; a different creation time means this is not the volume checked.
    $created = @(& $DockerCommand volume inspect --format '{{.CreatedAt}}' $Row.Volume 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]($created | Select-Object -First 1) -ne $Row.VolumeCreated) {
        return 'failed (the volume was removed or re-created during the run)'
    }
    return 'collected'
}

function Test-DockerReady($Rows) {
    # Before the run folder exists: no helper from an earlier run is left, the
    # helper image is here, and each volume exists (its creation time is kept).
    if (-not @($Rows | Where-Object Source -EQ 'volume')) { return }
    $stale = @(& $DockerCommand ps -a --filter 'label=cria.collector=helper' --format '{{.Names}}' 2>$null)
    if ($LASTEXITCODE -ne 0) { $problems.Add('docker: could not list containers; is Docker running?'); return }
    if ($stale) {
        $names = ($stale -join ' ')
        $problems.Add("docker: helper container(s) from an earlier run are still there; remove them with: docker rm -f $names")
        return
    }
    & $DockerCommand image inspect $HelperImage 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $problems.Add("helper image '$HelperImage' is not on this machine; pull it first (docker pull $HelperImage)")
        return
    }
    foreach ($r in $Rows | Where-Object Source -EQ 'volume') {
        $created = @(& $DockerCommand volume inspect --format '{{.CreatedAt}}' $r.Volume 2>$null)
        if ($LASTEXITCODE -ne 0) { Add-MissingRow $r; $r | Add-Member -NotePropertyName Skip -NotePropertyValue $true -Force; continue }
        $r | Add-Member -NotePropertyName VolumeCreated -NotePropertyValue ([string]($created | Select-Object -First 1)) -Force
    }
}

# ---------- The OWUI seed ----------

function Get-NodeLabel($Node) {
    # The first label of a node's MagicDNS name ('pc' in pc.<tailnet>.ts.net).
    $dns = [string]$Node['DNSName']
    if ($dns) { return ($dns -split '\.')[0].ToLowerInvariant() }
    return ([string]$Node['HostName']).ToLowerInvariant()
}

function Get-TailnetEndpoint {
    # Every tailnet address and MagicDNS name Tailscale reports, by placeholder
    # name: this machine is PC, the -SshHost node is VPS, any other node in
    # this tailnet is named after its first label, and a node from outside it
    # (shared in, or an exit node) gets EXT_ before its label. The exporter
    # swaps each value for its {{NAME}}, so the seed carries none of them;
    # Stage 4a renders them back.
    # Returns an ordered table, or $null after recording a problem. The
    # values are private: they go to the exporter on stdin, never anywhere else.
    $raw = @(& $TailscaleCommand status --json 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        $problems.Add('seed: ''tailscale status --json'' failed; is Tailscale running and signed in?')
        return $null
    }
    try { $status = ConvertFrom-Json -InputObject ($raw -join "`n") -AsHashtable -ErrorAction Stop }
    catch { $problems.Add('seed: the Tailscale status could not be read'); return $null }
    $suffix = ([string]$status['MagicDNSSuffix']).TrimEnd('.')
    if (-not $status['Self'] -or $suffix -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$') {
        $problems.Add('seed: the Tailscale status has no node for this machine or no MagicDNS name')
        return $null
    }
    # Sorted by name, so the numbering of a repeated label is the same each run.
    $all = @(if ($status['Peer']) { $status['Peer'].Values | Sort-Object { [string]$_['DNSName'] } })
    # Shared-in nodes and exit nodes have another suffix.
    $peers = @($all | Where-Object { ([string]$_['DNSName']).TrimEnd('.') -like "*.$suffix" })
    $outside = @($all | Where-Object { ([string]$_['DNSName']).TrimEnd('.') -notlike "*.$suffix" })
    $vps = @($peers | Where-Object { (Get-NodeLabel $_) -eq $SshHost.ToLowerInvariant() })
    if ($vps.Count -ne 1) {
        $problems.Add("seed: expected one node named '$SshHost' in the tailnet, found $($vps.Count)")
        return $null
    }
    $nodes = [ordered]@{ PC = $status['Self']; VPS = $vps[0] }
    $named = @($peers | Where-Object { -not [object]::ReferenceEquals($_, $vps[0]) } | ForEach-Object { @{ Prefix = ''; Node = $_ } }) +
        @($outside | ForEach-Object { @{ Prefix = 'EXT_'; Node = $_ } })
    foreach ($item in $named) {
        $name = (Get-NodeLabel $item.Node).ToUpperInvariant() -replace '[^A-Z0-9]', '_'
        if ($name -notmatch '^[A-Z]') { $name = 'NODE_' + $name }
        $name = $item.Prefix + $name
        for ($n = 2; $nodes.Contains($name); $n++) { $name = ($name -replace '_[0-9]+$', '') + "_$n" }
        $nodes[$name] = $item.Node
    }
    $endpoints = [ordered]@{}
    foreach ($key in $nodes.Keys) {
        foreach ($ip in @($nodes[$key]['TailscaleIPs'])) {
            if ("$ip" -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') { $endpoints["${key}_TS_IP"] = "$ip" }
            elseif ("$ip" -match '^[0-9a-fA-F:]+$') { $endpoints["${key}_TS_IP6"] = "$ip" }
        }
        $dns = ([string]$nodes[$key]['DNSName']).TrimEnd('.')
        if ($dns) { $endpoints["${key}_TS_NAME"] = $dns }
    }
    $endpoints['TS_DOMAIN'] = $suffix
    if (-not ($endpoints.Contains('PC_TS_IP') -and $endpoints.Contains('VPS_TS_IP'))) {
        $problems.Add('seed: the Tailscale status gives no IPv4 address for this machine or the VPS')
        return $null
    }
    return $endpoints
}

function Test-SeedOut {
    # Returns the full -SeedOut path when the seed can be written there: a
    # new folder, or one holding only the files of an earlier seed.
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SeedOut)
    $parent = Split-Path $full -Parent
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $problems.Add('seed: the folder above -SeedOut does not exist')
        return $null
    }
    $check = & $testPath -Path (Split-Path $full -Leaf) -Root $parent -Relative -Detailed
    if (-not $check.IsValid) { $problems.Add("seed: -SeedOut refused ($($check.Reason))"); return $null }
    if (Test-Path -LiteralPath $check.FullPath) {
        if (-not (Test-Path -LiteralPath $check.FullPath -PathType Container)) { $problems.Add('seed: -SeedOut is a file, not a folder'); return $null }
        $other = @(Get-ChildItem -LiteralPath $check.FullPath -Force | Where-Object {
                $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -cnotmatch $seedFileName })
        foreach ($item in $other) {
            $problems.Add("seed: -SeedOut holds '$($item.Name)', which is not part of a seed; move it, or choose another -SeedOut")
        }
        if ($other) { return $null }
    }
    return $check.FullPath
}

function Test-OwuiReady($Rows) {
    # Before the run folder exists: the OWUI container is running, its image
    # is known, and the tailnet's addresses are read for the exporter.
    if (-not @($Rows | Where-Object Source -EQ 'owui')) { return }
    if ($OwuiContainer -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
        $problems.Add('seed: -OwuiContainer is not a plain container name')
        return
    }
    $state = @(& $DockerCommand inspect --format '{{.State.Running}} {{.Image}}' $OwuiContainer 2>$null)
    if ($LASTEXITCODE -ne 0) { $problems.Add("seed: container '$OwuiContainer' was not found; is Docker running?"); return }
    $running, $image = ([string]($state | Select-Object -First 1)).Trim() -split ' ', 2
    if ($running -ne 'true') { $problems.Add("seed: container '$OwuiContainer' is not running; the seed is read from the running OWUI"); return }
    if ($image -notmatch '^sha256:[0-9a-f]{64}$') { $problems.Add("seed: the image of container '$OwuiContainer' could not be read"); return }
    $owui.Image = $image
    $digests = @(& $DockerCommand image inspect --format '{{json .RepoDigests}}' $image 2>$null)
    if ($LASTEXITCODE -eq 0) {
        try { $found = @(ConvertFrom-Json -InputObject ($digests -join "`n") -NoEnumerate -ErrorAction Stop) } catch { $found = @() }
        $found = @($found | ForEach-Object { $_ } | Where-Object { "$_" -match '^[a-z0-9][a-z0-9./_:-]*@sha256:[0-9a-f]{64}$' })
        $pick = @(@($found | Where-Object { $_ -like '*open-webui*' }) + $found) | Select-Object -First 1
        if ($pick) { $owui.Image = [string]$pick }
    }
    if ($owui.Image -notlike '*@sha256:*') { $warnings.Add('seed: the OWUI image has no registry digest; the seed records its local image id') }
    $owui.Endpoints = Get-TailnetEndpoint
}

function Get-JsonString([Text.Json.JsonElement]$Element) {
    # Every string anywhere under a JSON value.
    switch ($Element.ValueKind.ToString()) {
        'String' { $Element.GetString() }
        'Array' { foreach ($item in $Element.EnumerateArray()) { Get-JsonString $item } }
        'Object' { foreach ($p in $Element.EnumerateObject()) { Get-JsonString $p.Value } }
    }
}

function Copy-OwuiSeedRow($Row, [string]$Destination) {
    # Runs the exporter inside the OWUI container and checks its answer. The
    # secrets file is written to $Destination now; the seed is kept in memory
    # until Publish-Seed, after the whole bundle has passed.
    $argv = [Collections.Generic.List[string]]@('--stdout', '--image-digest', $owui.Image)
    foreach ($key in $owui.Endpoints.Keys) { $argv.Add('--endpoint'); $argv.Add("$key=$($owui.Endpoints[$key])") }
    $envelope = [ordered]@{
        argv   = $argv.ToArray()
        schema = [IO.File]::ReadAllText($seedSchema)
        script = [IO.File]::ReadAllText($exporter)
    } | ConvertTo-Json -Compress -Depth 3 -EscapeHandling EscapeNonAscii
    $answer = @($envelope | & $DockerCommand exec -i $OwuiContainer python3 -c $seedBoot 2>&1)
    $code = $LASTEXITCODE

    # Only the exporter's own lines are passed on; anything else on its error
    # output (a traceback, an OWUI log line) could hold a value, so it is counted.
    $lines = [Collections.Generic.List[string]]::new()
    $hidden = 0
    $stopped = $false
    foreach ($item in $answer) {
        if ($item -isnot [Management.Automation.ErrorRecord]) { if ("$item".Trim()) { $lines.Add("$item") }; continue }
        $text = $item.ToString()
        if ($text -cmatch '^(WARN|PROBLEM|OK|STOPPED) +(\S.*)$') {
            $kind, $what = $Matches[1], $Matches[2]
            if ($kind -eq 'WARN') { $warnings.Add("seed: $what") }
            elseif ($kind -eq 'PROBLEM') { $problems.Add("seed: $what"); $stopped = $true }
            elseif ($kind -eq 'OK') { $run.SeedSummary = $what }
        }
        elseif ($text.Trim()) { $hidden++ }
    }
    if ($hidden) { $warnings.Add("seed: $hidden other line(s) of error output from the export were not shown, because they could hold a value") }
    if ($code -ne 0) {
        if ($stopped) { return 'failed (the seed export stopped; see its problems)' }
        return "failed (the seed export ended with exit $code)"
    }

    $files = [ordered]@{}
    $secretsText = $null
    try {
        if ($lines.Count -ne 1) { throw 'not one document' }
        $doc = [Text.Json.JsonDocument]::Parse($lines[0])
        try {
            $root = $doc.RootElement
            if ((@($root.EnumerateObject() | ForEach-Object Name | Sort-Object) -join ',') -cne 'secrets_file,seed') { throw 'shape' }
            foreach ($p in $root.GetProperty('seed').EnumerateObject()) {
                if ($p.Name -cnotmatch $seedFileName -or $p.Value.ValueKind.ToString() -ne 'String') { throw 'shape' }
                $files[$p.Name] = $p.Value.GetString()
            }
            $secretsText = $root.GetProperty('secrets_file').GetString()
        }
        finally { $doc.Dispose() }
    }
    catch { return 'failed (the seed export gave no usable answer)' }

    $missing = @($seedFileNames | Where-Object { -not $files.Contains($_) })
    $extra = @($files.Keys | Where-Object { $seedFileNames -notcontains $_ })
    if ($missing -or $extra) { return "failed (the seed's files are not the expected set: missing $($missing.Count), unexpected $($extra.Count))" }

    $values = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        $sdoc = [Text.Json.JsonDocument]::Parse($secretsText)
        try {
            if ($sdoc.RootElement.GetProperty('owui_seed_secrets').GetInt32() -ne 1) { throw 'format' }
            $refsElement = $sdoc.RootElement.GetProperty('refs')
            $refs = @($refsElement.EnumerateObject() | ForEach-Object Name)
            foreach ($v in Get-JsonString $refsElement) { if ($v.Length -ge 8) { $null = $values.Add($v) } }
        }
        finally { $sdoc.Dispose() }
        $listed = @(ConvertFrom-Json -InputObject $files['secret_refs.json'] -NoEnumerate -ErrorAction Stop)
        $listed = @($listed | ForEach-Object { $_ })
    }
    catch { return 'failed (the secrets from the export are not in the expected format)' }
    $refSet = [Collections.Generic.HashSet[string]]::new([string[]]$refs, [StringComparer]::Ordinal)
    if ($refs.Count -ne $listed.Count -or @($listed | Where-Object { -not $refSet.Contains([string]$_) })) {
        return 'failed (the seed and its secrets file do not name the same references)'
    }
    # The exporter checks this too; a value from the secrets file must not
    # appear in the seed, raw or JSON-escaped.
    foreach ($name in $files.Keys) {
        foreach ($v in $values) {
            $escaped = $v.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
            if ($files[$name].Contains($v) -or $files[$name].Contains($escaped)) {
                return "failed (seed file $name holds the value of a secret reference)"
            }
        }
    }

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($secretsText)
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    $owui.Seed = $files
    return 'collected'
}

function Publish-Seed([string]$RunFolder) {
    # Last step. The seed is written into the run folder and scanned with
    # Test-NoSecrets.ps1, the repo's own gate, then copied into -SeedOut,
    # replacing an earlier seed file by file.
    $utf8 = [Text.UTF8Encoding]::new($false)
    $stage = Join-Path $RunFolder 'seed'
    Initialize-BundleFolder $stage
    foreach ($name in $owui.Seed.Keys) {
        $check = & $testPath -Path $name -Root $stage -Relative -Detailed
        if (-not $check.IsValid) { $problems.Add("seed: '$name' refused ($($check.Reason))"); return }
        [IO.File]::WriteAllText($check.FullPath, $owui.Seed[$name], $utf8)
        Protect-BundleFile $check.FullPath
    }
    $findings = @(& $scanTool -Path $stage -PassThru)
    foreach ($f in $findings) {
        $problems.Add("seed: the secret scan found '$($f.Rule)' in $($f.File) line $($f.Line); the seed was not written to -SeedOut")
    }
    if ($findings) { return }

    $target = $owui.Target
    if (Test-Path -LiteralPath $target) {
        $items = @(Get-ChildItem -LiteralPath $target -Force)
        if (@($items | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -cnotmatch $seedFileName })) {
            $problems.Add('seed: something other than seed files appeared in -SeedOut during the run; the seed was not written')
            return
        }
        foreach ($old in $items | Where-Object { -not $owui.Seed.Contains($_.Name) }) {
            $check = & $testPath -Path $old.Name -Root $target -Relative -Detailed
            if (-not $check.IsValid) { $problems.Add("seed: '$($old.Name)' in -SeedOut refused ($($check.Reason))"); return }
            Remove-Item -LiteralPath $check.FullPath -Force
        }
    }
    else { $null = [IO.Directory]::CreateDirectory($target) }
    foreach ($name in $owui.Seed.Keys) {
        $check = & $testPath -Path $name -Root $target -Relative -Detailed
        if (-not $check.IsValid) { $problems.Add("seed: '$name' refused in -SeedOut ($($check.Reason))"); return }
        [IO.File]::WriteAllText($check.FullPath, $owui.Seed[$name], $utf8)
    }
    $run.SeedOut = $target
    $run.SeedFiles = $owui.Seed.Count
}

function Get-PagingLocation {
    # Windows: where memory, the Docker VM's included, can be written to
    # disk: each page file, the system drive (hibernation and swap files) and
    # the WSL 2 swap file, from .wslconfig or its default place. Returns paths.
    # Throws when the page files cannot be listed: a place nobody can name
    # cannot be checked, so the caller refuses instead (R3-05).
    $found = [Collections.Generic.List[string]]::new()
    $found.Add($env:SystemDrive + '\')
    try { $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop) }
    catch { throw 'the page files could not be listed' }
    foreach ($p in $pageFiles) { $found.Add([string]$p.Name) }

    # .wslconfig is read whole first, the last value of a key winning, so
    # the order of swap= and swapFile= does not matter.
    $settings = @{}
    $config = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path -LiteralPath $config -PathType Leaf) {
        $section = ''
        foreach ($line in Get-Content -LiteralPath $config) {
            $l = ($line -replace '[#;].*$', '').Trim()
            if ($l -match '^\[(.+)\]$') { $section = $Matches[1].Trim().ToLowerInvariant(); continue }
            if ($section -ne 'wsl2' -or $l -notmatch '^([^=]+)=(.*)$') { continue }
            $settings[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim().Trim('"') -replace '\\\\', '\'
        }
    }
    # WSL's default is %TEMP%\swap.vhdx; older releases used the profile's
    # Temp folder. Both are named, since only their drives matter here.
    $swapFiles = if ($settings['swapfile']) { @($settings['swapfile']) } else {
        @((Join-Path ([IO.Path]::GetTempPath()) 'swap.vhdx'), (Join-Path $env:USERPROFILE 'AppData\Local\Temp\swap.vhdx'))
    }
    $swapOff = [string]$settings['swap'] -match '^0+\s*[A-Za-z]*$'
    foreach ($f in $swapFiles) {
        # With swap off, a swap file left from before is still on disk.
        if (-not $swapOff -or (Test-Path -LiteralPath $f)) { $found.Add($f) }
    }
    $found | Where-Object { $_ } | Select-Object -Unique
}

function Test-PagingBoundary {
    # The volume helper holds each copy in a tmpfs, which is memory and can
    # be paged out. On Windows each drive that can hold paged memory needs
    # BitLocker on, like the staging drive. Elsewhere, active swap is named.
    if ($onWindows) {
        try { $locations = @(Get-PagingLocation) }
        catch {
            $note = "docker: where memory can be paged is unknown ($($_.Exception.Message)), so the volume copies cannot be checked against it"
            if ($AllowUnencryptedStaging) { $warnings.Add("$note (allowed by -AllowUnencryptedStaging)") } else { $problems.Add($note) }
            return
        }
        $drives = @($locations | ForEach-Object { [IO.Path]::GetPathRoot($_) } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($d in $drives) {
            $state = Get-BitLockerState $d
            if ($state -eq 'On') { continue }
            $note = "docker: memory can be paged to drive '$d', where BitLocker is '$state'"
            if ($AllowUnencryptedStaging) { $warnings.Add("$note (allowed by -AllowUnencryptedStaging)") } else { $problems.Add($note) }
        }
        return
    }
    $swaps = @(Get-Content -LiteralPath '/proc/swaps' -ErrorAction SilentlyContinue | Select-Object -Skip 1 | Where-Object { $_.Trim() })
    if ($swaps) { $warnings.Add('docker: this machine has swap on, so a volume copy held in memory can be paged to disk; the swap''s encryption is not checked') }
}

function Get-ChangeableBy([string]$Path, [switch]$IsDriveRoot, [switch]$IsStagingRoot) {
    # Accounts other than the current user, SYSTEM and Administrators that
    # could delete, move or re-permission $Path or what is in it. Returns a
    # list of names, empty when there are none. Deny entries are not
    # subtracted and group membership is not expanded, so this errs towards
    # naming an account; it is not a full effective-access calculation.
    $names = [Collections.Generic.List[string]]::new()
    if ($onWindows) {
        $me = Get-CurrentUserSid
        # Me, SYSTEM, Administrators, CREATOR OWNER, OWNER RIGHTS (the
        # object's current owner, named on its own below) and TrustedInstaller.
        $trusted = @($me.Value, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-3-4',
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        # On any folder: DELETE, FILE_DELETE_CHILD, WRITE_DAC, WRITE_OWNER and
        # GENERIC_ALL, the rights that move, empty or take over a folder.
        # DELETE on a whole drive means nothing, so it is ignored there. The
        # staging root also may not let others add or change what is in it:
        # FILE_WRITE_DATA (add file), FILE_APPEND_DATA (add folder) and
        # GENERIC_WRITE. 'Write' and 'Modify' already map to the first two.
        $risky = 0x00010000 -bor 0x40 -bor 0x00040000 -bor 0x00080000 -bor 0x10000000
        if ($IsDriveRoot) { $risky = $risky -band (-bnot 0x00010000) }
        if ($IsStagingRoot) { $risky = $risky -bor 0x2 -bor 0x4 -bor 0x40000000 }
        $acl = Get-Acl -LiteralPath $Path
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
        if ($trusted -notcontains $owner.Value) { $names.Add("$owner (owner)") }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($trusted -contains $rule.IdentityReference.Value) { continue }
            if (([int]$rule.FileSystemRights) -band $risky) {
                $who = $rule.IdentityReference.Value
                try { $who = $rule.IdentityReference.Translate([Security.Principal.NTAccount]).Value } catch { $null = $_ }
                $names.Add($who)
            }
        }
    }
    else {
        $item = Get-Item -LiteralPath $Path -Force
        $me = [int](& id -u)
        if ($item.UnixStat.UserId -ne 0 -and $item.UnixStat.UserId -ne $me) { $names.Add("uid $($item.UnixStat.UserId) (owner)") }
        $mode = $item.UnixFileMode
        if (-not $item.UnixStat.IsSticky) {
            if ($mode -band [IO.UnixFileMode]::GroupWrite) { $names.Add("gid $($item.UnixStat.GroupId) (group write)") }
            if ($mode -band [IO.UnixFileMode]::OtherWrite) { $names.Add('everyone (other write)') }
        }
    }
    return , $names.ToArray()
}

function Test-StagingRoot {
    # Returns the full staging root when it may be used, after recording any
    # problem. Every folder above it, and the root itself, must be a real
    # folder, so files land on the drive whose BitLocker state was read.
    if (-not [IO.Path]::IsPathFullyQualified($StagingRoot) -or $StagingRoot -match '^[\\/]{2}') {
        $problems.Add('staging: -StagingRoot must be an absolute local path')
        return $null
    }
    $rootFull = [IO.Path]::GetFullPath($StagingRoot).TrimEnd([char[]]@('\', '/'))
    if ($onWindows -and [IO.DriveInfo]::new([IO.Path]::GetPathRoot($rootFull)).DriveType -ne 'Fixed') {
        $problems.Add('staging: -StagingRoot must be on a local fixed drive')
        return $null
    }
    try { $check = & $testPath -Path $rootFull -Root $rootFull -AllowRoot -Detailed }
    catch { $problems.Add('staging: -StagingRoot must be a folder below a drive or filesystem root'); return $null }
    if (-not $check.IsValid) { $problems.Add("staging: -StagingRoot refused ($($check.Reason))"); return $null }

    $top = [IO.Path]::GetPathRoot($rootFull)
    $current = $top
    foreach ($segment in @($rootFull.Substring($top.Length) -split '[\\/]' | Where-Object { $_ -ne '' })) {
        $parent = $current
        $current = [IO.Path]::Combine($current, $segment)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { break }
        $who = Get-ChangeableBy $parent -IsDriveRoot:($parent -eq $top)
        if ($who) {
            $problems.Add("staging: '$parent' can be changed by $($who -join ', '), who could move or replace the staging folder; use a -StagingRoot whose parent folders only your account and administrators can change")
            return $null
        }
    }
    if (Test-Path -LiteralPath $rootFull) {
        if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { $problems.Add('staging: -StagingRoot is not a folder'); return $null }
        $who = Get-ChangeableBy $rootFull -IsStagingRoot
        if ($who) {
            $problems.Add("staging: -StagingRoot can be changed by $($who -join ', '); use a folder only your account can change, or let the collector create it")
            return $null
        }
    }
    return $rootFull
}

function Initialize-RunFolder([string]$RootFull, [bool]$RootExisted) {
    # Creates <StagingRoot>/stack-secrets-<UTC time>, protected, and returns it.
    # A staging root that was absent at the check and is there now was made by
    # someone else in between, so it is refused, never adopted. One this run
    # creates must come out owned and reachable only by the current user, and
    # then the whole staging check runs again.
    if (Test-Path -LiteralPath $RootFull) {
        if (-not $RootExisted) { $problems.Add('staging: -StagingRoot appeared after it was checked; find out what made it, then run again'); return $null }
    }
    else {
        Initialize-ProtectedFolder $RootFull
        $why = Get-ProtectionProblem $RootFull -IsRunFolder
        if ($why) { $problems.Add("staging: the new -StagingRoot is not protected ($why)"); return $null }
    }
    $before = $problems.Count
    $again = Test-StagingRoot
    if ($problems.Count -ne $before) { return $null }
    if ($again -ne $RootFull) { $problems.Add('staging: -StagingRoot changed after it was checked'); return $null }

    $name = 'stack-secrets-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $check = & $testPath -Path $name -Root $RootFull -Relative -Detailed
    if (-not $check.IsValid) { $problems.Add("staging: run folder refused ($($check.Reason))"); return $null }
    if (Test-Path -LiteralPath $check.FullPath) { $problems.Add('staging: the run folder already exists'); return $null }

    Initialize-ProtectedFolder $check.FullPath
    $run.RunFolder = $check.FullPath
    $why = Get-ProtectionProblem $check.FullPath -IsRunFolder
    if ($why) { $problems.Add("staging: the run folder is not protected ($why)"); return $null }
    if (@(Get-ChildItem -LiteralPath $check.FullPath -Force).Count -ne 0) { $problems.Add('staging: the new run folder is not empty'); return $null }
    return $check.FullPath
}

function Get-StreamDigest([IO.Stream]$Stream) {
    # SHA-256 and length of everything the stream yields.
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer = [byte[]]::new(81920)
    $total = [long]0
    try {
        while (($n = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $n); $total += $n }
        return [pscustomobject]@{ Sha256 = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant(); Bytes = $total }
    }
    finally { $hash.Dispose() }
}

function Write-BundleZip([string]$RunFolder, [string]$BundleDir, [string[]]$Members, [hashtable]$Expected) {
    # Writes the ZIP inside the run folder with '/' entry names, then reads
    # every member back and checks its bytes against what the map promises
    # ($Expected: member -> Sha256 and Bytes), so the ZIP is what was checked.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zipPath = Join-Path $RunFolder ((Split-Path $RunFolder -Leaf) + '.zip')
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($m in $Members) {
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $BundleDir $m), $m, [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $zip.Dispose() }
    Protect-BundleFile $zipPath

    $seen = @{}
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($e in $zip.Entries) {
                $key = $e.FullName.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { $problems.Add("zip: '$($e.FullName)' appears twice"); continue }
                $seen[$key] = $true
                if (-not $Expected.ContainsKey($e.FullName)) { $problems.Add("zip: unexpected entry '$($e.FullName)'"); continue }
                $stream = $e.Open()
                try { $got = Get-StreamDigest $stream } finally { $stream.Dispose() }
                $want = $Expected[$e.FullName]
                if ($got.Bytes -ne $want.Bytes -or $got.Sha256 -ne $want.Sha256) { $problems.Add("zip: '$($e.FullName)' does not match the map") }
            }
        }
        finally { $zip.Dispose() }
    }
    catch {
        $problems.Add("zip: cannot be read back ($($_.Exception.GetType().Name))")
        return
    }
    foreach ($m in $Members) {
        if (-not $seen.ContainsKey($m.ToLowerInvariant())) { $problems.Add("zip: '$m' is missing") }
    }
    if ($problems.Count -gt 0) { return }
    $run.ZipPath = $zipPath
    $run.ZipSha256 = Get-Sha256 $zipPath
}

function Invoke-Collection {
    $manifest = Read-Manifest
    if (-not $manifest) { return }

    Invoke-Audit $manifest
    $owuiRows = @($manifest.Rows | Where-Object Source -EQ 'owui')
    if ($owuiRows) { $owui.Target = Test-SeedOut }
    $stagingFull = Test-StagingRoot
    $stagingExisted = [bool]($stagingFull -and (Test-Path -LiteralPath $stagingFull))
    $run.BitLocker = Get-BitLockerState $StagingRoot
    if ($onWindows -and $run.BitLocker -ne 'On') {
        $note = "staging: BitLocker on the -StagingRoot drive is '$($run.BitLocker)'"
        if ($AllowUnencryptedStaging) { $warnings.Add("$note (allowed by -AllowUnencryptedStaging)") } else { $problems.Add($note) }
    }
    if (@($manifest.Rows | Where-Object Source -In 'volume', 'owui')) { Test-PagingBoundary }

    $sources = @{}
    foreach ($r in $manifest.Rows | Where-Object Source -EQ 'pc') {
        $full = Test-PcRow $r
        if ($full) { $sources[$r.Id] = $full; if (-not $Execute) { Add-RowResult $r 'present' } }
    }
    if (-not $Execute) {
        foreach ($r in $manifest.Rows | Where-Object Source -NE 'pc') { Add-RowResult $r 'checked when collecting' }
        return
    }

    Test-DockerReady $manifest.Rows
    Test-OwuiReady $manifest.Rows
    if ($problems.Count -gt 0) { return }

    if (-not $stagingFull) { return }
    $runFolder = Initialize-RunFolder $stagingFull $stagingExisted
    if (-not $runFolder) { return }
    $bundleDir = Join-Path $runFolder 'bundle'
    Initialize-BundleFolder $bundleDir

    $destinations = @{}
    foreach ($r in $manifest.Rows) {
        $member = $r.Folder + '/' + $r.BundleFile
        $check = & $testPath -Path $member -Root $bundleDir -Relative -Detailed
        if (-not $check.IsValid) { $problems.Add("row '$($r.Id)': bundle path refused ($($check.Reason))"); continue }
        Initialize-BundleFolder (Split-Path $check.FullPath -Parent)
        $destinations[$r.Id] = $check.FullPath
    }
    if ($problems.Count -gt 0) { return }

    $collected = [Collections.Generic.List[object]]::new()
    $vpsRows = @($manifest.Rows | Where-Object Source -EQ 'vps')
    $vpsStatus = if ($vpsRows) { Copy-VpsRow $vpsRows $destinations } else { @{} }

    foreach ($r in $manifest.Rows) {
        if ((Get-OptionalProperty $r 'Skip') -or ($r.Source -eq 'pc' -and -not $sources.ContainsKey($r.Id))) { continue }
        $status = switch ($r.Source) {
            'pc' { Copy-PcRow $sources[$r.Id] $destinations[$r.Id] }
            'vps' { $vpsStatus[$r.Id] }
            'volume' { Copy-VolumeRow $r $destinations[$r.Id] }
            'owui' { Copy-OwuiSeedRow $r $destinations[$r.Id] }
        }
        if ($status -eq 'missing') { Add-MissingRow $r; continue }
        Add-RowResult $r $status
        if ($status -ne 'collected') { $problems.Add("row '$($r.Id)': $status"); continue }
        Protect-BundleFile $destinations[$r.Id]
        $collected.Add($r)
    }
    if ($problems.Count -gt 0) { return }
    if ($collected.Count -eq 0) { $problems.Add('bundle: nothing was collected'); return }

    # The restore map: names, logical destinations, sizes and hashes only.
    $entries = foreach ($r in $collected) {
        $e = [ordered]@{
            id          = $r.Id
            folder      = $r.Folder
            file        = $r.BundleFile
            destination = $r.Location
            sha256      = Get-Sha256 $destinations[$r.Id]
            bytes       = (Get-Item -LiteralPath $destinations[$r.Id] -Force).Length
            required    = $r.Required
        }
        foreach ($field in 'Mode', 'Owner', 'Group') {
            $value = Get-OptionalProperty $r $field
            if ($value) { $e[$field.ToLowerInvariant()] = $value }
        }
        $e
    }
    $map = [ordered]@{
        formatVersion = 1
        createdUtc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        collector     = [ordered]@{ name = 'Collect-StackSecrets.ps1'; version = $collectorVersion }
        inventory     = $manifest.Inventory
        entries       = @($entries)
    }
    $mapPath = Join-Path $bundleDir $mapFileName
    [IO.File]::WriteAllText($mapPath, ($map | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    Protect-BundleFile $mapPath
    $mapSha256 = Get-Sha256 $mapPath

    # The same check the restorer runs, over the finished bundle and against
    # the inventory it was collected from (C-08).
    $verify = & $testMap -MapPath $mapPath -RootsPath $RootsPath -FoldersPath $FoldersPath -InventoryPath $ManifestPath -BundleRoot $bundleDir
    foreach ($p in $verify.Problems) { $problems.Add("final check: $p") }
    if ((Get-Sha256 $mapPath) -ne $mapSha256) { $problems.Add('final check: the map changed while it was being checked') }
    if ($problems.Count -gt 0) { return }

    # The ZIP must hold exactly what was checked: the map as checked, and each
    # file with the size and hash the map gives it.
    $expected = @{ $mapFileName = [pscustomobject]@{ Sha256 = $mapSha256; Bytes = (Get-Item -LiteralPath $mapPath -Force).Length } }
    foreach ($e in $entries) { $expected[$e.folder + '/' + $e.file] = [pscustomobject]@{ Sha256 = $e.sha256; Bytes = $e.bytes } }
    $members = @($mapFileName) + @($collected | ForEach-Object { $_.Folder + '/' + $_.BundleFile })
    Write-BundleZip $runFolder $bundleDir $members $expected
    if ($problems.Count -gt 0) { return }

    # Last: nothing in the run folder, the ZIP included, is reachable by anyone else (C-04, C-05).
    foreach ($item in Get-ChildItem -LiteralPath $runFolder -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $problems.Add("permissions: '$($item.Name)' is a junction or symbolic link"); continue }
        $why = Get-ProtectionProblem $item.FullName
        if ($why) { $problems.Add("permissions: '$($item.FullName.Substring($runFolder.Length + 1))': $why") }
    }
    if ($problems.Count -gt 0) { return }

    # The seed goes to the repo only when everything else has passed.
    if ($owui.Seed) { Publish-Seed $runFolder }
}

# ---------- Run ----------

try {
    $null = Invoke-Collection
}
catch {
    # Exception text can echo what it was handling, so keep only the type and line.
    $problems.Add("stopped: $($_.Exception.GetType().Name) at line $($_.InvocationInfo.ScriptLineNumber)")
}
finally {
    if ($problems.Count -gt 0 -and $run.RunFolder -and -not $KeepOnFailure) {
        # Only the folder this run created, and only inside the staging root.
        $inside = & $testPath -Path $run.RunFolder -Root ([IO.Path]::GetFullPath($StagingRoot)) -Detailed
        if ($inside.IsValid -and $inside.FullPath -eq $run.RunFolder) {
            try { Remove-Item -LiteralPath $run.RunFolder -Recurse -Force -ErrorAction Stop } catch { $null = $_ }
        }
        if (Test-Path -LiteralPath $run.RunFolder) {
            # Kept in the result so the summary names it.
            $problems.Add('cleanup: the run folder could not be fully removed and may hold plaintext secrets; delete it by hand')
        }
        else {
            $run.RunFolder = $null
            $run.ZipPath = $null
            $run.ZipSha256 = $null
        }
    }
}

$result = Get-RunResult
if ($PassThru) { return $result }

Write-Output ("Collect-StackSecrets $collectorVersion  [" + $result.Mode.ToUpperInvariant() + ']')
# Columns as wide as their longest entry, so long ids and locations stay aligned.
$idWidth = (@($result.Rows | ForEach-Object { $_.Id.Length }) + 2 | Measure-Object -Maximum).Maximum
$locationWidth = (@($result.Rows | ForEach-Object { $_.Location.Length }) + 8 | Measure-Object -Maximum).Maximum
foreach ($r in $result.Rows) {
    Write-Output ('  {0}  {1} {2} {3}' -f $r.Folder, $r.Id.PadRight($idWidth), $r.Location.PadRight($locationWidth), $r.Status)
}
$tally = ($result.Rows | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
Write-Output "  Rows: $(@($result.Rows).Count) ($tally)"
Write-Output "  Staging drive BitLocker: $($result.BitLocker)"
if ($result.SeedSummary) { Write-Output "  OWUI $($result.SeedSummary)" }
if ($result.SeedOut) { Write-Output "  Seed:     $($result.SeedFiles) file(s) written to $($result.SeedOut)" }
foreach ($w in $result.Warnings) { Write-Output "  WARN     $w" }
foreach ($p in $result.Problems) { Write-Output "  PROBLEM  $p" }

if (-not $result.IsValid) {
    Write-Output 'Result: NOT COMPLETE. Nothing may be uploaded or deleted. Fix the problems above and run again.'
    if ($result.RunFolder) { Write-Output "The failed run folder is still there: $($result.RunFolder). It holds plaintext secrets: delete it once inspected." }
    exit 1
}
if (-not $Execute) {
    Write-Output 'Result: plan only. Nothing was copied, and ssh, scp and docker were not called. Run again with -Execute to collect.'
    return
}
Write-Output "Result: complete. $(@($result.Rows | Where-Object Status -EQ 'collected').Count) file(s) collected."
Write-Output "  ZIP:      $($result.ZipPath)"
Write-Output "  SHA-256:  $($result.ZipSha256)"
Write-Output 'Next:'
Write-Output '  1. Upload the ZIP to its Bitwarden item and put the SHA-256 above in the item''s notes.'
Write-Output '  2. Download it back into this run folder and check the SHA-256 matches (round trip).'
Write-Output '  3. Only then delete the run folder. It holds plaintext secrets.'
if ($result.SeedOut) { Write-Output '  4. Commit the seed folder. It holds no secrets; CI scans it again.' }
