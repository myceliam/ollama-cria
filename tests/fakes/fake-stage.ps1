# A stage script for the controller tests, copied in as NN-fake.ps1. What
# it does is set per stage number in $global:CriaStage:
#   Run      'done' (default), 'failed', 'needs-user' or 'reboot'
#   Check    'passed' (default), 'failed' or 'needs-user'
#   Throw    a message to throw in Run, after creating the files
#   Create   file names to create in $global:CriaLive and record as owned
#   Keep     file names to create and record as 'keep'
#   Data     a table returned as the stage's data
#   Step     a step line to report
#   Ask      an id the stage asks about until it is accepted
#   Rows     extra checkpoint rows, each @{ What; Actual; Ok }
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Run', 'Check')][string]$Mode,
    [Parameter(Mandatory)][hashtable]$Context
)

# In a child process (the exit code tests) there is no configuration.
$all = Get-Variable -Name CriaStage -Scope Global -ValueOnly -ErrorAction SilentlyContinue
$calls = Get-Variable -Name CriaStageCalls -Scope Global -ValueOnly -ErrorAction SilentlyContinue
$seen = Get-Variable -Name CriaStageSeen -Scope Global -ValueOnly -ErrorAction SilentlyContinue
$cfg = if ($all -is [hashtable] -and $all["$($Context.Stage)"]) { $all["$($Context.Stage)"] } else { @{} }
if ($null -ne $calls) { $calls.Add("$($Context.Stage):$Mode") }
if ($seen -is [hashtable]) { $seen["$($Context.Stage):$Mode"] = $Context }

if ($Mode -eq 'Check') {
    $status = if ($cfg.ContainsKey('Check')) { $cfg['Check'] } else { 'passed' }
    $r = New-StageResult -Status 'passed'
    if ($status -eq 'needs-user') { Add-StageAsk $r 'a person must look' }
    else { Add-StageCheck $r 'fake check' 'passed' $status ($status -eq 'passed') }
    foreach ($row in @($cfg['Rows'])) { if ($row) { Add-StageCheck $r $row.What '' $row.Actual $row.Ok } }
    return $r
}
if ($Mode -eq 'Plan') {
    $r = New-StageResult -Status 'planned'
    $r.Steps.Add("would run stage $($Context.Stage)")
    return $r
}
$r = New-StageResult -Status 'done'
foreach ($name in @($cfg['Create'])) {
    if (-not $name) { continue }
    $p = Join-Path $global:CriaLive $name
    [IO.File]::WriteAllText($p, 'made')
    & $Context.Own 'file' $p $global:CriaLive
}
foreach ($name in @($cfg['Keep'])) {
    if (-not $name) { continue }
    $p = Join-Path $global:CriaLive $name
    [IO.File]::WriteAllText($p, 'made')
    & $Context.Own 'file' $p $global:CriaLive 'keep'
}
if ($cfg['Throw']) { throw $cfg['Throw'] }
if ($cfg['Data']) { foreach ($k in $cfg['Data'].Keys) { $r.Data[$k] = $cfg['Data'][$k] } }
if ($cfg['Step']) { $r.Steps.Add($cfg['Step']) }
if ($cfg['Ask'] -and $cfg['Ask'] -notin $Context.Accepted) { Add-StageAsk $r 'answer the question' -Id $cfg['Ask'] }
if ($cfg['Run']) { $r.Status = $cfg['Run'] }
$r.Steps.Add("ran stage $($Context.Stage)")
return $r
