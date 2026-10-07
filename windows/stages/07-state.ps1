#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 7: images, volumes, service state and the OWUI functional seed
    (docs/RESTORE.md Stage 7).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context. Needs Stages 5 and 6, and the seed committed in
    manifests/owui-seed/seed.

    Run, in up to three visits, because two steps need a person:

      7a  Every image of the PC compose projects (manifests/topology.json):
          the projects' own builds first, then every other image pulled at
          its digest and tagged as the compose file names it: OWUI at the
          digest the seed records (C-40), the rest from
          manifests/images.json. Nothing is created until every image is
          there (C-36).
      7b  The volume owui-data, created with the label ollama-cria.stage=7
          (an owui-data this stage did not create is refused, never used or
          removed), then 'docker compose create' for each project: volumes,
          networks and containers, nothing started.
      7c  tools/Restore-StackSecrets.ps1 places bundle folder 07 (ntfy's
          user.db, Bolt's server keys) into their volumes.
      7d  OWUI is started alone (no dependencies) on 127.0.0.1:3000. With no
          account yet, the stage asks a person to create the admin account
          and stops. Next visit: OWUI is stopped and tools/Import-OwuiSeed.py
          runs in a container of the same image with the seed, the folder-03
          secrets and the new tailnet addresses on its standard input, never
          on a command line.
      7e  OWUI is started alone again. The stage writes an empty owner-only
          owui-api-key.txt in the staging folder and asks a person to paste
          a new API key into it. Next visit: the key must open OWUI's
          calendar API (what the gcal bridge uses); then it goes into every
          file in manifests/owui-api-consumers.json, and OWUI is stopped.
          Nothing runs until Stage 8.

    Check is checkpoint 7: every image is there, OWUI's at the seed's digest;
    owui-data is this stage's; bundle folder 07 was placed; in OWUI's
    database every seeded table holds the seed's row count, no {{OWNER}} or
    {{BUNDLE:...}} is left, there is one account, and SQLite's integrity and
    foreign-key checks pass; every API key consumer holds a key, and the key
    opened OWUI when it was placed.
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
Import-Module (Join-Path $PSScriptRoot '../../tools/RecoveryHost.psm1')
Import-Module $Context.Tools.StackCapture

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
foreach ($k in @($Context.Data.Keys)) { $result.Data[$k] = $Context.Data[$k] }
$machine = $Context.Machine
$repo = $Context.RepoRoot
$alias = $Context.Topology['hosts']['vps']['sshAlias']
$stage1 = $Context.State['stages']['1']
$bundleData = if ($stage1 -is [hashtable] -and $stage1['data'] -is [hashtable]) { $stage1['data'] } else { @{} }
$owuiUrl = 'http://127.0.0.1:3000'
$volumeLabel = 'ollama-cria.stage'
$keyPath = Join-Path $Context.StagingRoot 'owui-api-key.txt'
$seedDir = Join-Path $repo 'manifests/owui-seed/seed'
$seedNames = 'access_grant', 'config', 'function', 'group', 'group_member', 'model', 'prompt', 'provenance', 'secret_refs', 'skill', 'tool', 'user_settings'
$seededTables = 'tool', 'function', 'model', 'skill', 'prompt', 'group', 'group_member', 'access_grant'
$images = Get-Content -LiteralPath (Join-Path $repo 'manifests/images.json') -Raw | ConvertFrom-Json -AsHashtable
$consumers = @((Get-Content -LiteralPath (Join-Path $repo 'manifests/owui-api-consumers.json') -Raw | ConvertFrom-Json -AsHashtable)['consumers'])
$projects = @($Context.Topology['composeProjects'] | Where-Object {
        $r = $Context.Topology['roots'][$_['root']]
        $r -and $r['host'] -eq 'pc'
    })
$owuiProject = @($projects | Where-Object { $_['name'] -eq 'ollama' })[0]

# Runs inside a container of the OWUI image, read-only against its
# database; the script travels on standard input. It prints one JSON line of
# counts and flags, never a value.
$verifyScript = @'
import json, sqlite3
db = sqlite3.connect('file:/app/backend/data/webui.db?mode=ro', uri=True)
tables = ['tool', 'function', 'model', 'skill', 'prompt', 'group', 'group_member', 'access_grant']
names = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
counts, left = {}, 0
for t in tables:
    if t not in names:
        counts[t] = -1
        continue
    counts[t] = db.execute('SELECT count(*) FROM "%s"' % t).fetchone()[0]
    for col in [r[1] for r in db.execute('PRAGMA table_info("%s")' % t)]:
        q = 'SELECT count(*) FROM "%s" WHERE CAST("%s" AS TEXT) LIKE ? OR CAST("%s" AS TEXT) LIKE ?' % (t, col, col)
        left += db.execute(q, ('%{{OWNER}}%', '%{{BUNDLE:%')).fetchone()[0]
users = db.execute('SELECT count(*) FROM user').fetchone()[0] if 'user' in names else -1
print(json.dumps({'counts': counts, 'left': left, 'users': users,
                  'integrity': db.execute('PRAGMA integrity_check').fetchone()[0],
                  'fk': len(db.execute('PRAGMA foreign_key_check').fetchall())}))
'@

# ---------- helpers ----------

function Get-ComposeArgument($Project) {
    $root = $Context.Topology['roots'][$Project['root']]
    $file = [IO.Path]::GetFullPath((Join-Path ([Environment]::ExpandEnvironmentVariables($root['path'])) $Project['file']))
    return @('compose', '-p', $Project['name'], '-f', $file, '--project-directory', [IO.Path]::GetDirectoryName($file))
}

function Invoke-Docker([string[]]$Arguments) { & $machine.Exec 'docker' $Arguments }

function Test-Image([string]$Reference) { (Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $Reference)).ExitCode -eq 0 }

function Read-Seed {
    if (-not (Test-Path -LiteralPath $seedDir -PathType Container)) {
        $result.Problems.Add('manifests/owui-seed/seed is not in the repo yet: commit the seed from the first capture (docs/RESTORE.md 7d)')
        return $null
    }
    $files = [ordered]@{}
    $missing = @($seedNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $seedDir "$_.json") -PathType Leaf) })
    if ($missing.Count) { $result.Problems.Add("manifests/owui-seed/seed lacks $($missing -join ', ') (.json)"); return $null }
    foreach ($n in $seedNames) { $files["$n.json"] = [IO.File]::ReadAllText((Join-Path $seedDir "$n.json")) }
    try { $prov = $files['provenance.json'] | ConvertFrom-Json -AsHashtable }
    catch { $result.Problems.Add('manifests/owui-seed/seed/provenance.json is not valid JSON'); return $null }
    if ("$($prov['image_digest'])" -notmatch '^ghcr\.io/open-webui/open-webui@sha256:[0-9a-f]{64}$') {
        $result.Problems.Add('the seed records no OWUI image digest (provenance.json image_digest); OWUI must start at the version the seed came from (C-40)')
        return $null
    }
    return @{ Files = $files; Provenance = $prov }
}

function Get-PullSource([string]$Reference, $Seed) {
    # A reference with a registry digest for an image a compose file names.
    if ($Reference -like 'ghcr.io/open-webui/open-webui:*' -or $Reference -like 'ghcr.io/open-webui/open-webui@*') { return $Seed.Provenance['image_digest'] }
    if ($Reference -match '@sha256:[0-9a-f]{64}$') { return $Reference }
    $repoName = $Reference -replace ':[^/:]+$', ''
    foreach ($i in @($images['pc'])) {
        if ($i['image'] -ne $Reference) { continue }
        $d = @($i['repoDigests'])[0]
        if ($d -and $d -match '^(.+)@sha256:[0-9a-f]{64}$' -and $Matches[1] -eq $repoName) { return $d }
    }
    return $null
}

function Get-ProjectImage($Project) {
    $r = Invoke-Docker ((Get-ComposeArgument $Project) + @('config', '--images'))
    if ($r.ExitCode -ne 0) { $result.Problems.Add("$($Project['name']): 'docker compose config' failed (exit $($r.ExitCode)); are its files and .env in place (Stage 4)?"); return $null }
    return , [string[]]@($r.Output | Where-Object { $_ -match '^[a-z0-9][a-z0-9./_:@-]*$' } | Sort-Object -Unique)
}

function Install-Image($Seed) {
    # 7a. Returns $true when every image of every project is present.
    $all = $true
    foreach ($p in $projects) {
        $refs = Get-ProjectImage $p
        if ($null -eq $refs) { $all = $false; continue }
        $missing = @($refs | Where-Object { -not (Test-Image $_) })
        if (-not $missing.Count) { $result.Steps.Add("$($p['name']): all $($refs.Count) images present"); continue }
        $build = Invoke-Docker ((Get-ComposeArgument $p) + @('build', '--quiet'))
        if ($build.ExitCode -ne 0) { $result.Problems.Add("$($p['name']): 'docker compose build' failed (exit $($build.ExitCode))"); $all = $false; continue }
        $pulled = 0
        foreach ($ref in @($missing | Where-Object { -not (Test-Image $_) })) {
            $source = Get-PullSource $ref $Seed
            if (-not $source) { $result.Problems.Add("$($ref): not built by its project and no pinned digest to pull (manifests/images.json)"); $all = $false; continue }
            if (-not (Test-Image $source)) {
                $pull = Invoke-Docker @('pull', '--quiet', $source)
                if ($pull.ExitCode -ne 0) { $result.Problems.Add("$($source): could not pull it (exit $($pull.ExitCode))"); $all = $false; continue }
            }
            if ($source -ne $ref) {
                $tag = Invoke-Docker @('tag', $source, $ref)
                if ($tag.ExitCode -ne 0) { $result.Problems.Add("$($ref): could not tag $source as it"); $all = $false; continue }
            }
            $pulled++
        }
        $result.Steps.Add("$($p['name']): built its own images, pulled $pulled at their digests")
    }
    return $all
}

function Test-OwnVolume {
    # $true when owui-data exists with this stage's label, $false when it is
    # missing, $null (and a problem) when it is someone else's.
    $r = Invoke-Docker @('volume', 'inspect', '--format', '{{json .Labels}}', 'owui-data')
    if ($r.ExitCode -ne 0) { return $false }
    $labels = $null
    try { $labels = ((@($r.Output) -join '') | ConvertFrom-Json -AsHashtable) } catch { $labels = $null }
    if ($labels -is [hashtable] -and $labels[$volumeLabel] -eq '7') { return $true }
    $result.Problems.Add("the Docker volume owui-data already exists and this stage did not create it. OWUI needs a new, empty one; if nothing in it is needed, remove it ('docker volume rm owui-data') and run again")
    return $null
}

function Initialize-Volume {
    # 7b.
    $own = Test-OwnVolume
    if ($null -eq $own) { return $false }
    if (-not $own) {
        $r = Invoke-Docker @('volume', 'create', '--label', "$volumeLabel=7", 'owui-data')
        if ($r.ExitCode -ne 0) { $result.Problems.Add("could not create the volume owui-data (exit $($r.ExitCode))"); return $false }
        $result.Steps.Add('created the volume owui-data')
    }
    foreach ($p in $projects) {
        $r = Invoke-Docker ((Get-ComposeArgument $p) + @('create', '--pull', 'never', '--no-build', '--no-recreate'))
        if ($r.ExitCode -ne 0) { $result.Problems.Add("$($p['name']): 'docker compose create' failed (exit $($r.ExitCode))"); return $false }
    }
    $result.Steps.Add("created the volumes and containers of $(@($projects | ForEach-Object { $_['name'] }) -join ', '); nothing started")
    return $true
}

function Get-HelperImage {
    $relay = @($images['pc'] | Where-Object { $_['container'] -eq 'web-vps-relay' })[0]
    if ($relay -and "$($relay['image'])" -match '@sha256:[0-9a-f]{64}$') { return $relay['image'] }
    return $null
}

function Restore-ServiceState {
    # 7c.
    $zip = $bundleData['BundlePath']
    $sha = $bundleData['BundleSha256']
    if (-not $zip -or -not $sha) { $result.Problems.Add('Stage 1 has not recorded the bundle'); return $false }
    $helper = Get-HelperImage
    if (-not $helper) { $result.Problems.Add('manifests/images.json gives web-vps-relay no pinned python image to use as the volume helper'); return $false }
    $r = & $Context.Tools.RestoreSecrets -ZipPath $zip -Sha256 $sha -Folder '07' -Execute -PassThru -DockerCommand $machine.Commands['docker'] -HelperImage $helper
    foreach ($w in @($r.Warnings)) { $result.Warnings.Add("service state: $w") }
    foreach ($p in @($r.Problems)) { $result.Problems.Add("service state: $p") }
    $rows = @($r.Rows | Where-Object { $_.Folder -eq '07' })
    $placed = @($rows | Where-Object { $_.Status -in 'placed', 'already in place' })
    $result.Data['ServiceState'] = [string[]]@($placed | ForEach-Object Id)
    $result.Steps.Add("service state: $($placed.Count) of $($rows.Count) files in their volumes (bundle folder 07)")
    return ($r.IsValid -and $placed.Count -eq $rows.Count)
}

function Open-Owui {
    $r = Invoke-Docker ((Get-ComposeArgument $owuiProject) + @('up', '-d', '--no-deps', '--pull', 'never', 'open-webui'))
    if ($r.ExitCode -ne 0) { $result.Problems.Add("could not start OWUI alone (exit $($r.ExitCode))"); return $false }
    foreach ($i in 1..36) {
        $h = & $machine.HttpJson "$owuiUrl/health"
        if ($h) { return $true }
        & $machine.Wait 5
    }
    $result.Problems.Add("OWUI started but $owuiUrl/health did not answer within 3 minutes ('docker logs open-webui' says why)")
    return $false
}

function Close-Owui {
    $r = Invoke-Docker ((Get-ComposeArgument $owuiProject) + @('stop', 'open-webui'))
    if ($r.ExitCode -ne 0) { $result.Problems.Add("could not stop OWUI (exit $($r.ExitCode))"); return $false }
    return $true
}

function Invoke-InOwui([string]$Boot, [string]$InputText) {
    # A python3 program in a new container of the OWUI service: its volume
    # and environment, no dependencies, no ports, removed afterwards.
    $arguments = (Get-ComposeArgument $owuiProject) + @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'python3', 'open-webui', '-c', $Boot)
    & $machine.ExecInput 'docker' $arguments $InputText
}

function Get-SeedState($Seed) {
    # The verify script's answer, or $null.
    $r = Invoke-InOwui 'import sys;exec(sys.stdin.read())' ($verifyScript -replace "`r", '')
    if ($r.ExitCode -ne 0) { return $null }
    $line = @($r.Output | Where-Object { $_ -like '{*' })[-1]
    if (-not $line) { return $null }
    try { $s = $line | ConvertFrom-Json -AsHashtable } catch { return $null }
    $want = $Seed.Provenance['counts']
    $s['match'] = $true
    foreach ($t in $seededTables) { if ([int]$s['counts'][$t] -ne [int]$want[$t]) { $s['match'] = $false } }
    return $s
}

function Get-BundleSecretText {
    $root = $bundleData['BundleRoot']
    if (-not $root) { $result.Problems.Add('Stage 1 has not recorded the unpacked bundle'); return $null }
    $mapPath = Join-Path $root '00-RESTORE-MAP.json'
    if (-not (Test-Path -LiteralPath $mapPath -PathType Leaf)) { $result.Problems.Add('the unpacked bundle has no 00-RESTORE-MAP.json'); return $null }
    $entry = @((Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json -AsHashtable)['entries'] | Where-Object { $_['id'] -eq 'owui-seed-secrets' })[0]
    if (-not $entry) { $result.Problems.Add('the bundle has no owui-seed-secrets row (folder 03)'); return $null }
    $path = Join-Path (Join-Path $root '03') ($entry['file'] -replace '\\', '/')
    $check = & $Context.PathCheck -Path $path -Root $root -Detailed
    if (-not @($check)[0].IsValid -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $result.Problems.Add('bundle folder 03: the OWUI secrets file is missing or fails the path check'); return $null }
    return [IO.File]::ReadAllText($path)
}

function Import-Seed($Seed, $Endpoint) {
    $valuesText = Get-BundleSecretText
    if ($null -eq $valuesText) { return $false }
    $argv = [Collections.Generic.List[string]]::new()
    foreach ($k in $Endpoint.Keys) { $argv.Add('--endpoint'); $argv.Add("$k=$($Endpoint[$k])") }
    $envelope = [ordered]@{
        script  = [IO.File]::ReadAllText((Join-Path $repo 'tools/Import-OwuiSeed.py')) -replace "`r", ''
        schema  = [IO.File]::ReadAllText((Join-Path $repo 'manifests/owui-seed/schema.json'))
        seed    = $Seed.Files
        secrets = $valuesText
        argv    = $argv.ToArray()
    } | ConvertTo-Json -Depth 4 -Compress
    $boot = "import json,sys;e=json.loads(sys.stdin.read());g={'__name__':'owui_seed_import'};" +
    "exec(compile(e['script'],'Import-OwuiSeed.py','exec'),g);" +
    "sys.exit(g['main'](e['argv'],seed_files=e['seed'],secrets_text=e['secrets'],schema_text=e['schema']))"
    $r = Invoke-InOwui $boot $envelope
    $said = $false
    foreach ($l in @($r.Output)) {
        if ($l -match '^OK\s+(.+)$') { $result.Steps.Add("seed: $($Matches[1])"); $said = $true }
        elseif ($l -match '^WARN\s+(.+)$') { $result.Warnings.Add("seed: $($Matches[1])") }
        elseif ($l -match '^PROBLEM\s+(.+)$') { $result.Problems.Add("seed: $($Matches[1])"); $said = $true }
        elseif ($l -match '^STOPPED\s+(.+)$') { $result.Steps.Add("seed: $($Matches[1])") }
    }
    if ($r.ExitCode -ne 0 -and -not $said) { $result.Problems.Add("seed: the importer stopped (exit $($r.ExitCode)) before saying why; nothing was written") }
    return $r.ExitCode -eq 0
}

function Get-OnboardingState {
    # $true while OWUI has no account yet.
    $cfg = & $machine.HttpJson "$owuiUrl/api/config"
    if (-not $cfg) { return $null }
    $p = $cfg.PSObject.Properties['onboarding']
    return [bool]($p -and $p.Value)
}

function Resolve-Location([string]$Location) {
    $roots = (Get-Content -LiteralPath $Context.RootsPath -Raw | ConvertFrom-Json -AsHashtable)['roots']
    $name, $rel = $Location -split ':', 2
    $root = $roots[$name]
    if (-not $root -or $root['kind'] -ne 'path' -or $root['host'] -ne 'pc') { return $null }
    $base = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($root['path']))
    return @{ Root = $base; Path = [IO.Path]::GetFullPath((Join-Path $base $rel)) }
}

function Read-ApiKey {
    # The key in the file, or $null with the reason in $script:keyWhy.
    $script:keyWhy = 'is empty'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { $script:keyWhy = 'is missing'; return $null }
    $text = [IO.File]::ReadAllText($keyPath).Trim()
    if (-not $text) { return $null }
    if ($text -notmatch '^sk-[A-Za-z0-9_-]{16,200}$') { $script:keyWhy = 'does not hold one OWUI API key (sk-...) alone'; return $null }
    return $text
}

function Write-ConsumerKey([string]$Key) {
    # Writes NAME=<key> into each consumer, keeping every other line.
    $done = [Collections.Generic.List[string]]::new()
    foreach ($c in $consumers) {
        $where = Resolve-Location $c['location']
        if (-not $where) { $result.Problems.Add("$($c['name']): $($c['location']) is not under a PC root in recovery-roots.json"); continue }
        $check = & $Context.PathCheck -Path $where.Path -Root $where.Root -Detailed
        if (-not @($check)[0].IsValid) { $result.Problems.Add("$($c['name']): $($c['location']) fails the path check"); continue }
        if (-not (Test-Path -LiteralPath $where.Path -PathType Leaf)) { $result.Problems.Add("$($c['name']): $($c['location']) is missing; Stage 4 places it"); continue }
        $text = [IO.File]::ReadAllText($where.Path)
        $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
        $pattern = '(?m)^[ \t]*' + [regex]::Escape($c['setting']) + '[ \t]*=.*?(?=\r?$)'
        $line = "$($c['setting'])=$Key"
        $new = if ([regex]::IsMatch($text, $pattern)) { [regex]::Replace($text, $pattern, $line.Replace('$', '$$')) }
        else { $(if ($text -and -not $text.EndsWith("`n")) { $text + $nl } else { $text }) + $line + $nl }
        if ($new -ceq $text) { $done.Add($c['name']); continue }
        $temp = "$($where.Path).cria-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($new)
        $s = Open-NewOwnerOnlyFile -Path $temp
        try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
        # [NullString]: a plain $null would reach .NET as '' (no backup wanted).
        try { [IO.File]::Replace($temp, $where.Path, [NullString]::Value) }
        catch {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            $result.Problems.Add("$($c['name']): could not write $($c['location']) ($($_.Exception.GetType().Name))")
            continue
        }
        $done.Add($c['name'])
    }
    return , $done.ToArray()
}

function Get-ConsumerState {
    # Per consumer: 'a key', 'no key', or 'missing'. Never a value.
    $out = [ordered]@{}
    foreach ($c in $consumers) {
        $where = Resolve-Location $c['location']
        if (-not $where -or -not (Test-Path -LiteralPath $where.Path -PathType Leaf)) { $out[$c['name']] = 'missing'; continue }
        $m = [regex]::Match([IO.File]::ReadAllText($where.Path), '(?m)^[ \t]*' + [regex]::Escape($c['setting']) + '[ \t]*=[ \t]*(sk-[A-Za-z0-9_-]{16,200})[ \t]*\r?$')
        $out[$c['name']] = $(if ($m.Success) { 'a key' } else { 'no key' })
    }
    return $out
}

function Get-Endpoint {
    try { return Get-TailnetEndpoint -SshHost $alias -TailscaleCommand $machine.Commands['tailscale'] }
    catch { $result.Problems.Add("tailnet: $($_.Exception.Message)"); return $null }
}

# ---------- the seed and the key, with the person ----------

function Invoke-Seed($Seed) {
    # 7d. $true once the seed is in.
    if ($result.Data['SeedImported']) { return $true }
    if (-not (Open-Owui)) { return $false }
    $onboarding = Get-OnboardingState
    if ($null -eq $onboarding) { $result.Problems.Add("OWUI answers /health but not $owuiUrl/api/config"); return $false }
    if ($onboarding) {
        Add-StageAsk $result ("OWUI is running alone at $owuiUrl with an empty database. Open it in a browser on this PC and create the admin account " +
            '(the first account becomes the admin; use the email you sign in with today). Then run the same command again: ' +
            'pwsh -File .\Invoke-StackRecovery.ps1 -Execute')
        return $false
    }
    if (-not (Close-Owui)) { return $false }
    $state = Get-SeedState $Seed
    if ($state -and $state['match'] -and $state['left'] -eq 0 -and $state['users'] -eq 1) {
        $result.Steps.Add('seed: already in OWUI''s database')
    }
    else {
        $endpoint = Get-Endpoint
        if (-not $endpoint) { return $false }
        if (-not (Import-Seed $Seed $endpoint)) { return $false }
    }
    $result.Data['SeedImported'] = $true
    return $true
}

function Invoke-ApiKey {
    # 7e. $true once every consumer holds a key that opened OWUI.
    if ($result.Data['ApiKeyChecked']) { return $true }
    if (-not (Open-Owui)) { return $false }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        $s = Open-NewOwnerOnlyFile -Path $keyPath
        $s.Dispose()
        & $Context.Own 'file' $keyPath $Context.StagingRoot 'keep' -Plaintext
    }
    $ask = "Sign in at $owuiUrl as the admin. In Settings > Account > API keys, create a key and paste it, alone, into $keyPath (only you can read that file; Stage 11 deletes it). Save it, then run the same command again: pwsh -File .\Invoke-StackRecovery.ps1 -Execute"
    $key = Read-ApiKey
    if (-not $key) {
        Add-StageAsk $result $(if ($script:keyWhy -eq 'is empty') { $ask } else { "$keyPath $($script:keyWhy). $ask" })
        return $false
    }
    $status = & $machine.HttpStatus "$owuiUrl/api/v1/calendars/" @{ Authorization = "Bearer $key" }
    if ($status -in 401, 403) {
        Add-StageAsk $result "OWUI refused the key in $keyPath (HTTP $status). Create a new key and replace the file's contents. $ask"
        return $false
    }
    if ($status -ne 200) { $result.Problems.Add("OWUI's calendar API answered HTTP $status to the new key; the gcal bridge needs it"); return $false }
    $done = Write-ConsumerKey $key
    if ($done.Count -ne $consumers.Count) { return $false }
    $result.Steps.Add("the new OWUI API key opens OWUI's calendar API and is in $($done.Count) consumer(s): $($done -join ', ')")
    $result.Data['ApiKeyChecked'] = $true
    return $true
}

# ---------- checkpoint ----------

function Test-Checkpoint($Seed) {
    $present = 0; $total = 0; $absent = [Collections.Generic.List[string]]::new()
    foreach ($p in $projects) {
        $refs = Get-ProjectImage $p
        if ($null -eq $refs) { $total++; $absent.Add("$($p['name']) (its images could not be listed)"); continue }
        foreach ($ref in $refs) {
            $total++
            if (Test-Image $ref) { $present++ } else { $absent.Add($ref) }
        }
    }
    Add-StageCheck $result 'every image of the PC compose projects is here' "$total of $total" "$present of $total$(if ($absent.Count) { "; missing: $($absent -join ', ')" })" ($total -gt 0 -and $present -eq $total)
    if ($Seed) {
        $atDigest = Test-Image $Seed.Provenance['image_digest']
        Add-StageCheck $result 'OWUI image at the digest the seed records (C-40)' 'present' $(if ($atDigest) { 'present' } else { 'missing' }) $atDigest
    }
    $own = Test-OwnVolume
    Add-StageCheck $result 'owui-data was created by this stage' 'yes' $(if ($own) { 'yes' } elseif ($null -eq $own) { 'someone else''s' } else { 'missing' }) ([bool]$own)
    $state = @($result.Data['ServiceState'])
    $okState = ($state -contains 'ntfy-user-db') -and ($state -contains 'bolt-server-keys')
    Add-StageCheck $result 'ntfy user.db and Bolt server keys placed in their volumes' 'both' $(if ($okState) { 'both' } else { "$($state.Count) placed" }) $okState
    if ($Seed) {
        $s = Get-SeedState $Seed
        if (-not $s) { Add-StageCheck $result 'OWUI database readable' 'yes' 'no' $false }
        else {
            $have = ($seededTables | ForEach-Object { "$($s['counts'][$_])" }) -join ' / '
            $want = ($seededTables | ForEach-Object { "$($Seed.Provenance['counts'][$_])" }) -join ' / '
            Add-StageCheck $result "seeded rows ($($seededTables -join ' / '))" $want $have ([bool]$s['match'])
            Add-StageCheck $result 'no {{OWNER}} or {{BUNDLE:...}} left' '0' "$($s['left'])" ($s['left'] -eq 0)
            Add-StageCheck $result 'accounts in OWUI' '1' "$($s['users'])" ($s['users'] -eq 1)
            Add-StageCheck $result 'PRAGMA integrity_check, foreign_key_check' 'ok, 0 rows' "$($s['integrity']), $($s['fk']) rows" ($s['integrity'] -eq 'ok' -and $s['fk'] -eq 0)
        }
    }
    $cs = Get-ConsumerState
    $bad = @($cs.Keys | Where-Object { $cs[$_] -ne 'a key' } | ForEach-Object { "$($_): $($cs[$_])" })
    Add-StageCheck $result 'every OWUI API key consumer holds a key' "$($cs.Count) of $($cs.Count)" "$($cs.Count - $bad.Count) of $($cs.Count)$(if ($bad) { "; $($bad -join ', ')" })" ($bad.Count -eq 0)
    $checked = [bool]$result.Data['ApiKeyChecked']
    Add-StageCheck $result 'the key opened OWUI''s calendar API when it was placed' 'yes' $(if ($checked) { 'yes' } else { 'no' }) $checked
}

# ---------- main ----------

$seed = Read-Seed

if ($Mode -eq 'Check') {
    Test-Checkpoint $seed
    if ($result.Problems.Count -and $result.Status -eq 'passed') { $result.Status = 'failed' }
    return $result
}

if ($Mode -eq 'Plan') {
    if ($seed) {
        $result.Steps.Add("would build the images of $(@($projects | ForEach-Object { $_['name'] }) -join ', ') and pull the rest at their digests, OWUI $($seed.Provenance['owui_version']) at the seed's")
        $result.Steps.Add('would create owui-data and every project''s volumes and containers without starting them, then place bundle folder 07')
        $result.Steps.Add("would start OWUI alone for you to create the admin account, import the seed ($($seededTables.Count) tables), then ask you for a new API key for $($consumers.Count) consumer(s)")
    }
    $result.Status = 'planned'
    return $result
}

if ($seed -and (Install-Image $seed) -and (Initialize-Volume) -and (Restore-ServiceState) -and (Invoke-Seed $seed) -and (Invoke-ApiKey)) {
    $null = Close-Owui
}

if ($result.Problems.Count) { $result.Status = 'failed' }
return $result
