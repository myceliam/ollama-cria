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
      Get-StackPlaceholder    the endpoint placeholders a text holds
      Export-EndpointManifest writes manifests/endpoints.json: every templated
                              file in the folders that are deployed or read by
                              a stage, and the placeholders it holds
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Endpoint placeholders only. Other {{...}} text (Go templates such as
# {{.Names}}, Jinja) is never touched.
$script:EndpointName = '^(?:[A-Z][A-Z0-9_]*_TS_(?:IP|IP6|NAME)|TS_DOMAIN)$'
$script:Placeholder = '\{\{([A-Z][A-Z0-9_]*)\}\}'

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

function Get-EndpointRegex([string]) {
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

function ConvertTo-StackTemplate {
    <#
    .SYNOPSIS
        Swaps every endpoint value in -Text for its {{NAME}}. Returns the new
        text and the placeholders it now holds. Throws, naming the
        placeholder, when the text already holds one, because it would be
        filled in at restore time.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [Collections.IDictionary]$Endpoint
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
    return [pscustomobject]@{ Text = $Text; Placeholders = (Get-StackPlaceholder -Text $Text) }
}

function ConvertFrom-StackTemplate {
    <#
    .SYNOPSIS
        Fills every endpoint placeholder in -Text from -Endpoint (Stage 4a).
        Throws, naming it, on a placeholder with no value.
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
    foreach ($name in (Get-StackPlaceholder -Text $Text)) {
        if (-not $Endpoint.Contains($name) -or -not [string]$Endpoint[$name]) {
            throw [InvalidOperationException]::new("{{$name}} has no value; is that node in the tailnet under the same name?")
        }
    }
    return [regex]::Replace($Text, $script:Placeholder, {
            param($m)
            $name = $m.Groups[1].Value
            if ($name -match $script:EndpointName) { return [string]$Endpoint[$name] }
            return $m.Value
        })
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
    foreach ($rel in ($files | Sort-Object -Unique -CaseSensitive)) {
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

Export-ModuleMember -Function Get-TailnetEndpoint, ConvertTo-StackTemplate, ConvertFrom-StackTemplate, Get-StackPlaceholder, Export-EndpointManifest
