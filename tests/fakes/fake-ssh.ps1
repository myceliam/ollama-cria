# Test stand-in for ssh, used by tests/Collect-StackSecrets.Tests.ps1,
# tests/Restore-StackSecrets.Tests.ps1 and tests/Sync-StackFiles.Tests.ps1.
# Drops the options and the host name, then runs the remote command with the
# local bash, so the real remote scripts are exercised. Its input is passed
# on with CRLF line ends, as PowerShell on Windows sends it to ssh.
$rest = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-o') { $i++; continue }
    if ($args[$i] -like '-*') { continue }
    $rest.Add($args[$i])
}
if ($rest.Count -lt 2) { exit 255 }
# The VPS's address list for tools/Sync-StackFiles.ps1: a docker bridge, a
# tailnet address, and whatever $env:CRIA_FAKE_VPS_ADDRESSES lists
# (comma-separated), or a failed connection when it says 'fail'.
if (($rest[1..($rest.Count - 1)] -join ' ') -eq 'ip -o addr show scope global') {
    if ($env:CRIA_FAKE_VPS_ADDRESSES -eq 'fail') { exit 255 }
    $listed = @(([string]$env:CRIA_FAKE_VPS_ADDRESSES) -split ',' | Where-Object { $_ })
    foreach ($a in @(@('172', '17', '0', '1') -join '.') + @(@('100', '64', '0', '8') -join '.') + $listed) {
        $family = if ($a.Contains(':')) { 'inet6' } else { 'inet' }
        "2: eth0    $family $a/24 scope global eth0\       valid_lft forever preferred_lft forever"
    }
    exit 0
}
$input | ForEach-Object { "$_`r" } | & bash -c ($rest[1..($rest.Count - 1)] -join ' ')
exit $LASTEXITCODE
