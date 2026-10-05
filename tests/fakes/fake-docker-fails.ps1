# Test stand-in for docker, used only by tests/Collect-StackSecrets.Tests.ps1.
# Says the image and every volume exist, then fails to create the helper, so a
# test can make the collector fail after its run folder exists.
if ($args.Count -ge 2 -and $args[1] -eq 'inspect') { exit 0 }
exit 1
