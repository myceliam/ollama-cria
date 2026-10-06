[CmdletBinding()]
param(
    [switch] $SkipScheduledTask,
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSCommandPath
$stackRoot = Split-Path -Parent $toolRoot
$envFile = Join-Path $stackRoot '.env'
$config = Get-Content -LiteralPath (Join-Path $toolRoot 'config.json') -Raw | ConvertFrom-Json
$variableName = [string]$config.token_environment_variable

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Stack .env file not found: $envFile"
}

$existing = Get-Content -LiteralPath $envFile | Where-Object { $_ -match "^$([regex]::Escape($variableName))=" } | Select-Object -Last 1
if (-not $existing) {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [IO.File]::AppendAllText($envFile, [Environment]::NewLine + "$variableName=$token" + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host "$variableName generated and stored in the stack .env (value not printed)."
}
else {
    Write-Host "$variableName already exists in the stack .env; preserving it."
}

New-Item -ItemType Directory -Force -Path (Join-Path $toolRoot 'state\results') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stackRoot 'logs') | Out-Null

& 'C:\Python313\python.exe' -m py_compile (Join-Path $toolRoot 'server.py')
foreach ($scriptName in 'Validate-ReadCommand.ps1', 'Invoke-Elevated.ps1', 'Elevated-Runner.ps1', 'Start-WindowsPowerShellTool.ps1') {
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $toolRoot $scriptName), [ref]$null, [ref]$errors) | Out-Null
    if ($errors) { throw "$scriptName failed PowerShell parsing: $($errors[0].Message)" }
}

$taskName = 'OWUI-Windows-PowerShell-Tool'
if (-not $SkipScheduledTask) {
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $pythonPath = 'C:\Python313\python.exe'
    $serverPath = Join-Path $toolRoot 'server.py'
    $oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($oldTask -and $oldTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 1
    }
    foreach ($listener in @(Get-NetTCPConnection -LocalAddress ([string]$config.bind_host) -LocalPort ([int]$config.port) -State Listen -ErrorAction SilentlyContinue)) {
        $listenerProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
        if ($listenerProcess.ExecutablePath -ine $pythonPath -or $listenerProcess.CommandLine -notlike "*$serverPath*") {
            throw "Port $($config.port) is owned by unexpected process $($listener.OwningProcess); refusing to replace it."
        }
        Stop-Process -Id $listener.OwningProcess -Force
    }
    $action = New-ScheduledTaskAction -Execute $pythonPath -Argument "`"$serverPath`"" -WorkingDirectory $toolRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Non-elevated Windows PowerShell broker for the Open WebUI approval-popup tool.' -Force | Out-Null
    Write-Host "Scheduled task $taskName registered at LIMITED privilege."
}

if (-not $NoStart) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $taskName
    }
    else {
        $startScript = Join-Path $toolRoot 'Start-WindowsPowerShellTool.ps1'
        Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-File',$startScript) -WorkingDirectory $toolRoot -WindowStyle Hidden
    }
}

Write-Host 'Install complete. The broker remains non-elevated; elevated calls use one-off Windows UAC.'
