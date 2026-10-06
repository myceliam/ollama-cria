<#
.SYNOPSIS
    Checks a restore map (00-RESTORE-MAP.json), and optionally the bundle it
    describes, before anything is restored from it.

.DESCRIPTION
    The collector writes the map into the secrets bundle and the restorer reads
    it (review finding C-08: one versioned format for both ends). This script is
    the shared check both of them call. It looks for:

      1. Schema: the map matches manifests/schemas/restore-map.schema.json and
         the roots file matches manifests/schemas/recovery-roots.schema.json.
      2. Roots: every root has the field its kind needs (path, volume or
         consumer), and every path root is an absolute path for its host
         (E:\x on the PC, /x on the VPS; %VAR% at the start is allowed on the
         PC), below a drive or filesystem root, with no '.', '..' or empty
         segment. Whether a root is a link is checked on its own host by the
         restorer, which runs Test-RecoveryPath.ps1 against the real folder.
         No two roots on one host may name the same or nested folders (or the
         same volume), so two destinations can never be one file under two
         names. Roots that start with %VAR% are compared as written; the
         restorer compares them again once the variables are expanded.
      3. Rows: every destination names a known root; each bundle folder goes to
         the kind of root it belongs to (folder 05 to the VPS, 07 to a Docker
         volume, 03 to the OWUI seed importer, the rest to a PC folder); mode,
         owner and group only appear on VPS and Docker volume rows (both are
         Linux filesystems).
      4. Paths: every file name and destination passes Test-RecoveryPath.ps1
         as a relative path (C-49) and names a file, not a folder (no trailing
         separator).
      5. Uniqueness: ids, destinations and bundle files are each unique,
         ignoring case.
      6. Completeness: the map's inventory block lists every required row of
         the inventory it was collected from. Each of those ids has a required
         entry, and no other entry is required. With -InventoryPath, the
         block's SHA-256 must match that file, and every required row in the
         file must be in the map; an optional row that is absent is a warning.
      7. With -BundleRoot: the bundle's own 00-RESTORE-MAP.json exists and is
         byte for byte the map that was checked, so a restorer reading it
         reads exactly what passed; every required row's file is in the
         bundle, inside it, with the right byte length and SHA-256; and the
         bundle holds no file the map does not list and no link.

    A missing optional file is a warning, not a problem: the restorer skips
    that row. Problems and warnings name rows by id and file name only. They
    never include file contents or hashes.

.PARAMETER MapPath
    The restore map to check.

.PARAMETER RootsPath
    The logical roots file. Defaults to manifests/recovery-roots.json in this repo.

.PARAMETER InventoryPath
    The secret inventory (manifests/secrets.json) the restorer trusts. When
    given, the map must have been collected from exactly this file.

.PARAMETER BundleRoot
    The unpacked bundle folder (the one holding 00-RESTORE-MAP.json and the
    numbered folders). When given, the files themselves are checked too.

.OUTPUTS
    [pscustomobject] with IsValid, EntryCount, Problems and Warnings. IsValid
    is true when there are no problems; warnings do not change it.

.EXAMPLE
    ./tools/Test-RestoreMap.ps1 -MapPath E:\recovery-secrets\bundle\00-RESTORE-MAP.json -BundleRoot E:\recovery-secrets\bundle
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [string]$MapPath,

    [string]$RootsPath = (Join-Path $PSScriptRoot '../manifests/recovery-roots.json'),

    [string]$InventoryPath,

    [string]$BundleRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$mapSchema = Join-Path $repo 'manifests/schemas/restore-map.schema.json'
$rootsSchema = Join-Path $repo 'manifests/schemas/recovery-roots.schema.json'
$testPath = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
$mapFileName = '00-RESTORE-MAP.json'

$problems = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$entryCount = 0

function Get-MapResult {
    [pscustomobject]@{
        IsValid    = ($problems.Count -eq 0)
        EntryCount = $entryCount
        Problems   = $problems.ToArray()
        Warnings   = $warnings.ToArray()
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

function Get-RootPathProblem([string]$Path, [string]$OnHost) {
    # Syntax only, for the host the root lives on, so this works on either machine.
    if ($Path -match '[\x00-\x1F<>"|?*]') { return 'control or wildcard character' }
    if ($OnHost -eq 'vps') {
        if ($Path -notmatch '^/(?!/)') { return 'not an absolute VPS path (/...)' }
        $body = $Path.Substring(1)
        if ($body.Contains('\')) { return 'backslash in a VPS path' }
    }
    else {
        if ($Path -match '^[\\/]{2}') { return 'UNC or device path' }
        if ($Path -match '^[A-Za-z]:[\\/]') { $body = $Path.Substring(3) }
        elseif ($Path -match '^%[A-Za-z_][A-Za-z0-9_]*%[\\/]') { $body = $Path.Substring($Path.IndexOfAny([char[]]@('\', '/')) + 1) }
        else { return 'not an absolute PC path (E:\... or %VAR%\...)' }
        if ($body.Contains(':')) { return 'colon after the drive' }
    }
    $body = $body -replace '[\\/]$', ''
    if ($body -eq '') { return 'a whole drive or filesystem root, which is too broad' }
    foreach ($s in $body -split '[\\/]') {
        if ($s -eq '') { return 'empty segment (doubled separator)' }
        if ($s -eq '.' -or $s -eq '..') { return "'$s' segment" }
    }
    return $null
}

function Get-RootKey([string]$Path, [string]$OnHost) {
    # One spelling per folder: / for \, no trailing separator, and lower case
    # on the PC, where paths ignore case.
    $key = ($Path -replace '\\', '/') -replace '/+$', ''
    if ($OnHost -ne 'vps') { $key = $key.ToLowerInvariant() }
    return $key
}

function Get-UniqueKey([string]$Text) {
    # One spelling per place: / for \, no trailing separator, lower case.
    return (($Text -replace '\\', '/') -replace '/+$', '').ToLowerInvariant()
}

# Which kind of root each bundle folder may restore to (docs/RESTORE.md Stage 4b).
$folderRule = @{
    '01' = @{ Kind = 'path'; Host = 'pc' }
    '02' = @{ Kind = 'path'; Host = 'pc' }
    '03' = @{ Kind = 'consumed'; Host = 'pc' }
    '04' = @{ Kind = 'path'; Host = 'pc' }
    '05' = @{ Kind = 'path'; Host = 'vps' }
    '07' = @{ Kind = 'volume'; Host = 'pc' }
}

# ---------- 1. Schemas ----------
$mapOk = Test-AgainstSchema $MapPath $mapSchema 'map'
$rootsOk = Test-AgainstSchema $RootsPath $rootsSchema 'roots file'
if (-not ($mapOk -and $rootsOk)) { return (Get-MapResult) }

$map = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json
$roots = (Get-Content -LiteralPath $RootsPath -Raw | ConvertFrom-Json).roots
$entryCount = @($map.entries).Count

# ---------- 2. Roots ----------
$rootByName = @{}
foreach ($r in $roots.PSObject.Properties) {
    $rootByName[$r.Name] = $r.Value
    $need = @{ path = 'path'; volume = 'volume'; consumed = 'consumer' }[$r.Value.kind]
    if (-not (Get-OptionalProperty $r.Value $need)) {
        $problems.Add("root '$($r.Name)': kind '$($r.Value.kind)' needs '$need'")
    }
    foreach ($other in @('path', 'volume', 'consumer') | Where-Object { $_ -ne $need }) {
        if ($null -ne (Get-OptionalProperty $r.Value $other)) {
            $problems.Add("root '$($r.Name)': kind '$($r.Value.kind)' must not have '$other'")
        }
    }
    if ($r.Value.kind -ne 'path' -and $r.Value.host -ne 'pc') {
        $problems.Add("root '$($r.Name)': kind '$($r.Value.kind)' is PC-only")
    }
    $rootPath = Get-OptionalProperty $r.Value 'path'
    if ($r.Value.kind -eq 'path' -and $rootPath) {
        $why = Get-RootPathProblem $rootPath $r.Value.host
        if ($why) { $problems.Add("root '$($r.Name)': path refused ($why)") }
    }
}

# Two names for one folder (or one inside the other) would let two rows that
# look unique write the same file.
$rootNames = @($rootByName.Keys | Sort-Object)
for ($a = 0; $a -lt $rootNames.Count; $a++) {
    for ($b = $a + 1; $b -lt $rootNames.Count; $b++) {
        $ra = $rootByName[$rootNames[$a]]; $rb = $rootByName[$rootNames[$b]]
        if ($ra.kind -ne $rb.kind -or $ra.host -ne $rb.host -or $ra.kind -eq 'consumed') { continue }
        if ($ra.kind -eq 'volume') {
            $va = Get-OptionalProperty $ra 'volume'; $vb = Get-OptionalProperty $rb 'volume'
            if ($va -and $va -eq $vb) { $problems.Add("roots '$($rootNames[$a])' and '$($rootNames[$b])' name the same volume") }
            continue
        }
        $pa = Get-OptionalProperty $ra 'path'; $pb = Get-OptionalProperty $rb 'path'
        if (-not $pa -or -not $pb) { continue }   # already reported above
        $ka = Get-RootKey $pa $ra.host; $kb = Get-RootKey $pb $rb.host
        if ($ka -eq $kb -or $ka.StartsWith($kb + '/') -or $kb.StartsWith($ka + '/')) {
            $problems.Add("roots '$($rootNames[$a])' and '$($rootNames[$b])' name the same or nested folders")
        }
    }
}

# ---------- 3 to 5. Rows ----------
$ids = @{}
$destinations = @{}
$files = @{}
$syntaxBase = Join-Path ([IO.Path]::GetTempPath()) 'cria-syntax'

$n = 0
foreach ($e in $map.entries) {
    $n++
    $label = "entry #$n ('$($e.id)')"

    $idKey = $e.id.ToLowerInvariant()
    if ($ids.ContainsKey($idKey)) { $problems.Add("${label}: id already used by entry #$($ids[$idKey])") } else { $ids[$idKey] = $n }

    # File inside its bundle folder
    $fileCheck = & $testPath -Path $e.file -Root (Join-Path $syntaxBase "bundle-$($e.folder)") -Relative -SyntaxOnly -Detailed
    if (-not $fileCheck.IsValid) { $problems.Add("${label}: file name refused ($($fileCheck.Reason))") }
    elseif ($e.file -match '[\\/]$') { $problems.Add("${label}: file name refused (ends in a separator, so it names a folder)") }
    $fileKey = Get-UniqueKey ($e.folder + '/' + $e.file)
    if ($files.ContainsKey($fileKey)) { $problems.Add("${label}: same bundle file as entry #$($files[$fileKey])") } else { $files[$fileKey] = $n }

    # Destination: '<root>:<relative>'
    $rootName, $relative = $e.destination -split ':', 2
    $root = $rootByName[$rootName]
    if (-not $root) {
        $problems.Add("${label}: unknown root '$rootName'")
    }
    else {
        $rule = $folderRule[$e.folder]
        if ($root.kind -ne $rule.Kind -or $root.host -ne $rule.Host) {
            $problems.Add("${label}: folder $($e.folder) must go to a $($rule.Host) '$($rule.Kind)' root, not '$rootName'")
        }
        $hasLinuxBits = @('mode', 'owner', 'group' | Where-Object { $null -ne (Get-OptionalProperty $e $_) }).Count -gt 0
        if ($hasLinuxBits -and $root.host -ne 'vps' -and $root.kind -ne 'volume') {
            $problems.Add("${label}: mode, owner and group are only for VPS and volume destinations")
        }
    }

    # Syntax only: the real root may be on another host or inside a Docker
    # volume. The restorer checks against the real folder before writing.
    $destCheck = & $testPath -Path $relative -Root (Join-Path $syntaxBase $rootName) -Relative -SyntaxOnly -Detailed
    if (-not $destCheck.IsValid) { $problems.Add("${label}: destination refused ($($destCheck.Reason))") }
    elseif ($relative -match '[\\/]$') { $problems.Add("${label}: destination refused (ends in a separator, so it names a folder)") }
    $destKey = $rootName.ToLowerInvariant() + ':' + (Get-UniqueKey $relative)
    if ($destinations.ContainsKey($destKey)) { $problems.Add("${label}: same destination as entry #$($destinations[$destKey])") } else { $destinations[$destKey] = $n }
}

# ---------- 6. Completeness ----------
$listedRequired = @{}
foreach ($id in @($map.inventory.required)) { $listedRequired[$id.ToLowerInvariant()] = $true }
$entryById = @{}
foreach ($e in $map.entries) { $entryById[$e.id.ToLowerInvariant()] = $e }
foreach ($id in @($map.inventory.required)) {
    $e = $entryById[$id.ToLowerInvariant()]
    if (-not $e) { $problems.Add("inventory: required row '$id' has no entry in the map") }
    elseif (-not $e.required) { $problems.Add("inventory: required row '$id' is marked optional in the map") }
}
foreach ($e in $map.entries) {
    if ($e.required -and -not $listedRequired.ContainsKey($e.id.ToLowerInvariant())) {
        $problems.Add("entry '$($e.id)': required, but not a required row of the inventory")
    }
}
if ($InventoryPath) {
    if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
        $problems.Add('inventory: file not found')
    }
    else {
        $inventoryHash = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($inventoryHash -ne $map.inventory.sha256) { $problems.Add('inventory: the map was collected from a different inventory') }
        foreach ($row in @((Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json).rows)) {
            if ($entryById.ContainsKey($row.id.ToLowerInvariant())) { continue }
            if ($row.required) {
                # Already reported above when the map's own list names it.
                if (-not $listedRequired.ContainsKey($row.id.ToLowerInvariant())) { $problems.Add("inventory: required row '$($row.id)' has no entry in the map") }
            }
            else { $warnings.Add("inventory: optional row '$($row.id)' is not in the map") }
        }
    }
}

# ---------- 7. The bundle itself ----------
if ($BundleRoot) {
    if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) {
        $problems.Add('bundle: folder not found')
        return (Get-MapResult)
    }
    $bundleFull = [IO.Path]::GetFullPath($BundleRoot)

    # The restorer reads the map inside the bundle, so it must be the one checked here.
    $bundledMap = & $testPath -Path $mapFileName -Root $bundleFull -Relative -Detailed
    if (-not $bundledMap.IsValid) {
        $problems.Add("bundle: $mapFileName refused ($($bundledMap.Reason))")
    }
    elseif (-not (Test-Path -LiteralPath $bundledMap.FullPath -PathType Leaf)) {
        $problems.Add("bundle: $mapFileName is missing")
    }
    else {
        $checkedHash = (Get-FileHash -LiteralPath $MapPath -Algorithm SHA256).Hash
        $bundledHash = (Get-FileHash -LiteralPath $bundledMap.FullPath -Algorithm SHA256).Hash
        if ($checkedHash -ne $bundledHash) { $problems.Add("bundle: $mapFileName differs from the map that was checked") }
    }

    $n = 0
    foreach ($e in $map.entries) {
        $n++
        $label = "entry #$n ('$($e.id)')"
        $member = $e.folder + '/' + ($e.file -replace '\\', '/')
        $check = & $testPath -Path $member -Root $bundleFull -Relative -Detailed
        if (-not $check.IsValid) { $problems.Add("${label}: bundle path refused ($($check.Reason))"); continue }
        if (-not (Test-Path -LiteralPath $check.FullPath -PathType Leaf)) {
            if ($e.required) { $problems.Add("${label}: missing from the bundle (required)") }
            else { $warnings.Add("${label}: missing from the bundle (optional, the restorer skips it)") }
            continue
        }
        $item = Get-Item -LiteralPath $check.FullPath -Force
        if ($item.Length -ne $e.bytes) { $problems.Add("${label}: byte length differs from the map"); continue }
        $hash = (Get-FileHash -LiteralPath $check.FullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $e.sha256) { $problems.Add("${label}: SHA-256 differs from the map") }
    }

    # Anything in the bundle that the map does not list is a stray file, possibly a stray secret.
    foreach ($item in Get-ChildItem -LiteralPath $bundleFull -Recurse -Force) {
        $rel = $item.FullName.Substring($bundleFull.TrimEnd([char[]]@('\', '/')).Length).TrimStart([char[]]@('\', '/')) -replace '\\', '/'
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $problems.Add("bundle: '$rel' is a junction or symbolic link")
            continue
        }
        if ($item.PSIsContainer -or $rel -eq $mapFileName) { continue }
        if (-not $files.ContainsKey($rel.ToLowerInvariant())) {
            $problems.Add("bundle: '$rel' is not listed in the map")
        }
    }
}

return (Get-MapResult)
