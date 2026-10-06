# Test stand-in for ssh, used by tests/Collect-StackSecrets.Tests.ps1 and
# tests/Restore-StackSecrets.Tests.ps1. Drops the options and the host name,
# then runs the remote command with the local bash, its input passed on, so
# the real remote scripts are exercised.
$rest = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-o') { $i++; continue }
    if ($args[$i] -like '-*') { continue }
    $rest.Add($args[$i])
}
if ($rest.Count -lt 2) { exit 255 }
$input | & bash -c ($rest[1..($rest.Count - 1)] -join ' ')
exit $LASTEXITCODE
