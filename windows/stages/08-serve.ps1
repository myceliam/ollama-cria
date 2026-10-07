#Requires -Version 7.4
<#
.SYNOPSIS
    Stage 8: start services, Tailscale Serve and automation (docs/RESTORE.md
    Stage 8).

.DESCRIPTION
    Run by Invoke-StackRecovery.ps1 with -Mode Plan, Run or Check and the
    controller's -Context, in an elevated window. Needs Stage 7.

    It works for the account signed in at the console: a window elevated as
    another account is refused, because the tasks and the Startup folder
    would be that account's.

    Run, in this order:

      8a  Port 8188 is reserved (an administered TCP exclusion), so WinNAT
          cannot take it from ComfyUI after a restart. Only when it is not:
          winnat is stopped, the range added and winnat started again, even
          when adding failed (C-31). Then the inbound firewall rule
          'ComfyUI 8188 - loopback and tailnet only' (C-52) and the pagefile,
          32768 to 81920 MB on C: (R-07; it takes effect at the restart in
          Stage 10). Each is changed only when it differs; a rule or setting
          this stage did not make is reported, never changed.
      8b  The startup items in manifests/tasks.json: the ComfyUI launcher is
          copied into the Startup folder and the AutoFree shortcut made.
          ComfyUI is started once through the launcher, as you, and must
          answer. Then start-stack.ps1 brings up the PC stack. It still
          exits 0 when a service is down (C-27 is not in it yet), so this
          stage checks for itself: every service of every PC compose project
          running and healthy, every container on its current configuration
          (one left from Stage 7 with old settings is recreated), and every
          health URL below answering 200. Then OWUI's tool catalogue must
          list every tool server the seed enables; OWUI is restarted once
          when one is missing (a catalogue cached while mcpo was down).
      8c  Tailscale Serve: every rule in manifests/serve.json is added with
          'tailscale serve --bg'. A port already serving something else, an
          extra rule or Funnel is reported, never changed (C-23).
      8d  Scheduled tasks: each task in manifests/tasks.json that is not on
          this PC is imported from its XML (the live definition) with this
          account's SID, name and profile folder, once the scripts and
          programs it runs are here. A task already there is left alone, and
          one the manifest has disabled is disabled. Tasks that start only at
          sign-in (the PowerShell tool's broker, LibreHardwareMonitor) are
          started now, so Stage 9 finds them running.

    Check is checkpoint 8: the port reserved, the firewall rule in place and
    no other rule opening 8188, the pagefile, the startup items,
    start-stack.ps1's exit code, every service running healthy on its
    current configuration, every health URL at 200, the tool catalogue,
    exactly the Serve rules with Funnel off, every task present with the
    manifest's enabled state; and, from Liam, OWUI opening on the PC's
    tailnet name from the phone (-Accept owui-phone).
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
foreach ($k in @($Context.Data.Keys)) { $result.Data[$k] = $Context.Data[$k] }
$machine = $Context.Machine
$repo = $Context.RepoRoot
$act = $Mode -eq 'Run'
$checking = $Mode -eq 'Check'
$owuiUrl = 'http://127.0.0.1:3000'
$comfyPort = 8188
$comfyUrl = "http://127.0.0.1:$comfyPort/system_stats"
$keyPath = Join-Path $Context.StagingRoot 'owui-api-key.txt'
$seedDir = Join-Path $repo 'manifests/owui-seed/seed'
$ollamaApp = if ($Context['OllamaApp']) { $Context['OllamaApp'] } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs/Ollama/ollama app.exe' }
$serveRules = @((Get-Content -LiteralPath (Join-Path $repo 'manifests/serve.json') -Raw | ConvertFrom-Json -AsHashtable)['rules'])
$taskManifest = Get-Content -LiteralPath (Join-Path $repo 'manifests/tasks.json') -Raw | ConvertFrom-Json -AsHashtable
$sources = @((Get-Content -LiteralPath (Join-Path $repo 'manifests/stack-files.json') -Raw | ConvertFrom-Json -AsHashtable)['sources'])
$projects = @($Context.Topology['composeProjects'] | Where-Object {
        $r = $Context.Topology['roots'][$_['root']]
        $r -and $r['host'] -eq 'pc'
    })
$owuiProject = @($projects | Where-Object { $_['name'] -eq 'ollama' }) | Select-Object -First 1
$stackRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Context.Topology['roots']['stack']['path']))

# The live PC's rule (read 7 October 2026): TCP 8188 from the tailnet's
# range and this PC only. Docker's containers reach ComfyUI through
# Docker Desktop, which connects from this PC.
$firewallName = 'ComfyUI 8188 - loopback and tailnet only'
$firewallRemote = @('100.64.0.0/10', '127.0.0.1')
$quietRemote = @('100.64.0.0/10', '100.64.0.0/255.192.0.0', '127.0.0.1', '::1')
$pagefile = @{ Name = 'C:\pagefile.sys'; InitialSize = 32768; MaximumSize = 81920 }

# What must answer 200 on this PC (C-27): a 401, 404 or 500 is a failure.
# Bolt publishes only on the tailnet address; its compose health check and
# Stage 9 cover it.
$healthUrls = [ordered]@{
    'Open WebUI'            = "$owuiUrl/health"
    'mcpo-core'             = 'http://127.0.0.1:18000/openapi.json'
    'open-terminal'         = 'http://127.0.0.1:18019/openapi.json'
    'SearXNG via the relay' = 'http://127.0.0.1:8080/config'
    'Jina Reader via the relay' = 'http://127.0.0.1:3001/'
    'gcal bridge'           = 'http://127.0.0.1:18100/health'
    'Gmail bridge'          = 'http://127.0.0.1:18101/health'
    'ntfy'                  = 'http://127.0.0.1:8090/v1/health'
    'Dozzle'                = 'http://127.0.0.1:18088/'
    'dashboard'             = 'http://127.0.0.1:6080/'
    'ComfyUI'               = $comfyUrl
    'Ollama'                = 'http://127.0.0.1:11434/api/version'
}

# ---------- helpers ----------

function Get-Field($Object, [string]$Name) {
    # A property of a parsed JSON object or a key of a hashtable, or $null.
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-ComposeArgument($Project) {
    $root = $Context.Topology['roots'][$Project['root']]
    $file = [IO.Path]::GetFullPath((Join-Path ([Environment]::ExpandEnvironmentVariables($root['path'])) $Project['file']))
    return @('compose', '-p', $Project['name'], '-f', $file, '--project-directory', [IO.Path]::GetDirectoryName($file))
}

function Invoke-Docker([string[]]$Arguments) { & $machine.Exec 'docker' $Arguments }

function Get-Line($Run) {
    # The non-empty output lines of a command, trimmed.
    return , @(@($Run.Output) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

function Resolve-RepoFile([string]$RepoPath) {
    # Where a file of this repo lives on this PC (manifests/stack-files.json
    # and the topology's roots), or $null.
    foreach ($s in $sources) {
        if ($s['host'] -ne 'pc') { continue }
        $prefix = "$($s['repoFolder'])/"
        if (-not $RepoPath.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        $topologyRoot = $Context.Topology['roots'][$s['name']]
        $root = if ($topologyRoot) { $topologyRoot['path'] } else { $s['root'] }
        return [IO.Path]::GetFullPath((Join-Path ([Environment]::ExpandEnvironmentVariables($root)) $RepoPath.Substring($prefix.Length)))
    }
    return $null
}

function Test-FullPath([string]$Path) {
    # True for an absolute Windows (or, in the tests, Unix) path.
    return [IO.Path]::IsPathFullyQualified($Path)
}

function Expand-AccountText([string]$Text, $Account, [switch]$Xml) {
    # The account's SID, name and profile folder in place of the
    # placeholders tools/Sync-StackManifests.ps1 left.
    $values = @{ '{{USER_SID}}' = $Account.Sid; '{{USER_ID}}' = $Account.Id; '{{USER_PROFILE}}' = $Account.Profile }
    foreach ($k in $values.Keys) {
        $v = [string]$values[$k]
        if ($Xml) { $v = [Security.SecurityElement]::Escape($v) }
        $Text = $Text.Replace($k, $v)
    }
    return $Text
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

# ---------- 8a: account, prerequisites, port, firewall, pagefile ----------

function Get-Account {
    $a = & $machine.Account
    if ($a.Console -and $a.Console -ne $a.Id) {
        $result.Problems.Add("this window runs as $($a.Id), but $($a.Console) is signed in. Run the controller from that account and accept the admin prompt as it, so the tasks and startup items are its own.")
        return $null
    }
    if (-not $a.Console) { $result.Warnings.Add("nobody is signed in at the console (a remote session?); the tasks and startup items go to $($a.Id)") }
    return $a
}

function Test-Prerequisite {
    # Docker and Ollama, which Stages 3 and 6 started, answering.
    $info = Invoke-Docker @('info', '--format', '{{.ServerVersion}}')
    if ($info.ExitCode -ne 0 -or -not (Get-Line $info).Count) {
        $result.Problems.Add('Docker does not answer. Start Docker Desktop and wait for "Engine running", then run again.')
        return $false
    }
    if ((& $machine.HttpStatus 'http://127.0.0.1:11434/api/version') -eq 200) { return $true }
    if ($checking) { return $true }
    if (-not (Test-Path -LiteralPath $ollamaApp -PathType Leaf)) { $result.Problems.Add("Ollama is not answering and is not installed at $ollamaApp"); return $false }
    & $machine.StartProcess $ollamaApp
    for ($i = 0; $i -lt 12; $i++) {
        & $machine.Wait 5
        if ((& $machine.HttpStatus 'http://127.0.0.1:11434/api/version') -eq 200) { $result.Steps.Add('started Ollama'); return $true }
    }
    Add-StageAsk $result 'Ollama did not answer on 127.0.0.1:11434. Start Ollama from the Start menu, then run again.'
    return $false
}

function Get-PortReservation {
    # 'reserved' (an administered range holds 8188), 'taken' (a range WinNAT
    # made holds it), 'free', or $null when netsh does not answer.
    $r = & $machine.Exec 'netsh' @('interface', 'ipv4', 'show', 'excludedportrange', 'protocol=tcp')
    if ($r.ExitCode -ne 0) { return $null }
    $cover = @(foreach ($l in @($r.Output)) {
            if ("$l" -match '^\s*(\d+)\s+(\d+)\s*(\*)?\s*$' -and [int]$Matches[1] -le $comfyPort -and $comfyPort -le [int]$Matches[2]) { [bool]$Matches[3] }
        })
    if ($cover -contains $true) { return 'reserved' }
    if ($cover.Count) { return 'taken' }
    return 'free'
}

function Get-WinNatState {
    # $true when winnat runs, $false when it is stopped, $null without it.
    $r = & $machine.Exec 'sc.exe' @('query', 'winnat')
    if ($r.ExitCode -ne 0) { return $null }
    return [bool](@($r.Output) -match 'RUNNING').Count
}

function Invoke-PortReservation {
    $state = Get-PortReservation
    if ($null -eq $state) { $result.Problems.Add('netsh could not list the excluded port ranges'); return }
    if ($checking) { Add-StageCheck $result 'TCP 8188 reserved for ComfyUI (C-31)' 'reserved' $state ($state -eq 'reserved'); return }
    if ($state -eq 'reserved') { $result.Steps.Add('TCP 8188 is already reserved for ComfyUI'); return }
    if (-not $act) { $result.Steps.Add("would reserve TCP 8188 (now $state), stopping winnat around it"); return }
    $nat = Get-WinNatState
    if ($nat) { $null = & $machine.Exec 'net' @('stop', 'winnat') }
    try {
        $add = & $machine.Exec 'netsh' @('int', 'ipv4', 'add', 'excludedportrange', 'protocol=tcp', "startport=$comfyPort", 'numberofports=1')
    }
    finally {
        # Always, even when adding failed (C-31): Docker and WSL need it.
        if ($nat) {
            $null = & $machine.Exec 'net' @('start', 'winnat')
            if (-not (Get-WinNatState)) { $result.Problems.Add("winnat did not start again. Run 'net start winnat' in an admin window now: Docker's and WSL's networking need it") }
        }
    }
    if ($add.ExitCode -ne 0) { $result.Problems.Add("netsh could not reserve TCP 8188 (exit $($add.ExitCode)); if ComfyUI is running, stop it and run again"); return }
    if ((Get-PortReservation) -ne 'reserved') { $result.Problems.Add('TCP 8188 is still not reserved after netsh added it'); return }
    $result.Steps.Add("reserved TCP 8188 for ComfyUI$(if ($nat) { ' (winnat restarted)' })")
}

function Test-CoversPort($Rule) {
    if ($Rule.Protocol -notin 'TCP', 'Any') { return $false }
    foreach ($p in @($Rule.LocalPort)) {
        if ($p -eq 'Any' -or $p -eq "$comfyPort") { return $true }
        if ($p -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le $comfyPort -and $comfyPort -le [int]$Matches[2]) { return $true }
    }
    return $false
}

function Test-QuietRemote([string[]]$Address) {
    # True when every remote address is the tailnet's range or this PC.
    if (-not @($Address).Count) { return $false }
    foreach ($a in $Address) { if ($a -notin $quietRemote) { return $false } }
    return $true
}

function Invoke-FirewallRule {
    $rules = @(& $machine.FirewallRules $comfyPort)
    $ours = @($rules | Where-Object { $_.DisplayName -eq $firewallName })
    $wanted = "inbound TCP $comfyPort allowed from $($firewallRemote -join ' and ') only"
    if (-not $ours.Count) {
        if ($checking) { Add-StageCheck $result "firewall rule '$firewallName' (C-52)" $wanted 'missing' $false }
        elseif (-not $act) { $result.Steps.Add("would add the firewall rule '$firewallName'") }
        else {
            & $machine.AddFirewallRule $firewallName $comfyPort $firewallRemote
            $result.Steps.Add("added the firewall rule '$firewallName'")
        }
    }
    else {
        $r = $ours[0]
        $right = $ours.Count -eq 1 -and $r.Enabled -and $r.Direction -eq 'Inbound' -and $r.Action -eq 'Allow' -and $r.Protocol -eq 'TCP' -and
        (@($r.LocalPort) -join ',') -eq "$comfyPort" -and (Test-QuietRemote $r.RemoteAddress) -and @($r.RemoteAddress).Count -eq $firewallRemote.Count
        $now = if ($ours.Count -gt 1) { "$($ours.Count) rules of that name" } else { "$(if ($r.Enabled) { 'enabled' } else { 'disabled' }) $($r.Direction) $($r.Action) $($r.Protocol) $(@($r.LocalPort) -join ',') from $(@($r.RemoteAddress) -join ' and ')" }
        if ($checking) { Add-StageCheck $result "firewall rule '$firewallName' (C-52)" $wanted $(if ($right) { $wanted } else { $now }) $right }
        elseif ($right) { $result.Steps.Add("the firewall rule '$firewallName' is already in place") }
        else { $result.Problems.Add("the firewall rule '$firewallName' is there but is $now; set it to $wanted, or remove it, then run again") }
    }
    $open = @($rules | Where-Object {
            $_.DisplayName -ne $firewallName -and $_.Enabled -and $_.Direction -eq 'Inbound' -and (Test-CoversPort $_) -and -not (Test-QuietRemote $_.RemoteAddress)
        })
    $opening = @($open | Where-Object { $_.Action -eq 'Allow' })
    $blocking = @($open | Where-Object { $_.Action -eq 'Block' })
    if ($checking) {
        Add-StageCheck $result 'no other firewall rule opens 8188 beyond the tailnet' 'none' $(if ($opening.Count) { ($opening | ForEach-Object { "'$($_.DisplayName)'" }) -join ', ' } else { 'none' }) ($opening.Count -eq 0)
    }
    elseif ($opening.Count) {
        $names = ($opening | ForEach-Object { "'$($_.DisplayName)'$(if ($_.Program -and $_.Program -ne 'Any') { " ($($_.Program))" })" }) -join ', '
        Add-StageAsk $result "Windows Firewall lets other networks reach ComfyUI's port through $names. ComfyUI must answer only this PC and the tailnet (C-52): turn those rules off in Windows Defender Firewall > Inbound Rules, then run again."
    }
    foreach ($b in $blocking) { $result.Warnings.Add("the firewall rule '$($b.DisplayName)' blocks TCP $comfyPort$(if ($b.Program -and $b.Program -ne 'Any') { " for $($b.Program)" }); if the tailnet cannot reach ComfyUI in Stage 9, turn it off") }
}

function Invoke-Pagefile {
    $p = & $machine.Pagefile
    $f = @($p.Files | Where-Object { $_.Name -eq $pagefile.Name }) | Select-Object -First 1
    $now = if ($p.Automatic) { 'managed by Windows' } elseif ($f) { "$($f.InitialSize) to $($f.MaximumSize) MB" } else { 'not set' }
    $want = "$($pagefile.InitialSize) to $($pagefile.MaximumSize) MB"
    $right = -not $p.Automatic -and $f -and $f.InitialSize -eq $pagefile.InitialSize -and $f.MaximumSize -eq $pagefile.MaximumSize
    if ($checking) {
        $pending = if ($result.Data['PagefileChanged'] -and -not $right) { ' (set; waits for the restart in Stage 10)' } else { '' }
        Add-StageCheck $result "pagefile $($pagefile.Name) (R-07)" $want "$now$pending" ($right -or [bool]$result.Data['PagefileChanged'])
        return
    }
    if ($right) { $result.Steps.Add("the pagefile is already $want"); return }
    if (-not $act) { $result.Steps.Add("would set the pagefile $($pagefile.Name) to $want (now $now)"); return }
    & $machine.SetPagefile $pagefile.Name $pagefile.InitialSize $pagefile.MaximumSize
    $result.Data['PagefileChanged'] = $true
    $result.Steps.Add("set the pagefile $($pagefile.Name) to $want (was $now)")
    $result.Warnings.Add('the new pagefile takes effect at the restart in Stage 10')
}

# ---------- 8b: startup items, ComfyUI, the stack, the tool catalogue ----------

function Get-StartupTarget($Item, $Account) {
    # The item's path in the Startup folder, or $null after a problem.
    $check = @(& $Context.PathCheck -Path $Item['name'] -Root $Account.Startup -Relative -Detailed)[0]
    if (-not $check.IsValid) { $result.Problems.Add("startup item $($Item['name']): $($check.Reason)"); return $null }
    return $check.FullPath
}

function Get-StartupFileState($Item, [string]$Dest) {
    # 'same', 'missing', 'ours' (this stage's older copy) or 'other'.
    if (-not (Test-Path -LiteralPath $Dest)) { return 'missing' }
    if (-not (Test-Path -LiteralPath $Dest -PathType Leaf)) { return 'other' }
    $want = (Get-FileHash -LiteralPath (Join-Path $repo $Item['file']) -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash -eq $want) { return 'same' }
    if (& $Context.IsOwned $Dest) { return 'ours' }
    return 'other'
}

function Get-ShortcutWant($Item, $Account) {
    @{
        Target           = Expand-AccountText $Item['target'] $Account
        Arguments        = Expand-AccountText $Item['arguments'] $Account
        WorkingDirectory = Expand-AccountText $Item['workingDirectory'] $Account
    }
}

function Test-SameShortcut($Have, $Want) {
    return $Have -and $Have.Target -eq $Want.Target -and $Have.Arguments -eq $Want.Arguments -and $Have.WorkingDirectory -eq $Want.WorkingDirectory
}

function Get-MissingNeed([string[]]$RepoFiles, [string[]]$Programs) {
    # What an item runs that is not on this PC.
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($r in @($RepoFiles | Where-Object { $_ })) {
        $p = Resolve-RepoFile $r
        if (-not $p) { $missing.Add("$r (no PC folder holds it)") }
        elseif (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing.Add($p) }
    }
    foreach ($p in @($Programs | Where-Object { $_ })) {
        if ((Test-FullPath $p) -and -not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing.Add($p) }
    }
    return , $missing.ToArray()
}

function Install-StartupItem($Account) {
    if (-not (Test-Path -LiteralPath $Account.Startup -PathType Container)) { $result.Problems.Add("the Startup folder $($Account.Startup) is missing"); return }
    $items = @($taskManifest['startup'])
    $good = 0
    foreach ($item in $items) {
        $name = $item['name']
        $dest = Get-StartupTarget $item $Account
        if (-not $dest) { continue }
        if ($item['kind'] -eq 'file') {
            $state = Get-StartupFileState $item $dest
            if ($checking) { if ($state -eq 'same') { $good++ } else { $result.Problems.Add("startup item $($name): $state") }; continue }
            if ($state -eq 'same') { $result.Steps.Add("startup item $name is already in place"); $good++; continue }
            if ($state -eq 'other') { $result.Problems.Add("startup item $($name): a different file is already in $($Account.Startup); move it away and run again"); continue }
            if (-not $act) { $result.Steps.Add("would copy $name into the Startup folder"); continue }
            if ($state -eq 'ours') { $null = & $Context.RemoveOwned $dest }
            $temp = "$dest.cria-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
            [IO.File]::Copy((Join-Path $repo $item['file']), $temp, $false)
            [IO.File]::Move($temp, $dest, $false)
            & $Context.Own 'file' $dest $Account.Startup 'wipe'
            $result.Steps.Add("copied $name into the Startup folder")
            $good++
            continue
        }
        if ($item['kind'] -ne 'shortcut') { $result.Problems.Add("startup item $($name): unknown kind '$($item['kind'])'"); continue }
        $want = Get-ShortcutWant $item $Account
        $have = & $machine.ReadShortcut $dest
        if (Test-SameShortcut $have $want) {
            if (-not $checking) { $result.Steps.Add("startup item $name is already in place") }
            $good++
            continue
        }
        if ($checking) { $result.Problems.Add("startup item $($name): $(if ($have) { 'a different shortcut' } else { 'missing' })"); continue }
        if ($have -or (Test-Path -LiteralPath $dest)) { $result.Problems.Add("startup item $($name): a different shortcut is already in $($Account.Startup); move it away and run again"); continue }
        $need = Get-MissingNeed @($item['runs']) @($want.Target)
        if ($need.Count) { $result.Problems.Add("startup item $($name): it runs $($need -join ', '), which is not on this PC"); continue }
        if (-not $act) { $result.Steps.Add("would make the shortcut $name in the Startup folder"); continue }
        & $machine.WriteShortcut $dest $want.Target $want.Arguments $want.WorkingDirectory
        & $Context.Own 'file' $dest $Account.Startup 'wipe'
        $result.Steps.Add("made the shortcut $name in the Startup folder")
        $good++
    }
    if ($checking) { Add-StageCheck $result 'startup items in place (ComfyUI launcher, AutoFree)' "$($items.Count) of $($items.Count)" "$good of $($items.Count)" ($good -eq $items.Count) }
}

function Invoke-ComfyUi($Account) {
    # Starts ComfyUI through its launcher, as you, unless it answers. (The
    # checkpoint tests it with the other health URLs.)
    if ($checking) { return }
    if ((& $machine.HttpStatus $comfyUrl) -eq 200) { $result.Steps.Add('ComfyUI already answers'); return }
    if (-not $act) { $result.Steps.Add('would start ComfyUI through its launcher'); return }
    $vbs = Join-Path $Account.Startup 'start_comfyui_hidden.vbs'
    if (-not (Test-Path -LiteralPath $vbs -PathType Leaf)) { $result.Problems.Add("ComfyUI's launcher is not in the Startup folder, so ComfyUI was not started"); return }
    & $Context.Say 'starting ComfyUI as you and waiting up to five minutes for it'
    & $machine.StartProcess $vbs
    for ($i = 0; $i -lt 60; $i++) {
        & $machine.Wait 5
        if ((& $machine.HttpStatus $comfyUrl) -eq 200) { $result.Steps.Add('started ComfyUI through its launcher'); return }
    }
    $result.Problems.Add("ComfyUI did not answer on $comfyUrl within five minutes. Run its launcher's command in a window to see why: .venv\Scripts\python.exe main.py --listen 0.0.0.0 --port $comfyPort, in the ComfyUI folder")
}

function Invoke-StartStack {
    $script = Join-Path $stackRoot 'start-stack.ps1'
    if ($checking) { return $true }
    if (-not $act) { $result.Steps.Add('would run start-stack.ps1 and check every service, health URL and the tool catalogue'); return $true }
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { $result.Problems.Add("$script is missing; Stage 4 places it"); return $false }
    & $Context.Say 'running start-stack.ps1 (it waits for every service)'
    $r = & $machine.Exec 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) -Stream
    $result.Data['StartStackExit'] = $r.ExitCode
    if ($r.ExitCode -ne 0) { $result.Problems.Add("start-stack.ps1 exited $($r.ExitCode) (its log is in $(Join-Path $stackRoot 'logs'))"); return $false }
    $result.Steps.Add('start-stack.ps1 exited 0')
    return $true
}

function Get-ProjectState($Project) {
    # The services start-stack.ps1 starts (the project's active profile) and
    # those that are not running healthy, as 'service: state'.
    $base = Get-ComposeArgument $Project
    $svc = Invoke-Docker ($base + @('config', '--services'))
    if ($svc.ExitCode -ne 0) { return @{ Total = 0; Bad = @("$($Project['name']): its compose file did not load") } }
    $names = Get-Line $svc
    $seen = @{}
    foreach ($l in (Get-Line (Invoke-Docker ($base + @('ps', '-a', '--format', '{{.Service}} {{.State}} {{.Health}}'))))) {
        $p = $l -split '\s+'
        $seen[$p[0]] = @{ State = $p[1]; Health = $(if ($p.Count -gt 2) { $p[2] } else { '' }) }
    }
    $bad = @(foreach ($n in $names) {
            $s = $seen[$n]
            if (-not $s) { "$($n): no container" }
            elseif ($s.State -ne 'running') { "$($n): $($s.State)" }
            elseif ($s.Health -and $s.Health -ne 'healthy') { "$($n): $($s.Health)" }
        })
    return @{ Total = $names.Count; Bad = $bad }
}

function Get-StaleService($Project) {
    # The services whose container runs an older configuration than the
    # compose file and its .env now give, or $null when compose cannot say.
    $h = Invoke-Docker ((Get-ComposeArgument $Project) + @('config', '--hash', '*'))
    if ($h.ExitCode -ne 0) { return $null }
    $want = @{}
    foreach ($l in (Get-Line $h)) { $p = $l -split '\s+'; if ($p.Count -ge 2) { $want[$p[0]] = $p[1] } }
    $have = @{}
    $r = Invoke-Docker @('ps', '-a', '--filter', "label=com.docker.compose.project=$($Project['name'])", '--format', '{{.Label "com.docker.compose.service"}} {{.Label "com.docker.compose.config-hash"}}')
    foreach ($l in (Get-Line $r)) { $p = $l -split '\s+'; if ($p.Count -ge 2) { $have[$p[0]] = $p[1] } }
    return , @($want.Keys | Where-Object { $have.ContainsKey($_) -and $have[$_] -ne $want[$_] } | Sort-Object)
}

function Get-StackState {
    $total = 0; $bad = [Collections.Generic.List[string]]::new()
    foreach ($p in $projects) {
        $s = Get-ProjectState $p
        $total += $s.Total
        foreach ($b in $s.Bad) { $bad.Add("$($p['name'])/$b") }
    }
    $urlBad = [Collections.Generic.List[string]]::new()
    foreach ($k in $healthUrls.Keys) {
        $code = & $machine.HttpStatus $healthUrls[$k]
        if ($code -ne 200) { $urlBad.Add("$k ($(if ($code) { "HTTP $code" } else { 'no answer' }))") }
    }
    return @{ Total = $total; Bad = $bad.ToArray(); UrlBad = $urlBad.ToArray(); Ok = ($total -gt 0 -and $bad.Count -eq 0 -and $urlBad.Count -eq 0) }
}

function Wait-Stack {
    # Up to five minutes for every service to run healthy and every health
    # URL to answer 200; the last state either way. (A URL that hangs costs
    # its 10-second timeout, so the clock counts too.)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; ; $i++) {
        $s = Get-StackState
        if ($s.Ok -or $i -ge 60 -or $clock.Elapsed.TotalSeconds -ge 300) { return $s }
        & $machine.Wait 5
    }
}

function Repair-StaleService {
    # Recreates containers left on an older configuration (a gcal bridge
    # created in Stage 7 before its new API key, for one).
    foreach ($p in $projects) {
        $stale = Get-StaleService $p
        if ($null -eq $stale) { $result.Warnings.Add("$($p['name']): compose could not give its configuration hashes, so stale containers were not looked for"); continue }
        if (-not $stale.Count) { continue }
        $r = Invoke-Docker ((Get-ComposeArgument $p) + @('up', '-d', '--no-build', '--pull', 'never') + $stale)
        if ($r.ExitCode -ne 0) { $result.Problems.Add("$($p['name']): could not recreate $($stale -join ', ') on its current configuration (exit $($r.ExitCode))"); continue }
        $result.Steps.Add("$($p['name']): recreated $($stale -join ', ') on its current configuration")
    }
}

function Get-ToolServer {
    # The tool server connections the seed enables, or $null.
    $path = Join-Path $seedDir 'config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $result.Problems.Add('manifests/owui-seed/seed/config.json is not in the repo yet: commit the seed from the first capture (docs/RESTORE.md 7d)')
        return $null
    }
    $raw = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)['tool_server.connections']
    $list = if ($null -eq $raw) { @() } else { @($raw) }
    $out = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $list.Count; $i++) {
        $c = $list[$i]
        if ($c -isnot [Collections.IDictionary] -or $c['config'] -isnot [Collections.IDictionary] -or -not $c['config']['enable']) { continue }
        $info = if ($c['info'] -is [Collections.IDictionary]) { $c['info'] } else { @{} }
        $id = [string]$info['id']
        $out.Add(@{ Index = $i; Id = $id; Name = $(if ($info['name']) { [string]$info['name'] } elseif ($id) { $id } else { "connection $($i + 1)" }) })
    }
    return , $out.ToArray()
}

function Get-MissingServer($Servers, [string]$Key) {
    # The names of the servers OWUI's tool list lacks, or $null with the
    # HTTP status in $script:catalogueStatus when OWUI would not show it.
    $headers = @{ Authorization = "Bearer $Key" }
    $script:catalogueStatus = & $machine.HttpStatus "$owuiUrl/api/v1/tools/" $headers
    if ($script:catalogueStatus -ne 200) { return $null }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($t in @(& $machine.HttpJson "$owuiUrl/api/v1/tools/" $headers)) { $id = Get-Field $t 'id'; if ($id) { [void]$ids.Add([string]$id) } }
    # OWUI lists an OpenAPI server as server:<id> (its index when it has no
    # id) and an MCP server as server:mcp:<id>.
    return , @($Servers | Where-Object { -not ($ids.Contains("server:$($_.Id)") -or $ids.Contains("server:mcp:$($_.Id)") -or $ids.Contains("server:$($_.Index)")) } | ForEach-Object { $_.Name })
}

function Wait-Owui {
    for ($i = 0; $i -lt 36; $i++) {
        if ((& $machine.HttpStatus "$owuiUrl/health") -eq 200) { return $true }
        & $machine.Wait 5
    }
    return $false
}

function Invoke-ToolCatalogue {
    $servers = Get-ToolServer
    if ($null -eq $servers) { return }
    $label = 'OWUI tool catalogue: every tool server the seed enables'
    if (-not $act -and -not $checking) { $result.Steps.Add("would check OWUI lists all $($servers.Count) tool servers"); return }
    $key = Read-ApiKey
    if (-not $key) { $result.Problems.Add("the OWUI API key Stage 7 left in $keyPath $script:keyWhy, so the tool catalogue cannot be read"); return }
    $missing = Get-MissingServer $servers $key
    if ($null -ne $missing -and $missing.Count -and $act) {
        # A catalogue OWUI cached while mcpo was still down: restart it once.
        $r = Invoke-Docker ((Get-ComposeArgument $owuiProject) + @('restart', 'open-webui'))
        if ($r.ExitCode -eq 0 -and (Wait-Owui)) {
            $result.Steps.Add("OWUI restarted to load its tool servers again ($($missing.Count) were missing)")
            $missing = Get-MissingServer $servers $key
        }
    }
    if ($null -eq $missing) {
        if ($Context.Accepted -contains 'tool-catalogue') { $result.Steps.Add('tool catalogue: checked by you in OWUI (accepted)'); return }
        Add-StageAsk $result ("OWUI would not show its tool list to the API key (HTTP $script:catalogueStatus). Sign in to OWUI as the admin and check that the admin settings list all " +
            "$($servers.Count) tool servers and each one connects. Then run again with -Accept tool-catalogue.") -Id 'tool-catalogue'
        return
    }
    $n = $servers.Count
    if ($checking) { Add-StageCheck $result $label "$n of $n" "$($n - $missing.Count) of $n$(if ($missing.Count) { "; missing: $($missing -join ', ')" })" ($missing.Count -eq 0); return }
    if ($missing.Count) { $result.Problems.Add("OWUI's tool catalogue lacks $($missing.Count) of $n tool servers: $($missing -join ', '). 'docker logs mcpo-core' and 'docker logs open-webui' say why") }
    else { $result.Steps.Add("OWUI's tool catalogue lists all $n tool servers") }
}

function Invoke-Stack($Account) {
    Invoke-ComfyUi $Account
    if (-not (Invoke-StartStack)) { return }
    if ($act) {
        Repair-StaleService
        & $Context.Say 'waiting up to five minutes for every service to run healthy'
    }
    $s = if ($act) { Wait-Stack } else { Get-StackState }
    if ($checking) {
        $exit = $result.Data['StartStackExit']
        Add-StageCheck $result 'start-stack.ps1 exit code' '0' $(if ($null -eq $exit) { 'not run' } else { "$exit" }) ($exit -eq 0)
        Add-StageCheck $result 'PC compose services running and healthy' "$($s.Total) of $($s.Total)" "$($s.Total - $s.Bad.Count) of $($s.Total)$(if ($s.Bad.Count) { "; $($s.Bad -join ', ')" })" ($s.Total -gt 0 -and $s.Bad.Count -eq 0)
        $stale = @(foreach ($p in $projects) { $x = Get-StaleService $p; if ($x) { $x | ForEach-Object { "$($p['name'])/$_" } } })
        Add-StageCheck $result 'every container on its current configuration' 'all' $(if ($stale.Count) { "older: $($stale -join ', ')" } else { 'all' }) ($stale.Count -eq 0)
        $n = $healthUrls.Count
        Add-StageCheck $result 'health URLs answer 200 (C-27)' "$n of $n" "$($n - $s.UrlBad.Count) of $n$(if ($s.UrlBad.Count) { "; $($s.UrlBad -join ', ')" })" ($s.UrlBad.Count -eq 0)
    }
    elseif ($act) {
        if (-not $s.Ok) {
            foreach ($b in $s.Bad) { $result.Problems.Add("service $b") }
            foreach ($u in $s.UrlBad) { $result.Problems.Add("health URL $u") }
            return
        }
        $result.Steps.Add("$($s.Total) services running and healthy; all $($healthUrls.Count) health URLs answer 200")
    }
    Invoke-ToolCatalogue
}

# ---------- 8c: Tailscale Serve ----------

function Get-ServeState {
    # The rules Serve has now, keyed 'port|path' ('port|' for TCP), what it
    # has that this stage does not know, and the ports with Funnel on; or
    # $null. Host names are dropped as they are read.
    $r = & $machine.Exec 'tailscale' @('serve', 'status', '--json')
    if ($r.ExitCode -ne 0) { return $null }
    $text = (@($r.Output) -join "`n").Trim()
    $s = $null
    if ($text) { try { $s = ConvertFrom-Json -InputObject $text -AsHashtable } catch { return $null } }
    if ($null -eq $s) { $s = @{} }
    $rules = @{}; $other = [Collections.Generic.List[string]]::new()
    $web = @{}
    if ($s['Web'] -is [Collections.IDictionary]) { foreach ($k in $s['Web'].Keys) { $web[($k -replace '^.*:', '')] = $s['Web'][$k] } }
    if ($s['TCP'] -is [Collections.IDictionary]) {
        foreach ($port in $s['TCP'].Keys) {
            $t = $s['TCP'][$port]
            if ($t['TCPForward']) { $rules["$port|"] = @{ Kind = 'tcp'; Target = [string]$t['TCPForward'] }; continue }
            if ($t['HTTPS'] -and $web.ContainsKey([string]$port) -and $web[[string]$port]['Handlers'] -is [Collections.IDictionary]) {
                $handlers = $web[[string]$port]['Handlers']
                foreach ($path in $handlers.Keys) {
                    if ($handlers[$path]['Proxy']) { $rules["$port|$path"] = @{ Kind = 'https'; Target = [string]$handlers[$path]['Proxy'] } }
                    else { $other.Add("port $port $path (not a proxy)") }
                }
                continue
            }
            $other.Add("port $port")
        }
    }
    $funnel = @(if ($s['AllowFunnel'] -is [Collections.IDictionary]) { foreach ($k in $s['AllowFunnel'].Keys) { if ($s['AllowFunnel'][$k]) { $k -replace '^.*:', '' } } })
    return @{ Rules = $rules; Other = $other.ToArray(); Funnel = $funnel }
}

function Get-ServeKey($Rule) { if ($Rule['kind'] -eq 'tcp') { "$($Rule['port'])|" } else { "$($Rule['port'])|$($Rule['path'])" } }

function Get-ServeArgument($Rule) {
    if ($Rule['kind'] -eq 'tcp') { return @('serve', '--bg', "--tcp=$($Rule['port'])", "tcp://$($Rule['target'])") }
    $a = @('serve', '--bg', "--https=$($Rule['port'])")
    if ($Rule['path'] -and $Rule['path'] -ne '/') { $a += "--set-path=$($Rule['path'])" }
    return $a + @($Rule['target'])
}

function Invoke-Serve {
    $s = Get-ServeState
    if ($null -eq $s) { $result.Problems.Add("'tailscale serve status --json' did not answer; is Tailscale running and signed in?"); return }
    $wanted = @{}
    $added = 0; $same = 0; $conflict = [Collections.Generic.List[string]]::new()
    foreach ($rule in $serveRules) {
        $key = Get-ServeKey $rule
        $wanted[$key] = $true
        $have = $s.Rules[$key]
        if ($have -and $have.Kind -eq $rule['kind'] -and $have.Target -eq $rule['target']) { $same++; continue }
        if ($have) { $conflict.Add("port $($rule['port']) serves $($have.Target), not $($rule['target'])"); continue }
        if ($checking) { $conflict.Add("port $($rule['port']) is not served"); continue }
        if (-not $act) { $added++; continue }
        $r = & $machine.Exec 'tailscale' (Get-ServeArgument $rule)
        if ($r.ExitCode -ne 0) { $result.Problems.Add("tailscale serve could not add port $($rule['port']) (exit $($r.ExitCode)); run 'tailscale $((Get-ServeArgument $rule) -join ' ')' by hand to see why"); continue }
        $added++
    }
    $extra = @($s.Rules.Keys | Where-Object { -not $wanted.ContainsKey($_) } | ForEach-Object { "port $($_ -replace '\|$', '' -replace '\|', ' ')" }) + @($s.Other)
    $n = $serveRules.Count
    if ($checking) {
        $bad = @($conflict) + @($extra | ForEach-Object { "extra: $_" })
        Add-StageCheck $result 'Tailscale Serve: exactly the rules in serve.json' "$n rules" $(if ($bad.Count) { "$same of $n; $($bad -join ', ')" } else { "$n rules" }) ($bad.Count -eq 0 -and $same -eq $n)
        Add-StageCheck $result 'Tailscale Funnel (C-23)' 'off' $(if ($s.Funnel.Count) { "on for port $($s.Funnel -join ', ')" } else { 'off' }) ($s.Funnel.Count -eq 0)
        return
    }
    foreach ($c in $conflict) { $result.Problems.Add("Serve: $c. Turn that port off with 'tailscale serve --https=<port> off' (or --tcp) and run again") }
    foreach ($x in $extra) { $result.Problems.Add("Serve: $x is not in serve.json; turn it off with 'tailscale serve' and run again") }
    foreach ($f in $s.Funnel) { $result.Problems.Add("Funnel is on for port $f; the stack never uses Funnel (C-23). Turn it off with 'tailscale funnel --https=$f off'") }
    if (-not $act) { $result.Steps.Add("would add $added Serve rule(s); $same already there"); return }
    $result.Steps.Add("Tailscale Serve: $added rule(s) added, $same already there")
}

# ---------- 8d: scheduled tasks ----------

function Get-TaskXml($Task, $Account) {
    # The task's XML for this account, as Task Scheduler takes it, or $null.
    $path = Join-Path $repo $Task['xml']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $result.Problems.Add("task $($Task['name']): $($Task['xml']) is not in the repo"); return $null }
    $text = Expand-AccountText ([IO.File]::ReadAllText($path)) $Account -Xml
    $left = [regex]::Match($text, '\{\{[A-Z0-9_]+\}\}')
    if ($left.Success) { $result.Problems.Add("task $($Task['name']): its XML still holds $($left.Value)"); return $null }
    # Stored as UTF-8; Task Scheduler takes the text as Export-ScheduledTask
    # gave it, declared UTF-16.
    return [regex]::Replace($text, '^(\s*<\?xml[^>]*encoding=")UTF-8(")', '${1}UTF-16$2')
}

function Get-TaskProgram([string]$Xml) {
    @([regex]::Matches($Xml, '<Command>([^<]+)</Command>') | ForEach-Object { [Environment]::ExpandEnvironmentVariables([Net.WebUtility]::HtmlDecode($_.Groups[1].Value.Trim())) })
}

function Test-LogonOnly([string]$Xml) {
    $kinds = @([regex]::Matches($Xml, '<(\w+Trigger)\b') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    return $kinds.Count -eq 1 -and $kinds[0] -eq 'LogonTrigger'
}

function Install-Task($Account) {
    $tasks = @($taskManifest['tasks'])
    $imported = 0; $present = 0; $right = 0
    $wrong = [Collections.Generic.List[string]]::new()
    foreach ($t in $tasks) {
        $name = $t['name']
        $state = & $machine.TaskState $name
        if ($checking) {
            if (-not $state) { $wrong.Add("$name missing") }
            elseif ($t['enabled'] -and $state -eq 'Disabled') { $wrong.Add("$name disabled") }
            elseif (-not $t['enabled'] -and $state -ne 'Disabled') { $wrong.Add("$name enabled") }
            else { $right++ }
            continue
        }
        if ($state) {
            $present++
            if (-not $t['enabled'] -and $state -ne 'Disabled') {
                if ($act) { & $machine.DisableTask $name; $result.Steps.Add("$name disabled, as on the old PC") }
                else { $result.Steps.Add("would disable $name") }
            }
            continue
        }
        $xml = Get-TaskXml $t $Account
        if (-not $xml) { continue }
        $need = Get-MissingNeed @($t['runs']) @(Get-TaskProgram $xml)
        if ($need.Count) { $result.Problems.Add("task $($name): not imported; it runs $($need -join ', '), which is not on this PC"); continue }
        if (-not $act) { $imported++; continue }
        try { & $machine.RegisterTask $name $xml }
        catch { $result.Problems.Add("task $($name): Task Scheduler refused its XML ($($_.Exception.Message))"); continue }
        $imported++
        if (-not $t['enabled'] -and (& $machine.TaskState $name) -ne 'Disabled') { & $machine.DisableTask $name }
        if ($t['enabled'] -and $name -ne 'OWUI-Stack-Startup' -and (Test-LogonOnly $xml)) {
            # It would wait for the next sign-in; Stage 9 needs it now.
            try { & $machine.StartTask $name; $result.Steps.Add("started $name, which otherwise waits for the next sign-in") }
            catch { $result.Warnings.Add("$($name): imported, but it did not start ($($_.Exception.Message)); it starts at the next sign-in") }
        }
    }
    if ($checking) {
        Add-StageCheck $result 'scheduled tasks present, MorningBrief disabled' "$($tasks.Count) of $($tasks.Count)" "$right of $($tasks.Count)$(if ($wrong.Count) { "; $($wrong -join ', ')" })" ($right -eq $tasks.Count)
        return
    }
    $result.Steps.Add("scheduled tasks: $(if ($act) { $imported } else { "would import $imported" }) imported, $present already here")
}

# ---------- main ----------

if ($Mode -eq 'Plan') {
    $result.Steps.Add("would reserve TCP $comfyPort, add the firewall rule '$firewallName' and set the pagefile to 32768 to 81920 MB, each only if it differs")
    $result.Steps.Add("would place $(@($taskManifest['startup']).Count) startup items, start ComfyUI, run start-stack.ps1 and check $($healthUrls.Count) health URLs and OWUI's tool catalogue")
    $result.Steps.Add("would add the $($serveRules.Count) Serve rules in serve.json and import the $(@($taskManifest['tasks']).Count) scheduled tasks that are missing")
    $result.Status = 'planned'
    return $result
}

if ($act -and -not (& $machine.IsElevated)) {
    $result.Problems.Add('Stage 8 needs admin rights; the controller runs it in an elevated window')
    $result.Status = 'failed'
    return $result
}

$account = Get-Account
if ($account -and (Test-Prerequisite)) {
    Invoke-PortReservation
    Invoke-FirewallRule
    Invoke-Pagefile
    Install-StartupItem $account
    Invoke-Stack $account
    Invoke-Serve
    Install-Task $account
    if ($checking -and $Context.Accepted -notcontains 'owui-phone') {
        Add-StageAsk $result ("From your phone, on the tailnet, open https://<this PC's tailnet name>/ (Serve's port 443). When OWUI's sign-in page opens, " +
            'run again with -Accept owui-phone.') -Id 'owui-phone'
    }
}

if ($result.Problems.Count -and $result.Status -in 'done', 'passed') { $result.Status = 'failed' }
return $result
