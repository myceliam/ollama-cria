[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CommandBase64,
    [Parameter(Mandatory)] [string] $WorkingDirectoryBase64,
    [Parameter(Mandatory)] [int] $TimeoutSeconds,
    [Parameter(Mandatory)] [int] $MaxOutputChars,
    [Parameter(Mandatory)] [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
$stdoutPath = "$ResultPath.stdout"
$stderrPath = "$ResultPath.stderr"

try {
    $command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CommandBase64))
    $workingDirectory = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($WorkingDirectoryBase64))
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw 'Working directory does not exist.'
    }

    $prelude = @'
$ProgressPreference='SilentlyContinue';
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);
$OutputEncoding=[Text.UTF8Encoding]::new($false);
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prelude + $command))
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $process = Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
    ) -WorkingDirectory $workingDirectory -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill($true) } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        $process.WaitForExit()
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding utf8 } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding utf8 } else { '' }
    $truncated = ($stdout.Length + $stderr.Length) -gt $MaxOutputChars
    if ($stdout.Length -gt $MaxOutputChars) { $stdout = $stdout.Substring(0, $MaxOutputChars) }
    $remaining = [Math]::Max(0, $MaxOutputChars - $stdout.Length)
    if ($stderr.Length -gt $remaining) { $stderr = $stderr.Substring(0, $remaining) }

    $result = [ordered]@{
        status = if (-not $finished) { 'timed_out' } elseif ($process.ExitCode -eq 0) { 'ok' } else { 'command_failed' }
        exit_code = if ($finished) { $process.ExitCode } else { $null }
        stdout = $stdout
        stderr = $stderr
        timed_out = (-not $finished)
        output_truncated = $truncated
        elevated_identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
}
catch {
    $result = [ordered]@{
        status = 'elevation_failed'
        exit_code = $null
        stdout = ''
        stderr = "Elevated runner failed: $($_.Exception.GetType().Name): $($_.Exception.Message)"
        timed_out = $false
        output_truncated = $false
    }
}
finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
}

$result | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
