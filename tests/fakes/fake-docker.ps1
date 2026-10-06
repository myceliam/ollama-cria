# Test stand-in for docker, used only by tests/Collect-StackSecrets.Tests.ps1.
# Image and volume checks always pass. What 'docker run' does depends on
# $env:CRIA_FAKE_DOCKER:
#   run-fails  exits 1 without answering (the helper never ran)
#   bad-exit   prints a good answer, then exits 1
#   mismatch   exits 0, but the hash it reports is not the data it sends
#   stuck      answers well, but the container never goes away ('rm' fails)
#   lock       makes the newest run folder's bundle folder read-only, then
#              exits 1, so the collector cannot delete it (Linux only)
#   anything else: a good answer
$mode = $env:CRIA_FAKE_DOCKER
$command = $args[0]
if ($command -eq 'image') { exit 0 }
if ($command -eq 'volume') { 'fake-created-time'; exit 0 }
if ($command -eq 'rm') { if ($mode -eq 'stuck') { exit 1 }; exit 0 }
if ($command -eq 'ps') {
    $filter = $args[[Array]::IndexOf($args, '--filter') + 1]
    if ($mode -eq 'stuck' -and $filter -like 'name=*') { $filter.Substring(5).Trim('^', '$', '/') }
    exit 0
}
if ($command -ne 'run') { exit 1 }

if ($mode -eq 'run-fails') { exit 1 }
if ($mode -eq 'lock') {
    $runFolder = Get-ChildItem -LiteralPath $env:CRIA_FAKE_STAGING -Directory -Filter 'stack-secrets-*' | Sort-Object Name | Select-Object -Last 1
    & chmod 0500 (Join-Path $runFolder.FullName 'bundle')
    exit 1
}
$data = [Text.Encoding]::ASCII.GetBytes('fake-volume-content')
$sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
if ($mode -eq 'mismatch') { $sha = '0' * 64 }
[ordered]@{ status = 'ok'; bytes = $data.Length; sha256 = $sha; mode = '0640'; uid = 1000; gid = 1000 } | ConvertTo-Json -Compress
[Convert]::ToBase64String($data)
if ($mode -eq 'bad-exit') { exit 1 }
exit 0
