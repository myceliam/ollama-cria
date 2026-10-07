#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 9: functional tests (docs/RESTORE.md Stage 9).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context, as the signed-in user. Needs Stage 8. It changes
    nothing on either machine.

    manifests/acceptance.json has one row per capability (C-46). Run needs
    the seed in the repo and OWUI accepting the API key Stage 7 left; then:

      1. Coverage. Every tool and function in the OWUI seed must be named by
         a row's 'covers', and every tool server the seed enables must match
         exactly one row's 'server'. A gap is a problem: add the row. A
         server row that matches no enabled server is skipped.
      2. Every auto row's probe, once: a request from this PC to 127.0.0.1
         or a tailnet address, a call to one of mcpo-core's servers, OWUI
         loading a tool's or function's code (which installs its
         requirements), or a request from the VPS to the PC (row group 12).
         Credentials come from the OWUI API key Stage 7 left and the .env
         files Stage 4 rendered. They stay in this process, and no answer is
         written down: only its HTTP status and whether it held what the row
         expects.
      3. One row per model preset in the seed. An active preset's tools,
         skills, filters and actions must be the seed's (each skill present,
         in the seed's on or off state), and it must answer a short prompt
         through OWUI's chat API, which saves no chat. A preset built on a
         pipe function (comfyui_studio) is not asked, because it makes
         media: that function's user row covers it. An inactive preset is
         not asked either.

    A failed row names the stage that owns it.

    Check is checkpoint 9: the results the last Run recorded, one check per
    group, and every user row accepted. The user rows are asked here, each
    with its id: do what it says, then run again with -Accept <id>,<id>...
    Check calls nothing again; run the stage again to test again (Stage 10
    does, after the reboot).
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
foreach ($k in @($Context.Data.Keys)) { $result.Data[$k] = $Context.Data[$k] }
$machine = $Context.Machine
$repo = $Context.RepoRoot
$owuiUrl = 'http://127.0.0.1:3000'
$mcpoUrl = 'http://127.0.0.1:18000'
$keyPath = Join-Path $Context.StagingRoot 'owui-api-key.txt'
$seedDir = Join-Path $repo 'manifests/owui-seed/seed'
$manifest = Get-Content -LiteralPath (Join-Path $repo 'manifests/acceptance.json') -Raw | ConvertFrom-Json -AsHashtable
$rows = @($manifest['rows'])
$alias = $Context.Topology['hosts']['vps']['sshAlias']
$stackRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['stack']['path']))

# What a probe's 'uses' names, besides the OWUI key: a value in a .env file
# Stage 4 rendered under the stack root, and the header it goes in.
$credentials = @{
    mcpo     = @{ File = '.env'; Name = 'MCPO_API_KEY'; Header = 'Authorization' }
    terminal = @{ File = '.env'; Name = 'OPEN_TERMINAL_API_KEY'; Header = 'Authorization' }
    pstool   = @{ File = '.env'; Name = 'WINDOWS_POWERSHELL_TOOL_TOKEN'; Header = 'Authorization' }
    gcal     = @{ File = 'gcal-owui-bridge/.env'; Name = 'GCAL_BRIDGE_API_KEY'; Header = 'X-API-Key' }
    gmail    = @{ File = 'gmail-owui-bridge/.env'; Name = 'GMAIL_BRIDGE_API_KEY'; Header = 'X-API-Key' }
}
$headerCache = @{}
$endpointCache = @{}

# ---------- helpers ----------

function Get-Field($Object, [string]$Name) {
    # A property of a parsed JSON object or a key of a hashtable, or $null.
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Read-Seed([string]$Name) {
    # One file of the seed, parsed, or $null when it is not there.
    $p = Join-Path $seedDir "$Name.json"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    return , (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate)
}

function Get-Seed {
    # The seed's tools, functions, model presets, skills and enabled tool
    # servers, or $null (with a problem) when the seed is not in the repo.
    $config = Read-Seed 'config'
    if ($null -eq $config) {
        $result.Problems.Add('manifests/owui-seed/seed is not in the repo yet: commit the seed from the first capture (docs/RESTORE.md 7d)')
        return $null
    }
    $servers = [Collections.Generic.List[object]]::new()
    $list = @($config['tool_server.connections'] | Where-Object { $null -ne $_ })
    for ($i = 0; $i -lt $list.Count; $i++) {
        $c = $list[$i]
        if ($c -isnot [Collections.IDictionary] -or $c['config'] -isnot [Collections.IDictionary] -or -not $c['config']['enable']) { continue }
        $info = if ($c['info'] -is [Collections.IDictionary]) { $c['info'] } else { @{} }
        $name = if ($info['name']) { [string]$info['name'] } elseif ($info['id']) { [string]$info['id'] } else { "connection $($i + 1)" }
        $servers.Add(@{ Name = $name; Url = [string]$c['url'] })
    }
    $table = { param($n) $t = Read-Seed $n; , @(if ($null -ne $t) { $t | Where-Object { $_ -is [Collections.IDictionary] } }) }
    return @{
        Tools     = (& $table 'tool')
        Functions = (& $table 'function')
        Models    = (& $table 'model')
        Skills    = (& $table 'skill')
        Servers   = $servers.ToArray()
    }
}

function Get-Coverage($Seed) {
    # Problems (C-46) and the server rows to skip: @{ Gaps; Skipped }.
    $gaps = [Collections.Generic.List[string]]::new()
    $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in $rows) { foreach ($c in @($r['covers'] | Where-Object { $_ })) { [void]$covered.Add([string]$c) } }
    $held = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($t in $Seed.Tools) { [void]$held.Add("tool:$($t['id'])") }
    foreach ($f in $Seed.Functions) { [void]$held.Add("function:$($f['id'])") }
    foreach ($h in ($held | Sort-Object)) {
        if (-not $covered.Contains($h)) { $gaps.Add("the seed's $($h -replace ':', ' ') has no row in acceptance.json") }
    }
    foreach ($c in ($covered | Sort-Object)) {
        if (-not $held.Contains($c)) { $gaps.Add("acceptance.json covers $($c -replace ':', ' '), which the seed does not hold") }
    }
    $serverRows = @($rows | Where-Object { $_['server'] })
    $matched = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($s in $Seed.Servers) {
        $hits = @($serverRows | Where-Object { $s.Url -match $_['server'] })
        if ($hits.Count -eq 0) { $gaps.Add("the seed's tool server '$($s.Name)' has no row in acceptance.json") }
        elseif ($hits.Count -gt 1) { $gaps.Add("the seed's tool server '$($s.Name)' matches more than one row: $(($hits | ForEach-Object { $_['id'] }) -join ', ')") }
        foreach ($h in $hits) { [void]$matched.Add([string]$h['id']) }
    }
    $skipped = @($serverRows | Where-Object { -not $matched.Contains([string]$_['id']) } | ForEach-Object { [string]$_['id'] })
    return @{ Gaps = $gaps.ToArray(); Skipped = $skipped }
}

function Read-ApiKey {
    # The key Stage 7 left, or $null with the reason in $script:keyWhy.
    $script:keyWhy = 'is empty'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { $script:keyWhy = 'is missing'; return $null }
    $text = [IO.File]::ReadAllText($keyPath).Trim()
    if (-not $text) { return $null }
    if ($text -notmatch '^sk-[A-Za-z0-9_-]{16,200}$') { $script:keyWhy = 'does not hold one OWUI API key (sk-...) alone'; return $null }
    return $text
}

function Read-EnvValue([string]$Path, [string]$Name) {
    # The last value of $Name in a .env file, unquoted, or $null.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $found = $null
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match ('^\s*(?:export\s+)?' + [regex]::Escape($Name) + '\s*=\s*(.*?)\s*$')) { $found = $Matches[1] }
    }
    if ($null -eq $found) { return $null }
    if ($found -match '^"(.*)"$' -or $found -match "^'(.*)'$") { $found = $Matches[1] }
    if (-not $found) { return $null }
    return $found
}

function Get-AuthHeader([string]$Uses) {
    # The headers a probe sends, or $null with the reason in $script:headerWhy.
    if (-not $Uses -or $Uses -eq 'none') { return @{} }
    if ($headerCache.ContainsKey($Uses)) { return $headerCache[$Uses] }
    if ($Uses -eq 'owui') {
        $value = Read-ApiKey
        $script:headerWhy = "the OWUI API key: $keyPath $script:keyWhy"
        $header = 'Authorization'
    }
    else {
        $c = $credentials[$Uses]
        $file = Join-Path $stackRoot $c.File
        $value = Read-EnvValue $file $c.Name
        $script:headerWhy = "$($c.Name) is not set in $file (Stage 4 renders it)"
        $header = $c.Header
    }
    if (-not $value) { return $null }
    $h = if ($header -eq 'Authorization') { @{ Authorization = "Bearer $value" } } else { @{ $header = $value } }
    $headerCache[$Uses] = $h
    return $h
}

function Expand-Url([string]$Url) {
    # The URL with {{PC_TS_IP}} and {{VPS_TS_IP}} filled in from Tailscale,
    # or $null with a problem when they cannot be read.
    if ($Url -notmatch '\{\{') { return $Url }
    if (-not $endpointCache.Count) {
        try {
            $e = Get-TailnetEndpoint -SshHost $alias -TailscaleCommand $machine.Commands['tailscale']
            $endpointCache['PC_TS_IP'] = $e['PC_TS_IP']
            $endpointCache['VPS_TS_IP'] = $e['VPS_TS_IP']
        }
        catch {
            $result.Problems.Add("tailnet: $($_.Exception.Message)")
            $endpointCache['failed'] = $true
        }
    }
    if ($endpointCache['failed']) { return $null }
    return ($Url -replace '\{\{PC_TS_IP\}\}', $endpointCache['PC_TS_IP'] -replace '\{\{VPS_TS_IP\}\}', $endpointCache['VPS_TS_IP'])
}

function Format-Value($Value) {
    # A field's value for the report, only when it is short and plain.
    if ($null -eq $Value) { return 'missing' }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return (ConvertTo-Json -InputObject $Value -Compress) }
    if ($Value -is [string] -and $Value -match '^[A-Za-z0-9_ .:-]{1,40}$') { return "'$Value'" }
    return 'something else'
}

function Get-AnswerProblem($Probe, $Answer) {
    # $null when the answer is what the probe expects, else why not. Never
    # quotes the answer.
    if ($Answer.Status -eq 0) { return 'nothing answered in time' }
    if ($Probe['anyStatus']) { return $null }
    $want = if ($Probe['status']) { [int]$Probe['status'] } else { 200 }
    if ($Answer.Status -ne $want) { return "HTTP $($Answer.Status)" }
    if ($Probe['contains'] -and -not ([string]$Answer.Body).Contains([string]$Probe['contains'], [StringComparison]::Ordinal)) {
        return "HTTP $($Answer.Status), but the answer lacks '$($Probe['contains'])'"
    }
    if ($Probe['fields']) {
        $json = try { ConvertFrom-Json -InputObject ([string]$Answer.Body) -AsHashtable -ErrorAction Stop } catch { $null }
        if ($json -isnot [Collections.IDictionary]) { return "HTTP $($Answer.Status), but the answer is not a JSON object" }
        foreach ($k in @($Probe['fields'].Keys | Sort-Object)) {
            $have = ConvertTo-Json -InputObject $json[$k] -Compress -Depth 5
            $allowed = @($Probe['fields'][$k] | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 5 })
            if ($allowed -cnotcontains $have) { return "HTTP $($Answer.Status), but $k is $(Format-Value $json[$k])" }
        }
    }
    return $null
}

function Invoke-Http([string]$Method, [string]$Url, [hashtable]$Headers, $Body, [int]$TimeoutSec) {
    if ($null -eq $Body) { return (& $machine.HttpCall $Method $Url $Headers -TimeoutSec $TimeoutSec) }
    return (& $machine.HttpCall $Method $Url $Headers (ConvertTo-Json -InputObject $Body -Compress -Depth 20) $TimeoutSec)
}

function Invoke-Probe($Row) {
    # $null when the row passes, else why not. $script:note may add detail.
    $script:note = $null
    $p = $Row['probe']
    $timeout = if ($p['timeoutSec']) { [int]$p['timeoutSec'] } else { 30 }
    switch ($p['type']) {
        'http' {
            $url = Expand-Url $p['url']
            if (-not $url) { return 'the tailnet addresses could not be read' }
            $headers = Get-AuthHeader $p['uses']
            if ($null -eq $headers) { return $script:headerWhy }
            $method = if ($p['method']) { [string]$p['method'] } else { 'GET' }
            $body = if ($p.ContainsKey('body')) { $p['body'] } else { $null }
            return (Get-AnswerProblem $p (Invoke-Http $method $url $headers $body $timeout))
        }
        'mcpo' {
            $headers = Get-AuthHeader 'mcpo'
            if ($null -eq $headers) { return $script:headerWhy }
            $server = [string]$p['server']
            if (-not $p['operation']) {
                $answer = Invoke-Http 'GET' "$mcpoUrl/$server/openapi.json" $headers $null $timeout
                $why = Get-AnswerProblem @{} $answer
                if ($why) { return $why }
                $spec = try { ConvertFrom-Json -InputObject ([string]$answer.Body) -AsHashtable -ErrorAction Stop } catch { $null }
                $n = if ($spec -is [Collections.IDictionary] -and $spec['paths'] -is [Collections.IDictionary]) { $spec['paths'].Count } else { 0 }
                if ($n -lt 1) { return 'it lists no tools' }
                $script:note = "$n tools"
                return $null
            }
            $body = if ($p.ContainsKey('body')) { $p['body'] } else { @{} }
            return (Get-AnswerProblem $p (Invoke-Http 'POST' "$mcpoUrl/$server/$($p['operation'])" $headers $body $timeout))
        }
        'owui-load' {
            $headers = Get-AuthHeader 'owui'
            if ($null -eq $headers) { return $script:headerWhy }
            $kind = if ($p['kind'] -eq 'tool') { 'tools' } else { 'functions' }
            return (Get-AnswerProblem @{} (Invoke-Http 'GET' "$owuiUrl/api/v1/$kind/id/$([uri]::EscapeDataString([string]$p['id']))/valves/spec" $headers $null 180))
        }
    }
    return "unknown probe type '$($p['type'])'"
}

function Add-RowResult($Results, [string]$Id, [int]$Group, [int]$Owner, [string]$Why, [string]$Note) {
    $ok = -not $Why
    $actual = if ($ok) { $(if ($Note) { $Note } else { 'passed' }) } else { $Why }
    $Results[$Id] = @{ group = $Group; owner = $Owner; ok = $ok; actual = $actual }
    if ($ok) { $result.Steps.Add("ok    ${Id}: $actual") }
    else {
        $result.Steps.Add("FAIL  ${Id}: $actual")
        $result.Problems.Add("$Id failed ($actual); Stage $Owner owns it")
    }
}

function Invoke-VpsRow($Results, $VpsRows) {
    # Every vps row in one SSH call to linux/stages/09-reach.sh.
    if (-not $VpsRows.Count) { return }
    $lines = [Collections.Generic.List[string]]::new()
    $names = @{}
    foreach ($r in $VpsRows) {
        $url = Expand-Url $r['probe']['url']
        if (-not $url) { Add-RowResult $Results $r['id'] $r['group'] $r['owner'] 'the tailnet addresses could not be read' $null; continue }
        $name = ([string]$r['id'] -replace '[^a-z0-9_-]', '_')
        $names[[string]$r['id']] = $name
        $lines.Add("$name $url")
    }
    if (-not $lines.Count) { return }
    $run = Invoke-VpsScript -Machine $machine -Alias $alias -Path (Join-Path $repo 'linux/stages/09-reach.sh') -InputLines $lines.ToArray()
    $facts = Add-VpsOutput -Result $result -Run $run -Label '09-reach.sh'
    foreach ($r in $VpsRows) {
        $id = [string]$r['id']
        if (-not $names.ContainsKey($id)) { continue }
        $p = $r['probe']
        $code = [string]$facts["reach_$($names[$id])"]
        $why = if ($code -notmatch '^[0-9]{3}$') { 'the VPS did not report it' }
        elseif ($code -eq '000') { 'nothing answered the VPS' }
        elseif ($p['anyStatus']) { $null }
        elseif ([int]$code -ne $(if ($p['status']) { [int]$p['status'] } else { 200 })) { "HTTP $code from the VPS" }
        else { $null }
        Add-RowResult $Results $id $r['group'] $r['owner'] $why "HTTP $code from the VPS"
    }
}

function Get-PipeOf($Model, [string[]]$Pipes) {
    # The pipe function a preset is built on, or $null.
    foreach ($id in @([string]$Model['id'], [string]$Model['base_model_id'])) {
        if (-not $id) { continue }
        foreach ($p in $Pipes) { if ($id -eq $p -or $id.StartsWith("$p.", [StringComparison]::Ordinal)) { return $p } }
    }
    return $null
}

function Get-AttachmentProblem($Model, $Seed, $Headers, $SkillState) {
    # $null when OWUI shows the preset with the seed's tools, skills, filters
    # and actions, and each of its skills as the seed has it.
    $id = [string]$Model['id']
    $answer = Invoke-Http 'GET' "$owuiUrl/api/v1/models/model?id=$([uri]::EscapeDataString($id))" $Headers $null 30
    $why = Get-AnswerProblem @{} $answer
    if ($why) { return "OWUI does not show it ($why)" }
    $have = try { ConvertFrom-Json -InputObject ([string]$answer.Body) -AsHashtable -ErrorAction Stop } catch { $null }
    $haveMeta = Get-Field $have 'meta'
    $seedMeta = $Model['meta']
    foreach ($k in 'toolIds', 'skillIds', 'filterIds', 'actionIds') {
        $a = @(@(Get-Field $seedMeta $k) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join "`n"
        $b = @(@(Get-Field $haveMeta $k) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join "`n"
        if ($a -cne $b) { return "its $k are not the seed's" }
    }
    foreach ($s in @(@(Get-Field $seedMeta 'skillIds') | Where-Object { $_ } | ForEach-Object { [string]$_ })) {
        $seedSkill = @($Seed.Skills | Where-Object { [string]$_['id'] -eq $s }) | Select-Object -First 1
        if (-not $seedSkill) { $result.Warnings.Add("preset $id names skill $s, which the seed does not hold; not checked"); continue }
        if (-not $SkillState.ContainsKey($s)) {
            $sa = Invoke-Http 'GET' "$owuiUrl/api/v1/skills/id/$([uri]::EscapeDataString($s))" $Headers $null 30
            $SkillState[$s] = if ($sa.Status -ne 200) { "HTTP $($sa.Status)" } else {
                $j = try { ConvertFrom-Json -InputObject ([string]$sa.Body) -AsHashtable -ErrorAction Stop } catch { $null }
                if ([bool](Get-Field $j 'is_active') -eq [bool]$seedSkill['is_active']) { 'ok' } else { 'switched the other way from the seed' }
            }
        }
        if ($SkillState[$s] -ne 'ok') { return "its skill $s is not as the seed has it ($($SkillState[$s]))" }
    }
    return $null
}

function Get-ChatProblem([string]$Id, $Headers) {
    # $null when the preset answers the prompt; never keeps the answer.
    $spec = $manifest['models']
    $body = @{ model = $Id; stream = $false; messages = @(@{ role = 'user'; content = [string]$spec['prompt'] }) }
    $answer = Invoke-Http 'POST' "$owuiUrl/api/chat/completions" $Headers $body ([int]$spec['timeoutSec'])
    $why = Get-AnswerProblem @{} $answer
    if ($why) { return $why }
    $json = try { ConvertFrom-Json -InputObject ([string]$answer.Body) -AsHashtable -ErrorAction Stop } catch { $null }
    $first = @(Get-Field $json 'choices') | Select-Object -First 1
    $text = [string](Get-Field (Get-Field $first 'message') 'content')
    if (-not $text.Trim()) { return 'HTTP 200, but no answer text' }
    return $null
}

function Invoke-ModelRow($Results, $Seed) {
    $spec = $manifest['models']
    $headers = Get-AuthHeader 'owui'
    $pipes = @($Seed.Functions | Where-Object { $_['type'] -eq 'pipe' } | ForEach-Object { [string]$_['id'] })
    $skillState = @{}
    foreach ($m in @($Seed.Models | Sort-Object { [string]$_['id'] })) {
        $id = [string]$m['id']
        $rowId = "model:$id"
        if (-not $m['is_active']) { Add-RowResult $Results $rowId $spec['group'] $spec['owner'] $null 'inactive in the seed; not asked'; continue }
        $pipe = Get-PipeOf $m $pipes
        if ($pipe) { Add-RowResult $Results $rowId $spec['group'] $spec['owner'] $null "built on the $pipe pipe; its user row tests it"; continue }
        if ($null -eq $headers) { Add-RowResult $Results $rowId $spec['group'] $spec['owner'] $script:headerWhy $null; continue }
        $why = Get-AttachmentProblem $m $Seed $headers $skillState
        if (-not $why) { $why = Get-ChatProblem $id $headers }
        Add-RowResult $Results $rowId $spec['group'] $spec['owner'] $why 'answered; tools and skills as seeded'
    }
}

function Get-GroupName([int]$Group) {
    $n = $manifest['groups']["$Group"]
    if ($n) { return "$Group $n" }
    return "$Group"
}

# ---------- main ----------

$userRows = @($rows | Where-Object { $_['who'] -eq 'user' })
$autoRows = @($rows | Where-Object { $_['who'] -eq 'auto' })

if ($Mode -eq 'Plan') {
    $seed = Get-Seed
    if ($seed) {
        $cover = Get-Coverage $seed
        foreach ($g in $cover.Gaps) { $result.Warnings.Add("would fail: $g") }
        $active = @($seed.Models | Where-Object { $_['is_active'] }).Count
        $result.Steps.Add("would check that acceptance.json covers the seed's $($seed.Tools.Count) tools, $($seed.Functions.Count) functions and $($seed.Servers.Count) enabled tool servers")
        $result.Steps.Add("would run $($autoRows.Count - $cover.Skipped.Count) auto rows and one row for each of the $($seed.Models.Count) model presets ($active active)")
    }
    else {
        foreach ($p in @($result.Problems)) { $result.Warnings.Add("would fail: $p") }
        $result.Problems.Clear()
    }
    $result.Steps.Add("would then ask for $($userRows.Count) user rows: $(($userRows | ForEach-Object { $_['id'] }) -join ', ')")
    $result.Status = 'planned'
    return $result
}

if ($Mode -eq 'Run') {
    $seed = Get-Seed
    if (-not $seed) { $result.Status = 'failed'; return $result }
    if ($null -eq (Get-AuthHeader 'owui')) {
        $result.Problems.Add("Stage 9 needs $($script:headerWhy). Create a key in OWUI (Settings > Account > API keys), paste it into that file alone, and run again.")
        $result.Status = 'failed'
        return $result
    }
    $open = Invoke-Http 'GET' "$owuiUrl/api/v1/tools/" (Get-AuthHeader 'owui') $null 30
    if ($open.Status -ne 200) {
        $result.Problems.Add("OWUI did not accept the API key in $keyPath ($(Get-AnswerProblem @{} $open)). Create a new key in OWUI (Settings > Account > API keys), replace the file's contents with it, and run again.")
        $result.Status = 'failed'
        return $result
    }
    $cover = Get-Coverage $seed
    foreach ($g in $cover.Gaps) { $result.Problems.Add("$g (C-46)") }
    foreach ($s in $cover.Skipped) { $result.Steps.Add("skip  ${s}: not a tool server the seed enables") }
    $results = [ordered]@{}
    $vpsRows = [Collections.Generic.List[object]]::new()
    foreach ($r in $autoRows) {
        if ($cover.Skipped -contains $r['id']) { continue }
        if ($r['probe']['type'] -eq 'vps') { $vpsRows.Add($r); continue }
        $why = Invoke-Probe $r
        Add-RowResult $results $r['id'] $r['group'] $r['owner'] $why $script:note
    }
    Invoke-VpsRow $results $vpsRows
    Invoke-ModelRow $results $seed
    $result.Data['Results'] = $results
    $result.Data['Gaps'] = @($cover.Gaps)
    $result.Data['Tested'] = [DateTime]::UtcNow.ToString('o')
    if ($result.Problems.Count) { $result.Status = 'failed' }
    return $result
}

# Check: the recorded results, by group, and the user rows.
$results = $Context.Data['Results']
if ($results -isnot [Collections.IDictionary] -or -not $results.Count) {
    Add-StageCheck $result 'Stage 9 has run its probes' 'yes' 'no' $false
    return $result
}
$gaps = @($Context.Data['Gaps'] | Where-Object { $_ })
Add-StageCheck $result 'acceptance.json covers every tool, function and tool server in the seed (C-46)' 'all' $(if ($gaps.Count) { "$($gaps.Count) gaps" } else { 'all' }) ($gaps.Count -eq 0)
$failed = $false
$waiting = [Collections.Generic.List[string]]::new()
$groups = @(@($results.Values | ForEach-Object { [int]$_['group'] }) + @($userRows | ForEach-Object { [int]$_['group'] }) | Sort-Object -Unique)
foreach ($g in $groups) {
    $bad = [Collections.Generic.List[string]]::new()
    $n = 0
    foreach ($id in @($results.Keys)) {
        $r = $results[$id]
        if ([int]$r['group'] -ne $g) { continue }
        $n++
        if (-not $r['ok']) { $bad.Add("$id failed"); $failed = $true }
    }
    foreach ($u in @($userRows | Where-Object { [int]$_['group'] -eq $g })) {
        $n++
        if ($Context.Accepted -notcontains $u['id']) { $bad.Add("$($u['id']) waits on you"); $waiting.Add([string]$u['id']) }
    }
    Add-StageCheck $result (Get-GroupName $g) "$n of $n" "$($n - $bad.Count) of $n$(if ($bad.Count) { "; $($bad -join ', ')" })" ($bad.Count -eq 0)
}
foreach ($u in $userRows) {
    if ($waiting -notcontains $u['id']) { continue }
    Add-StageAsk $result "$($u['steps']) Then run again with -Accept $($u['id'])." -Id $u['id']
}
if ($waiting.Count -gt 1) { $result.Steps.Add("to answer every question at once: -Accept $($waiting -join ',')") }
$result.Status = if ($failed -or $gaps.Count) { 'failed' } elseif ($waiting.Count) { 'needs-user' } else { 'passed' }
return $result
