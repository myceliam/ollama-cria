#Requires -Version 7.4
<#
.SYNOPSIS
    Reads the facts a rebuild needs from the live PC and VPS and writes them
    as manifests in this repo (docs/RESTORE.md Appendix B): models, the
    Ollama profile, Windows apps, ComfyUI and its weights, Serve rules,
    scheduled tasks and container images.

.DESCRIPTION
    Each section writes its own files:

      ollama        manifests/ollama-models.json: every model with its digest;
                    custom models point at their Modelfile in stack/modelfiles
                    and name the model they are built from (Stage 6a)
      ollama-env    manifests/ollama-env.json: the Machine-scope OLLAMA_*
                    profile and HF_HOME (Stage 3c)
      windows-apps  manifests/windows-apps.json: winget ids and versions of the
                    apps the stack needs, and the GPU driver (Stage 3)
      comfyui       manifests/comfyui-nodes.json and
                    manifests/comfyui-requirements.lock: ComfyUI's commit, its
                    custom nodes' commits, and its venv's packages (Stage 3d)
      weights       manifests/comfyui-weights.json: every file of 1 MB or more
                    under models\ with its size, SHA-256 and, where one can be
                    found and checked, a download URL (Stage 6b). A URL already
                    in the file for the same bytes is kept, so one added by
                    hand survives a re-run. Slow: it hashes every weight.
      serve         manifests/serve.json: the Tailscale Serve rules, with no
                    host names (Stage 8c)
      tasks         manifests/tasks.json and windows/tasks/*.xml: the stack's
                    scheduled tasks with the user's SID and name templated,
                    the startup items, and what is left out (Stage 8d)
      images        manifests/images.json: the image behind every container on
                    the PC and the VPS, with its registry digest (Stage 5b, 7a)

    Two modes, as tools/Sync-StackFiles.ps1:

      Plan (the default). Reads, builds and scans every manifest, and says
      which would be new or changed. Writes nothing in the repo.

      -Execute. The same, then writes the new and changed files.

    Rules it keeps:

      - Read-only on the live machines. It reads APIs, lists, git metadata
        and file hashes; it changes nothing there. The weights section may
        ask Hugging Face (a HEAD request, to read a file's SHA-256) and
        Civitai (its look-up by SHA-256) where a weight came from; -Offline
        stops that.
      - No secrets and no private addresses: every manifest goes through the
        same templating and scan as the stack files before it reaches the
        repo, and a finding stops the run.
      - Output: file names, statuses and counts. Never a value.

.PARAMETER Only
    The sections to run. All of them by default except weights, which is slow
    and runs only when named.

.PARAMETER Execute
    Write the new and changed manifests.

.PARAMETER ComfyRoot
    The ComfyUI checkout.

.PARAMETER OllamaUrl
    Ollama's local API.

.PARAMETER Offline
    Weights: do not ask Hugging Face or Civitai for download URLs.

.PARAMETER SshHost
    The SSH alias of the VPS, and its node name in the tailnet.

.PARAMETER RepoPath
    The repo to write into. Defaults to the repo this script is in.

.PARAMETER PassThru
    Return the result object instead of printing a summary and setting the
    exit code.

.EXAMPLE
    ./tools/Sync-StackManifests.ps1

.EXAMPLE
    ./tools/Sync-StackManifests.ps1 -Only weights -Execute
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are read inside the helper functions.')]
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [ValidateSet('ollama', 'ollama-env', 'windows-apps', 'comfyui', 'weights', 'serve', 'tasks', 'images')]
    [string[]]$Only,

    [switch]$Execute,

    [string]$ComfyRoot = 'E:\ai\comfyui\ComfyUI',

    [string]$OllamaUrl = 'http://127.0.0.1:11434',

    [switch]$Offline,

    [string]$SshHost = 'vps',

    [string]$RepoPath = (Split-Path $PSScriptRoot -Parent),

    [switch]$PassThru,

    # Test seams.
    [Parameter(DontShow)]
    [string]$TailscaleCommand = 'tailscale',

    [Parameter(DontShow)]
    [string]$DockerCommand = 'docker',

    [Parameter(DontShow)]
    [string]$SshCommand = 'ssh',

    [Parameter(DontShow)]
    [string]$PythonCommand,

    [Parameter(DontShow)]
    [string]$WingetCommand = 'winget',

    [Parameter(DontShow)]
    [string]$NvidiaSmiCommand = 'nvidia-smi'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'StackCapture.psm1') -Force
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20')
$minWeightBytes = 1MB

$problems = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$rows = [Collections.Generic.List[object]]::new()
$outputs = [Collections.Generic.List[object]]::new()

# What the stack needs from winget (Stage 3), and why.
$wantedApps = [ordered]@{
    'Docker.DockerDesktop'                    = 'Docker engine for the PC stack (Stage 3b)'
    'Ollama.Ollama'                           = 'Ollama (Stage 3b)'
    'Python.Python.3.11'                      = 'ComfyUI venv (Stage 3d)'
    'Python.Python.3.13'                      = 'The Windows PowerShell tool task runs C:\Python313\python.exe'
    'Git.Git'                                 = 'Cloning this repo and ComfyUI (Step 0)'
    'Tailscale.Tailscale'                     = 'The tailnet and Serve (Step 0, Stage 8c)'
    'Microsoft.PowerShell'                    = 'PowerShell 7 for every script here (Step 0)'
    'LibreHardwareMonitor.LibreHardwareMonitor' = 'Sensor readings the ntfy PC-health watcher reads'
}

# The scheduled tasks the stack needs (Stage 8d). An installer script, when
# named, is how the stage recreates the task; otherwise the XML is imported.
$wantedTasks = [ordered]@{
    'OWUI-Stack-Startup'           = 'stack/_support/scripts/installers/install-startup-task.ps1'
    'OWUI-mcpo-Watchdog'           = 'stack/_support/scripts/installers/install-mcpo-watchdog-task.ps1'
    'OWUI-ntfy-Fast'               = $null
    'OWUI-ntfy-PcHealth'           = $null
    'OWUI-ntfy-MorningBrief'       = $null
    'OWUI-Windows-PowerShell-Tool' = $null
    'Tailscale-Status-Feed'        = $null
    'LibreHardwareMonitor'         = $null
}
# Retired; never recreated (RESTORE.md Stage 8d, R-20).
$retiredTasks = @('OWUI-Nightly-Backup', 'OWUI-Weekly-VPS-Push', 'OWUI-ntfy-Backups', 'Ollama Weekly Backup', 'OWUI-Automation-Chat-Tidy')
# Live folders and where their files are in this repo.
$repoOf = [ordered]@{ 'E:\ai\ollama\' = 'stack/'; 'E:\ai\ag-startuip\cline-dashboard\' = 'extras/dashboard/' }

# ---------- Small helpers ----------

function Get-RunResult {
    [pscustomobject]@{
        Mode     = if ($Execute) { 'Execute' } else { 'Plan' }
        IsValid  = ($problems.Count -eq 0)
        Rows     = $rows.ToArray()
        Problems = $problems.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function Get-OptionalProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Add-Output([string]$Dest, [string]$Text) {
    # Queues one manifest. Text is LF; .gitattributes decides the checkout.
    $outputs.Add([pscustomobject]@{ Dest = $Dest; Text = ($Text -replace "`r`n", "`n") })
}

function Add-JsonOutput([string]$Dest, $Doc) {
    Add-Output $Dest ((($Doc | ConvertTo-Json -Depth 12) -replace "`r`n", "`n") + "`n")
}

function Invoke-Native {
    # Runs a program, returns its output lines, and records a problem (and
    # returns $null) when it fails. Never passes on its error text.
    param([string]$Label, [string]$Command, [string[]]$Arguments)
    $global:LASTEXITCODE = 0
    try { $out = @(& $Command @Arguments 2>$null) }
    catch { $problems.Add("${Label}: '$Command' could not be run"); return $null }
    if ($LASTEXITCODE -ne 0) { $problems.Add("${Label}: '$Command' failed (exit $LASTEXITCODE)"); return $null }
    return , [string[]]@($out | ForEach-Object { [string]$_ })
}

function Get-RepoRelative([string]$LivePath) {
    # The repo path of a file under one of the copied folders, or $null.
    foreach ($k in $repoOf.Keys) {
        if ($LivePath.StartsWith($k, [StringComparison]::OrdinalIgnoreCase)) {
            return $repoOf[$k] + ($LivePath.Substring($k.Length) -replace '\\', '/')
        }
    }
    return $null
}

# ---------- Sections ----------

function Read-Ollama {
    try {
        $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 20
        $version = (Invoke-RestMethod -Uri "$OllamaUrl/api/version" -TimeoutSec 20).version
    }
    catch { $problems.Add("ollama: the API at $OllamaUrl did not answer; is Ollama running?"); return }
    # Custom models: a Modelfile in stack/modelfiles whose FROM is the model's
    # parent and whose file name is the model's name with the punctuation
    # left out (qwen3.5-agent:9b is qwen3.5-agent_9b.Modelfile).
    $modelfiles = @()
    $mfDir = Join-Path $RepoPath 'stack/modelfiles'
    if (Test-Path -LiteralPath $mfDir -PathType Container) {
        $modelfiles = @(Get-ChildItem -LiteralPath $mfDir -Filter '*.Modelfile' -File | ForEach-Object {
                $from = @(Get-Content -LiteralPath $_.FullName | Where-Object { $_ -match '^\s*FROM\s+\S' } | ForEach-Object { ($_ -replace '^\s*FROM\s+', '').Trim() }) | Select-Object -First 1
                [pscustomobject]@{ File = "stack/modelfiles/$($_.Name)"; Stem = ($_.BaseName.ToLowerInvariant() -replace '[^a-z0-9]', ''); From = [string]$from; Used = $false }
            })
    }
    $names = @{}
    foreach ($m in $tags.models) { $names[[string]$m.name] = $true }
    $models = [Collections.Generic.List[object]]::new()
    foreach ($m in ($tags.models | Sort-Object { [string]$_.name } -CaseSensitive)) {
        $d = $m.details
        $row = [ordered]@{
            name          = [string]$m.name
            digest        = [string]$m.digest
            bytes         = [long]$m.size
            family        = [string](Get-OptionalProperty $d 'family')
            parameterSize = [string](Get-OptionalProperty $d 'parameter_size')
            quantization  = [string](Get-OptionalProperty $d 'quantization_level')
            source        = 'registry'
        }
        $parent = [string](Get-OptionalProperty $d 'parent_model')
        # A parent that is a path (a blob on whoever built it) is the
        # registry's business; a parent that is a model here is a local build.
        if ($parent -and $parent -notmatch '[\\]|^/|blobs') {
            $full = ($row.name.ToLowerInvariant() -replace '[^a-z0-9]', '')
            $short = (($row.name -replace ':[^:]*$', '').ToLowerInvariant() -replace '[^a-z0-9]', '')
            $match = @($modelfiles | Where-Object { $_.From -eq $parent -and ($_.Stem -eq $full -or $_.Stem -eq $short) })
            if ($match.Count -ne 1) {
                $problems.Add("ollama: $($row.name) is built from $parent here, but $($match.Count) Modelfiles in stack/modelfiles match it; it needs exactly one")
                continue
            }
            $match[0].Used = $true
            if (-not $names.ContainsKey($parent)) { $problems.Add("ollama: $($row.name) is built from $parent, which is not installed") }
            $row.source = 'modelfile'
            $row['base'] = $parent
            $row['modelfile'] = $match[0].File
        }
        $models.Add($row)
    }
    foreach ($mf in ($modelfiles | Where-Object { -not $_.Used })) { $warnings.Add("ollama: $($mf.File) builds no installed model") }
    Add-JsonOutput 'manifests/ollama-models.json' ([ordered]@{
            '$schema'     = './schemas/ollama-models.schema.json'
            formatVersion = 1
            ollamaVersion = [string]$version
            note          = 'Written by tools/Sync-StackManifests.ps1. Stage 6a pulls every registry model and checks its digest, then builds each modelfile model from its base.'
            models        = $models.ToArray()
        })
}

function Read-OllamaEnv {
    if (-not $IsWindows) { $problems.Add('ollama-env: reads Machine-scope variables, so it runs on Windows only'); return }
    $machine = [Environment]::GetEnvironmentVariables('Machine')
    $vars = [Collections.Generic.List[object]]::new()
    foreach ($k in ($machine.Keys | Where-Object { $_ -match '^OLLAMA_' -or $_ -eq 'HF_HOME' } | Sort-Object -CaseSensitive)) {
        $vars.Add([ordered]@{ name = [string]$k; value = [string]$machine[$k] })
    }
    if (-not @($vars | Where-Object { $_.name -like 'OLLAMA_*' })) { $problems.Add('ollama-env: no OLLAMA_* variable at Machine scope') }
    $user = [Environment]::GetEnvironmentVariables('User')
    foreach ($k in ($user.Keys | Where-Object { $_ -match '^OLLAMA_' })) {
        $warnings.Add("ollama-env: $k is also set at User scope, where it silently wins over Machine scope (Appendix F); remove it")
    }
    Add-JsonOutput 'manifests/ollama-env.json' ([ordered]@{
            '$schema'     = './schemas/ollama-env.schema.json'
            formatVersion = 1
            scope         = 'Machine'
            note          = 'Written by tools/Sync-StackManifests.ps1. Stage 3c writes each variable at Machine scope, removes any OLLAMA_* at User scope, then restarts Ollama.'
            variables     = $vars.ToArray()
        })
}

function Read-WindowsApp {
    if (-not $IsWindows) { $problems.Add('windows-apps: reads winget, so it runs on Windows only'); return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cria-winget-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $null = Invoke-Native 'windows-apps' $WingetCommand @('export', '-o', $tmp, '--include-versions', '--accept-source-agreements', '--disable-interactivity')
        if (-not (Test-Path -LiteralPath $tmp)) { if (-not $problems.Count) { $problems.Add('windows-apps: winget export wrote nothing') }; return }
        $export = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
    }
    finally {
        $check = & (Join-Path $PSScriptRoot 'Test-RecoveryPath.ps1') -Path (Split-Path $tmp -Leaf) -Root ([IO.Path]::GetTempPath()) -Relative -Detailed
        if ($check.IsValid -and (Test-Path -LiteralPath $check.FullPath)) { Remove-Item -LiteralPath $check.FullPath -Force }
    }
    $found = @{}
    foreach ($s in @($export.Sources)) { foreach ($p in @($s.Packages)) { $found[[string]$p.PackageIdentifier] = [string](Get-OptionalProperty $p 'Version') } }
    $apps = [Collections.Generic.List[object]]::new()
    foreach ($id in $wantedApps.Keys) {
        if (-not $found.ContainsKey($id)) { $warnings.Add("windows-apps: $id is not installed through winget here"); continue }
        $apps.Add([ordered]@{ id = $id; version = $found[$id]; why = $wantedApps[$id] })
    }
    $gpu = $null
    $smi = Invoke-Native 'windows-apps' $NvidiaSmiCommand @('--query-gpu=name,driver_version', '--format=csv,noheader')
    if ($smi) {
        $name, $driver = ($smi[0] -split ',\s*', 2)
        $gpu = [ordered]@{ name = $name.Trim(); driver = $driver.Trim() }
    }
    Add-JsonOutput 'manifests/windows-apps.json' ([ordered]@{
            '$schema'     = './schemas/windows-apps.schema.json'
            formatVersion = 1
            note          = 'Written by tools/Sync-StackManifests.ps1. Stage 3 installs these versions with winget and pins Ollama and Docker Desktop (C-30); the GPU driver is checked with nvidia-smi.'
            packages      = $apps.ToArray()
            gpu           = $gpu
        })
}

function Read-ComfyUi {
    if (-not (Test-Path -LiteralPath (Join-Path $ComfyRoot '.git'))) { $problems.Add('comfyui: -ComfyRoot is not a git checkout'); return }
    $head = Invoke-Native 'comfyui' 'git' @('-C', $ComfyRoot, 'rev-parse', 'HEAD')
    $remote = Invoke-Native 'comfyui' 'git' @('-C', $ComfyRoot, 'remote', 'get-url', 'origin')
    $changed = Invoke-Native 'comfyui' 'git' @('-C', $ComfyRoot, 'status', '--porcelain', '--untracked-files=no')
    if ($null -eq $head -or $null -eq $remote -or $null -eq $changed) { return }
    foreach ($c in $changed) { $warnings.Add("comfyui: ComfyUI's own file '$($c.Substring(3))' differs from its commit; a rebuild will not have that change") }
    $python = if ($PythonCommand) { $PythonCommand } else { Join-Path $ComfyRoot '.venv\Scripts\python.exe' }
    $pyVersion = Invoke-Native 'comfyui' $python @('--version')
    $freeze = Invoke-Native 'comfyui' $python @('-m', 'pip', 'freeze')
    if ($null -eq $pyVersion -or $null -eq $freeze) { return }
    $nodes = [Collections.Generic.List[object]]::new()
    $manual = [Collections.Generic.List[string]]::new()
    $nodeRoot = Join-Path $ComfyRoot 'custom_nodes'
    foreach ($dir in (Get-ChildItem -LiteralPath $nodeRoot -Directory -Force | Sort-Object Name -CaseSensitive)) {
        if ($dir.Name -eq '__pycache__') { continue }
        $tracked = Invoke-Native 'comfyui' 'git' @('-C', $ComfyRoot, 'ls-files', '--', "custom_nodes/$($dir.Name)")
        if ($tracked) { continue }   # part of ComfyUI itself
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName '.git'))) { $manual.Add($dir.Name); continue }
        $u = Invoke-Native 'comfyui' 'git' @('-C', $dir.FullName, 'remote', 'get-url', 'origin')
        $c = Invoke-Native 'comfyui' 'git' @('-C', $dir.FullName, 'rev-parse', 'HEAD')
        $d = Invoke-Native 'comfyui' 'git' @('-C', $dir.FullName, 'status', '--porcelain', '--untracked-files=no')
        if ($null -eq $u -or $null -eq $c -or $null -eq $d) { continue }
        if ($d.Count) { $warnings.Add("comfyui: custom node $($dir.Name) has local changes a rebuild will not have") }
        $nodes.Add([ordered]@{ name = $dir.Name; repo = ($u[0] -replace '//[^/@]+@', '//'); commit = $c[0] })
    }
    foreach ($m in $manual) { $warnings.Add("comfyui: custom node folder $m is not a git checkout; it cannot be rebuilt from a commit") }
    $lines = [string[]]@($freeze | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    [Array]::Sort($lines, [StringComparer]::OrdinalIgnoreCase)
    foreach ($l in ($lines | Where-Object { $_ -match '\s@\s+file:|^-e\s' })) {
        $warnings.Add("comfyui: the venv package '$(($l -split '[\s=@]', 2)[0])' was installed from a local folder or file; the lock cannot reinstall it")
    }
    # The CUDA wheel index of the installed torch build (torch==2.5.1+cu124).
    $indexes = [Collections.Generic.List[string]]::new()
    $torch = @($lines | Where-Object { $_ -match '^torch==[^+]+\+(cu\d+)$' }) | Select-Object -First 1
    if ($torch -and $torch -match '\+(cu\d+)$') { $indexes.Add("https://download.pytorch.org/whl/$($Matches[1])") }
    elseif (-not @($lines | Where-Object { $_ -match '^torch==' })) { $warnings.Add('comfyui: torch is not in the venv') }
    else { $warnings.Add('comfyui: the venv has a torch build without CUDA') }
    $indexes.Add('https://pypi.org/simple')
    Add-JsonOutput 'manifests/comfyui-nodes.json' ([ordered]@{
            '$schema'     = './schemas/comfyui-nodes.schema.json'
            formatVersion = 1
            note          = 'Written by tools/Sync-StackManifests.ps1. Stage 3d clones ComfyUI and each node at these commits and installs comfyui-requirements.lock into a Python venv of this version.'
            comfyui       = [ordered]@{ repo = ($remote[0] -replace '//[^/@]+@', '//'); commit = $head[0] }
            python        = ($pyVersion[0] -replace '^Python\s+', '').Trim()
            pipIndexUrls  = $indexes.ToArray()
            nodes         = $nodes.ToArray()
            manual        = $manual.ToArray()
        })
    $install = '#   pip install -r comfyui-requirements.lock --index-url ' + $indexes[0]
    if ($indexes.Count -gt 1) { $install += ' --extra-index-url ' + $indexes[1] }
    $header = @(
        '# ComfyUI venv packages, from pip freeze. Written by tools/Sync-StackManifests.ps1.'
        '# Install with the indexes in comfyui-nodes.json so the CUDA wheels resolve (RESTORE.md Stage 3d):'
        $install
    )
    Add-Output 'manifests/comfyui-requirements.lock' ((@($header) + $lines -join "`n") + "`n")
}

function Get-ManagerUrl {
    # filename (lower case) -> download URLs, from ComfyUI-Manager's model lists.
    $map = @{}
    $places = @((Join-Path $ComfyRoot 'custom_nodes/ComfyUI-Manager'), (Join-Path $ComfyRoot 'user'))
    foreach ($p in $places) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*model-list.json' -ErrorAction SilentlyContinue)) {
            try { $doc = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            foreach ($m in @(Get-OptionalProperty $doc 'models')) {
                $fn = [string](Get-OptionalProperty $m 'filename')
                $url = [string](Get-OptionalProperty $m 'url')
                if (-not $fn -or $url -notmatch '^https://') { continue }
                $key = $fn.ToLowerInvariant()
                if (-not $map.ContainsKey($key)) { $map[$key] = [Collections.Generic.HashSet[string]]::new() }
                [void]$map[$key].Add($url)
            }
        }
    }
    return $map
}

function Find-WeightUrl([string]$Name, [string]$Sha256, [hashtable]$Manager) {
    # A URL whose file is known to have this SHA-256, or a gated Hugging Face
    # URL that could not be checked, or $null.
    $gated = $null
    if ($Manager.ContainsKey($Name.ToLowerInvariant())) {
        foreach ($url in $Manager[$Name.ToLowerInvariant()]) {
            if ($url -notmatch '^https://huggingface\.co/[^/]+/[^/]+/resolve/') { continue }
            try {
                $r = Invoke-WebRequest -Uri $url -Method Head -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 30
                $etag = [string](@($r.Headers['X-Linked-Etag']) | Select-Object -First 1)
                if ($etag.Trim('"').ToLowerInvariant() -eq $Sha256) { return [ordered]@{ url = $url; auth = 'none'; checked = $true } }
                if ($r.StatusCode -in 401, 403 -and -not $gated) { $gated = [ordered]@{ url = $url; auth = 'huggingface'; checked = $false } }
            }
            catch { continue }
        }
    }
    if ($gated) { return $gated }
    try {
        $r = Invoke-RestMethod -Uri "https://civitai.com/api/v1/model-versions/by-hash/$Sha256" -TimeoutSec 30
        foreach ($f in @($r.files)) {
            $h = [string](Get-OptionalProperty (Get-OptionalProperty $f 'hashes') 'SHA256')
            if ($h.ToLowerInvariant() -eq $Sha256 -and [string]$f.downloadUrl -match '^https://') {
                return [ordered]@{ url = [string]$f.downloadUrl; auth = 'civitai'; checked = $true }
            }
        }
    }
    catch { $null = $_ }   # not on Civitai, or it did not answer
    return $null
}

function Read-Weight {
    $modelsRoot = Join-Path $ComfyRoot 'models'
    if (-not (Test-Path -LiteralPath $modelsRoot -PathType Container)) { $problems.Add('weights: ComfyUI has no models folder'); return }
    $before = @{}
    $existing = Join-Path $RepoPath 'manifests/comfyui-weights.json'
    if (Test-Path -LiteralPath $existing -PathType Leaf) {
        foreach ($w in @((Get-Content -LiteralPath $existing -Raw | ConvertFrom-Json).weights)) { $before[[string]$w.dest] = $w }
    }
    $manager = if ($Offline) { @{} } else { Get-ManagerUrl }
    $weights = [Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $modelsRoot -Recurse -File -Force | Where-Object {
            $_.Length -ge $minWeightBytes -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    foreach ($f in ($files | Sort-Object { [IO.Path]::GetRelativePath($modelsRoot, $_.FullName) } -CaseSensitive)) {
        $dest = [IO.Path]::GetRelativePath($modelsRoot, $f.FullName) -replace '\\', '/'
        $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $role = if ($dest.Contains('/')) { $dest.Split('/')[0] } else { 'root' }
        $row = [ordered]@{ dest = $dest; bytes = $f.Length; sha256 = $sha; role = $role; required = $true; url = $null; auth = 'none'; checked = $false }
        $old = $before[$dest]
        if ($old -and [string]$old.sha256 -eq $sha) {
            if ($null -ne (Get-OptionalProperty $old 'required')) { $row.required = [bool]$old.required }
            if (Get-OptionalProperty $old 'url') {
                $row.url = [string]$old.url; $row.auth = [string]$old.auth; $row.checked = [bool](Get-OptionalProperty $old 'checked')
            }
        }
        if (-not $row.url -and -not $Offline) {
            $hit = Find-WeightUrl $f.Name $sha $manager
            if ($hit) { $row.url = $hit.url; $row.auth = $hit.auth; $row.checked = $hit.checked }
        }
        if (-not $row.url) { $warnings.Add("weights: $dest has no known download URL; add one by hand, or keep a copy of the file") }
        $weights.Add($row)
    }
    Add-JsonOutput 'manifests/comfyui-weights.json' ([ordered]@{
            '$schema'     = './schemas/comfyui-weights.schema.json'
            formatVersion = 1
            note          = 'Written by tools/Sync-StackManifests.ps1. dest is under ComfyUI\models. Stage 6b downloads each url to dest.partial, checks bytes and sha256, then renames it. checked means the URL was seen to serve this exact SHA-256. A url or required set by hand is kept for the same bytes.'
            weights       = $weights.ToArray()
        })
}

function Read-Serve {
    $raw = Invoke-Native 'serve' $TailscaleCommand @('serve', 'status', '--json')
    if ($null -eq $raw) { return }
    try { $s = ConvertFrom-Json -InputObject ($raw -join "`n") -AsHashtable } catch { $problems.Add('serve: the status could not be read'); return }
    $rules = [Collections.Generic.List[object]]::new()
    $web = @{}
    if ($s -and $s['Web']) { foreach ($k in $s['Web'].Keys) { $web[($k -replace '^.*:', '')] = $s['Web'][$k] } }
    if ($s -and $s['TCP']) {
        foreach ($port in ($s['TCP'].Keys | Sort-Object { [int]$_ })) {
            $t = $s['TCP'][$port]
            if ($t['TCPForward']) { $rules.Add([ordered]@{ port = [int]$port; kind = 'tcp'; target = [string]$t['TCPForward'] }); continue }
            if ($t['HTTPS'] -and $web.ContainsKey([string]$port)) {
                foreach ($path in ($web[[string]$port]['Handlers'].Keys | Sort-Object -CaseSensitive)) {
                    $h = $web[[string]$port]['Handlers'][$path]
                    if (-not $h['Proxy']) { $problems.Add("serve: port $port $path is not a proxy rule; this tool records proxies only"); continue }
                    $rules.Add([ordered]@{ port = [int]$port; kind = 'https'; path = [string]$path; target = [string]$h['Proxy'] })
                }
                continue
            }
            $problems.Add("serve: port $port has a rule this tool does not know")
        }
    }
    if ($s -and $s['AllowFunnel'] -and @($s['AllowFunnel'].Values | Where-Object { $_ }).Count) { $problems.Add('serve: Funnel is on for a port; the stack never uses Funnel (C-23)') }
    Add-JsonOutput 'manifests/serve.json' ([ordered]@{
            '$schema'     = './schemas/serve.schema.json'
            formatVersion = 1
            note          = 'Written by tools/Sync-StackManifests.ps1. Stage 8c sets exactly these rules with tailscale serve --bg, tailnet only, never Funnel.'
            rules         = $rules.ToArray()
        })
}

function ConvertTo-TaskTemplate([string]$Text) {
    # The user's SID, account name and profile folder become placeholders
    # Stage 8d fills for the new account.
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $Text = $Text.Replace($sid, '{{USER_SID}}')
    foreach ($id in @("$env:USERDOMAIN\$env:USERNAME", "$env:COMPUTERNAME\$env:USERNAME") | Select-Object -Unique) {
        $Text = [regex]::Replace($Text, [regex]::Escape($id), '{{USER_ID}}', 'IgnoreCase')
    }
    $Text = [regex]::Replace($Text, '(?i)(<(?:UserId|Author)>)' + [regex]::Escape($env:USERNAME) + '(</)', '$1{{USER_ID}}$2')
    $Text = [regex]::Replace($Text, [regex]::Escape($env:USERPROFILE), '{{USER_PROFILE}}', 'IgnoreCase')
    return $Text
}

function Read-Task {
    if (-not $IsWindows) { $problems.Add('tasks: reads the Task Scheduler, so it runs on Windows only'); return }
    $all = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop)
    $tasks = [Collections.Generic.List[object]]::new()
    foreach ($name in $wantedTasks.Keys) {
        $t = @($all | Where-Object TaskName -EQ $name)
        if (-not $t) { $warnings.Add("tasks: $name is not on this PC"); continue }
        $t = $t[0]
        # Stored as UTF-8, so the declaration says so (Export-ScheduledTask
        # says UTF-16, which is what it hands back in memory).
        $xml = ConvertTo-TaskTemplate (Export-ScheduledTask -TaskName $name -TaskPath '\')
        $xml = $xml -replace '^(<\?xml[^>]*encoding=")UTF-16(")', '${1}UTF-8$2'
        $file = 'windows/tasks/' + ($name -replace '[^A-Za-z0-9._-]', '-') + '.xml'
        Add-Output $file $xml
        $runs = [Collections.Generic.List[string]]::new()
        foreach ($a in $t.Actions) {
            foreach ($m in [regex]::Matches("$($a.Execute) $($a.Arguments)", '[A-Za-z]:\\[^"]+?\.(ps1|psm1|py|vbs|exe)\b')) {
                $rel = Get-RepoRelative $m.Value
                if (-not $rel) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $RepoPath $rel) -PathType Leaf)) { $warnings.Add("tasks: $name runs $rel, which is not in the repo") }
                $runs.Add($rel)
            }
        }
        $installer = $wantedTasks[$name]
        $tasks.Add([ordered]@{
                name    = $name
                enabled = ([string]$t.State -ne 'Disabled')
                install = if ($installer) { $installer } else { 'xml' }
                xml     = $file
                runs    = @($runs | Select-Object -Unique)
            })
    }
    $startup = [Collections.Generic.List[object]]::new()
    $startupOther = [Collections.Generic.List[string]]::new()
    $folder = [Environment]::GetFolderPath('Startup')
    $shell = New-Object -ComObject WScript.Shell
    foreach ($item in (Get-ChildItem -LiteralPath $folder -File | Sort-Object Name -CaseSensitive)) {
        if ($item.Name -eq 'start_comfyui_hidden.vbs') {
            $startup.Add([ordered]@{ name = $item.Name; kind = 'file'; file = 'windows/startup/start_comfyui_hidden.vbs' })
        }
        elseif ($item.Name -like 'OWUI*.lnk') {
            $l = $shell.CreateShortcut($item.FullName)
            $startup.Add([ordered]@{
                    name             = $item.Name
                    kind             = 'shortcut'
                    target           = ConvertTo-TaskTemplate $l.TargetPath
                    arguments        = ConvertTo-TaskTemplate $l.Arguments
                    workingDirectory = ConvertTo-TaskTemplate $l.WorkingDirectory
                })
        }
        elseif ($item.Name -ne 'desktop.ini') { $startupOther.Add($item.Name) }
    }
    $known = @($wantedTasks.Keys) + $retiredTasks
    Add-JsonOutput 'manifests/tasks.json' ([ordered]@{
            '$schema'     = './schemas/tasks.schema.json'
            formatVersion = 1
            note          = 'Written by tools/Sync-StackManifests.ps1. Stage 8d recreates each task (with its installer script, or by importing its XML with {{USER_SID}}, {{USER_ID}} and {{USER_PROFILE}} filled for the new account) and the startup items, then Stage 10 checks each one ran.'
            tasks         = $tasks.ToArray()
            startup       = $startup.ToArray()
            retired       = $retiredTasks
            notCovered    = @($all | Where-Object { $_.TaskName -notin $known } | ForEach-Object TaskName | Sort-Object -CaseSensitive)
            startupNotCovered = $startupOther.ToArray()
        })
}

function Get-ContainerImage([string]$Label, [scriptblock]$Docker) {
    # Every container and the image behind it, through $Docker (local or
    # over ssh). Returns rows, or $null after recording a problem.
    $lines = & $Docker @('ps', '-a', '--format', '{{.Names}}')
    if ($null -eq $lines) { return $null }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($name in ($lines | Where-Object { $_ } | Sort-Object -CaseSensitive)) {
        $info = & $Docker @('inspect', '--format', '{{.Config.Image}}|{{.Image}}|{{.State.Status}}|{{index .Config.Labels "com.docker.compose.project"}}', $name)
        if ($null -eq $info) { return $null }
        $ref, $id, $state, $project = ([string]$info[0]).Split('|')
        if ($project -eq '<no value>') { $project = '' }
        $digests = & $Docker @('image', 'inspect', '--format', '{{json .RepoDigests}}', $id)
        $repoDigests = @()
        if ($digests) { try { $repoDigests = @(ConvertFrom-Json -InputObject ($digests -join '') -NoEnumerate | ForEach-Object { $_ } | Sort-Object -CaseSensitive) } catch { $repoDigests = @() } }
        if (-not $repoDigests) { $warnings.Add("images: $Label container $name runs a local image with no registry digest") }
        $out.Add([ordered]@{ container = $name; project = $project; state = $state; image = $ref; imageId = $id; repoDigests = $repoDigests })
    }
    return , $out.ToArray()
}

function Read-Image {
    $pc = Get-ContainerImage 'PC' { param($a) Invoke-Native 'images' $DockerCommand $a }
    $vpsDocker = {
        param($a)
        $quoted = ($a | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
        Invoke-Native 'images' $SshCommand (@($sshOptions) + @($SshHost, "sudo -n docker $quoted"))
    }
    $vps = Get-ContainerImage 'VPS' $vpsDocker
    if ($null -eq $pc -or $null -eq $vps) { return }
    Add-JsonOutput 'manifests/images.json' ([ordered]@{
            '$schema'     = './schemas/images.schema.json'
            formatVersion = 1
            note          = 'Written by tools/Sync-StackManifests.ps1. The image behind every container when it was captured. Stage 5b and 7a pull registry images at these digests and build the local ones before any container is created.'
            pc            = $pc
            vps           = $vps
        })
}

function Test-ManifestSchema($Item) {
    # Each JSON manifest must match its schema in manifests/schemas before it
    # is written, so a stage never reads one it does not understand.
    $schema = Join-Path $RepoPath ('manifests/schemas/' + [IO.Path]::GetFileNameWithoutExtension($Item.Dest) + '.schema.json')
    if (-not (Test-Path -LiteralPath $schema -PathType Leaf)) { $problems.Add("$($Item.Dest): no schema at manifests/schemas"); return }
    $json = [Text.Encoding]::UTF8.GetString($Item.Bytes)
    $schemaErrors = $null
    $ok = Test-Json -Json $json -SchemaFile $schema -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    if (-not $ok) {
        $why = @($schemaErrors | Select-Object -First 3 | ForEach-Object {
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message } }) -join '; '
        $problems.Add("$($Item.Dest): does not match its schema ($why)")
    }
}

# ---------- The run ----------

function Invoke-ManifestSync {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath 'manifests') -PathType Container)) {
        $problems.Add('-RepoPath: not an ollama-cria checkout (no manifests folder)')
        return
    }
    $script:RepoPath = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
    $sections = if ($Only) { $Only } else { @('ollama', 'ollama-env', 'windows-apps', 'comfyui', 'serve', 'tasks', 'images') }
    $needsTailnet = @($sections | Where-Object { $_ -ne 'weights' }).Count -gt 0
    $endpoint = $null
    if ($needsTailnet) {
        try { $endpoint = Get-TailnetEndpoint -SshHost $SshHost -TailscaleCommand $TailscaleCommand }
        catch { $problems.Add("tailnet: $($_.Exception.Message)"); return }
    }
    foreach ($s in $sections) {
        switch ($s) {
            'ollama' { Read-Ollama }
            'ollama-env' { Read-OllamaEnv }
            'windows-apps' { Read-WindowsApp }
            'comfyui' { Read-ComfyUi }
            'weights' { Read-Weight }
            'serve' { Read-Serve }
            'tasks' { Read-Task }
            'images' { Read-Image }
        }
    }
    if ($problems.Count -gt 0) { return }

    $items = [Collections.Generic.List[object]]::new()
    foreach ($o in $outputs) {
        $text = $o.Text
        if ($endpoint) {
            try { $t = ConvertTo-StackTemplate -Text $text -Endpoint $endpoint }
            catch { $problems.Add("$($o.Dest): $($_.Exception.Message)"); continue }
            foreach ($n in $t.StaleLines) { $warnings.Add("$($o.Dest):${n}: a tailnet address no node has now; stored as a stale placeholder") }
            $text = $t.Text
        }
        if ($o.Dest -match '(?i)\.(ps1|psm1|psd1|vbs|bat|cmd)$') { $text = $text -replace "`n", "`r`n" }
        $items.Add([pscustomobject]@{ Dest = $o.Dest; Bytes = [Text.UTF8Encoding]::new($false).GetBytes($text) })
    }
    if ($problems.Count -gt 0) { return }
    foreach ($i in ($items | Where-Object Dest -Like 'manifests/*.json')) { Test-ManifestSchema $i }
    if ($problems.Count -gt 0) { return }
    foreach ($f in (Test-RepoContent -Item $items.ToArray())) { $problems.Add($f) }
    if ($problems.Count -gt 0) { return }

    foreach ($i in $items) {
        try { $status = Get-RepoFileStatus -RepoPath $RepoPath -Relative $i.Dest -Bytes $i.Bytes }
        catch { $problems.Add("$($i.Dest): $($_.Exception.Message)"); continue }
        $rows.Add([pscustomobject]@{ File = $i.Dest; Status = $status })
    }
    if ($problems.Count -gt 0 -or -not $Execute) { return }
    foreach ($i in $items) {
        $row = $rows | Where-Object File -EQ $i.Dest | Select-Object -First 1
        if ($row.Status -ne 'unchanged') { Write-RepoFile -Root $RepoPath -Relative $i.Dest -Bytes $i.Bytes }
    }
    [void](Export-EndpointManifest -RepoPath $RepoPath)
}

Invoke-ManifestSync
$result = Get-RunResult
if ($PassThru) { return $result }

foreach ($r in $result.Rows) { Write-Output ("  {0,-9} {1}" -f $r.Status, $r.File) }
foreach ($w in $result.Warnings) { Write-Output "  note: $w" }
foreach ($p in $result.Problems) { Write-Output "  PROBLEM: $p" }
$verb = if ($Execute) { 'written' } else { 'planned (nothing written; add -Execute)' }
if ($result.IsValid) { Write-Output "Sync-StackManifests: $($result.Rows.Count) file(s); $verb." }
else {
    Write-Output "Sync-StackManifests: stopped with $($result.Problems.Count) problem(s); nothing was written."
    exit 1
}
