<#
.SYNOPSIS
    Checks that a path stays inside an allowed root before anything is written,
    copied, extracted or deleted.

.DESCRIPTION
    The one path check every ollama-cria stage uses (docs/RESTORE.md, Controller,
    "Paths"; review findings C-44 and C-49). A path passes only when all of these
    hold:

      - It is not empty and has no control characters or < > " | ? *
        (so a wildcard can never reach Remove-Item).
      - No segment is '.' or '..', and no segment is empty ('a\\b').
      - No segment ends in a dot or a space. Windows silently strips them, so
        'notes.' and 'notes' would be two names for one file.
      - No segment is a Windows device name (CON, PRN, AUX, NUL, COM1-9,
        LPT1-9, CONIN$, CONOUT$), with or without an extension.
      - No segment looks like an 8.3 short name ('~' then a digit), which can
        be a second name for a long one.
      - No colon after the drive letter (alternate data streams).
      - With -Relative: the path is not rooted (no drive, no leading slash, no
        UNC, \\?\ or \\.\ prefix). Use it for archive members and restore-map
        destinations.
      - An absolute path must start with the root as written (after both
        separators are treated alike); only the part below the root gets the
        name checks above, so the root itself may contain names such as an
        8.3 'RUNNER~1' profile folder.
      - Once joined to the root and normalised, it is inside the root. The root
        itself only passes with -AllowRoot.
      - Unless -SyntaxOnly: the root and every existing folder or file between
        the root and the target is a real item, not a junction or symbolic link.
      - With several paths: no two resolve to the same place, ignoring case.

    The root must be fully qualified on the machine running the check (a
    drive and a separator on Windows, a leading / elsewhere), so it can never
    resolve against the current drive or folder. It must not be a drive or
    filesystem root, so a caller can never be pointed at the whole of E:\ or /.

    Both \ and / are treated as separators on every platform.

    Not covered (documented, not silently assumed):
      - Hard links to files, and per-directory NTFS case sensitivity.
        Remove-RecoveryPlaintext.ps1 adds its own "same object the controller
        created" check before deleting.
      - A race between this check and the caller's use of the path. A process
        that can write inside the root could swap a checked folder for a link
        after the check. PowerShell has no portable no-follow open, so the
        guard is where the roots live instead: callers only use roots that no
        other account can write to (the collector's run folder is owner-only),
        and they walk the finished output for links afterwards (the bundle
        walk in Test-RestoreMap.ps1). Anything able to win the race already
        runs as the owner and could read the secrets directly.

.PARAMETER Path
    One or more paths to check. Relative paths are resolved against -Root.

.PARAMETER Root
    The folder every path must stay inside.

.PARAMETER Relative
    Refuse rooted paths. Use for archive members and restore-map destinations.

.PARAMETER SyntaxOnly
    Skip the filesystem checks (links and junctions). Use when the target is on
    another host or inside a Docker volume, where this machine cannot see it.

.PARAMETER AllowRoot
    Accept a path that resolves to the root itself.

.PARAMETER Detailed
    Return one object per path (Path, FullPath, IsValid, Reason) instead of a
    single [bool].

.OUTPUTS
    [bool] by default: $true only if every path passes.
    With -Detailed: [pscustomobject] per path.

.EXAMPLE
    ./tools/Test-RecoveryPath.ps1 -Path 'secrets/ntfy-publisher' -Root 'E:\ai\ollama' -Relative

.EXAMPLE
    $bad = ./tools/Test-RecoveryPath.ps1 -Path $zipMembers -Root 'E:\recovery-secrets' -Relative -Detailed |
        Where-Object { -not $_.IsValid }
#>
[CmdletBinding()]
[OutputType([bool], [pscustomobject])]
param(
    [Parameter(Mandatory)]
    [AllowNull()]
    [AllowEmptyString()]
    [string[]]$Path,

    [Parameter(Mandatory)]
    [string]$Root,

    [switch]$Relative,
    [switch]$SyntaxOnly,
    [switch]$AllowRoot,
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sep = [IO.Path]::DirectorySeparatorChar
$onWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
# Windows paths ignore case; elsewhere a case difference is a different file.
$comparison = if ($onWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

$deviceName = '^(CON|PRN|AUX|NUL|COM[0-9\u00B9\u00B2\u00B3]|LPT[0-9\u00B9\u00B2\u00B3]|CONIN\$|CONOUT\$)(\..*)?$'
$badChars = '[\x00-\x1F<>"|?*]'

function Split-Segment([string]$Text) {
    # Treat \ and / alike, whatever the platform.
    , ($Text -split '[\\/]')
}

function Test-Rooted([string]$Text) {
    # Drive ('C:', 'C:\x', 'C:x'), leading separator ('\x', '/x'), UNC and device prefixes ('\\x', '//x').
    return ($Text -match '^[A-Za-z]:' -or $Text -match '^[\\/]')
}

function Get-SegmentProblem([string[]]$Segments) {
    foreach ($s in $Segments) {
        if ($s -eq '') { return 'empty segment (doubled separator)' }
        if ($s -eq '.' -or $s -eq '..') { return "'$s' segment" }
        if ($s -match '[. ]$') { return 'a segment ends in a dot or a space' }
        if ($s -match $deviceName) { return 'a segment is a Windows device name' }
        if ($s -match '~[0-9]') { return 'a segment looks like an 8.3 short name' }
    }
    return $null
}

function ConvertTo-NativePath([string]$Text) {
    return ($Text -replace '[\\/]', [string]$sep)
}

function Test-IsLink([string]$FullPath) {
    $item = Get-Item -LiteralPath $FullPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }      # does not exist
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# ---------- The root ----------
if ([string]::IsNullOrWhiteSpace($Root)) { throw 'Root is empty.' }
if ($Root -match $badChars) { throw 'Root contains a control or wildcard character.' }
if ($Root -match '^[\\/]{2}') { throw "Root must not be a UNC or device path: '$Root'." }
if ($Root -match '^([A-Za-z]:)?[\\/]+$') { throw "Root is a whole drive or filesystem root, which is too broad: '$Root'." }
# Fully qualified for this machine: 'C:\x' on Windows, '/x' elsewhere. '\x' on
# Windows or 'C:\x' on Linux would resolve against the current drive or folder.
$rootNative = ConvertTo-NativePath $Root
if (-not [IO.Path]::IsPathFullyQualified($rootNative)) { throw "Root must be an absolute path on this machine: '$Root'." }

$rootFull = [IO.Path]::GetFullPath($rootNative)
$rootTrimmed = $rootFull.TrimEnd([char[]]@('\', '/'))
if ($rootTrimmed -eq '' -or $rootTrimmed -match '^[A-Za-z]:$') {
    throw "Root is a whole drive or filesystem root, which is too broad: '$Root'."
}
$rootFull = $rootTrimmed

$rootIsLink = $false
if (-not $SyntaxOnly) {
    $rootIsLink = (Test-IsLink $rootFull) -eq $true
}

# ---------- Each path ----------
$results = [Collections.Generic.List[object]]::new()
$seen = @{}   # lower-cased full path -> index of the first path that used it

for ($i = 0; $i -lt $Path.Count; $i++) {
    $p = $Path[$i]
    $full = $null
    $reason = $null

    if ([string]::IsNullOrWhiteSpace($p)) {
        $reason = 'empty path'
    }
    elseif ($p -match $badChars) {
        $reason = 'control or wildcard character'
    }
    elseif ($rootIsLink) {
        $reason = 'the root is a junction or symbolic link'
    }

    if (-not $reason) {
        # $body is the part of the path below the root. Every check after this one
        # looks only at $body, so the root may contain names (such as a runner's
        # 8.3 'RUNNER~1' profile) that a path below it may not.
        $body = $p
        $isAbsolute = Test-Rooted $p
        if ($isAbsolute) {
            $native = ConvertTo-NativePath $p
            $prefix = $rootFull + $sep
            if ($Relative) {
                $reason = 'rooted path where a relative one is required'
            }
            elseif ($p -match '^[\\/]{2}') {
                $reason = 'UNC or device path'
            }
            elseif ($p -match '^[A-Za-z]:(?![\\/])') {
                $reason = 'drive-relative path (for example C:folder)'
            }
            elseif ($native.Equals($rootFull, $comparison) -or $native.Equals($prefix, $comparison)) {
                $body = ''
            }
            elseif ($native.StartsWith($prefix, $comparison)) {
                $body = $native.Substring($prefix.Length)
            }
            else {
                # Absolute paths must start with the root exactly as it normalises,
                # so the segment checks below see every name under the root.
                $reason = 'outside the root'
            }
        }
    }

    if (-not $reason -and $body.Contains(':')) {
        $reason = 'colon after the drive (alternate data stream)'
    }

    if (-not $reason) {
        # A single trailing separator is allowed (folder entries in archives end with '/').
        $trimmed = $body -replace '[\\/]$', ''
        if ($trimmed -eq '') {
            if (-not $AllowRoot -or $Relative) {
                $reason = if ($isAbsolute) { 'the path is the root itself' } else { 'path names no item' }
            }
        }
        else {
            $segments = Split-Segment $trimmed
            $reason = Get-SegmentProblem $segments
        }
    }

    if (-not $reason) {
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($rootFull, (ConvertTo-NativePath $trimmed))).TrimEnd([char[]]@('\', '/'))

        # Checked again after normalising, as a second line of defence.
        $inside = $full.StartsWith($rootFull + $sep, $comparison)
        $isRoot = $full.Equals($rootFull, $comparison)
        if ($isRoot -and -not $AllowRoot) { $reason = 'the path is the root itself' }
        elseif (-not $inside -and -not $isRoot) { $reason = 'outside the root' }
    }

    if (-not $reason -and -not $SyntaxOnly -and $full.Length -gt $rootFull.Length) {
        # Walk from the root to the target; stop at the first item that does not exist yet.
        $rest = $full.Substring($rootFull.Length).TrimStart([char[]]@('\', '/'))
        $current = $rootFull
        foreach ($s in ($rest -split '[\\/]')) {
            $current = [IO.Path]::Combine($current, $s)
            $isLink = Test-IsLink $current
            if ($null -eq $isLink) { break }
            if ($isLink) { $reason = 'a junction or symbolic link on the way'; break }
        }
    }

    if (-not $reason) {
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $reason = "same place as path #$($seen[$key] + 1), ignoring case"
        }
        else {
            $seen[$key] = $i
        }
    }

    if ($reason) { Write-Verbose "Refused path #$($i + 1): $reason" }

    $results.Add([pscustomobject]@{
            Path     = $p
            FullPath = $full
            IsValid  = (-not $reason)
            Reason   = $reason
        })
}

if ($Detailed) {
    return $results.ToArray()
}
return (@($results | Where-Object { -not $_.IsValid }).Count -eq 0 -and $results.Count -gt 0)
