# Test stand-in for docker, used only by tests/Collect-StackSecrets.Tests.ps1.
# Image and volume checks always pass. What 'docker run' does depends on
# $env:CRIA_FAKE_DOCKER:
#   run-fails  exits 1 without answering (the helper never ran)
#   bad-exit   prints a good answer, then exits 1
#   mismatch   exits 0, but the hash it reports is not the data it sends
#   stuck      answers well, but the container never goes away ('rm' fails)
#   lock       makes the newest run folder's bundle folder read-only, then
#              exits 1, so the collector cannot delete it (Linux only)
#   appear     creates the staging root while the image is checked, as
#              another account could between the check and the run
#   anything else: a good answer
# For the OWUI seed, 'inspect' and 'image inspect' describe a running
# container, and 'exec' runs the real exporter with the local Python against
# the fake OWUI in tests/python/fake_owui and the database named in
# $env:CRIA_FAKE_OWUI_DB. Modes:
#   owui-stopped  the container is not running
#   seed-stop     the exporter sees another OWUI version, so it stops
#   seed-noise    one more line of other error output, with a fake key in it
#   seed-leak     a value from the secrets file is put into a seed file
#   seed-scan     a token the exporter never saw is put into a seed file
$mode = $env:CRIA_FAKE_DOCKER
$command = $args[0]
if ($command -eq 'image') {
    if ($mode -eq 'appear') { New-Item -ItemType Directory -Path $env:CRIA_FAKE_STAGING | Out-Null }
    if ($args -contains '{{json .RepoDigests}}') { '["ghcr.io/open-webui/open-webui@sha256:' + ('f' * 64) + '"]' }
    exit 0
}
if ($command -eq 'inspect') {
    $running = if ($mode -eq 'owui-stopped') { 'false' } else { 'true' }
    "$running sha256:" + ('e' * 64)
    exit 0
}
if ($command -eq 'exec') {
    $envelope = (@($input) -join "`n") | ConvertFrom-Json -AsHashtable
    $envelope.argv = @($envelope.argv) + @('--db', $env:CRIA_FAKE_OWUI_DB)
    $python = @(if ($IsWindows) { 'python', 'python3' } else { 'python3', 'python' }) |
        ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1
    # This script runs in the caller's process, so the environment is put back.
    $saved = $env:PYTHONPATH, $env:FAKE_OWUI_VERSION
    try {
        $env:PYTHONPATH = Join-Path $PSScriptRoot '../python/fake_owui'
        if ($mode -eq 'seed-stop') { $env:FAKE_OWUI_VERSION = '0.0.1' }
        $json = $envelope | ConvertTo-Json -Compress -Depth 5 -EscapeHandling EscapeNonAscii
        $answer = @($json | & $python.Source -c $args[-1] 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $env:PYTHONPATH, $env:FAKE_OWUI_VERSION = $saved }
    foreach ($item in $answer) {
        if ($item -is [Management.Automation.ErrorRecord]) { Write-Error -Message $item.ToString() -ErrorAction Continue; continue }
        $line = [string]$item
        if ($mode -in 'seed-leak', 'seed-scan' -and $line.StartsWith('{')) {
            $doc = $line | ConvertFrom-Json -AsHashtable
            $extra = if ($mode -eq 'seed-leak') { @(($doc.secrets_file | ConvertFrom-Json -AsHashtable).refs['config/openai.api_keys'])[0] } else { 'ghp_' + ('x' * 36) }
            $doc.seed['prompt.json'] = $doc.seed['prompt.json'].Replace('Tidy this', "Tidy this $extra")
            $line = $doc | ConvertTo-Json -Compress -Depth 5 -EscapeHandling EscapeNonAscii
        }
        $line
    }
    if ($mode -eq 'seed-noise') { Write-Error -Message ('Traceback (most recent call last): key=' + 'sk-' + ('N' * 40)) -ErrorAction Continue }
    exit $code
}
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
