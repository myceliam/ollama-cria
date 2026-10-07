# Test stand-in for 'ssh <options> vps "sudo -n docker ..."', used only by
# tests/Sync-StackManifests.Tests.ps1. It takes the words of the remote
# command apart as the remote shell would (each is single-quoted, with
# '\'' for a quote) and hands them to fake-docker-images.ps1 as the VPS.
$command = [string]$args[-1]
$prefix = 'sudo -n docker '
if ($args.Count -lt 2 -or $args[-2] -ne 'vps' -or -not $command.StartsWith($prefix)) { exit 97 }
$rest = $command.Substring($prefix.Length)
$words = [Collections.Generic.List[string]]::new()
foreach ($m in [regex]::Matches($rest, "\G\s*'((?:[^']|'\\'')*)'")) { $words.Add($m.Groups[1].Value.Replace("'\''", "'")) }
if (($words | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" }) -join ' ' -ne $rest) { exit 96 }
$saved = $env:CRIA_FAKE_DOCKER_HOST
try {
    $env:CRIA_FAKE_DOCKER_HOST = 'vps'
    & (Join-Path $PSScriptRoot 'fake-docker-images.ps1') @words
    $code = $LASTEXITCODE
}
finally { $env:CRIA_FAKE_DOCKER_HOST = $saved }
exit $code
