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
$input | ForEach-Object { "$_`r" } | & bash -c ($rest[1..($rest.Count - 1)] -join ' ')
exit $LASTEXITCODE
