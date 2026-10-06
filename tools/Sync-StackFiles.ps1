#Requires -Version 7.4
<#
.SYNOPSIS
    Copies the stack's own files from the live PC and VPS into this repo,
    with every tailnet address and name swapped for its placeholder
    (docs/RESTORE.md Appendix D; Stage 1 and Stage 4a read the result).

.DESCRIPTION
    manifests/stack-files.json lists, by source, every file to copy: the PC
    stack under E:\ai\ollama, the ComfyUI logon launcher, the dashboard, and
    the VPS web egress, Kokoro, the Groq relay site and Docker's drop-in.
    Each source owns one folder of this repo with the same layout as on the
    machine.

    Two modes:

      Plan (the default). Reads every listed file, templates it, scans it,
      and says which repo files would be new or changed. Writes nothing in
      the repo.

      -Execute. The same, then writes the new and changed files and
      rewrites manifests/endpoints.json from the repo.

    Rules it keeps:

      - Read-only on the live machines. PC files are read in place; VPS files
        come back over one ssh call per source as base64, from a fixed
        script that refuses links and anything that is not a plain file.
        Host keys are never accepted automatically.
      - No private addresses. Every tailnet IPv4 and IPv6 address and every
        MagicDNS name Tailscale reports becomes {{PC_TS_IP}},
        {{VPS_TS_NAME}}, {{TS_DOMAIN}} and so on (tools/StackCapture.psm1).
        A file that already holds such a placeholder is refused, since it
        would be filled in at restore time.
      - No secrets. The templated files are written to a private temporary
        folder and scanned with tools/Test-NoSecrets.ps1, the same scan CI
        runs. Any finding (a secret-shaped string, a tailnet address that
        is not a node any more, a forbidden file name) stops the run before
        the repo is touched, and the finding is reported by file, line and
        rule only.
      - Fails closed. A missing file, a link, a file over 1 MB, or text that
        is not UTF-8 stops the run; nothing is written.
      - Paths. Every path read, written or removed is checked with
        tools/Test-RecoveryPath.ps1 first.
      - Line endings follow .gitattributes: CRLF for .ps1, .psm1, .psd1,
        .vbs, .bat and .cmd, LF for everything else. Comparing ignores them,
        so a Windows checkout is not reported as changed.
      - Never deletes from the repo. A file in a source's folder that the
        list no longer names is reported, and left for a person to remove.
      - Output. Source names, repo paths, statuses and placeholder names.
        Never file content.

.PARAMETER ManifestPath
    The file list. Defaults to manifests/stack-files.json in this repo.

.PARAMETER RepoPath
    The repo to write into. Defaults to the repo this script is in.

.PARAMETER Source
    Only these sources (their names in the file list).

.PARAMETER Execute
    Write the new and changed files and the endpoint list.

.PARAMETER SshHost
    The SSH alias of the VPS, and its node name in the tailnet.

.PARAMETER PassThru
    Return the result object instead of printing a summary and setting the
    exit code.

.OUTPUTS
    With -PassThru: [pscustomobject] with Mode, IsValid, Rows (Source, File,
    Status, Placeholders), Problems, Warnings and EndpointsWritten.

.EXAMPLE
    ./tools/Sync-StackFiles.ps1

    Shows which repo files would change, touching nothing.

.EXAMPLE
    ./tools/Sync-StackFiles.ps1 -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are read inside the helper functions.')]
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '../manifests/stack-files.json'),

    [string]$RepoPath = (Split-Path $PSScriptRoot -Parent),

    [string[]]$Source,

    [switch]$Execute,

    [string]$SshHost = 'vps',

    [switch]$PassThru,

    # Test seams: the programs used to reach the VPS and read the tailnet.
    [Parameter(DontShow)]
    [string]$SshCommand = 'ssh',

    [Parameter(DontShow)]
    [string]$TailscaleCommand = 'tailscale'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'StackCapture.psm1') -Force
$testPath = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
$scanScript = Join-Path $PSScriptRoot 'Test-NoSecrets.ps1'
$schemaPath = Join-Path $PSScriptRoot '../manifests/schemas/stack-files.schema.json'
$maxFileBytes = 1MB
$crlfTypes = '(?i)\.(ps1|psm1|psd1|vbs|bat|cmd)$'
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20')

$problems = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$rows = [Collections.Generic.List[object]]::new()
$state = [pscustomobject]@{ EndpointsWritten = $false }

# Runs on the VPS through ssh: bash SCRIPT <root as base64> <max bytes>, with
# one base64 relative path per line on its input (CRLF line ends when
# PowerShell on Windows sends it). Prints one line per path,
# in order: 'ok <content as base64>', or one word saying why not. Reads only.
$remoteRead = @'
set -u
root=$(printf '%s' "$1" | base64 -d 2>/dev/null) || exit 3
max=$2
case "$root" in /*) ;; *) exit 3;; esac
while IFS= read -r line; do
  rel=$(printf '%s' "$line" | tr -d '\r' | base64 -d 2>/dev/null) || { echo bad; continue; }
  case "/$rel/" in */../*|*/./*|//*) echo bad; continue;; esac
  st=ok
  [ -L "$root" ] && st=link
  q=$root
  for s in $(printf '%s' "$rel" | tr '/' ' '); do
    q="$q/$s"
    if [ -L "$q" ]; then st=link; fi
  done
  p="$root/$rel"
  if [ "$st" = ok ]; then
    if [ ! -e "$p" ]; then st=missing
    elif [ ! -f "$p" ]; then st=notfile
    elif [ ! -r "$p" ]; then st=unreadable
    elif [ "$(stat -c %s -- "$p" 2>/dev/null || echo x)" = x ]; then st=unreadable
    elif [ "$(stat -c %s -- "$p")" -gt "$max" ]; then st=big
    fi
  fi
  if [ "$st" = ok ]; then
    b=$(base64 -w0 -- "$p" 2>/dev/null) || { echo unreadable; continue; }
    printf 'ok %s\n' "$b"
  else
    echo "$st"
  fi
done
'@

# ---------- Small helpers ----------

function Get-RunResult {
    [pscustomobject]@{
        Mode             = if ($Execute) { 'Execute' } else { 'Plan' }
        IsValid          = ($problems.Count -eq 0)
        Rows             = $rows.ToArray()
        Problems         = $problems.ToArray()
        Warnings         = $warnings.ToArray()
        EndpointsWritten = $state.EndpointsWritten
    }
}

function ConvertTo-Base64([string]$Text) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Test-SameByte([byte[]]$A, [byte[]]$B) {
    # Equal once CRLF is read as LF, so a checkout's line endings do not count
    # as a change. Latin-1 maps every byte to one character and back.
    $latin = [Text.Encoding]::Latin1
    return ($latin.GetString($A).Replace("`r`n", "`n") -ceq $latin.GetString($B).Replace("`r`n", "`n"))
}

# ---------- The file list ----------

function Read-StackManifest {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { $problems.Add('file list: not found'); return $null }
    $schemaErrors = $null
    $ok = Test-Json -Path $ManifestPath -SchemaFile $schemaPath -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    if (-not $ok) {
        foreach ($e in $schemaErrors) {
            $msg = if ($e.ErrorDetails -and $e.ErrorDetails.Message) { $e.ErrorDetails.Message } else { $e.Exception.Message }
            $problems.Add("file list: $msg")
        }
        if (-not $schemaErrors) { $problems.Add('file list: does not match its schema') }
        return $null
    }
    $doc = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $names = @{}
    $folders = [Collections.Generic.List[string]]::new()
    $destinations = @{}
    foreach ($src in $doc.sources) {
        if ($names.ContainsKey($src.name)) { $problems.Add("file list: source '$($src.name)' is listed twice") }
        $names[$src.name] = $true
        foreach ($other in $folders) {
            if (($src.repoFolder + '/').StartsWith($other + '/', [StringComparison]::OrdinalIgnoreCase) -or
                ($other + '/').StartsWith($src.repoFolder + '/', [StringComparison]::OrdinalIgnoreCase)) {
                $problems.Add("file list: source '$($src.name)' shares its repo folder with another source")
            }
        }
        $folders.Add($src.repoFolder)
        if ($src.host -eq 'vps' -and ($src.root -notmatch '^(/[A-Za-z0-9._-]+)+$' -or $src.root -match '/\.{1,2}(/|$)')) {
            $problems.Add("file list: source '$($src.name)' has a VPS root that is not a plain absolute path")
        }
        foreach ($f in $src.files) {
            if ($f -match '(^|/)\.{1,2}(/|$)') { $problems.Add("file list: '$($src.name)/$f' has a '.' or '..' segment"); continue }
            $dest = "$($src.repoFolder)/$f"
            $key = $dest.ToLowerInvariant()
            if ($destinations.ContainsKey($key)) { $problems.Add("file list: '$dest' is listed twice (names differ only in case)") }
            $destinations[$key] = $true
        }
    }
    foreach ($s in @($Source)) {
        if ($s -and -not $names.ContainsKey($s)) { $problems.Add("-Source: '$s' is not in the file list") }
    }
    if ($problems.Count -gt 0) { return $null }
    $picked = @($doc.sources | Where-Object { -not $Source -or $Source -contains $_.name })
    return , $picked
}

# ---------- Reading the live files ----------

function Read-PcSource($Src, $Fetched) {
    $root = [Environment]::ExpandEnvironmentVariables([string]$Src.root)
    if (-not [IO.Path]::IsPathFullyQualified($root)) { $problems.Add("$($Src.name): the root is not a full path"); return }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { $problems.Add("$($Src.name): the root folder does not exist"); return }
    $checks = @(& $testPath -Path @($Src.files) -Root $root -Relative -Detailed)
    for ($i = 0; $i -lt $checks.Count; $i++) {
        $file = [string]@($Src.files)[$i]
        $label = "$($Src.repoFolder)/$file"
        if (-not $checks[$i].IsValid) { $problems.Add("${label}: refused ($($checks[$i].Reason))"); continue }
        $item = Get-Item -LiteralPath $checks[$i].FullPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { $problems.Add("${label}: not found on the PC"); continue }
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $problems.Add("${label}: not a plain file on the PC"); continue }
        if ($item.Length -gt $maxFileBytes) { $problems.Add("${label}: over 1 MB; not a stack file this tool should copy"); continue }
        $Fetched.Add([pscustomobject]@{ Source = $Src.name; File = $file; Dest = $label; Bytes = [IO.File]::ReadAllBytes($item.FullName) })
    }
}

function Read-VpsSource($Src, $Fetched) {
    $script = ConvertTo-Base64 ($remoteRead -replace "`r", '')
    $remote = 't=$(mktemp) && echo ' + $script + ' | base64 -d > $t && bash $t ' + (ConvertTo-Base64 $Src.root) + ' ' + $maxFileBytes +
        '; r=$?; rm -f $t; exit $r'
    $files = @($Src.files)
    $lines = @($files | ForEach-Object { ConvertTo-Base64 $_ })
    $out = @($lines | & $SshCommand @sshOptions $SshHost $remote 2>$null)
    $code = $LASTEXITCODE
    if ($code -ne 0 -or $out.Count -ne $files.Count) {
        $problems.Add("$($Src.name): the VPS read failed (ssh exit $code, $($out.Count) of $($files.Count) answers)")
        return
    }
    for ($i = 0; $i -lt $files.Count; $i++) {
        $label = "$($Src.repoFolder)/$($files[$i])"
        $line = [string]$out[$i]
        if ($line.StartsWith('ok ')) {
            try { $bytes = [Convert]::FromBase64String($line.Substring(3)) }
            catch { $problems.Add("${label}: the VPS answer could not be decoded"); continue }
            $Fetched.Add([pscustomobject]@{ Source = $Src.name; File = $files[$i]; Dest = $label; Bytes = $bytes })
            continue
        }
        $why = switch ($line) {
            'missing' { 'not found on the VPS' }
            'link' { 'a symbolic link on the way on the VPS' }
            'notfile' { 'not a plain file on the VPS' }
            'unreadable' { 'not readable on the VPS as this user' }
            'big' { 'over 1 MB; not a stack file this tool should copy' }
            default { 'the VPS read failed' }
        }
        $problems.Add("${label}: $why")
    }
}

# ---------- Templating ----------

function ConvertTo-RepoByte($Item, $Endpoint) {
    # The file as it goes in the repo: endpoints templated, line endings as
    # .gitattributes wants them, a UTF-8 byte order mark kept if it had one.
    # Returns $null after recording a problem.
    $bytes = [byte[]]$Item.Bytes
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (($bytes.Length -ge 2) -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        $problems.Add("$($Item.Dest): UTF-16 text; save it as UTF-8 and run again")
        return $null
    }
    $start = if ($bom) { 3 } else { 0 }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $start, $bytes.Length - $start) }
    catch { $problems.Add("$($Item.Dest): not UTF-8 text"); return $null }
    if ($text.Contains([char]0)) { $problems.Add("$($Item.Dest): binary (holds NUL bytes)"); return $null }
    try { $t = ConvertTo-StackTemplate -Text $text -Endpoint $Endpoint }
    catch { $problems.Add("$($Item.Dest): $($_.Exception.Message)"); return $null }
    $text = $t.Text -replace "`r`n", "`n"
    if ($Item.Dest -match $crlfTypes) { $text = $text -replace "`n", "`r`n" }
    $body = [Text.UTF8Encoding]::new($false).GetBytes($text)
    if ($bom) { $body = [byte[]](0xEF, 0xBB, 0xBF) + $body }
    $Item | Add-Member -NotePropertyName Placeholders -NotePropertyValue $t.Placeholders
    return , [byte[]]$body
}

function Write-CheckedFile([string]$Root, [string]$Relative, [byte[]]$Bytes) {
    $check = & $testPath -Path $Relative -Root $Root -Relative -Detailed
    if (-not $check.IsValid) { throw [InvalidOperationException]::new("$Relative refused ($($check.Reason))") }
    $parent = Split-Path $check.FullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllBytes($check.FullPath, $Bytes)
}

function Initialize-Staging {
    $base = [IO.Path]::GetTempPath()
    $name = 'cria-sync-' + [guid]::NewGuid().ToString('N')
    $check = & $testPath -Path $name -Root $base -Relative -Detailed
    if (-not $check.IsValid) { throw [InvalidOperationException]::new("the temporary folder was refused ($($check.Reason))") }
    if ($IsWindows) { [void](New-Item -ItemType Directory -Path $check.FullPath) }
    else { [void][IO.Directory]::CreateDirectory($check.FullPath, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    return $check.FullPath
}

function Clear-Staging([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $base = [IO.Path]::GetTempPath()
    $check = & $testPath -Path (Split-Path $Path -Leaf) -Root $base -Relative -Detailed
    if ($check.IsValid -and $check.FullPath -eq $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    else { $warnings.Add('the temporary folder could not be checked, so it was left in place') }
}

# ---------- The run ----------

function Invoke-Sync {
    $sources = Read-StackManifest
    if ($null -eq $sources) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath 'manifests') -PathType Container)) {
        $problems.Add('-RepoPath: not an ollama-cria checkout (no manifests folder)')
        return
    }
    $script:RepoPath = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
    try { $endpoint = Get-TailnetEndpoint -SshHost $SshHost -TailscaleCommand $TailscaleCommand }
    catch { $problems.Add("tailnet: $($_.Exception.Message)"); return }

    $fetched = [Collections.Generic.List[object]]::new()
    foreach ($src in $sources) {
        if ($src.host -eq 'pc') { Read-PcSource $src $fetched } else { Read-VpsSource $src $fetched }
    }
    if ($problems.Count -gt 0) { return }

    foreach ($item in $fetched) {
        $body = ConvertTo-RepoByte $item $endpoint
        if ($null -ne $body) { $item | Add-Member -NotePropertyName RepoBytes -NotePropertyValue $body }
    }
    if ($problems.Count -gt 0) { return }

    $stage = Initialize-Staging
    try {
        foreach ($item in $fetched) { Write-CheckedFile $stage $item.Dest $item.RepoBytes }
        foreach ($f in @(& $scanScript -Path $stage -PassThru)) {
            $where = if ($f.Line) { "$($f.File):$($f.Line)" } else { $f.File }
            $problems.Add("${where}: $($f.Rule)")
        }
    }
    finally { Clear-Staging $stage }
    if ($problems.Count -gt 0) { return }

    $listed = @{}
    foreach ($item in $fetched) {
        $listed[$item.Dest.ToLowerInvariant()] = $true
        $check = & $testPath -Path $item.Dest -Root $RepoPath -Relative -Detailed
        if (-not $check.IsValid) { $problems.Add("$($item.Dest): refused in the repo ($($check.Reason))"); continue }
        $status = 'new'
        if (Test-Path -LiteralPath $check.FullPath -PathType Leaf) {
            $status = if (Test-SameByte ([IO.File]::ReadAllBytes($check.FullPath)) $item.RepoBytes) { 'unchanged' } else { 'changed' }
        }
        $rows.Add([pscustomobject]@{ Source = $item.Source; File = $item.Dest; Status = $status; Placeholders = $item.Placeholders })
    }
    foreach ($src in $sources) {
        $folder = Join-Path $RepoPath $src.repoFolder
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $folder -Recurse -File -Force)) {
            $rel = [IO.Path]::GetRelativePath($RepoPath, $f.FullName) -replace '\\', '/'
            if (-not $listed.ContainsKey($rel.ToLowerInvariant())) { $warnings.Add("${rel}: in the repo but not in the file list; left as it is") }
        }
    }
    if ($problems.Count -gt 0 -or -not $Execute) { return }

    foreach ($item in $fetched) {
        $row = $rows | Where-Object { $_.File -eq $item.Dest } | Select-Object -First 1
        if ($row.Status -ne 'unchanged') { Write-CheckedFile $RepoPath $item.Dest $item.RepoBytes }
    }
    $state.EndpointsWritten = -not (Export-EndpointManifest -RepoPath $RepoPath)
}

Invoke-Sync
$result = Get-RunResult
if ($PassThru) { return $result }

foreach ($r in ($result.Rows | Where-Object Status -NE 'unchanged')) {
    $marks = if ($r.Placeholders.Count) { '  {{' + ($r.Placeholders -join '}} {{') + '}}' } else { '' }
    Write-Output ("  {0,-9} {1}{2}" -f $r.Status, $r.File, $marks)
}
foreach ($w in $result.Warnings) { Write-Output "  note: $w" }
foreach ($p in $result.Problems) { Write-Output "  PROBLEM: $p" }
$counts = $result.Rows | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }
$verb = if ($Execute) { 'written' } else { 'planned (nothing written; add -Execute)' }
if ($result.IsValid) {
    Write-Output "Sync-StackFiles: $($result.Rows.Count) file(s): $($counts -join ', '); $verb."
    if ($result.EndpointsWritten) { Write-Output 'Sync-StackFiles: manifests/endpoints.json rewritten.' }
}
else {
    Write-Output "Sync-StackFiles: stopped with $($result.Problems.Count) problem(s); nothing was written."
    exit 1
}
