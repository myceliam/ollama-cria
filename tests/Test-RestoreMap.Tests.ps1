#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '../tools/Test-RestoreMap.ps1'
    $script:Roots = Join-Path $PSScriptRoot '../manifests/recovery-roots.json'

    # Builds a small bundle with fake, non-secret content and a matching map.
    # Nothing secret-shaped is ever written: the content is 'fake-' plus a GUID.
    function New-TestBundle {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $rows = @(
            @{ id = 'stack-env'; folder = '01'; file = 'stack.env'; destination = 'stack:.env'; required = $true }
            @{ id = 'owui-openai-key'; folder = '03'; file = 'openai-api-key'; destination = 'owui-secrets:openai-api-key'; required = $true }
            @{ id = 'vps-egress-env'; folder = '05'; file = 'egress.env'; destination = 'vps-egress:.env'; required = $true; mode = '0600'; owner = 'liam' }
            @{ id = 'ntfy-user-db'; folder = '07'; file = 'ntfy/user.db'; destination = 'ntfy-data:user.db'; required = $false }
        )
        foreach ($r in $rows) {
            $path = Join-Path $dir (Join-Path $r.folder $r.file)
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            Set-Content -LiteralPath $path -Value ('fake-' + [guid]::NewGuid().ToString('n')) -NoNewline
            $r.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $r.bytes = (Get-Item -LiteralPath $path).Length
        }
        $map = [ordered]@{
            formatVersion = 1
            createdUtc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            collector     = [ordered]@{ name = 'Collect-StackSecrets.ps1'; version = '1.0.0' }
            entries       = $rows
        }
        $bundle = [pscustomobject]@{ Dir = $dir; MapPath = (Join-Path $dir '00-RESTORE-MAP.json'); Map = $map }
        Save-TestMap $bundle
        return $bundle
    }

    function Save-TestMap($Bundle) {
        $Bundle.Map | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Bundle.MapPath
    }

    function Invoke-Check($Bundle, [switch]$WithBundle, [string]$RootsPath = $script:Roots) {
        if ($WithBundle) { & $script:Tool -MapPath $Bundle.MapPath -RootsPath $RootsPath -BundleRoot $Bundle.Dir }
        else { & $script:Tool -MapPath $Bundle.MapPath -RootsPath $RootsPath }
    }
}

Describe 'Test-RestoreMap' {

    Context 'a good map and bundle' {
        It 'passes the map on its own' {
            $b = New-TestBundle
            $r = Invoke-Check $b
            $r.Problems | Should -BeNullOrEmpty
            $r.IsValid | Should -BeTrue
            $r.EntryCount | Should -Be 4
        }

        It 'passes the map with its bundle' {
            $b = New-TestBundle
            (Invoke-Check $b -WithBundle).Problems | Should -BeNullOrEmpty
        }

        It 'accepts the repo''s roots file' {
            Test-Json -Path $script:Roots -SchemaFile (Join-Path $PSScriptRoot '../manifests/schemas/recovery-roots.schema.json') |
                Should -BeTrue
        }
    }

    Context 'schema' {
        It 'refuses an unknown format version' {
            $b = New-TestBundle
            $b.Map.formatVersion = 2
            Save-TestMap $b
            $r = Invoke-Check $b
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Match '^map:'
        }

        It 'refuses an unknown field (no free text that could carry a secret)' {
            $b = New-TestBundle
            $b.Map.entries[0].note = 'anything'
            Save-TestMap $b
            (Invoke-Check $b).IsValid | Should -BeFalse
        }

        It 'refuses bundle folder 06, removed in v0.3' {
            $b = New-TestBundle
            $b.Map.entries[0].folder = '06'
            Save-TestMap $b
            (Invoke-Check $b).IsValid | Should -BeFalse
        }

        It 'refuses a short hash' {
            $b = New-TestBundle
            $b.Map.entries[0].sha256 = 'abc123'
            Save-TestMap $b
            (Invoke-Check $b).IsValid | Should -BeFalse
        }

        It 'refuses a missing map file' {
            $r = & $script:Tool -MapPath (Join-Path $TestDrive 'nope.json') -RootsPath $script:Roots
            $r.Problems | Should -Contain 'map: file not found'
        }
    }

    Context 'rows' {
        It 'refuses an unknown root' {
            $b = New-TestBundle
            $b.Map.entries[0].destination = 'nowhere:.env'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #1 ('stack-env'): unknown root 'nowhere'"
        }

        It 'refuses a bundle folder sent to the wrong kind of root' {
            $b = New-TestBundle
            $b.Map.entries[2].destination = 'stack:egress.env'
            $b.Map.entries[2].Remove('mode'); $b.Map.entries[2].Remove('owner')
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match "folder 05 must go to a vps 'path' root"
        }

        It 'refuses mode and owner on a PC row' {
            $b = New-TestBundle
            $b.Map.entries[0].mode = '0600'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match 'mode and owner are only for VPS destinations'
        }

        It 'refuses a destination that climbs out of its root' {
            $b = New-TestBundle
            $b.Map.entries[0].destination = 'stack:../../Windows/x'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match "destination refused \('\.\.' segment\)"
        }

        It 'refuses an absolute destination' {
            $b = New-TestBundle
            $b.Map.entries[0].destination = 'stack:/etc/x'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match 'destination refused \(rooted path'
        }

        It 'refuses a bundle file name that climbs out of its folder' {
            $b = New-TestBundle
            $b.Map.entries[0].file = '../02/x'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match 'file name refused'
        }
    }

    Context 'uniqueness' {
        It 'refuses two rows with the same id' {
            $b = New-TestBundle
            $b.Map.entries[1].id = 'stack-env'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match 'id already used by entry #1'
        }

        It 'refuses two destinations that differ only by case' {
            $b = New-TestBundle
            $copy = @{} + $b.Map.entries[0]
            $copy.id = 'stack-env-2'; $copy.file = 'other.env'; $copy.destination = 'stack:.ENV'
            $b.Map.entries += $copy
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match 'same destination as entry #1'
        }

        It 'refuses two rows for the same bundle file' {
            $b = New-TestBundle
            $copy = @{} + $b.Map.entries[0]
            $copy.id = 'stack-env-2'; $copy.file = 'STACK.env'; $copy.destination = 'stack:other.env'
            $b.Map.entries += $copy
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Match 'same bundle file as entry #1'
        }
    }

    Context 'the bundle' {
        It 'reports a missing required file' {
            $b = New-TestBundle
            Remove-Item -LiteralPath (Join-Path $b.Dir '01/stack.env')
            (Invoke-Check $b -WithBundle).Problems | Should -Contain "entry #1 ('stack-env'): missing from the bundle (required)"
        }

        It 'reports a file whose length changed' {
            $b = New-TestBundle
            Add-Content -LiteralPath (Join-Path $b.Dir '01/stack.env') -Value 'x' -NoNewline
            (Invoke-Check $b -WithBundle).Problems | Should -Match 'byte length differs'
        }

        It 'reports a file whose content changed but not its length' {
            $b = New-TestBundle
            $p = Join-Path $b.Dir '01/stack.env'
            $text = Get-Content -LiteralPath $p -Raw
            Set-Content -LiteralPath $p -Value ($text.Substring(0, $text.Length - 1) + 'Z') -NoNewline
            (Invoke-Check $b -WithBundle).Problems | Should -Match 'SHA-256 differs'
        }

        It 'reports a file the map does not list' {
            $b = New-TestBundle
            Set-Content -LiteralPath (Join-Path $b.Dir '01/stray.txt') -Value 'stray'
            (Invoke-Check $b -WithBundle).Problems | Should -Contain "bundle: '01/stray.txt' is not listed in the map"
        }

        It 'never echoes file content or hashes in its problems' {
            $b = New-TestBundle
            $p = Join-Path $b.Dir '01/stack.env'
            $content = Get-Content -LiteralPath $p -Raw
            $hash = $b.Map.entries[0].sha256
            Set-Content -LiteralPath $p -Value ($content.Substring(0, $content.Length - 1) + 'Z') -NoNewline
            $all = (Invoke-Check $b -WithBundle).Problems -join "`n"
            $all | Should -Not -BeNullOrEmpty
            $all | Should -Not -Match ([regex]::Escape($content.Substring(5)))
            $all | Should -Not -Match $hash
        }
    }

    Context 'the roots file' {
        It 'refuses a volume root with no volume name' {
            $roots = Get-Content -LiteralPath $script:Roots -Raw | ConvertFrom-Json -AsHashtable
            $roots.roots['ntfy-data'].Remove('volume')
            $roots.roots['ntfy-data'].path = 'E:\somewhere'
            $rootsPath = Join-Path $TestDrive 'roots-bad.json'
            $roots | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rootsPath
            $b = New-TestBundle
            $r = Invoke-Check $b -RootsPath $rootsPath
            $r.Problems | Should -Contain "root 'ntfy-data': kind 'volume' needs 'volume'"
            $r.Problems | Should -Contain "root 'ntfy-data': kind 'volume' must not have 'path'"
        }
    }
}
