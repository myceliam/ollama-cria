# Test stand-in for scp, used only by tests/Collect-StackSecrets.Tests.ps1.
# Copies 'host:/path' to the local destination with cp.
$rest = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-o') { $i++; continue }
    if ($args[$i] -like '-*') { continue }
    $rest.Add($args[$i])
}
if ($rest.Count -ne 2) { exit 255 }
& cp -- $rest[0].Substring($rest[0].IndexOf(':') + 1) $rest[1]
exit $LASTEXITCODE
