<#
.SYNOPSIS
    Shared helpers for the tools that copy the live stack into this repo and
    render it back out: tailnet endpoints, address templating and the endpoint
    list (docs/RESTORE.md Stage 4a and Appendix E).

.DESCRIPTION
    The repo never holds a tailnet address or MagicDNS name (AGENTS.md). Every
    one is stored as a placeholder named after its node:

      {{PC_TS_IP}}, {{PC_TS_IP6}}, {{PC_TS_NAME}}    this machine
      {{VPS_TS_IP}}, {{VPS_TS_NAME}}, ...            the node named after the
                                                     SSH alias of the VPS
      {{FOLD_TS_IP}}, ...                            any other node, by the
                                                     first label of its name
      {{EXT_<LABEL>_TS_IP}}, ...                     a node from outside the
                                                     tailnet (shared in, or an
                                                     exit node)
      {{TS_DOMAIN}}                                  the MagicDNS suffix
      {{STALE_TS_IP}}, {{STALE_TS_IP6}}              an address in Tailscale's
                                                     range that no node has
                                                     now; it renders as a
                                                     documentation address
                                                     (RFC 5737, RFC 3849) that
                                                     goes nowhere, as the old
                                                     one already does
      {{VPS_PUBLIC_IP}}, {{VPS_PUBLIC_IP6}}          the VPS's own public
                                                     address, kept out of the
                                                     repo; it renders as a
                                                     documentation address
                                                     too, so a line that needs
                                                     the real one is fixed by
                                                     hand (the sync names it)

    Get-TailnetEndpoint reads them from 'tailscale status --json'; the same
    names come out on the rebuilt machines as long as the nodes keep their
    names (Stage 2b), so a template captured today renders there.

    Exported functions:

      Get-TailnetEndpoint     the endpoint table, or an exception saying why not
      ConvertTo-StackTemplate swaps every endpoint value in a text for its
                              placeholder
      ConvertFrom-StackTemplate
                              the reverse, for Stage 4a; fails on a placeholder
                              it has no value for
      Find-TailnetAddress     the addresses in Tailscale's ranges a text holds
      Get-StackPlaceholder    the endpoint placeholders a text holds
      Select-PublicAddress    the public addresses in a list (what the VPS
                              reports, less its private and tailnet ones)
      Export-EndpointManifest writes manifests/endpoints.json: every templated
                              file in the folders that are deployed or read by
                              a stage, and the placeholders it holds
      Test-RepoContent        scans files bound for the repo with
                              tools/Test-NoSecrets.ps1 in a private temporary
                              folder, before any of them reaches the repo
      Get-RepoFileStatus      new, changed or unchanged against the repo,
                              ignoring a checkout's line endings
      Write-RepoFile          writes one file under a root, path checked
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Endpoint placeholders only. Other {{...}} text (Go templates such as
# {{.Names}}, Jinja) is never touched.
$script:EndpointName = '^(?:[A-Z][A-Z0-9_]*_TS_(?:IP|IP6|NAME)|TS_DOMAIN|VPS_PUBLIC_IP6?)$'
$script:Placeholder = '\{\{([A-Z][A-Z0-9_]*)\}\}'

# Any address left in Tailscale's ranges once every node's own is swapped.
# Tailscale's service address and the ranges written as networks are the
# same in every tailnet, so they stay (tools/Test-NoSecrets.ps1 passes them).
$script:StaleIp = [regex]::new('\b(?!100\.100\.100\.100\b)(?!100\.64\.0\.0/)100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b')
$script:StaleIp6 = [regex]::new('\b(?!fd7a:115c:a1e0::53\b)(?!fd7a:115c:a1e0::/)fd7a:115c:a1e0:[0-9a-f:]*[0-9a-f]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)

# Placeholders that never render to a real address: documentation addresses
# (RFC 5737, RFC 3849) that go nowhere.
$script:FixedValue = @{
    STALE_TS_IP    = '192.0.2.1'
    STALE_TS_IP6   = '2001:db8::1'
    VPS_PUBLIC_IP  = '192.0.2.2'
    VPS_PUBLIC_IP6 = '2001:db8::2'
}

# Where templated files can live: folders copied to a machine at restore
# time, and the manifests the stages read. The OWUI seed is rendered by its
# own importer; the schemas and the list itself hold no endpoints.
$script:EndpointFolders = @('stack', 'vps', 'extras', 'windows/startup', 'windows/tasks')
$script:EndpointListPath = 'manifests/endpoints.json'

function Get-NodeLabel($Node) {
    # The first label of a node's MagicDNS name ('pc' in pc.<tailnet>.ts.net).
    $dns = [string]$Node['DNSName']
    if ($dns) { return ($dns -split '\.')[0].ToLowerInvariant() }
    return ([string]$Node['HostName']).ToLowerInvariant()
}

function Get-TailnetEndpoint {
    <#
    .SYNOPSIS
        Every tailnet address and MagicDNS name Tailscale reports, by
        placeholder name. Throws when Tailscale cannot be read or the PC or
        VPS is missing. The values are private: callers keep them in memory.
    #>
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$SshHost,

        [string]$TailscaleCommand = 'tailscale'
    )
    # A stand-in script may not set the exit code, so start from success.
    $global:LASTEXITCODE = 0
    $raw = @(& $TailscaleCommand status --json 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw [InvalidOperationException]::new('''tailscale status --json'' failed; is Tailscale running and signed in?')
    }
    try { $status = ConvertFrom-Json -InputObject ($raw -join "`n") -AsHashtable -ErrorAction Stop }
    catch { throw [InvalidOperationException]::new('the Tailscale status could not be read') }
    $suffix = ([string]$status['MagicDNSSuffix']).TrimEnd('.')
    if (-not $status['Self'] -or $suffix -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$') {
        throw [InvalidOperationException]::new('the Tailscale status has no node for this machine or no MagicDNS name')
    }
    # Sorted by name, so the numbering of a repeated label is the same each run.
    $all = @(if ($status['Peer']) { $status['Peer'].Values | Sort-Object { [string]$_['DNSName'] } })
    # Shared-in nodes and exit nodes have another suffix.
    $peers = @($all | Where-Object { ([string]$_['DNSName']).TrimEnd('.') -like "*.$suffix" })
    $outside = @($all | Where-Object { ([string]$_['DNSName']).TrimEnd('.') -notlike "*.$suffix" })
    $vps = @($peers | Where-Object { (Get-NodeLabel $_) -eq $SshHost.ToLowerInvariant() })
    if ($vps.Count -ne 1) {
        throw [InvalidOperationException]::new("expected one node named '$SshHost' in the tailnet, found $($vps.Count)")
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
        throw [InvalidOperationException]::new('the Tailscale status gives no IPv4 address for this machine or the VPS')
    }
    return $endpoints
}

function Get-EndpointRegex([string]$Value) {
    # A whole address or name only: an address must not match inside a longer
    # one that adds a digit, and pc.<tailnet>.ts.net not inside
    # mypc.<tailnet>.ts.net.
    $v = [regex]::Escape($Value)
    $ignore = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    if ($Value -match '^[0-9.]+$') { return [regex]::new("(?<![0-9.])$v(?![0-9]|\.[0-9])") }
    if ($Value -match '^[0-9A-Fa-f:]+$') { return [regex]::new("(?<![0-9A-Fa-f:])$v(?![0-9A-Fa-f:])", $ignore) }
    return [regex]::new("(?<![A-Za-z0-9_-])$v(?![A-Za-z0-9_-])", $ignore)
}

function Get-StackPlaceholder {
    <#
    .SYNOPSIS
        The endpoint placeholder names a text holds, sorted, each once.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    $names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($m in [regex]::Matches($Text, $script:Placeholder)) {
        if ($m.Groups[1].Value -match $script:EndpointName) { [void]$names.Add($m.Groups[1].Value) }
    }
    return , [string[]]@($names)
}

function Select-PublicAddress {
    <#
    .SYNOPSIS
        The public addresses in -Address, in their usual short form: IPv4
        outside the private, shared (Tailscale's), loopback, link-local and
        multicast ranges, and IPv6 global unicast (2000::/3). Anything that
        is not an address is dropped.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [string[]]$Address = @()
    )
    $found = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($a in $Address) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse(([string]$a).Trim(), [ref]$ip)) { continue }
        $b = $ip.GetAddressBytes()
        if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
            $private = $b[0] -in 0, 10, 127 -or $b[0] -ge 224 -or
                ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or
                ($b[0] -eq 169 -and $b[1] -eq 254) -or
                ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
                ($b[0] -eq 192 -and $b[1] -eq 168)
            if (-not $private) { [void]$found.Add($ip.ToString()) }
        }
        elseif ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and ($b[0] -band 0xE0) -eq 0x20) {
            [void]$found.Add($ip.ToString())
        }
    }
    return , [string[]]@($found)
}

function ConvertTo-StackTemplate {
    <#
    .SYNOPSIS
        Swaps every endpoint value in -Text for its {{NAME}}, each of
        -PublicAddress for {{VPS_PUBLIC_IP}} or {{VPS_PUBLIC_IP6}}, then any
        other address in Tailscale's ranges for {{STALE_TS_IP}} or
        {{STALE_TS_IP6}}. Returns the new text, the placeholders it now
        holds and the line numbers of the public and the stale addresses.
        Throws, naming the placeholder, when the text already holds one,
        because it would be filled in at restore time.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [Collections.IDictionary]$Endpoint,

        # The VPS's public addresses (Select-PublicAddress).
        [AllowEmptyCollection()]
        [string[]]$PublicAddress = @()
    )
    $already = Get-StackPlaceholder -Text $Text
    if ($already.Count -gt 0) {
        throw [InvalidOperationException]::new("it already holds {{$($already[0])}}, which would be filled in at restore time")
    }
    # Longest value first, so a name is replaced before the domain inside it.
    $order = @($Endpoint.Keys | Sort-Object { ([string]$Endpoint[$_]).Length } -Descending)
    foreach ($key in $order) {
        $value = [string]$Endpoint[$key]
        if (-not $value) { continue }
        $Text = (Get-EndpointRegex $value).Replace($Text, "{{$key}}")
    }
    $publicLines = [Collections.Generic.SortedSet[int]]::new()
    foreach ($a in @($PublicAddress | Where-Object { $_ } | Sort-Object Length -Descending)) {
        $re = Get-EndpointRegex $a
        foreach ($m in $re.Matches($Text)) { [void]$publicLines.Add($Text.Substring(0, $m.Index).Split("`n").Count) }
        $Text = $re.Replace($Text, $(if ($a.Contains(':')) { '{{VPS_PUBLIC_IP6}}' } else { '{{VPS_PUBLIC_IP}}' }))
    }
    $staleLines = [Collections.Generic.SortedSet[int]]::new()
    foreach ($m in @($script:StaleIp.Matches($Text)) + @($script:StaleIp6.Matches($Text))) {
        [void]$staleLines.Add($Text.Substring(0, $m.Index).Split("`n").Count)
    }
    $Text = $script:StaleIp.Replace($Text, '{{STALE_TS_IP}}')
    $Text = $script:StaleIp6.Replace($Text, '{{STALE_TS_IP6}}')
    return [pscustomobject]@{
        Text         = $Text
        Placeholders = (Get-StackPlaceholder -Text $Text)
        PublicLines  = [int[]]@($publicLines)
        StaleLines   = [int[]]@($staleLines)
    }
}

function Find-TailnetAddress {
    <#
    .SYNOPSIS
        Every address in Tailscale's ranges that -Text holds, each once.
        Tailscale's service address and ranges written as networks are left
        out, as in ConvertTo-StackTemplate. Stage 4 uses it to prove a
        rendered file holds only the new nodes' addresses.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    $found = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in @($script:StaleIp.Matches($Text)) + @($script:StaleIp6.Matches($Text))) { [void]$found.Add($m.Value) }
    return , [string[]]@($found)
}

function ConvertFrom-StackTemplate {
    <#
    .SYNOPSIS
        Fills every endpoint placeholder in -Text from -Endpoint (Stage 4a),
        and a stale one with its documentation address. Throws, naming it,
        on a placeholder with no value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [Collections.IDictionary]$Endpoint
    )
    $values = @{}
    foreach ($k in $script:FixedValue.Keys) { $values[$k] = $script:FixedValue[$k] }
    foreach ($k in $Endpoint.Keys) { $values[[string]$k] = [string]$Endpoint[$k] }
    foreach ($name in (Get-StackPlaceholder -Text $Text)) {
        if (-not $values.ContainsKey($name) -or -not $values[$name]) {
            throw [InvalidOperationException]::new("{{$name}} has no value; is that node in the tailnet under the same name?")
        }
    }
    return [regex]::Replace($Text, $script:Placeholder, {
            param($m)
            $name = $m.Groups[1].Value
            if ($name -match $script:EndpointName) { return $values[$name] }
            return $m.Value
        })
}

function Write-RepoFile {
    <#
    .SYNOPSIS
        Writes -Bytes to -Relative under -Root, after
        tools/Test-RecoveryPath.ps1 has checked the path (no '..', no link on
        the way). Creates the folders above it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Relative,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )
    $pathCheck = & (Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1') -Path $Relative -Root $Root -Relative -Detailed
    if (-not $pathCheck.IsValid) { throw [InvalidOperationException]::new("$Relative refused ($($pathCheck.Reason))") }
    $parent = Split-Path $pathCheck.FullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllBytes($pathCheck.FullPath, $Bytes)
}

function Get-RepoFileStatus {
    <#
    .SYNOPSIS
        'new', 'changed' or 'unchanged' for -Bytes against -Relative in the
        repo. CRLF counts as LF, so a Windows checkout is not a change.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath,

        [Parameter(Mandatory)]
        [string]$Relative,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )
    $pathCheck = & (Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1') -Path $Relative -Root $RepoPath -Relative -Detailed
    if (-not $pathCheck.IsValid) { throw [InvalidOperationException]::new("$Relative refused in the repo ($($pathCheck.Reason))") }
    if (-not (Test-Path -LiteralPath $pathCheck.FullPath -PathType Leaf)) { return 'new' }
    # Latin-1 maps every byte to one character and back.
    $latin = [Text.Encoding]::Latin1
    $old = $latin.GetString([IO.File]::ReadAllBytes($pathCheck.FullPath)).Replace("`r`n", "`n")
    $new = $latin.GetString($Bytes).Replace("`r`n", "`n")
    if ($old -ceq $new) { return 'unchanged' }
    return 'changed'
}

function Test-RepoContent {
    <#
    .SYNOPSIS
        Scans files bound for the repo before any of them is written there.
        -Item is a list of objects with Dest (the repo path) and Bytes. They
        are written to a new temporary folder only the current user can
        read, scanned with tools/Test-NoSecrets.ps1, and the folder is
        removed. Returns one line per finding: '<repo path>:<line>: <rule>'.
        Never the matched text.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Item
    )
    $testPath = Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1'
    $base = [IO.Path]::GetTempPath()
    $name = 'cria-scan-' + [guid]::NewGuid().ToString('N')
    $pathCheck = & $testPath -Path $name -Root $base -Relative -Detailed
    if (-not $pathCheck.IsValid) { throw [InvalidOperationException]::new("the temporary folder was refused ($($pathCheck.Reason))") }
    $stage = $pathCheck.FullPath
    if ($IsWindows) { [void](New-Item -ItemType Directory -Path $stage) }
    else { [void][IO.Directory]::CreateDirectory($stage, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    $found = [Collections.Generic.List[string]]::new()
    try {
        foreach ($i in $Item) { Write-RepoFile -Root $stage -Relative $i.Dest -Bytes $i.Bytes }
        foreach ($f in @(& (Join-Path $PSScriptRoot 'Test-NoSecrets.ps1') -Path $stage -PassThru)) {
            $where = if ($f.Line) { "$($f.File):$($f.Line)" } else { $f.File }
            $found.Add("${where}: $($f.Rule)")
        }
    }
    finally {
        $again = & $testPath -Path $name -Root $base -Relative -Detailed
        if ($again.IsValid -and $again.FullPath -eq $stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
    return , $found.ToArray()
}

function Get-EndpointListRow([string]$RepoPath) {
    $rows = [Collections.Generic.List[object]]::new()
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $files = [Collections.Generic.List[string]]::new()
    foreach ($folder in $script:EndpointFolders) {
        $full = Join-Path $RepoPath $folder
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $full -Recurse -File -Force)) {
            if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $files.Add(([IO.Path]::GetRelativePath($RepoPath, $f.FullName) -replace '\\', '/'))
        }
    }
    $manifests = Join-Path $RepoPath 'manifests'
    if (Test-Path -LiteralPath $manifests -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $manifests -File -Force -Filter '*.json')) {
            $rel = 'manifests/' + $f.Name
            if ($rel -ne $script:EndpointListPath) { $files.Add($rel) }
        }
    }
    # Ordinal order, so the list is the same on every machine and culture.
    $sorted = [string[]]@($files | Select-Object -Unique)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    foreach ($rel in $sorted) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $RepoPath $rel))
        try { $text = $utf8.GetString($bytes) } catch { continue }   # not text: holds no placeholder
        $names = Get-StackPlaceholder -Text $text
        if ($names.Count -gt 0) { $rows.Add([ordered]@{ file = $rel; placeholders = $names }) }
    }
    return , $rows.ToArray()
}

function Export-EndpointManifest {
    <#
    .SYNOPSIS
        Writes manifests/endpoints.json from the files in the repo, or with
        -Check only says whether it is current. Returns $true when the file
        is (now) current and was already, $false when it was written or is
        stale.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath,

        [switch]$Check
    )
    $RepoPath = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
    $doc = [ordered]@{
        '$schema'     = './schemas/endpoints.schema.json'
        formatVersion = 1
        note          = 'Written by tools/Sync-StackFiles.ps1. Every file below holds the placeholders listed; Stage 4a fills them from the new tailnet. Do not edit by hand.'
        files         = $null
    }
    $doc.files = Get-EndpointListRow $RepoPath
    $text = ($doc | ConvertTo-Json -Depth 6) -replace "`r`n", "`n"
    $text += "`n"
    $pathCheck = & (Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1') -Path $script:EndpointListPath -Root $RepoPath -Relative -Detailed
    if (-not $pathCheck.IsValid) { throw [InvalidOperationException]::new("$($script:EndpointListPath) refused ($($pathCheck.Reason))") }
    $path = $pathCheck.FullPath
    $current = if (Test-Path -LiteralPath $path -PathType Leaf) { ([IO.File]::ReadAllText($path)) -replace "`r`n", "`n" } else { $null }
    if ($current -ceq $text) { return $true }
    if (-not $Check) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }
    return $false
}

Export-ModuleMember -Function Get-TailnetEndpoint, ConvertTo-StackTemplate, ConvertFrom-StackTemplate, Get-StackPlaceholder, Find-TailnetAddress, Export-EndpointManifest,
    Write-RepoFile, Get-RepoFileStatus, Test-RepoContent, Select-PublicAddress
