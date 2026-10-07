#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 3: the Windows runtime. Virtualisation, WSL, the GPU driver, the
    pinned apps, Docker running and the Machine-scope Ollama profile
    (docs/RESTORE.md Stage 3).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context. Run needs admin rights; the controller starts an
    elevated child for it. Nothing that writes stack data starts here
    (C-13). ComfyUI is fetched in Stage 6, which runs as the signed-in user.

    Run:

      3a  Firmware virtualisation must be on (or a hypervisor already
          running). WSL: when the Virtual Machine Platform is not enabled or
          'wsl --version' fails, 'wsl --install --no-distribution'; a pending
          feature means a restart, and the stage carries on after it.
          The GPU: nvidia-smi must report the card in windows-apps.json; a
          different driver version is a warning. With no NVIDIA card (a
          rehearsal machine) the stage asks; -Accept gpu carries on without
          CUDA.
      3b  Every package in windows-apps.json that winget does not list is
          installed with winget at its recorded version ('exact': false means
          any version). PATH is reloaded after each install (C-53). Ollama
          and Docker Desktop are pinned so 'winget upgrade --all' leaves them
          (C-30). PowerShell is not reinstalled from inside itself.
      3c  Every variable in ollama-env.json is set at Machine scope, every
          OLLAMA_* at User scope is removed (a User copy wins over Machine,
          C-12), and Ollama is stopped when anything changed so its next
          start (Stage 6) reads the new profile.
      3d  Docker: when 'docker info' does not answer, Docker Desktop is
          started as the signed-in user and given five minutes. The first
          start asks a person to accept its terms.

    Check is checkpoint 3: virtualisation, WSL, the GPU, every package
    listed by winget, the two pins, the Docker engine answering, the Machine
    profile matching, and no OLLAMA_* at User scope.
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

$result = New-StageResult -Status $(switch ($Mode) { 'Plan' { 'planned' } 'Run' { 'done' } 'Check' { 'passed' } })
$machine = $Context.Machine
$act = $Mode -eq 'Run'
$checking = $Mode -eq 'Check'
$apps = Get-Content -LiteralPath (Join-Path $Context.RepoRoot 'manifests/windows-apps.json') -Raw | ConvertFrom-Json -AsHashtable
$ollamaEnv = Get-Content -LiteralPath (Join-Path $Context.RepoRoot 'manifests/ollama-env.json') -Raw | ConvertFrom-Json -AsHashtable

# Pinned so 'winget upgrade --all' never moves them (C-30).
$pinned = @('Docker.DockerDesktop', 'Ollama.Ollama')
# winget: restart to finish, restart started; installers: 3010, 1641.
$rebootCodes = @(-1978334967, -1978334965, 3010, 1641)
$dockerDesktop = if ($Context['DockerDesktop']) { $Context['DockerDesktop'] } else { Join-Path ([Environment]::GetFolderPath('ProgramFiles') + '\') 'Docker\Docker\Docker Desktop.exe' }
$script:reboot = $false

function Sync-ProcessPath {
    # New installs add to PATH; this window picks them up without a restart.
    $machinePath = & $machine.GetEnv 'Path' 'Machine'
    $userPath = & $machine.GetEnv 'Path' 'User'
    if (-not $machinePath) { return }
    $env:Path = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
}

function Test-Virtualisation {
    $v = & $machine.Virtualization
    $ok = [bool]($v['Firmware'] -or $v['Hypervisor'])
    if ($checking) { Add-StageCheck $result 'virtualisation' 'on' $(if ($ok) { 'on' } else { 'off' }) $ok; return $ok }
    if ($ok) { $result.Steps.Add('virtualisation is on') }
    else { Add-StageAsk $result 'Virtualisation is off in the firmware. Turn on SVM (AMD) or VT-x (Intel) in the BIOS, then run again.' }
    return $ok
}

function Test-Wsl {
    $feature = & $machine.Feature 'VirtualMachinePlatform'
    $version = & $machine.Exec 'wsl' @('--version')
    $ready = $feature -eq 'Enabled' -and $version.ExitCode -eq 0
    if ($checking) { Add-StageCheck $result 'WSL and the Virtual Machine Platform' 'ready' $(if ($ready) { 'ready' } else { "platform $feature, wsl exit $($version.ExitCode)" }) $ready; return }
    if ($ready) { $result.Steps.Add('WSL is installed and the Virtual Machine Platform is on'); return }
    if ($feature -eq 'EnablePending') { $script:reboot = $true; $result.Steps.Add('WSL is waiting for a restart'); return }
    if (-not $act) { $result.Steps.Add("would install WSL with 'wsl --install --no-distribution' (platform: $feature)"); return }
    $install = & $machine.Exec 'wsl' @('--install', '--no-distribution')
    if ($install.ExitCode -ne 0 -and $install.ExitCode -notin $rebootCodes) { $result.Problems.Add("'wsl --install --no-distribution' failed (exit $($install.ExitCode))"); return }
    $feature = & $machine.Feature 'VirtualMachinePlatform'
    if ($feature -eq 'Enabled' -and (& $machine.Exec 'wsl' @('--version')).ExitCode -eq 0) { $result.Steps.Add('installed WSL'); return }
    $script:reboot = $true
    $result.Steps.Add('installed WSL; it needs a restart')
}

function Test-Gpu {
    $want = $apps['gpu']
    $smi = & $machine.Exec 'nvidia-smi' @('--query-gpu=name,driver_version', '--format=csv,noheader')
    $line = if ($smi.ExitCode -eq 0 -and $smi.Output) { [string]$smi.Output[0] } else { '' }
    $parts = @($line -split ',\s*', 2)
    $name = $parts[0]
    $driver = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $accepted = $Context.Accepted -contains 'gpu'
    $match = $name -eq $want['name']
    if ($checking) {
        Add-StageCheck $result 'GPU (nvidia-smi)' "$($want['name']), driver $($want['driver'])" $(if ($name) { "$name, driver $driver" } elseif ($accepted) { 'none (accepted)' } else { 'none' }) ($match -or $accepted)
        return
    }
    if ($match) {
        $result.Steps.Add("GPU: $name, driver $driver")
        if ($driver -ne $want['driver']) { $result.Warnings.Add("the GPU driver is $driver, not $($want['driver']) as recorded") }
    }
    elseif ($accepted) { $result.Warnings.Add("GPU: $(if ($name) { $name } else { 'no NVIDIA card' }) instead of $($want['name']), accepted; ComfyUI and Ollama will run without CUDA") }
    elseif ($name) { Add-StageAsk $result "nvidia-smi reports $name, not $($want['name']). If that is expected (a rehearsal machine), run again with -Accept gpu." -Id 'gpu' }
    else { Add-StageAsk $result "No NVIDIA driver answers. Install driver $($want['driver']) for the $($want['name']) from nvidia.com (or let Windows Update do it), then run again. On a machine without that card, run again with -Accept gpu." -Id 'gpu' }
}

function Test-Installed([string]$Id) {
    if ($Id -eq 'Microsoft.PowerShell') { return $true }   # this is running in it
    $r = & $machine.Exec 'winget' @('list', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    return ($r.ExitCode -eq 0)
}

function Test-Pinned([string]$Id) {
    $r = & $machine.Exec 'winget' @('pin', 'list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity')
    return ($r.ExitCode -eq 0 -and @($r.Output | Where-Object { $_ -match "(^|\s)$([regex]::Escape($Id))(\s|$)" }).Count -gt 0)
}

function Install-App {
    $packages = @($apps['packages'])
    $missing = 0
    foreach ($p in $packages) {
        $id = $p['id']
        $installed = Test-Installed $id
        if ($checking) { if (-not $installed) { $missing++; $result.Problems.Add("$id is not installed") }; continue }
        if ($installed) { $result.Steps.Add("$id is installed"); continue }
        $exact = -not ($p.ContainsKey('exact') -and -not $p['exact'])
        $label = if ($exact) { "$id $($p['version'])" } else { "$id (any version)" }
        if (-not $act) { $result.Steps.Add("would install $label with winget"); continue }
        $arguments = @('install', '--id', $id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($exact) { $arguments += @('--version', $p['version']) }
        & $Context.Say "installing $label"
        $r = & $machine.Exec 'winget' $arguments -Stream
        if ($r.ExitCode -in $rebootCodes) { $script:reboot = $true; $result.Steps.Add("installed $label; it needs a restart") }
        elseif ($r.ExitCode -ne 0) { $result.Problems.Add("winget could not install $label (exit $($r.ExitCode))"); continue }
        elseif ($id -eq 'Docker.DockerDesktop') {
            # Its installer adds you to docker-users, which only counts from
            # your next sign-in; until then Docker refuses you outside an
            # admin window.
            $script:reboot = $true
            $result.Steps.Add("installed $label; it needs a restart so you join docker-users")
        }
        else { $result.Steps.Add("installed $label") }
        Sync-ProcessPath
    }
    if ($checking) { Add-StageCheck $result 'apps from windows-apps.json' "$($packages.Count) installed" "$($packages.Count - $missing) installed" ($missing -eq 0) }
    foreach ($id in $pinned) {
        if (-not ($packages | Where-Object { $_['id'] -eq $id })) { continue }
        $isPinned = Test-Pinned $id
        if ($checking) { Add-StageCheck $result "winget pin: $id" 'pinned' $(if ($isPinned) { 'pinned' } else { 'not pinned' }) $isPinned; continue }
        if ($isPinned) { $result.Steps.Add("$id is pinned"); continue }
        if (-not $act) { $result.Steps.Add("would pin $id"); continue }
        if (-not (Test-Installed $id)) { continue }
        $r = & $machine.Exec 'winget' @('pin', 'add', '--id', $id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
        if ($r.ExitCode -eq 0) { $result.Steps.Add("pinned $id") } else { $result.Problems.Add("winget could not pin $id (exit $($r.ExitCode))") }
    }
}

function Install-OllamaProfile {
    $changed = 0
    $wrong = 0
    foreach ($v in @($ollamaEnv['variables'])) {
        $now = & $machine.GetEnv $v['name'] 'Machine'
        if ($v['value'] -match '^[A-Za-z]:\\' -and -not $checking) {
            $drive = $v['value'].Substring(0, 3)
            if (-not (Test-Path -LiteralPath $drive)) { $result.Warnings.Add("$($v['name']) points at $($v['value']), but there is no $drive drive") }
        }
        if ($now -ceq $v['value']) { continue }
        if ($checking) { $wrong++; continue }
        if (-not $act) { $result.Steps.Add("would set $($v['name']) at Machine scope"); continue }
        & $machine.SetEnv $v['name'] $v['value'] 'Machine'
        $changed++
    }
    $userCopies = @(& $machine.EnvNames 'User' | Where-Object { $_ -match '^OLLAMA_' } | Sort-Object)
    if ($checking) {
        $total = @($ollamaEnv['variables']).Count
        Add-StageCheck $result 'Ollama profile at Machine scope' "$total of $total" "$($total - $wrong) of $total" ($wrong -eq 0)
        Add-StageCheck $result 'OLLAMA_* at User scope' 'none' $(if ($userCopies) { $userCopies -join ', ' } else { 'none' }) ($userCopies.Count -eq 0)
        return
    }
    foreach ($name in $userCopies) {
        if (-not $act) { $result.Steps.Add("would remove $name at User scope"); continue }
        & $machine.SetEnv $name $null 'User'
        $changed++
    }
    if (-not $act) { return }
    if ($changed -eq 0) { $result.Steps.Add('the Ollama profile is already in place'); return }
    $stopped = (& $machine.StopProcess 'ollama app') + (& $machine.StopProcess 'ollama')
    $result.Steps.Add("set the Ollama profile ($changed changes)$(if ($stopped) { '; stopped Ollama so Stage 6 starts it with the new profile' })")
}

function Test-Docker {
    $info = & $machine.Exec 'docker' @('info', '--format', '{{.ServerVersion}}')
    $version = if ($info.ExitCode -eq 0 -and $info.Output) { [string]$info.Output[0] } else { $null }
    if ($checking) {
        Add-StageCheck $result 'Docker engine answers' 'a server version' $(if ($version) { $version } else { 'no answer' }) ([bool]$version)
        if (-not $version) { $result.Warnings.Add("Docker does not answer this window. Start Docker Desktop; if it was installed since you last signed in to Windows, sign out and in first (that is when you join docker-users).") }
        return
    }
    if ($version) { $result.Steps.Add("Docker engine $version answers"); return }
    if ($script:reboot) { $result.Steps.Add('Docker starts after the restart'); return }
    if (-not $act) { $result.Steps.Add('would start Docker Desktop and wait for its engine'); return }
    if (-not (Test-Path -LiteralPath $dockerDesktop -PathType Leaf)) { $result.Problems.Add("Docker Desktop is not at $dockerDesktop"); return }
    & $Context.Say 'starting Docker Desktop as you and waiting up to five minutes for its engine'
    & $machine.StartProcess $dockerDesktop
    for ($i = 0; $i -lt 30; $i++) {
        & $machine.Wait 10
        $info = & $machine.Exec 'docker' @('info', '--format', '{{.ServerVersion}}')
        if ($info.ExitCode -eq 0 -and $info.Output) { $result.Steps.Add("Docker engine $($info.Output[0]) answers"); return }
    }
    Add-StageAsk $result "Docker Desktop's engine did not answer. Open Docker Desktop, accept its terms and wait for 'Engine running'. If it asks you to sign out and in, do that. Then run again."
}

if ($Mode -eq 'Plan' -and -not (& $machine.IsElevated)) {
    $result.Warnings.Add('without admin rights the WSL feature state reads as unknown; the run itself is elevated')
}

$virtualOk = Test-Virtualisation
if ($virtualOk -or $checking) {
    Test-Wsl
    Test-Gpu
    Install-App
    Install-OllamaProfile
    Test-Docker
}

if ($Mode -eq 'Plan') { $result.Status = 'planned' }
elseif ($result.Problems.Count) { $result.Status = 'failed' }
elseif ($Mode -eq 'Run' -and $script:reboot -and $result.Status -eq 'done') { $result.Status = 'reboot' }
return $result
