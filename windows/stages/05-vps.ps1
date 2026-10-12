#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 5: the VPS guard, web egress, Kokoro and the Groq STT relay
    (docs/RESTORE.md Stage 5).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context. Needs Stage 4 (the VPS files rendered under
    <state root>\rendered, and the egress .env placed on the VPS).

    Run:

      Place  Every file Stage 4 rendered for a VPS source goes to that
             source's folder on the VPS (manifests/stack-files.json), the
             guard's unit also to /etc/systemd/system, and the restore-only
             files in linux/files/web-egress (the searxng-mcp build and its
             compose override, R-13) into the egress folder. Files under
             /home/<account> belong to the account (scripts 0755, the rest
             0644); files under /etc to root (0644). linux/stages/05-place.sh
             writes them: never through a link, never over a file it did not
             write.
      Start  linux/stages/05-services.sh: the guard first, proved loaded,
             and Docker made to need it (C-20, C-43); then every image the
             two compose projects use, pulled at its digest from
             manifests/images.json and tagged as the compose file names it,
             or built (the hardened Jina Reader, searxng-mcp); then
             owui-web-egress and kokoro with nothing else pulled, waiting
             until healthy; then only the Groq relay site in nginx.

    Check is checkpoint 5: the guard is enabled, active and loaded, and
    Docker needs it; every service runs and gluetun is healthy; the exit
    address inside the tunnel differs from the VPS's own; Kokoro, the relay
    and the gateway listen on the tailnet address only; nginx's
    configuration passes; and from this PC the gateway is healthy, Kokoro
    lists its model and a SearXNG search returns results. The kill-switch
    test is Stage 10's.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Run', 'Check')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../tools/RecoveryState.psm1')
Import-Module (Join-Path $PSScriptRoot '../../tools/RecoveryVps.psm1')
Import-Module $Context.Tools.StackCapture

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
$machine = $Context.Machine
$repo = $Context.RepoRoot
$alias = $Context.Topology['hosts']['vps']['sshAlias']
$account = $Context.Topology['hosts']['vps']['user']
$renderRoot = Join-Path $Context.StateRoot 'rendered'
$stages = Join-Path $repo 'linux/stages'
$sources = @((Get-Content -LiteralPath (Join-Path $repo 'manifests/stack-files.json') -Raw | ConvertFrom-Json -AsHashtable)['sources'] |
        Where-Object { $_['host'] -eq 'vps' })
$egressRoot = @($sources | Where-Object { $_['name'] -eq 'vps-egress' })[0]['root']
$projects = 'owui-web-egress', 'kokoro'
$guardUnit = 'owui-web-egress-guard.service'

# Images built on the VPS instead of pulled, by container: the hardened Jina
# Reader from the captured build folder, and searxng-mcp from the
# restore-only one (R-13).
$builds = @{
    'vps-web-jina-reader' = @{ Folder = "$egressRoot/jina-official" }
    'vps-web-searxng-mcp' = @{ Tag = 'searxng-mcp:1.6.0'; Folder = "$egressRoot/searxng-mcp" }
}

function Get-PlacedFile {
    # Every file this stage places: where it is on this PC, where it goes,
    # its mode and owner. Records a problem for any that is missing.
    $files = [Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Local, [string]$Remote)
        $inHome = $Remote.StartsWith("/home/$account/")
        $files.Add([pscustomobject]@{
                Local  = $Local
                Remote = $Remote
                Mode   = $(if ($inHome -and $Remote.EndsWith('.sh')) { '0755' } else { '0644' })
                Owner  = $(if ($inHome) { $account } else { 'root' })
            })
    }
    foreach ($s in $sources) {
        foreach ($f in @($s['files'])) {
            $local = Join-Path (Join-Path $renderRoot $s['name']) $f
            if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { $result.Problems.Add("$($local): not rendered; Stage 4 writes it"); continue }
            & $add $local "$($s['root'].TrimEnd('/'))/$f"
            if ($s['name'] -eq 'vps-egress' -and $f -eq $guardUnit) { & $add $local "/etc/systemd/system/$guardUnit" }
        }
    }
    $extra = Join-Path $repo 'linux/files/web-egress'
    foreach ($f in Get-ChildItem -LiteralPath $extra -Recurse -File | Sort-Object FullName) {
        & $add $f.FullName "$egressRoot/$([IO.Path]::GetRelativePath($extra, $f.FullName) -replace '\\', '/')"
    }
    return , $files.ToArray()
}

function Get-ImageLine {
    # 'pull <ref@digest> <tag or ->' or 'build <tag> <folder>' for every
    # container of the two VPS projects.
    $vps = @((Get-Content -LiteralPath (Join-Path $repo 'manifests/images.json') -Raw | ConvertFrom-Json -AsHashtable)['vps'] |
            Where-Object { $_['project'] -in $projects })
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($i in ($vps | Sort-Object { $_['container'] })) {
        $b = $builds[$i['container']]
        if ($b) {
            $tag = if ($b['Tag']) { $b['Tag'] } else { $i['image'] }
            $lines.Add("build $tag $($b['Folder'])")
            continue
        }
        $ref = @($i['repoDigests'])[0]
        if ($ref -notmatch '@sha256:[0-9a-f]{64}$') { $result.Problems.Add("$($i['container']): manifests/images.json has no registry digest to pull"); continue }
        $tag = if ($i['image'] -match '@|^sha256:') { '-' } else { $i['image'] }
        $line = "pull $ref $tag"
        if (-not $lines.Contains($line)) { $lines.Add($line) }
    }
    return , $lines.ToArray()
}

function Get-Endpoint {
    try { return Get-TailnetEndpoint -SshHost $alias -TailscaleCommand $machine.Commands['tailscale'] }
    catch { $result.Problems.Add("tailnet: $($_.Exception.Message)"); return $null }
}

function Invoke-Place($Files) {
    $lines = foreach ($f in $Files) {
        $bytes = [IO.File]::ReadAllBytes($f.Local)
        $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $path = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($f.Remote))
        "$path $($f.Mode) $($f.Owner) $sha $([Convert]::ToBase64String($bytes))"
    }
    $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path (Join-Path $stages '05-place.sh') -Arguments @($account) -InputLines @($lines)
    $null = Add-VpsOutput -Result $result -Run $run -Label '05-place.sh'
    $counts = [ordered]@{}
    foreach ($l in @($run.Output)) {
        if ($l -match '^PLACED (new|same|replaced) ') { $counts[$Matches[1]] = 1 + $(if ($counts.Contains($Matches[1])) { $counts[$Matches[1]] } else { 0 }) }
    }
    $summary = ($counts.Keys | ForEach-Object { "$($counts[$_]) $_" }) -join ', '
    $result.Steps.Add("placed $($Files.Count) files on the VPS: $(if ($summary) { $summary } else { 'none confirmed' })")
    $result.Data['Placed'] = [int]@($run.Output -match '^PLACED ').Count
    # Whether a running guard has to restart to load what was just written.
    $guardFiles = "$egressRoot/guard.sh", "$egressRoot/guard.nft", "/etc/systemd/system/$guardUnit"
    return [bool]@(@($run.Output) | Where-Object { $_ -match '^PLACED (new|replaced) (.+)$' -and $Matches[2] -in $guardFiles }).Count
}

function Invoke-Curl([string]$Url) {
    $r = & $machine.Exec 'curl' @('-fsS', '--max-time', '20', $Url)
    return [pscustomobject]@{ Ok = $r.ExitCode -eq 0; Text = (@($r.Output) -join "`n") }
}

function Test-Checkpoint {
    $endpoint = Get-Endpoint
    if (-not $endpoint) { Add-StageCheck $result 'the VPS is in the tailnet' 'yes' 'no' $false; return }
    $ip = $endpoint['VPS_TS_IP']
    $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path (Join-Path $stages '05-services.sh') -Arguments @('check', $account, $ip)
    $f = Add-VpsOutput -Result $result -Run $run -Label '05-services.sh'
    if ($run.ExitCode -ne 0) { Add-StageCheck $result 'the VPS answers over ssh as root (sudo -n)' 'yes' "exit $($run.ExitCode)" $false; return }
    $get = { param($Name) if ($f.ContainsKey($Name)) { $f[$Name] } else { 'not reported' } }
    $all = { param($Name) $v = & $get $Name; $v -match '^([1-9][0-9]*)/([0-9]+)$' -and $Matches[1] -eq $Matches[2] }
    Add-StageCheck $result 'guard unit enabled and active' 'yes, yes' "$(& $get 'guard-enabled'), $(& $get 'guard-active')" ((& $get 'guard-enabled') -eq 'yes' -and (& $get 'guard-active') -eq 'yes')
    Add-StageCheck $result "guard's nftables table and routing rules (IPv4 5260, IPv6 block 5265) loaded" 'yes, yes' "$(& $get 'nft-table'), $(& $get 'ip-rule')" ((& $get 'nft-table') -eq 'yes' -and (& $get 'ip-rule') -eq 'yes')
    Add-StageCheck $result 'Docker needs the guard (Requires= and After=)' 'yes' (& $get 'docker-needs-guard') ((& $get 'docker-needs-guard') -eq 'yes')
    Add-StageCheck $result 'owui-web-egress: every service running' 'all' (& $get 'egress-running') (& $all 'egress-running')
    Add-StageCheck $result 'gluetun' 'healthy' (& $get 'gluetun-health') ((& $get 'gluetun-health') -eq 'healthy')
    Add-StageCheck $result 'kokoro: every service running' 'all' (& $get 'kokoro-running') (& $all 'kokoro-running')
    Add-StageCheck $result "exit address inside the tunnel vs the VPS's own" 'differs' (& $get 'exit-ip') ((& $get 'exit-ip') -eq 'differs')
    foreach ($p in @(@{ Port = '8880'; Name = 'Kokoro' }, @{ Port = '18099'; Name = 'Groq STT relay' }, @{ Port = '13100'; Name = 'Brave/Jina gateway' })) {
        $v = & $get "listen-$($p.Port)"
        Add-StageCheck $result "$($p.Name) ($($p.Port)) listens on the tailnet address only" 'tailnet-only' $v ($v -eq 'tailnet-only')
    }
    Add-StageCheck $result 'nginx: Groq relay site on, configuration passes' 'yes, ok' "$(& $get 'nginx-site'), $(& $get 'nginx-test')" ((& $get 'nginx-site') -eq 'yes' -and (& $get 'nginx-test') -eq 'ok')

    $health = Invoke-Curl "http://${ip}:13100/health"
    Add-StageCheck $result 'from this PC: the gateway''s /health' 'answers' $(if ($health.Ok) { 'answers' } else { 'no answer' }) $health.Ok
    $models = Invoke-Curl "http://${ip}:8880/v1/models"
    $kokoro = $models.Ok -and $models.Text -match 'kokoro'
    Add-StageCheck $result 'from this PC: Kokoro lists its model' 'kokoro' $(if ($kokoro) { 'kokoro' } elseif ($models.Ok) { 'no kokoro model' } else { 'no answer' }) $kokoro
    $search = Invoke-Curl "http://${ip}:18080/search?q=open+source+software&format=json"
    $hits = 0
    if ($search.Ok) { try { $hits = @(($search.Text | ConvertFrom-Json).results).Count } catch { $hits = 0 } }
    Add-StageCheck $result 'from this PC: a SearXNG search returns results' 'some' "$hits" ($hits -gt 0)
}

if ($Mode -eq 'Check') {
    Test-Checkpoint
    if ($result.Problems.Count -and $result.Status -eq 'passed') { $result.Status = 'failed' }
    return $result
}

$files = Get-PlacedFile
$images = Get-ImageLine
if ($result.Problems.Count -eq 0) {
    $pulls = @($images | Where-Object { $_ -like 'pull *' }).Count
    $made = @($images | Where-Object { $_ -like 'build *' }).Count
    if ($Mode -eq 'Plan') {
        $result.Steps.Add("would place $($files.Count) files on the VPS, never over one this stage did not write")
        $result.Steps.Add("would load the guard and make Docker need it, then pull $pulls images at their digests and build $made")
        $result.Steps.Add("would start $($projects -join ' and ') with nothing else pulled, then switch on only the Groq relay site in nginx")
    }
    else {
        $endpoint = Get-Endpoint
        if ($endpoint) {
            $guardChanged = Invoke-Place $files
            if ($result.Problems.Count -eq 0) {
                $arguments = @('run', $account, $endpoint['VPS_TS_IP']) + @(if ($guardChanged) { 'guard-changed' })
                $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path (Join-Path $stages '05-services.sh') -Arguments $arguments -InputLines $images
                $null = Add-VpsOutput -Result $result -Run $run -Label '05-services.sh'
            }
        }
    }
}

if ($Mode -eq 'Plan') { $result.Status = 'planned' }
elseif ($result.Problems.Count) { $result.Status = 'failed' }
return $result
