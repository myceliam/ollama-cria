#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 6: fetch ComfyUI, the Ollama models and the ComfyUI weights, each
    from its origin and checked (docs/RESTORE.md Stages 3d and 6).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context, as the signed-in user. Needs Stages 1 and 3.

    Run:

      ComfyUI  Cloned into its root (topology.json) at the commit in
               comfyui-nodes.json, with a Python venv of that version and
               comfyui-requirements.lock installed from both package
               indexes (C-18). Each custom node is cloned at its commit.
               A folder the controller did not create is only checked,
               never changed. Each piece is marked 'keep' once checked, so
               an interrupted run wipes only the piece it was on.
      Ollama   Started as the signed-in user if it does not answer. Every
               registry model is pulled and its digest compared; every
               modelfile model is rebuilt from its base with its Modelfile
               (C-17). A digest that differs (the tag has moved on) stops
               for a person: -Accept model:<name> keeps the newer build, and
               nothing is ever swapped silently (C-48). Free space is checked
               first.
      Weights  Each row of comfyui-weights.json is downloaded with curl to
               <dest>.partial (resumed when it is already there), its size
               and SHA-256 checked, and only then renamed (C-17). Links are
               https only, also after redirects. A row with auth civitai or
               huggingface needs that site's token as one line in
               <staging>\download-tokens\<auth>-token.txt (6c); it travels to
               curl in an owner-only header file that is deleted afterwards,
               never in an argument or a URL (C-14), and curl does not send it
               on to another host. A checked file is remembered by size and
               time, so later runs and checks do not hash it again.

    Check is checkpoint 6: ComfyUI and every node at their commits, torch
    sees CUDA (unless the GPU was accepted as missing), every model present
    with its digest (or an accepted newer one), mxbai-embed-large present,
    and every required weight present as checked.
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

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
$machine = $Context.Machine
$repo = $Context.RepoRoot
$act = $Mode -eq 'Run'
$checking = $Mode -eq 'Check'
$onWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)

function Read-Manifest([string]$Name) { Get-Content -LiteralPath (Join-Path $repo "manifests/$Name") -Raw | ConvertFrom-Json -AsHashtable }
$nodes = Read-Manifest 'comfyui-nodes.json'
$models = @((Read-Manifest 'ollama-models.json')['models'])
$weights = @((Read-Manifest 'comfyui-weights.json')['weights'])
$lock = Join-Path $repo 'manifests/comfyui-requirements.lock'
$comfy = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['comfyui']['path']))
$venv = Join-Path $comfy '.venv'
$venvPython = if ($onWindows) { Join-Path $venv 'Scripts\python.exe' } else { Join-Path $venv 'bin/python' }
$modelsRoot = Join-Path $comfy 'models'
$tokens = Join-Path ([IO.Path]::GetFullPath($Context.StagingRoot)) 'download-tokens'
$ollamaApi = 'http://127.0.0.1:11434'
$ollamaApp = if ($Context['OllamaApp']) { $Context['OllamaApp'] } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs/Ollama/ollama app.exe' }

$stage3 = $Context.State['stages']['3']
$gpuAccepted = ($Context.Accepted -contains 'gpu') -or ($stage3 -is [hashtable] -and @($stage3['accepted']) -contains 'gpu')
$verified = @{}
if ($Context.Data['Verified'] -is [hashtable]) { foreach ($k in $Context.Data['Verified'].Keys) { $verified[$k] = $Context.Data['Verified'][$k] } }
$newerDigest = @{}
if ($Context.Data['AcceptedDigests'] -is [hashtable]) { foreach ($k in $Context.Data['AcceptedDigests'].Keys) { $newerDigest[$k] = $Context.Data['AcceptedDigests'][$k] } }

# ---------- ComfyUI ----------

function Get-Head([string]$Folder) {
    if (-not (Test-Path -LiteralPath (Join-Path $Folder '.git'))) { return $null }
    $r = & $machine.Exec 'git' @('-C', $Folder, 'rev-parse', 'HEAD')
    if ($r.ExitCode -eq 0 -and $r.Output -and $r.Output[0] -match '^[0-9a-f]{40}$') { return $r.Output[0] }
    return $null
}

function Sync-Checkout([string]$Label, [string]$Folder, [string]$Url, [string]$Commit, [string]$Root) {
    # A git checkout of $Url at $Commit in $Folder. Returns $true when it is.
    $check = & $Context.PathCheck -Path $Folder -Root $Root -AllowRoot -Detailed
    if (-not $check.IsValid) { $result.Problems.Add("$($Label): $($check.Reason)"); return $false }
    $head = Get-Head $Folder
    if ($checking) {
        Add-StageCheck $result "$Label at its commit" $Commit.Substring(0, 12) $(if ($head) { $head.Substring(0, 12) } else { 'not a checkout' }) ($head -eq $Commit)
        return ($head -eq $Commit)
    }
    if ($head -eq $Commit) {
        $result.Steps.Add("$Label is at $($Commit.Substring(0, 12))")
        if ($act -and (& $Context.IsOwned $Folder)) { & $Context.Keep $Folder }
        return $true
    }
    $exists = Test-Path -LiteralPath $Folder
    $owned = $exists -and (& $Context.IsOwned $Folder)
    if ($exists -and -not $owned) {
        $result.Problems.Add("$($Label): $Folder is $(if ($head) { "at $($head.Substring(0, 12))" } else { 'not a git checkout' }); the controller does not change a folder it did not create")
        return $false
    }
    if (-not $act) { $result.Steps.Add("would $(if ($head) { 'move' } else { 'clone' }) $Label to $($Commit.Substring(0, 12))"); return $false }
    if ($exists -and -not $head) {
        # A clone of ours that never finished: start it again.
        $removed = & $Context.RemoveOwned $Folder
        if ($removed -notin 'removed', 'gone') { $result.Problems.Add("$($Label): the unfinished clone in $Folder could not be removed ($removed)"); return $false }
        $exists = $false
    }
    if (-not $exists) {
        $made = @(New-FolderChain -Path $Folder)
        foreach ($m in $made) { & $Context.Own 'folder' $m $(if ($m -eq [IO.Path]::GetFullPath($Folder)) { $Root } else { $m }) $(if ($m -eq [IO.Path]::GetFullPath($Folder)) { 'wipe' } else { 'keep' }) }
        & $Context.Say "cloning $Label"
        $r = & $machine.Exec 'git' @('clone', '--quiet', '--no-checkout', $Url, $Folder) -Stream
        if ($r.ExitCode -ne 0) { $result.Problems.Add("$($Label): git clone failed (exit $($r.ExitCode))"); return $false }
    }
    else {
        $r = & $machine.Exec 'git' @('-C', $Folder, 'fetch', '--quiet', 'origin') -Stream
        if ($r.ExitCode -ne 0) { $result.Problems.Add("$($Label): git fetch failed (exit $($r.ExitCode))"); return $false }
    }
    $r = & $machine.Exec 'git' @('-C', $Folder, '-c', 'advice.detachedHead=false', 'checkout', '--quiet', '--detach', $Commit)
    if ($r.ExitCode -ne 0) { $result.Problems.Add("$($Label): git checkout of $($Commit.Substring(0, 12)) failed (exit $($r.ExitCode))"); return $false }
    if ((Get-Head $Folder) -ne $Commit) { $result.Problems.Add("$($Label): not at $($Commit.Substring(0, 12)) after checkout"); return $false }
    & $Context.Keep $Folder
    $result.Steps.Add("$Label checked out at $($Commit.Substring(0, 12))")
    return $true
}

function Install-Venv {
    $python = [string]$nodes['python']
    $short = ($python -split '\.')[0..1] -join '.'
    $lockSha = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant()
    $owned = (Test-Path -LiteralPath $venv) -and (& $Context.IsOwned $venv)
    if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
        if (-not $owned) { $result.Warnings.Add("the ComfyUI venv was not created by the controller; its packages are only checked, not installed"); return }
        if ($Context.Data['LockSha256'] -eq $lockSha) { $result.Steps.Add('the ComfyUI venv has the locked packages'); return }
    }
    if (-not $act) { $result.Steps.Add("would create the ComfyUI venv with Python $short and install comfyui-requirements.lock"); return }
    $version = & $machine.Exec 'py' @("-$short", '--version')
    $found = if ($version.ExitCode -eq 0 -and $version.Output) { ([string]$version.Output[0]) -replace '^Python\s+', '' } else { $null }
    if (-not $found) { $result.Problems.Add("Python $short is not installed (Stage 3 installs it)"); return }
    if ($found -ne $python) { $result.Warnings.Add("Python is $found, not $python as recorded") }
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        if (Test-Path -LiteralPath $venv) {
            if (-not $owned) { $result.Problems.Add("$venv exists without a Python in it, and the controller did not create it"); return }
            & $Context.RemoveOwned $venv | Out-Null
        }
        $r = & $machine.Exec 'py' @("-$short", '-m', 'venv', $venv)
        if ($r.ExitCode -ne 0) { $result.Problems.Add("creating the venv failed (exit $($r.ExitCode))"); return }
        & $Context.Own 'folder' $venv $comfy 'wipe'
    }
    $indexes = @($nodes['pipIndexUrls'])
    $arguments = @('-m', 'pip', 'install', '--disable-pip-version-check', '--requirement', $lock, '--index-url', $indexes[0])
    foreach ($extra in @($indexes | Select-Object -Skip 1)) { $arguments += @('--extra-index-url', $extra) }
    & $Context.Say 'installing the ComfyUI packages from comfyui-requirements.lock'
    $r = & $machine.Exec $venvPython $arguments -Stream
    if ($r.ExitCode -ne 0) { $result.Problems.Add("pip could not install comfyui-requirements.lock (exit $($r.ExitCode))"); return }
    & $Context.Keep $venv
    $result.Data['LockSha256'] = $lockSha
    $result.Steps.Add('created the ComfyUI venv and installed the locked packages')
}

function Install-ComfyUI {
    $c = $nodes['comfyui']
    $ok = Sync-Checkout 'ComfyUI' $comfy $c['repo'] $c['commit'] $comfy
    foreach ($n in @($nodes['nodes'])) {
        if ($n['name'] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $result.Problems.Add("custom node name '$($n['name'])' is not a plain folder name"); continue }
        if (-not $ok -and -not $checking) { continue }
        $null = Sync-Checkout "custom node $($n['name'])" (Join-Path $comfy "custom_nodes/$($n['name'])") $n['repo'] $n['commit'] $comfy
    }
    foreach ($m in @($nodes['manual'])) { $result.Warnings.Add("install by hand (not automated): $m") }
    if ($checking) {
        $r = & $machine.Exec $venvPython @('-c', 'import torch; print(torch.cuda.is_available())')
        $cuda = $r.ExitCode -eq 0 -and $r.Output -and $r.Output[-1] -eq 'True'
        Add-StageCheck $result 'torch sees CUDA' 'True' $(if ($r.ExitCode -ne 0) { 'torch does not load' } elseif ($cuda) { 'True' } elseif ($gpuAccepted) { 'False (GPU accepted as missing)' } else { 'False' }) ($cuda -or ($gpuAccepted -and $r.ExitCode -eq 0))
        return
    }
    if ($ok) { Install-Venv }
}

# ---------- Ollama ----------

function Get-OllamaModel {
    $tags = & $machine.HttpJson "$ollamaApi/api/tags"
    if ($null -eq $tags) { return $null }
    $have = @{}
    foreach ($m in @($tags.models)) { if ($m) { $have[[string]$m.name] = [string]$m.digest } }
    return $have
}

function Wait-Ollama {
    if ($null -ne (& $machine.HttpJson "$ollamaApi/api/version")) { return $true }
    if (-not $act) { $result.Steps.Add('would start Ollama'); return $false }
    if (-not (Test-Path -LiteralPath $ollamaApp -PathType Leaf)) { $result.Problems.Add("Ollama is not answering and is not installed at $ollamaApp"); return $false }
    & $machine.StartProcess $ollamaApp
    for ($i = 0; $i -lt 12; $i++) {
        & $machine.Wait 5
        if ($null -ne (& $machine.HttpJson "$ollamaApi/api/version")) { $result.Steps.Add('started Ollama'); return $true }
    }
    Add-StageAsk $result 'Ollama did not answer on 127.0.0.1:11434. Start Ollama from the Start menu, then run again.'
    return $false
}

function Test-Digest($Row, [string]$Have) {
    # 'ok', 'accepted' or 'differs'.
    if ($Have -eq $Row['digest']) { return 'ok' }
    if ($newerDigest[$Row['name']] -eq $Have -or $Context.Accepted -contains "model:$($Row['name'])") { $newerDigest[$Row['name']] = $Have; return 'accepted' }
    return 'differs'
}

function Install-OllamaModel {
    $up = $checking -or (Wait-Ollama)
    $have = if ($up) { Get-OllamaModel } else { $null }
    if ($null -eq $have) {
        if ($checking) { Add-StageCheck $result 'Ollama answers' 'yes' 'no' $false }
        elseif ($up) { $result.Problems.Add('Ollama answered, but its model list cannot be read') }
        else { $result.Steps.Add("would pull $(@($models | Where-Object source -eq 'registry').Count) models and build $(@($models | Where-Object source -eq 'modelfile').Count)") }
        return
    }
    $missing = @($models | Where-Object { -not $have.ContainsKey($_['name']) })
    if ($checking) {
        $bad = @(foreach ($m in $models) { if (-not $have.ContainsKey($m['name']) -or (Test-Digest $m $have[$m['name']]) -eq 'differs') { $m['name'] } })
        Add-StageCheck $result 'Ollama models present with their digests' "$($models.Count) of $($models.Count)" "$($models.Count - $bad.Count) of $($models.Count)" ($bad.Count -eq 0)
        $embed = @($have.Keys | Where-Object { $_ -like 'mxbai-embed-large*' }).Count -gt 0
        Add-StageCheck $result 'mxbai-embed-large present (OWUI embeddings)' 'yes' $(if ($embed) { 'yes' } else { 'no' }) $embed
        return
    }
    $need = [long](($missing | ForEach-Object { [long]$_['bytes'] } | Measure-Object -Sum).Sum)
    $store = [Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['ollama-models']['path'])
    if ($need -gt 0) {
        $free = [long](& $machine.FreeBytes $store)
        if ($free -lt [long]($need * 1.05)) { $result.Problems.Add("not enough free space for the models: $([math]::Round($need / 1GB)) GB needed, $([math]::Round($free / 1GB)) GB free on the drive of $store"); return }
    }
    if (-not $act) {
        $result.Steps.Add("would pull or build $($missing.Count) of $($models.Count) Ollama models ($([math]::Round($need / 1GB)) GB)")
        return
    }
    $order = @($models | Where-Object { $_['source'] -eq 'registry' }) + @($models | Where-Object { $_['source'] -eq 'modelfile' })
    foreach ($m in $order) {
        $name = $m['name']
        if (-not $have.ContainsKey($name)) {
            if ($m['source'] -eq 'registry') {
                & $Context.Say "pulling $name"
                $r = & $machine.Exec 'ollama' @('pull', $name) -Stream
                if ($r.ExitCode -ne 0) { $result.Problems.Add("ollama pull $name failed (exit $($r.ExitCode))"); continue }
            }
            else {
                $file = Join-Path $repo $m['modelfile']
                if (-not $have.ContainsKey($m['base']) -and -not (Get-OllamaModel).ContainsKey($m['base'])) { $result.Problems.Add("$($name): its base $($m['base']) is not there"); continue }
                & $Context.Say "building $name from its Modelfile"
                $r = & $machine.Exec 'ollama' @('create', $name, '-f', $file) -Stream
                if ($r.ExitCode -ne 0) { $result.Problems.Add("ollama create $name failed (exit $($r.ExitCode))"); continue }
            }
            $have = Get-OllamaModel
            if ($null -eq $have -or -not $have.ContainsKey($name)) { $result.Problems.Add("$($name): not listed after it was fetched"); $have = @{}; continue }
        }
        switch (Test-Digest $m $have[$name]) {
            'ok' { }
            'accepted' { $result.Warnings.Add("$($name): a newer build than recorded, accepted") }
            default { Add-StageAsk $result "$($name): Ollama now has a different build than recorded (the tag has moved on). Keep it with -Accept 'model:$name', or stop here." -Id "model:$name" }
        }
    }
    $result.Steps.Add("Ollama: $($models.Count) models checked, $($missing.Count) fetched")
    $result.Data['AcceptedDigests'] = $newerDigest
}

# ---------- Weights ----------

function Get-Token([string]$Auth) {
    # The token for a site, from the staging folder, or $null after an ask.
    $file = Join-Path $tokens "$Auth-token.txt"
    if ($act -and -not (Test-Path -LiteralPath $tokens)) {
        # Inside the staging folder, so owner-only by inheritance.
        $staging = [IO.Path]::GetFullPath($Context.StagingRoot)
        $check = & $Context.PathCheck -Path $tokens -Root $staging -Detailed
        if (-not $check.IsValid) { $result.Problems.Add("$($tokens): $($check.Reason)"); return $null }
        $null = [IO.Directory]::CreateDirectory($tokens)
        & $Context.Own 'folder' $tokens $staging 'keep' -Plaintext
    }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Add-StageAsk $result "Some weights need your $Auth token. Copy it from Bitwarden into a new file $file, one line, then run again. (Stage 11 deletes it.)"
        return $null
    }
    $check = & $Context.PathCheck -Path $file -Root ([IO.Path]::GetFullPath($Context.StagingRoot)) -Detailed
    if (-not $check.IsValid) { $result.Problems.Add("$($file): $($check.Reason)"); return $null }
    $why = Get-ProtectionProblem -Path $file
    if ($why) { $result.Problems.Add("$($file): $why; save it inside $tokens so only you can read it"); return $null }
    $token = ([IO.File]::ReadAllText($file)).Trim()
    if ($token -notmatch '^[A-Za-z0-9._~+/=-]{16,512}$') { $result.Problems.Add("$($file): holds more than one line or characters a token does not have"); return $null }
    if ($act -and -not (& $Context.IsOwned $file)) { & $Context.Own 'file' $file ([IO.Path]::GetFullPath($Context.StagingRoot)) 'keep' -Plaintext -Adopted }
    return $token
}

function Write-HeaderFile([string]$Auth, [string]$Token) {
    $file = Join-Path $tokens ".$Auth.header"
    if (Test-Path -LiteralPath $file) {
        if ((& $Context.RemoveOwned $file) -notin 'removed', 'gone') { throw [InvalidOperationException]::new("$file is in the way and the controller did not create it") }
    }
    $stream = Open-NewOwnerOnlyFile -Path $file
    try {
        $bytes = [Text.Encoding]::ASCII.GetBytes("Authorization: Bearer $Token`n")
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    & $Context.Own 'file' $file ([IO.Path]::GetFullPath($Context.StagingRoot)) 'wipe' -Plaintext
    return $file
}

function Test-Verified([string]$Dest, $Row) {
    $v = $verified[$Dest]
    if (-not ($v -is [hashtable])) { return $false }
    $item = Get-Item -LiteralPath $Dest -ErrorAction SilentlyContinue
    return ($item -and $item.Length -eq [long]$Row['bytes'] -and [long]$v['bytes'] -eq $item.Length -and [long]$v['ticks'] -eq $item.LastWriteTimeUtc.Ticks -and $v['sha256'] -eq $Row['sha256'])
}

function Add-Verified([string]$Dest, $Row) {
    $item = Get-Item -LiteralPath $Dest
    $verified[$Dest] = @{ bytes = $item.Length; ticks = $item.LastWriteTimeUtc.Ticks; sha256 = $Row['sha256'] }
}

function Get-Weight {
    $todo = [Collections.Generic.List[object]]::new()
    $bad = 0
    $unhashed = 0
    foreach ($w in $weights) {
        $check = & $Context.PathCheck -Path $w['dest'] -Root $modelsRoot -Relative -Detailed
        if (-not $check.IsValid) { $result.Problems.Add("weight $($w['dest']): $($check.Reason)"); continue }
        $dest = $check.FullPath
        if (Test-Verified $dest $w) { continue }
        if ($checking) { if ($w['required']) { $bad++; $result.Problems.Add("weight $($w['dest']): missing or not checked") }; continue }
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            $item = Get-Item -LiteralPath $dest
            # Plan does not hash: a weight can be tens of GB.
            if (-not $act -and $item.Length -eq [long]$w['bytes']) { $unhashed++; continue }
            if ($item.Length -eq [long]$w['bytes'] -and (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant() -eq $w['sha256']) {
                if ($act) { Add-Verified $dest $w }
                continue
            }
            $result.Problems.Add("weight $($w['dest']): a different file is already there; move it away and run again")
            continue
        }
        if (-not $w['url']) {
            $text = "weight $($w['dest']) has no download link: copy the file to $dest by hand, or add its url to manifests/comfyui-weights.json"
            if ($w['required']) { Add-StageAsk $result $text } else { $result.Warnings.Add("$text (optional)") }
            continue
        }
        $todo.Add(@{ Row = $w; Dest = $dest })
    }
    if ($checking) {
        $required = @($weights | Where-Object { $_['required'] }).Count
        Add-StageCheck $result 'required weights present and checked' "$required of $required" "$($required - $bad) of $required" ($bad -eq 0)
        return
    }
    $need = [long](($todo | ForEach-Object { [long]$_.Row['bytes'] } | Measure-Object -Sum).Sum)
    if ($unhashed) { $result.Steps.Add("would check $unhashed weights that are already there") }
    if ($todo.Count -eq 0) { $result.Steps.Add("weights: all $($weights.Count - $unhashed) others in place and checked"); return }
    if (-not $act) { $result.Steps.Add("would download $($todo.Count) of $($weights.Count) weights ($([math]::Round($need / 1GB)) GB)"); return }
    $free = [long](& $machine.FreeBytes $comfy)
    if ($free -lt [long]($need * 1.05)) { $result.Problems.Add("not enough free space for the weights: $([math]::Round($need / 1GB)) GB needed, $([math]::Round($free / 1GB)) GB free"); return }

    $headers = @{}
    try {
        foreach ($auth in @($todo | ForEach-Object { $_.Row['auth'] } | Where-Object { $_ -ne 'none' } | Sort-Object -Unique)) {
            $token = Get-Token $auth
            if ($token) { $headers[$auth] = Write-HeaderFile $auth $token }
            $token = $null
        }
        $done = 0
        foreach ($t in $todo) {
            $w = $t.Row
            if ($w['auth'] -ne 'none' -and -not $headers.ContainsKey($w['auth'])) { continue }
            if (Save-Weight $t.Dest $w $(if ($w['auth'] -ne 'none') { $headers[$w['auth']] } else { $null })) { $done++ }
        }
        $result.Steps.Add("weights: downloaded and checked $done of $($todo.Count)")
    }
    finally {
        foreach ($h in $headers.Values) { & $Context.RemoveOwned $h | Out-Null }
    }
}

function Save-Weight([string]$Dest, $Row, [string]$HeaderFile) {
    $partial = "$Dest.partial"
    $null = New-FolderChain -Path ([IO.Path]::GetDirectoryName($Dest))
    if (Test-Path -LiteralPath $partial) {
        if (-not (& $Context.IsOwned $partial)) { $result.Problems.Add("weight $($Row['dest']): $partial is in the way and the controller did not create it"); return $false }
        if ((Get-Item -LiteralPath $partial).Length -gt [long]$Row['bytes']) { [IO.File]::WriteAllBytes($partial, [byte[]]@()) }
    }
    else {
        [IO.File]::WriteAllBytes($partial, [byte[]]@())
        & $Context.Own 'file' $partial $modelsRoot 'keep'
    }
    if ((Get-Item -LiteralPath $partial).Length -lt [long]$Row['bytes']) {
        & $Context.Say "downloading $($Row['dest'])"
        $arguments = @('--fail', '--location', '--proto', '=https', '--proto-redir', '=https', '--retry', '3', '--retry-delay', '5',
            '--continue-at', '-', '--output', $partial)
        if ($HeaderFile) { $arguments += @('--header', "@$HeaderFile") }
        $arguments += $Row['url']
        $r = & $machine.Exec 'curl' $arguments -Stream
        if ($r.ExitCode -ne 0) {
            $text = "weight $($Row['dest']): download failed (curl exit $($r.ExitCode)); run again to resume"
            if ($Row['required']) { $result.Problems.Add($text) } else { $result.Warnings.Add($text) }
            return $false
        }
    }
    $size = (Get-Item -LiteralPath $partial).Length
    $sha = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($size -ne [long]$Row['bytes'] -or $sha -ne $Row['sha256']) {
        & $Context.RemoveOwned $partial | Out-Null
        $text = "weight $($Row['dest']): the download does not match its size and SHA-256; it was deleted"
        if ($Row['required']) { $result.Problems.Add($text) } else { $result.Warnings.Add($text) }
        return $false
    }
    [IO.File]::Move($partial, $Dest, $false)
    & $Context.RemoveOwned $partial | Out-Null
    & $Context.Own 'file' $Dest $modelsRoot 'keep'
    Add-Verified $Dest $Row
    return $true
}

# ---------- The stage ----------

Install-ComfyUI
Install-OllamaModel
if ($checking -or (Test-Path -LiteralPath $comfy -PathType Container)) { Get-Weight }
elseif ($Mode -eq 'Plan') { $result.Steps.Add('would download the weights once ComfyUI is cloned') }
$result.Data['Verified'] = $verified

if ($Mode -eq 'Plan') { $result.Status = 'planned' }
elseif ($result.Problems.Count) { $result.Status = 'failed' }
return $result
