# Test stand-in for 'winget export', used only by
# tests/Sync-StackManifests.Tests.ps1. Writes an export with three of the
# apps the stack needs (one newer than winget's source knows) and one it
# does not, to the file after -o.
if ($args[0] -ne 'export') { exit 1 }
$out = $args[[Array]::IndexOf($args, '-o') + 1]
$packages = @(
    @{ PackageIdentifier = 'Ollama.Ollama'; Version = '0.12.3' }
    @{ PackageIdentifier = 'Python.Python.3.13'; Version = '3.13.15' }
    @{ PackageIdentifier = 'Git.Git'; Version = '> 2.51.0' }
    @{ PackageIdentifier = 'Some.OtherApp'; Version = '1.0' }
)
@{ Sources = @(@{ Packages = $packages; SourceDetails = @{ Name = 'winget' } }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $out
exit 0
