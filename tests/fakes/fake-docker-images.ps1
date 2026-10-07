# Test stand-in for docker, used only by tests/Sync-StackManifests.Tests.ps1
# to list containers and their images. $env:CRIA_FAKE_DOCKER_HOST picks the
# machine ('vps', or the PC by default). $env:CRIA_FAKE_IMAGES set to
# 'fail-pc' or 'fail-vps' makes that machine's 'ps' fail. Any other command,
# or a format string other than the ones the tool sends, exits 98, so a
# quoting mistake on the way shows up as a failure.
$machine = if ($env:CRIA_FAKE_DOCKER_HOST) { $env:CRIA_FAKE_DOCKER_HOST } else { 'pc' }
function Get-FakeId([string]$Char) { 'sha256:' + ($Char * 64) }
$containers = if ($machine -eq 'vps') {
    [ordered]@{
        'vps-web-gateway' = @('vps-web-gateway:local', (Get-FakeId 'c'), 'running', 'vps-web', @())
        'vps-web-relay'   = @('vps-web-relay:gone', (Get-FakeId 'e'), 'exited', 'vps-web', @())
        'kokoro-tts'      = @('ghcr.io/remsky/kokoro-fastapi-cpu:v0.5.0', (Get-FakeId 'd'), 'running', 'kokoro', @('ghcr.io/remsky/kokoro-fastapi-cpu@sha256:' + ('4' * 64)))
    }
}
else {
    [ordered]@{
        'ntfy'       = @('binwiederhier/ntfy:v2.11.0', (Get-FakeId 'b'), 'running', '<no value>', @('binwiederhier/ntfy@sha256:' + ('2' * 64)))
        'open-webui' = @('ghcr.io/open-webui/open-webui:v0.11.4', (Get-FakeId 'a'), 'running', 'ollama', @('ghcr.io/open-webui/open-webui@sha256:' + ('1' * 64)))
    }
}
$inspectFormat = '{{.Name}}|{{.Config.Image}}|{{.Image}}|{{.State.Status}}|{{index .Config.Labels "com.docker.compose.project"}}'
if ($args.Count -eq 4 -and $args[0] -eq 'ps' -and $args[1] -eq '-a' -and $args[2] -eq '--format' -and $args[3] -ceq '{{.Names}}') {
    if ($env:CRIA_FAKE_IMAGES -eq "fail-$machine") { exit 1 }
    $containers.Keys
    exit 0
}
if ($args.Count -ge 4 -and $args[0] -eq 'inspect' -and $args[1] -eq '--format' -and $args[2] -ceq $inspectFormat) {
    foreach ($name in $args[3..($args.Count - 1)]) {
        if (-not $containers.Contains($name)) { exit 1 }
        $c = $containers[$name]
        "/$name|$($c[0])|$($c[1])|$($c[2])|$($c[3])"
    }
    exit 0
}
if ($args.Count -eq 7 -and ($args[0..5] -join ' ') -ceq 'image ls -a --no-trunc --digests --format' -and $args[6] -ceq '{{.ID}}|{{.Repository}}|{{.Tag}}|{{.Digest}}') {
    foreach ($c in $containers.Values) {
        $repo, $tag = $c[0] -split ':(?=[^:/]*$)'
        # 'gone': the container's image was rebuilt, and the tag moved to the new one.
        if ($tag -eq 'gone') { "$(Get-FakeId '0')|$repo|$tag|<none>"; continue }
        if (-not $c[4]) { "$($c[1])|$repo|$tag|<none>"; continue }
        foreach ($d in $c[4]) { "$($c[1])|$($d -replace '@.*$', '')|$tag|$($d -replace '^.*@', '')" }
    }
    "$(Get-FakeId 'f')|<none>|<none>|<none>"
    exit 0
}
exit 98
