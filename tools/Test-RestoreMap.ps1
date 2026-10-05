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
         consumer).
      3. Rows: every destination names a known root; each bundle folder goes to
         the kind of root it belongs to (folder 05 to the VPS, 07 to a Docker
         volume, 03 to the OWUI seed importer, the rest to a PC folder); mode
         and owner only appear on VPS rows.
      4. Paths: every file name and destination passes Test-RecoveryPath.ps1
         as a relative path (C-49).
      5. Uniqueness: ids, destinations and bundle files are each unique,
         ignoring case.
      6. With -BundleRoot: every row's file is in the bundle, inside it, with
         the right byte length and SHA-256; and the bundle holds no file the
         map does not list.

    Problems name rows by id and file name only. They never include file
    contents or hashes.

.PARAMETER MapPath
    The restore map to check.

.PARAMETER RootsPath
    The logical roots file. Defaults to manifests/recovery-roots.json in this repo.

.PARAMETER BundleRoot
    The unpacked bundle folder (the one holding 00-RESTORE-MAP.json and the
    numbered folders). When given, the files themselves are checked too.

.OUTPUTS
    [pscustomobject] with IsValid, EntryCount and Problems.

.EXAMPLE
    ./tools/Test-RestoreMap.ps1 -MapPath E:\recovery-secrets\bundle\00-RESTORE-MAP.json -BundleRoot E:\recovery-secrets\bundle
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [string]$MapPath,

    [string]$RootsPath = (Join-Path $PSScriptRoot '../manifests/recovery-roots.json'),

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
$entryCount = 0

function Get-MapResult {
    [pscustomobject]@{
        IsValid    = ($problems.Count -eq 0)
        EntryCount = $entryCount
        Problems   = $problems.ToArray()
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
    $fileKey = ($e.folder + '/' + ($e.file -replace '\\', '/')).ToLowerInvariant()
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
        $hasLinuxBits = ($null -ne (Get-OptionalProperty $e 'mode')) -or ($null -ne (Get-OptionalProperty $e 'owner'))
        if ($hasLinuxBits -and $root.host -ne 'vps') {
            $problems.Add("${label}: mode and owner are only for VPS destinations")
        }
    }

    $destCheck = & $testPath -Path $relative -Root (Join-Path $syntaxBase $rootName) -Relative -SyntaxOnly -Detailed
    if (-not $destCheck.IsValid) { $problems.Add("${label}: destination refused ($($destCheck.Reason))") }
    $destKey = ($rootName + ':' + ($relative -replace '\\', '/')).ToLowerInvariant()
    if ($destinations.ContainsKey($destKey)) { $problems.Add("${label}: same destination as entry #$($destinations[$destKey])") } else { $destinations[$destKey] = $n }
}

# ---------- 6. The bundle itself ----------
if ($BundleRoot) {
    if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) {
        $problems.Add('bundle: folder not found')
        return (Get-MapResult)
    }
    $bundleFull = [IO.Path]::GetFullPath($BundleRoot)

    $n = 0
    foreach ($e in $map.entries) {
        $n++
        $label = "entry #$n ('$($e.id)')"
        $member = $e.folder + '/' + ($e.file -replace '\\', '/')
        $check = & $testPath -Path $member -Root $bundleFull -Relative -Detailed
        if (-not $check.IsValid) { $problems.Add("${label}: bundle path refused ($($check.Reason))"); continue }
        if (-not (Test-Path -LiteralPath $check.FullPath -PathType Leaf)) {
            $problems.Add("${label}: missing from the bundle" + $(if ($e.required) { ' (required)' } else { ' (optional)' }))
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
