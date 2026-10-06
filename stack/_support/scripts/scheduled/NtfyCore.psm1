#Requires -Version 7.0
<#
    NtfyCore.psm1 - shared ntfy publishing for the OWUI / Ollama stack.
    Created 2026-09-11 (see AI-CHANGELOG.csv).

    WHY THIS EXISTS
      Every PC-side watcher needs the same four things: a token, a way to POST,
      a way to NOT spam (transition-only alerting), and a log. Putting them in
      one module means a new watcher is ~20 lines instead of ~100.

    TOPICS
      pc-alert : something is wrong or needs a decision.  priority 4-5.
      pc-info  : digests, briefs, completions, FYIs.      priority 2-3.
      owui     : owned by the OWUI event Function (owui-tools/ntfy_push.py).
                 Do NOT publish to it from here.

    AUTH
      Publisher account "pcmon" has rw on pc-alert and pc-info ONLY.
      Token lives in E:\ai\ollama\secrets\ntfy-pc.token (gitignored).
      The ntfy server runs auth-default-access=deny-all, so the token is required.

    PUBLISHING FORMAT
      JSON body to the server root, NOT headers. ntfy headers are ASCII-only,
      which mangles emoji and any non-ASCII in a title. JSON is UTF-8 clean.
#>

$script:NtfyBase  = "http://127.0.0.1:8090"
$script:TokenPath = "E:\ai\ollama\secrets\ntfy-pc.token"
$script:StatePath = "E:\ai\ollama\logs\ntfy-monitor.state.json"
$script:LogPath   = "E:\ai\ollama\logs\ntfy-monitor.log"

# --------------------------------------------------------------------- logging

function Write-NtfyLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","FAIL","SENT")][string]$Level = "INFO"
    )
    $line = "[{0}] {1,-4} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    try {
        $dir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    } catch { }
    Write-Verbose $line
}

# ------------------------------------------------------------------------ auth

function Get-NtfyToken {
    [CmdletBinding()] param()
    if (-not (Test-Path $script:TokenPath)) {
        throw "ntfy token missing at $($script:TokenPath). Recreate with: docker exec ntfy ntfy token add pcmon"
    }
    (Get-Content $script:TokenPath -Raw).Trim()
}

# --------------------------------------------------------------------- publish

function Send-Ntfy {
    <#
        .SYNOPSIS  Publish one notification. Never throws - a dead ntfy must not
                   kill the watcher that called it.
        .EXAMPLE   Send-Ntfy -Title "Disk low" -Message "E: 38 GB free" -Topic pc-alert -Priority 4 -Tags warning,floppy_disk
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("pc-alert","pc-info")][string]$Topic = "pc-info",
        [ValidateRange(1,5)][int]$Priority = 3,
        [string[]]$Tags = @(),
        [string]$Click,
        [switch]$Markdown
    )

    $body = [ordered]@{
        topic    = $Topic
        title    = $Title
        message  = $Message
        priority = $Priority
    }
    if ($Tags.Count) { $body.tags = $Tags }
    if ($Click)      { $body.click = $Click }
    if ($Markdown)   { $body.markdown = $true }

    try {
        $json = $body | ConvertTo-Json -Depth 4 -Compress
        $null = Invoke-RestMethod -Uri $script:NtfyBase -Method Post `
            -Headers @{ Authorization = "Bearer $(Get-NtfyToken)" } `
            -ContentType "application/json; charset=utf-8" `
            -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
            -TimeoutSec 15
        Write-NtfyLog -Level SENT -Message ("{0} p{1} | {2}" -f $Topic, $Priority, $Title)
        return $true
    } catch {
        Write-NtfyLog -Level FAIL -Message ("publish failed ({0}): {1}" -f $Title, $_.Exception.Message)
        return $false
    }
}

# ------------------------------------------------------------ transition state
#
#  The watchers run every 15 minutes. Without this, "disk low" would buzz 96
#  times a day. Send-NtfyTransition fires ONLY when a condition changes:
#  ok -> bad (the alert) and bad -> ok (the all-clear). Nothing in between.

function Get-NtfyState {
    [CmdletBinding()] param()
    if (-not (Test-Path $script:StatePath)) { return @{} }
    try {
        $raw = Get-Content $script:StatePath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $obj) { return @{} }
        return $obj
    } catch {
        Write-NtfyLog -Level WARN -Message "state file unreadable, starting clean: $($_.Exception.Message)"
        return @{}
    }
}

function Set-NtfyState {
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$State)
    try {
        $dir = Split-Path $script:StatePath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StatePath -Encoding UTF8
    } catch {
        Write-NtfyLog -Level FAIL -Message "could not save state: $($_.Exception.Message)"
    }
}

function ConvertTo-NtfyDate {
    <#
        .SYNOPSIS  Culture-proof read of a timestamp from the state file.
        .NOTES     2026-10-03 fix. PowerShell 7's ConvertFrom-Json turns ISO strings
                   into [datetime] objects. Passing one to [datetime]::TryParse
                   stringifies it in InvariantCulture (MM/dd) and re-parses it as
                   en-GB (dd/MM), so 03 Oct became 10 Mar and every -Repeat window
                   looked expired - three alerts every 15 minutes for weeks.
                   Always go through this helper; never TryParse a state value.
    #>
    param($Value)
    if ($null -eq $Value) { return [datetime]::MinValue }
    if ($Value -is [datetime]) { return $Value }
    if ($Value -is [datetimeoffset]) { return $Value.LocalDateTime }
    $out = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$out)) { return $out }
    return [datetime]::MinValue
}

function Send-NtfyTransition {
    <#
        .SYNOPSIS  Notify only when a condition CHANGES state.
        .PARAMETER Key     Stable identifier, e.g. "disk.E" or "gpu.hot".
        .PARAMETER IsBad   Current evaluation of the condition.
        .PARAMETER State   The hashtable from Get-NtfyState (mutated in place).
        .PARAMETER Repeat  Hours after which a still-bad condition re-alerts. 0 = never.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][bool]$IsBad,
        [Parameter(Mandatory)][hashtable]$State,
        [string]$BadTitle, [string]$BadMessage,
        [string]$OkTitle,  [string]$OkMessage,
        [int]$Priority = 4,
        [string[]]$Tags = @("warning"),
        [string[]]$OkTags = @("white_check_mark"),
        [int]$Repeat = 0,
        [string]$Click
    )

    $prev      = if ($State.ContainsKey($Key)) { $State[$Key] } else { $null }
    $wasBad    = $false
    $lastAlert = [datetime]::MinValue
    if ($prev) {
        if ($prev.ContainsKey("bad")) { $wasBad = [bool]$prev["bad"] }
        if ($prev.ContainsKey("at"))  { $lastAlert = ConvertTo-NtfyDate $prev["at"] }
    }

    $shouldAlert = $false
    if ($IsBad -and -not $wasBad) { $shouldAlert = $true }
    elseif ($IsBad -and $wasBad -and $Repeat -gt 0 -and ((Get-Date) - $lastAlert).TotalHours -ge $Repeat) { $shouldAlert = $true }

    if ($shouldAlert) {
        $send = @{ Title = $BadTitle; Message = $BadMessage; Topic = "pc-alert"; Priority = $Priority; Tags = $Tags }
        if ($Click) { $send.Click = $Click }
        Send-Ntfy @send | Out-Null
        $State[$Key] = @{ bad = $true; at = (Get-Date).ToString("o") }
    }
    elseif (-not $IsBad -and $wasBad) {
        if ($OkTitle) {
            Send-Ntfy -Title $OkTitle -Message $OkMessage -Topic "pc-info" -Priority 2 -Tags $OkTags | Out-Null
        }
        $State[$Key] = @{ bad = $false; at = (Get-Date).ToString("o") }
    }
    else {
        $keepAt = if ($prev -and $prev.ContainsKey("at")) { $prev["at"] } else { (Get-Date).ToString("o") }
        $State[$Key] = @{ bad = $IsBad; at = $keepAt }
    }
}

# ------------------------------------------------------------ long-job wrapper
#
#  Item 30. Wrap anything slow so it announces itself when it lands.
#  Short jobs stay silent - MinSeconds is the "was this worth telling him" gate.

function Invoke-NtfyJob {
    <#
        .EXAMPLE  Invoke-NtfyJob -Name "Nightly backup" -MinSeconds 120 -Script { & "D:\scripts\backup.ps1" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$MinSeconds = 120,
        [string[]]$Tags = @("hourglass_flowing_sand")
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $failed = $null
    try { & $Script } catch { $failed = $_ }
    $sw.Stop()

    $elapsed = [TimeSpan]::FromSeconds([math]::Round($sw.Elapsed.TotalSeconds))
    if ($elapsed.TotalHours -ge 1)        { $pretty = "{0}h{1:00}m" -f [int]$elapsed.TotalHours, $elapsed.Minutes }
    elseif ($elapsed.TotalMinutes -ge 1)  { $pretty = "{0}m {1:00}s" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds }
    else                                  { $pretty = "{0}s" -f [int]$elapsed.TotalSeconds }

    if ($failed) {
        Send-Ntfy -Title "$Name FAILED" -Message ("After {0}.`n{1}" -f $pretty, $failed.Exception.Message) `
                  -Topic "pc-alert" -Priority 5 -Tags @("rotating_light") | Out-Null
        throw $failed
    }
    if ($sw.Elapsed.TotalSeconds -ge $MinSeconds) {
        Send-Ntfy -Title "$Name finished" -Message ("Took {0}." -f $pretty) `
                  -Topic "pc-info" -Priority 2 -Tags $Tags | Out-Null
    }
}

Export-ModuleMember -Function Send-Ntfy, Send-NtfyTransition, Get-NtfyState, Set-NtfyState,
                              Get-NtfyToken, Write-NtfyLog, Invoke-NtfyJob, ConvertTo-NtfyDate
