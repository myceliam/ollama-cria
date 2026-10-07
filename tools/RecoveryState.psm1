<#
.SYNOPSIS
    The controller's state file, its lock, the record of what it created, and
    the shape of a stage result (docs/RESTORE.md, The controller).

.DESCRIPTION
    Used by Invoke-StackRecovery.ps1, the stage scripts under windows/stages
    and tools/Remove-RecoveryPlaintext.ps1.

    state.json, in the state root (E:\recovery-state), holds:

      formatVersion   1
      release         the commit (and tag) Stage 1 checked, and the SHA-256 of
                      every manifest then
      stages          per stage: status, attempts, start and end times, the
                      -Accept answers given, the stage's own data (paths,
                      hashes, counts) and the latest evidence file
      owned           every file and folder the controller created: stage,
                      kind, path, the root it was checked against, its
                      identity when created, and two flags. retry 'wipe' items
                      are removed when their stage was interrupted and runs
                      again; 'keep' items are re-checked instead. plaintext
                      items hold or contain secrets and are removed by
                      tools/Remove-RecoveryPlaintext.ps1 in Stage 11. adopted
                      items were not created by the controller but handed to
                      it on purpose (the bundle ZIP, a download token).

    It never holds a secret. Callers store names, paths, hashes, counts and
    statuses only, and Test-EvidenceSecretFree checks the evidence anyway.

    Ownership is proved by identity, never by path alone (C-45): an item is
    removed only if it still is the object recorded when it was created. On
    Windows the identity is the volume serial number and the file ID (NTFS
    "tunnelling" can hand a new file an old creation time, but never an old
    file ID); on Linux it is the device and inode. A link or junction never
    matches.

    Exported functions:

      Read-RecoveryState      the state, or a new one when there is no file
      Save-RecoveryState      writes it through a temporary file, then
                              replaces the old one in a single move
      Enter-RecoveryLock      one controller at a time; a lock left by a
                              process that is gone is taken over
      Exit-RecoveryLock
      Get-ItemIdentity        the identity of a file or folder, 'link' for a
                              link or junction, $null when it is missing
      Add-OwnedItem           records an item right after the controller
                              created it
      Set-OwnedItemRetry      'wipe' -> 'keep' once a step has checked it
      Get-OwnedItem           owned records, by stage, path or flag
      Test-OwnedItem          is this path an item the controller created, and
                              still the same object
      Remove-OwnedItem        removes one owned item if it is still the same
                              object, never following a link
      Clear-StageOwned        removes a stage's 'wipe' items, deepest first
      Get-OwnershipCallback   the Own, Keep, IsOwned and RemoveOwned script
                              blocks a stage gets in its context
      New-StageResult         the object every stage mode returns
      Add-StageCheck          adds a checkpoint row to it
      Add-StageAsk            adds something only a person can do
      Test-EvidenceSecretFree checks evidence files for any value from the
                              unpacked bundle; returns file names only
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OnWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
$script:PathCheck = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
$script:Comparison = if ($script:OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

if ($script:OnWindows -and -not ('Cria.FileIdentity' -as [type])) {
    # GetFileInformationByHandle: the volume serial number and file ID of a
    # file or folder, opened without following a link.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Cria {
    public static class FileIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct Info {
            public uint Attributes;
            public uint CreatedLow, CreatedHigh, AccessedLow, AccessedHigh, WrittenLow, WrittenHigh;
            public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
        public static string Get(string path) {
            // FILE_READ_ATTRIBUTES; share read, write and delete; OPEN_EXISTING;
            // FILE_FLAG_BACKUP_SEMANTICS (folders) | FILE_FLAG_OPEN_REPARSE_POINT.
            using (SafeFileHandle handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero)) {
                if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error(), path); }
                Info info;
                if (!GetFileInformationByHandle(handle, out info)) { throw new Win32Exception(Marshal.GetLastWin32Error(), path); }
                return info.VolumeSerial.ToString("x8") + ":" + info.IndexHigh.ToString("x8") + info.IndexLow.ToString("x8");
            }
        }
    }
}
'@
}

function Read-RecoveryState {
    <#
    .SYNOPSIS
        The state from -Path, or a new empty state when the file is missing.
        Throws when the file is not a state file this version can read.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ formatVersion = 1; release = @{}; stages = @{}; owned = [Collections.Generic.List[object]]::new() }
    }
    try { $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw [InvalidOperationException]::new("the state file $Path cannot be read; it is not JSON") }
    if ($state -isnot [hashtable] -or $state['formatVersion'] -ne 1) {
        throw [InvalidOperationException]::new("the state file $Path is not a format this controller reads")
    }
    foreach ($key in 'release', 'stages') { if ($state[$key] -isnot [hashtable]) { $state[$key] = @{} } }
    $owned = [Collections.Generic.List[object]]::new()
    foreach ($o in @($state['owned'])) { if ($o -is [hashtable]) { $owned.Add($o) } }
    $state['owned'] = $owned
    return $state
}

function Save-RecoveryState {
    <#
    .SYNOPSIS
        Writes the state to -Path: a temporary file next to it first, then one
        move that replaces the old file, so a crash leaves the old or the new
        state, never half of one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Save the controller state')) { return }
    $temp = "$Path.tmp"
    $json = $State | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($temp, $json + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $Path, $true)
}

function Enter-RecoveryLock {
    <#
    .SYNOPSIS
        Takes the controller lock in -StateRoot and returns its token. With
        -Token, checks that the lock is held under that token instead (an
        elevated child of the controller that holds it). A lock whose process
        is gone is taken over. Throws when another controller holds it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$Token
    )
    $lock = Join-Path $StateRoot 'state.lock'
    if ($Token) {
        $held = if (Test-Path -LiteralPath $lock -PathType Leaf) { (Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json -AsHashtable)['token'] } else { $null }
        if ($held -ne $Token) { throw [InvalidOperationException]::new('the controller lock is not held by the run that started this one') }
        return $Token
    }
    $new = [guid]::NewGuid().ToString('n')
    $body = [Text.Encoding]::UTF8.GetBytes((@{ token = $new; pid = $PID; started = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $stream = [IO.FileStream]::new($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($body, 0, $body.Length) } finally { $stream.Dispose() }
            return $new
        }
        catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { throw }
            $holder = $null
            try { $holder = (Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json -AsHashtable)['pid'] } catch { $holder = $null }
            if ($holder -and (Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue)) {
                throw [InvalidOperationException]::new("another controller run (process $holder) holds the lock in $StateRoot")
            }
            Write-Warning "A controller run that stopped without finishing left its lock; taking it over."
            Remove-Item -LiteralPath $lock -Force
        }
    }
    throw [InvalidOperationException]::new("the controller lock in $StateRoot could not be taken")
}

function Exit-RecoveryLock {
    <#
    .SYNOPSIS
        Releases the lock taken with Enter-RecoveryLock, if it still holds
        that token.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Token
    )
    $lock = Join-Path $StateRoot 'state.lock'
    if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return }
    $held = $null
    try { $held = (Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json -AsHashtable)['token'] } catch { $held = $null }
    if ($held -eq $Token -and $PSCmdlet.ShouldProcess($lock, 'Release the controller lock')) {
        Remove-Item -LiteralPath $lock -Force
    }
}

function Get-ItemIdentity {
    <#
    .SYNOPSIS
        The identity of the file or folder at -Path: 'fileid:<volume>:<id>'
        on Windows, 'inode:<device>:<inode>' elsewhere, 'link' for a link or
        junction, $null when nothing is there.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try { $attributes = [IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return $null }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) { return 'link' }
    if ($script:OnWindows) { return "fileid:$([Cria.FileIdentity]::Get([IO.Path]::GetFullPath($Path)))" }
    $stat = (Get-Item -LiteralPath $Path -Force).UnixStat
    return "inode:$($stat.DeviceId):$($stat.Inode)"
}

function Test-PathInRoot([string]$Path, [string]$Root) {
    # The shared path check (AGENTS.md): returns $null or the reason.
    $r = & $script:PathCheck -Path $Path -Root $Root -AllowRoot -Detailed
    if ($r.IsValid) { return $null }
    return $r.Reason
}

function Add-OwnedItem {
    <#
    .SYNOPSIS
        Records -Path as created by the controller in -Stage, right after it
        was created, and saves the state. The path must pass
        tools/Test-RecoveryPath.ps1 against -Root. Throws otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][int]$Stage,
        [Parameter(Mandatory)][ValidateSet('file', 'folder')][string]$Kind,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [ValidateSet('wipe', 'keep')][string]$Retry = 'wipe',
        [switch]$Plaintext,
        [switch]$Adopted
    )
    $reason = Test-PathInRoot $Path $Root
    if ($reason) { throw [InvalidOperationException]::new("cannot record $Path as owned: $reason") }
    $full = [IO.Path]::GetFullPath($Path)
    $identity = Get-ItemIdentity $full
    if ($null -eq $identity -or $identity -eq 'link') { throw [InvalidOperationException]::new("cannot record $Path as owned: it is missing or a link") }
    $isFolder = [IO.Directory]::Exists($full)
    if ($isFolder -ne ($Kind -eq 'folder')) { throw [InvalidOperationException]::new("cannot record $Path as owned: it is not a $Kind") }
    $existing = @($State['owned'] | Where-Object { $_['path'].Equals($full, $script:Comparison) })
    foreach ($e in $existing) { [void]$State['owned'].Remove($e) }
    $State['owned'].Add(@{
            stage     = $Stage
            kind      = $Kind
            path      = $full
            root      = [IO.Path]::GetFullPath($Root)
            identity  = $identity
            retry     = $Retry
            plaintext = [bool]$Plaintext
            adopted   = [bool]$Adopted
            recorded  = [DateTime]::UtcNow.ToString('o')
        })
    Save-RecoveryState -State $State -Path $StatePath
}

function Get-OwnedItem {
    <#
    .SYNOPSIS
        Owned records, filtered by -Stage, -Path, -Plaintext or -Retry.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [int]$Stage,
        [string]$Path,
        [switch]$Plaintext,
        [string]$Retry
    )
    foreach ($o in $State['owned']) {
        if ($PSBoundParameters.ContainsKey('Stage') -and $o['stage'] -ne $Stage) { continue }
        if ($Path -and -not $o['path'].Equals([IO.Path]::GetFullPath($Path), $script:Comparison)) { continue }
        if ($Plaintext -and -not $o['plaintext']) { continue }
        if ($Retry -and $o['retry'] -ne $Retry) { continue }
        $o
    }
}

function Set-OwnedItemRetry {
    <#
    .SYNOPSIS
        Changes the retry rule of an owned item (usually 'wipe' to 'keep' once
        a step has checked what it made) and saves the state.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('wipe', 'keep')][string]$Retry
    )
    $items = @(Get-OwnedItem -State $State -Path $Path)
    if (-not $items) { throw [InvalidOperationException]::new("$Path is not an item the controller created") }
    if (-not $PSCmdlet.ShouldProcess($Path, "Mark as $Retry")) { return }
    foreach ($o in $items) { $o['retry'] = $Retry }
    Save-RecoveryState -State $State -Path $StatePath
}

function Test-OwnedItem {
    <#
    .SYNOPSIS
        $true when -Path is an item the controller recorded and it is still
        that same object.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Path
    )
    $o = @(Get-OwnedItem -State $State -Path $Path) | Select-Object -First 1
    if ($null -eq $o) { return $false }
    return ((Get-ItemIdentity $o['path']) -eq $o['identity'])
}

function Invoke-NoFollowDelete([string]$Folder) {
    # Empties and removes a folder without following any link. Refuses (and
    # removes nothing more) at the first link or junction it meets.
    foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($Folder)) {
        $attributes = [IO.File]::GetAttributes($child)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { return 'link' }
        if ($attributes -band [IO.FileAttributes]::Directory) {
            $r = Invoke-NoFollowDelete $child
            if ($r -ne 'removed') { return $r }
        }
        else {
            if ($attributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($child, $attributes -band -bnot [IO.FileAttributes]::ReadOnly) }
            [IO.File]::Delete($child)
        }
    }
    [IO.Directory]::Delete($Folder, $false)
    return 'removed'
}

function Remove-OwnedItem {
    <#
    .SYNOPSIS
        Removes one owned item if it is still the object recorded, and drops
        its record. Returns 'removed', 'gone' (already missing), 'changed'
        (another object is there now; left alone and no longer owned), 'link'
        (a link on the way or inside; left alone) or 'path' (the path check
        failed; left alone).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][hashtable]$Item
    )
    $result = 'removed'
    if (Test-PathInRoot $Item['path'] $Item['root']) { return 'path' }
    $identity = Get-ItemIdentity $Item['path']
    if ($null -eq $identity) { $result = 'gone' }
    elseif ($identity -eq 'link') { return 'link' }
    elseif ($identity -ne $Item['identity']) { $result = 'changed' }
    elseif ($PSCmdlet.ShouldProcess($Item['path'], 'Remove an item the controller created')) {
        if ($Item['kind'] -eq 'folder') {
            $result = Invoke-NoFollowDelete $Item['path']
            if ($result -ne 'removed') { return $result }
        }
        else {
            $attributes = [IO.File]::GetAttributes($Item['path'])
            if ($attributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Item['path'], $attributes -band -bnot [IO.FileAttributes]::ReadOnly) }
            [IO.File]::Delete($Item['path'])
        }
    }
    else { return 'skipped' }
    [void]$State['owned'].Remove($Item)
    # Records of items inside a removed folder go with it.
    if ($Item['kind'] -eq 'folder' -and $result -eq 'removed') {
        $prefix = $Item['path'].TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        foreach ($o in @($State['owned'] | Where-Object { $_['path'].StartsWith($prefix, $script:Comparison) })) { [void]$State['owned'].Remove($o) }
    }
    Save-RecoveryState -State $State -Path $StatePath
    return $result
}

function Get-OwnershipCallback {
    <#
    .SYNOPSIS
        The four script blocks a stage records and checks ownership with,
        bound to one state and one stage:

          Own <kind> <path> <root> [<retry>] [-Plaintext] [-Adopted]
          Keep <path>           'wipe' -> 'keep'
          IsOwned <path>        created by the controller and unchanged
          RemoveOwned <path>    Remove-OwnedItem; 'not-owned' if never recorded

        With -PlanOnly the three that change anything throw.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are used inside the closures.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][int]$Stage,
        [switch]$PlanOnly
    )
    $planOnly = [bool]$PlanOnly
    # A closure runs outside this module, so it names the module's commands.
    @{
        Own         = {
            param([string]$Kind, [string]$Path, [string]$Root, [string]$Retry = 'wipe', [switch]$Plaintext, [switch]$Adopted)
            if ($planOnly) { throw [InvalidOperationException]::new('plan mode changes nothing') }
            RecoveryState\Add-OwnedItem -State $State -StatePath $StatePath -Stage $Stage -Kind $Kind -Path $Path -Root $Root -Retry $Retry -Plaintext:$Plaintext -Adopted:$Adopted
        }.GetNewClosure()
        Keep        = {
            param([string]$Path)
            if ($planOnly) { throw [InvalidOperationException]::new('plan mode changes nothing') }
            RecoveryState\Set-OwnedItemRetry -State $State -StatePath $StatePath -Path $Path -Retry 'keep'
        }.GetNewClosure()
        IsOwned     = { param([string]$Path) RecoveryState\Test-OwnedItem -State $State -Path $Path }.GetNewClosure()
        RemoveOwned = {
            param([string]$Path)
            if ($planOnly) { throw [InvalidOperationException]::new('plan mode changes nothing') }
            $item = @(RecoveryState\Get-OwnedItem -State $State -Path $Path) | Select-Object -First 1
            if ($null -eq $item) { return 'not-owned' }
            RecoveryState\Remove-OwnedItem -State $State -StatePath $StatePath -Item $item
        }.GetNewClosure()
    }
}

function Clear-StageOwned {
    <#
    .SYNOPSIS
        Removes every 'wipe' item -Stage created, deepest first, so an
        interrupted stage starts again from clean. Returns one line per item
        that was not simply removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][int]$Stage
    )
    $items = @(Get-OwnedItem -State $State -Stage $Stage -Retry 'wipe' | Sort-Object { $_['path'].Length } -Descending)
    foreach ($item in $items) {
        if (-not $State['owned'].Contains($item)) { continue }
        $r = Remove-OwnedItem -State $State -StatePath $StatePath -Item $item -WhatIf:$WhatIfPreference
        switch ($r) {
            'changed' { "$($item['path']): another item is there now; left alone" }
            'link' { "$($item['path']): a link or junction is on the way or inside; left alone" }
            'path' { "$($item['path']): fails the path check now; left alone" }
        }
    }
}

function New-StageResult {
    <#
    .SYNOPSIS
        The object every stage mode returns. Status is set by the stage:
        Plan 'planned'; Run 'done', 'failed', 'needs-user' or 'reboot'; Check
        'passed', 'failed' or 'needs-user'.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a new object; changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Status = 'done')
    [pscustomobject]@{
        Status   = $Status
        Steps    = [Collections.Generic.List[string]]::new()
        Checks   = [Collections.Generic.List[object]]::new()
        Asks     = [Collections.Generic.List[object]]::new()
        Problems = [Collections.Generic.List[string]]::new()
        Warnings = [Collections.Generic.List[string]]::new()
        Data     = @{}
    }
}

function Add-StageCheck {
    <#
    .SYNOPSIS
        Adds one checkpoint row to a stage result. A failed row makes the
        result 'failed' (unless it is already 'needs-user').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$What,
        [AllowEmptyString()][string]$Expected = '',
        [AllowEmptyString()][AllowNull()][string]$Actual = '',
        [Parameter(Mandatory)][bool]$Ok
    )
    $Result.Checks.Add([pscustomobject]@{ What = $What; Expected = $Expected; Actual = $Actual; Ok = $Ok })
    if (-not $Ok -and $Result.Status -ne 'needs-user') { $Result.Status = 'failed' }
}

function Add-StageAsk {
    <#
    .SYNOPSIS
        Adds something only a person can do to a stage result and makes it
        'needs-user' (unless it already failed). With -Id the person answers
        with Invoke-StackRecovery.ps1 -Accept <id>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Text,
        [string]$Id
    )
    $Result.Asks.Add([pscustomobject]@{ Id = $Id; Text = $Text })
    if ($Result.Status -ne 'failed') { $Result.Status = 'needs-user' }
}

function Get-SecretCandidate([string]$Path) {
    # Values worth matching from one unpacked bundle file: the whole text when
    # short, the value of every NAME=value line, every JSON string, and every
    # other line of 16 characters or more. Only for matching; never printed.
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 4MB -or [Array]::IndexOf($bytes, [byte]0) -ge 0) { return }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $trimmed = $text.Trim()
    if ($trimmed.Length -ge 8 -and $trimmed.Length -le 4096 -and $trimmed -notmatch '\n') { $trimmed }
    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
        try {
            $stack = [Collections.Generic.Stack[object]]::new()
            $stack.Push(($trimmed | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop))
            while ($stack.Count -gt 0) {
                $node = $stack.Pop()
                if ($node -is [string]) { if ($node.Length -ge 8) { $node } }
                elseif ($node -is [Collections.IDictionary]) { foreach ($v in $node.Values) { if ($null -ne $v) { $stack.Push($v) } } }
                elseif ($node -is [Collections.IEnumerable]) { foreach ($v in $node) { if ($null -ne $v) { $stack.Push($v) } } }
            }
        }
        catch { $null = $_ }
    }
    foreach ($line in ($text -split '\r?\n')) {
        $l = $line.Trim()
        if ($l -match '^(?:export\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*=\s*(.*)$') {
            $v = $Matches[1].Trim().Trim('"', "'")
            if ($v.Length -ge 8) { $v }
        }
        elseif ($l.Length -ge 16 -and $l -notmatch '^-----(BEGIN|END) ') { $l }
    }
}

function Test-EvidenceSecretFree {
    <#
    .SYNOPSIS
        Matches every evidence file in -EvidencePath against the values of the
        unpacked bundle in -BundleRoot. Returns the evidence files that hold
        one (names only; nothing is printed or kept about the value).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$EvidencePath,
        [Parameter(Mandatory)][string]$BundleRoot
    )
    $values = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($f in [IO.Directory]::EnumerateFiles($BundleRoot, '*', [IO.SearchOption]::AllDirectories)) {
        if ([IO.Path]::GetFileName($f) -eq '00-RESTORE-MAP.json') { continue }
        foreach ($v in @(Get-SecretCandidate $f)) {
            [void]$values.Add($v)
            # Evidence is JSON, so a value with a quote or backslash appears escaped.
            $escaped = (ConvertTo-Json -InputObject $v -Compress).Trim('"')
            if ($escaped -ne $v) { [void]$values.Add($escaped) }
        }
    }
    foreach ($e in $EvidencePath) {
        if (-not (Test-Path -LiteralPath $e -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($e)
        foreach ($v in $values) {
            if ($text.Contains($v)) { $e; break }
        }
    }
}

Export-ModuleMember -Function Read-RecoveryState, Save-RecoveryState, Enter-RecoveryLock, Exit-RecoveryLock,
Get-ItemIdentity, Add-OwnedItem, Get-OwnedItem, Set-OwnedItemRetry, Test-OwnedItem, Remove-OwnedItem,
Clear-StageOwned, Get-OwnershipCallback, New-StageResult, Add-StageCheck, Add-StageAsk, Test-EvidenceSecretFree
