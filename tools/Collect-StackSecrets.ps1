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
      row exists, runs the folder audits and reads the staging drive's
      BitLocker state. It never calls ssh, scp or docker (C-09).

      -Execute. Collects every row into a new folder under -StagingRoot,
      writes 00-RESTORE-MAP.json, re-checks the whole bundle with
      Test-RestoreMap.ps1, checks every item's permissions, then writes the
      ZIP inside the same protected folder and prints its SHA-256 (C-05,
      C-08).

    Rules it keeps:

      - Protected from birth. The run folder is created with an ACL that grants
        only the current user, inheritance off, and is read back before
        anything is copied. On Linux and macOS it is created with mode 0700.
        Anything else stops the run (C-04).
      - Fails closed. A missing required row, or any failed copy, hash, check
        or permission, stops the run with exit code 1, prints no next steps,
        and deletes the run folder this run created unless -KeepOnFailure is
        given (C-07).
      - Paths. Every source and bundle path goes through Test-RecoveryPath.ps1,
        so no junction, symbolic link or path outside its root is followed
        (C-49).
      - VPS rows. One ssh call runs a fixed script that reports, for each
        file, whether it is a regular file with no link on the way, its size
        and its SHA-256. scp then copies it, and the copy's hash must match.
        Host keys are never accepted automatically: BatchMode and
        StrictHostKeyChecking=yes (C-09, C-10).
      - Volume rows. A throw-away helper container with no network reads the
        Docker volume. SQLite files are copied with SQLite's backup API and
        integrity-checked, so there is no -wal file to lose (C-03).
      - Output. Ids, locations, statuses, counts and the ZIP's SHA-256. Never a
        secret value, and never native error text, which could echo one
        (C-50).

    Not collected here yet: folder 03, the OWUI secret values the seed refers
    to. Export-OwuiSeed.py writes those in Module 3.

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

.PARAMETER HelperImage
    The image for the throw-away volume reader. It must already be on this
    machine and must have python3; the collector never pulls it.

.PARAMETER AllowUnencryptedStaging
    Accept a staging drive whose BitLocker state is not 'On'. For tests only.

.PARAMETER KeepOnFailure
    Keep the run folder when the run fails, to inspect it. It holds plaintext
    secrets: delete it afterwards.

.PARAMETER PassThru
    Return the result object instead of printing a summary and setting the
    exit code.

.OUTPUTS
    With -PassThru: [pscustomobject] with Mode, IsValid, Rows, Problems,
    Warnings, BitLocker, RunFolder, ZipPath and ZipSha256.

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

    [switch]$AllowUnencryptedStaging,

    [switch]$KeepOnFailure,

    [switch]$PassThru,

    # Test seams: the programs used to reach the VPS and Docker.
    [Parameter(DontShow)]
    [string]$SshCommand = 'ssh',

    [Parameter(DontShow)]
    [string]$ScpCommand = 'scp',

    [Parameter(DontShow)]
    [string]$DockerCommand = 'docker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collectorVersion = '2.0.0'
$repo = Split-Path $PSScriptRoot -Parent
$testPath = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
$testMap = Join-Path $PSScriptRoot 'Test-RestoreMap.ps1'
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
    BitLocker = 'NotChecked'
    RunFolder = $null
    ZipPath   = $null
    ZipSha256 = $null
}

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

# Runs inside the helper container: argv is kind, then the path inside the
# volume. Exit codes: 0 copied, 2 missing, 3 a link on the way, 4 SQLite
# integrity check failed, 5 not a regular file. A SQLite copy is switched to
# rollback-journal mode, so it is one self-contained file.
$volumeCopy = @'
import os, shutil, sqlite3, sys
kind, rel = sys.argv[1], sys.argv[2]
src = os.path.normpath(os.path.join('/src', rel))
if not os.path.lexists(src):
    sys.exit(2)
if os.path.realpath(src) != src:
    sys.exit(3)
if not os.path.isfile(src):
    sys.exit(5)
os.makedirs('/tmp/cria', exist_ok=True)
dst = '/tmp/cria/item'
if kind == 'sqlite':
    source = sqlite3.connect('file:' + src + '?mode=ro', uri=True)
    copy = sqlite3.connect(dst)
    source.backup(copy)
    copy.execute('PRAGMA journal_mode=DELETE')
    ok = copy.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    copy.close()
    source.close()
    sys.exit(0 if ok else 4)
shutil.copyfile(src, dst)
'@

# ---------- Helpers ----------

function Get-RunResult {
    [pscustomobject]@{
        Mode      = $(if ($Execute) { 'Execute' } else { 'Plan' })
        IsValid   = ($problems.Count -eq 0)
        Rows      = $rowResults.ToArray()
        Problems  = $problems.ToArray()
        Warnings  = $warnings.ToArray()
        BitLocker = $run.BitLocker
        RunFolder = $run.RunFolder
        ZipPath   = $run.ZipPath
        ZipSha256 = $run.ZipSha256
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
    $mode = (Get-Item -LiteralPath $Path -Force).UnixFileMode
    $others = [IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
    if ($mode -band $others) { return 'group or others have access' }
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
        if ($root.kind -eq 'consumed') {
            $problems.Add("${label}: '$rootName' rows are written by Export-OwuiSeed.py, not this collector")
            continue
        }
        if ($m.kind -eq 'sqlite' -and $root.kind -ne 'volume') { $problems.Add("${label}: kind 'sqlite' is only for Docker volume roots") }
        if (($null -ne $mode -or $null -ne $owner) -and $root.host -ne 'vps') { $problems.Add("${label}: mode and owner are only for VPS rows") }

        $source = if ($root.kind -eq 'volume') { 'volume' } else { $root.host }
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
        else {
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

    if ($problems.Count -gt 0) { return $null }
    return [pscustomobject]@{ Rows = $rows.ToArray(); Audits = $audits; Roots = $roots; Locations = $locations }
}

function Invoke-Audit($Manifest) {
    # Every file in an audited folder must have a row. Names only are reported.
    foreach ($a in $Manifest.Audits | Where-Object { $null -ne $_ }) {
        $rootName, $relative = $a.location -split ':', 2
        $rootPath = [Environment]::ExpandEnvironmentVariables($Manifest.Roots[$rootName].path)
        try {
            if ($rootPath.Contains('%')) { throw 'unset variable' }
            $check = & $testPath -Path $relative -Root $rootPath -Relative -Detailed
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
            $logical = $rootName + ':' + (($relative -replace '\\', '/').TrimEnd('/') + '/' + $below)
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

function Copy-VolumeRow($Row, [string]$Destination) {
    $name = 'cria-collect-' + [guid]::NewGuid().ToString('n').Substring(0, 12)
    $mount = if ($Row.Kind -eq 'sqlite') { "$($Row.Volume):/src" } else { "$($Row.Volume):/src:ro" }
    $program = "import base64; exec(base64.b64decode('" + (ConvertTo-Base64 $volumeCopy) + "').decode())"
    & $DockerCommand create --name $name --network none --pull never -v $mount $HelperImage python3 -c $program $Row.Kind ($Row.Relative -replace '\\', '/') 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return "failed (docker create exit $LASTEXITCODE)" }
    try {
        & $DockerCommand start $name 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return "failed (docker start exit $LASTEXITCODE)" }
        $exit = (& $DockerCommand wait $name 2>$null) -as [int]
        switch ($exit) {
            0 { }
            2 { return 'missing' }
            3 { return 'refused (a symbolic link on the way)' }
            4 { return 'failed (SQLite integrity check)' }
            5 { return 'refused (not a regular file)' }
            default { return "failed (helper exit $exit)" }
        }
        & $DockerCommand cp "${name}:/tmp/cria/item" $Destination 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return "failed (docker cp exit $LASTEXITCODE)" }
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or (Test-IsLink $Destination)) { return 'failed (docker cp wrote no regular file)' }
        return 'collected'
    }
    finally {
        & $DockerCommand rm -f $name 2>$null | Out-Null
    }
}

function Test-DockerReady($Rows) {
    # Before the run folder exists: the helper image is here and each volume exists.
    if (-not @($Rows | Where-Object Source -EQ 'volume')) { return }
    & $DockerCommand image inspect $HelperImage 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $problems.Add("helper image '$HelperImage' is not on this machine; pull it first (docker pull $HelperImage)")
        return
    }
    foreach ($r in $Rows | Where-Object Source -EQ 'volume') {
        & $DockerCommand volume inspect $r.Volume 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Add-MissingRow $r; $r | Add-Member -NotePropertyName Skip -NotePropertyValue $true -Force }
    }
}

function Initialize-RunFolder {
    # Creates <StagingRoot>/stack-secrets-<UTC time>, protected, and returns it.
    if (-not [IO.Path]::IsPathFullyQualified($StagingRoot) -or $StagingRoot -match '^[\\/]{2}') {
        $problems.Add('staging: -StagingRoot must be an absolute local path')
        return $null
    }
    $rootFull = [IO.Path]::GetFullPath($StagingRoot).TrimEnd([char[]]@('\', '/'))
    if ($onWindows -and [IO.DriveInfo]::new([IO.Path]::GetPathRoot($rootFull)).DriveType -ne 'Fixed') {
        $problems.Add('staging: -StagingRoot must be on a local fixed drive')
        return $null
    }
    if (Test-Path -LiteralPath $rootFull) {
        if (Test-IsLink $rootFull) { $problems.Add('staging: -StagingRoot is a junction or symbolic link'); return $null }
        if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { $problems.Add('staging: -StagingRoot is not a folder'); return $null }
    }
    else {
        Initialize-ProtectedFolder $rootFull
    }

    $name = 'stack-secrets-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $check = & $testPath -Path $name -Root $rootFull -Relative -Detailed
    if (-not $check.IsValid) { $problems.Add("staging: run folder refused ($($check.Reason))"); return $null }
    if (Test-Path -LiteralPath $check.FullPath) { $problems.Add('staging: the run folder already exists'); return $null }

    Initialize-ProtectedFolder $check.FullPath
    $run.RunFolder = $check.FullPath
    $why = Get-ProtectionProblem $check.FullPath -IsRunFolder
    if ($why) { $problems.Add("staging: the run folder is not protected ($why)"); return $null }
    if (@(Get-ChildItem -LiteralPath $check.FullPath -Force).Count -ne 0) { $problems.Add('staging: the new run folder is not empty'); return $null }
    return $check.FullPath
}

function Write-BundleZip([string]$RunFolder, [string]$BundleDir, [string[]]$Members) {
    # Writes the ZIP inside the run folder with '/' entry names, then reopens it
    # and checks every entry against the bundle.
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

    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($zip.Entries | ForEach-Object FullName)
        if ($names.Count -ne $Members.Count) { $problems.Add('zip: entry count differs from the bundle'); return }
        foreach ($e in $zip.Entries) {
            if ($Members -cnotcontains $e.FullName) { $problems.Add("zip: unexpected entry '$($e.FullName)'"); continue }
            if ($e.Length -ne (Get-Item -LiteralPath (Join-Path $BundleDir $e.FullName) -Force).Length) { $problems.Add("zip: '$($e.FullName)' has the wrong length") }
        }
    }
    finally { $zip.Dispose() }
    $run.ZipPath = $zipPath
    $run.ZipSha256 = Get-Sha256 $zipPath
}

function Invoke-Collection {
    $manifest = Read-Manifest
    if (-not $manifest) { return }

    Invoke-Audit $manifest
    $run.BitLocker = Get-BitLockerState $StagingRoot
    if ($onWindows -and $run.BitLocker -ne 'On') {
        $note = "staging: BitLocker on the -StagingRoot drive is '$($run.BitLocker)'"
        if ($AllowUnencryptedStaging) { $warnings.Add("$note (allowed by -AllowUnencryptedStaging)") } else { $problems.Add($note) }
    }

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
    if ($problems.Count -gt 0) { return }

    $runFolder = Initialize-RunFolder
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
        if ($r.Mode) { $e.mode = $r.Mode }
        if ($r.Owner) { $e.owner = $r.Owner }
        $e
    }
    $map = [ordered]@{
        formatVersion = 1
        createdUtc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        collector     = [ordered]@{ name = 'Collect-StackSecrets.ps1'; version = $collectorVersion }
        entries       = @($entries)
    }
    $mapPath = Join-Path $bundleDir $mapFileName
    [IO.File]::WriteAllText($mapPath, ($map | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    Protect-BundleFile $mapPath

    # The same check the restorer runs, over the finished bundle (C-08).
    $verify = & $testMap -MapPath $mapPath -RootsPath $RootsPath -FoldersPath $FoldersPath -BundleRoot $bundleDir
    foreach ($p in $verify.Problems) { $problems.Add("final check: $p") }
    if ($problems.Count -gt 0) { return }

    $members = @($mapFileName) + @($collected | ForEach-Object { $_.Folder + '/' + $_.BundleFile })
    Write-BundleZip $runFolder $bundleDir $members
    if ($problems.Count -gt 0) { return }

    # Last: nothing in the run folder, the ZIP included, is reachable by anyone else (C-04, C-05).
    foreach ($item in Get-ChildItem -LiteralPath $runFolder -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $problems.Add("permissions: '$($item.Name)' is a junction or symbolic link"); continue }
        $why = Get-ProtectionProblem $item.FullName
        if ($why) { $problems.Add("permissions: '$($item.FullName.Substring($runFolder.Length + 1))': $why") }
    }
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
            Remove-Item -LiteralPath $run.RunFolder -Recurse -Force
            $run.RunFolder = $null
            $run.ZipPath = $null
            $run.ZipSha256 = $null
        }
        else {
            $problems.Add('cleanup: the run folder was not removed; delete it by hand')
        }
    }
}

$result = Get-RunResult
if ($PassThru) { return $result }

Write-Output ("Collect-StackSecrets $collectorVersion  [" + $result.Mode.ToUpperInvariant() + ']')
foreach ($r in $result.Rows) {
    Write-Output ('  {0}  {1,-22} {2,-44} {3}' -f $r.Folder, $r.Id, $r.Location, $r.Status)
}
Write-Output "  Staging drive BitLocker: $($result.BitLocker)"
foreach ($w in $result.Warnings) { Write-Output "  WARN     $w" }
foreach ($p in $result.Problems) { Write-Output "  PROBLEM  $p" }

if (-not $result.IsValid) {
    Write-Output 'Result: NOT COMPLETE. Nothing may be uploaded or deleted. Fix the problems above and run again.'
    if ($KeepOnFailure -and $result.RunFolder) { Write-Output "The failed run folder was kept: $($result.RunFolder). It holds plaintext secrets: delete it once inspected." }
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
