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
            inventory     = [ordered]@{ sha256 = ('0' * 64); required = @('stack-env', 'owui-openai-key', 'vps-egress-env') }
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

    # Writes an inventory with the bundle's rows (plus any extras) and points
    # the map's inventory block at it. Returns the inventory's path.
    function Save-TestInventory($Bundle, [object[]]$Extra = @()) {
        $rows = @($Bundle.Map.entries | ForEach-Object { [ordered]@{ id = $_.id; required = [bool]$_.required } }) + $Extra
        $path = Join-Path $TestDrive ('inventory-' + [guid]::NewGuid().ToString('n') + '.json')
        [ordered]@{ formatVersion = 1; rows = $rows } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
        $Bundle.Map.inventory.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Save-TestMap $Bundle
        return $path
    }

    # Writes a copy of the repo's roots file with one root's path changed.
    function Save-TestRoot([string]$Name, [string]$Path) {
        $roots = Get-Content -LiteralPath $script:Roots -Raw | ConvertFrom-Json -AsHashtable
        $roots.roots[$Name].path = $Path
        $rootsPath = Join-Path $TestDrive ('roots-' + [guid]::NewGuid().ToString('n') + '.json')
        $roots | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rootsPath
        return $rootsPath
    }
}

Describe 'Test-RestoreMap' {

    Context 'a good map and bundle' {
        It 'passes the map on its own' {
            $b = New-TestBundle
            $r = Invoke-Check $b
            $r.Problems | Should -BeNullOrEmpty
            $r.Warnings | Should -BeNullOrEmpty
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
            (Invoke-Check $b).Problems | Should -Match 'mode, owner and group are only for VPS and volume destinations'
        }

        It 'accepts mode, a numeric owner and a group on a Docker volume row' {
            # A volume is a Linux filesystem, so its files have an owner and mode (M1-05).
            $b = New-TestBundle
            $b.Map.entries[3].mode = '0640'
            $b.Map.entries[3].owner = '1000'
            $b.Map.entries[3].group = '1000'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -BeNullOrEmpty
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

        It 'refuses a file name that ends in a separator' {
            $b = New-TestBundle
            $b.Map.entries[0].file = 'stack.env/'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #1 ('stack-env'): file name refused (ends in a separator, so it names a folder)"
        }

        It 'refuses a destination that ends in a separator' {
            $b = New-TestBundle
            $b.Map.entries[0].destination = 'stack:.env\'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #1 ('stack-env'): destination refused (ends in a separator, so it names a folder)"
        }
    }

    Context 'uniqueness' {
        It 'refuses two rows with the same id' {
            $b = New-TestBundle
            $b.Map.entries[1].id = 'stack-env'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #2 ('stack-env'): id already used by entry #1"
        }

        It 'refuses two destinations that differ only by case' {
            $b = New-TestBundle
            $copy = @{} + $b.Map.entries[0]
            $copy.id = 'stack-env-2'; $copy.file = 'other.env'; $copy.destination = 'stack:.ENV'
            $b.Map.entries += $copy
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #5 ('stack-env-2'): same destination as entry #1"
        }

        It 'refuses two rows for the same bundle file' {
            $b = New-TestBundle
            $copy = @{} + $b.Map.entries[0]
            $copy.id = 'stack-env-2'; $copy.file = 'STACK.env'; $copy.destination = 'stack:other.env'
            $b.Map.entries += $copy
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #5 ('stack-env-2'): same bundle file as entry #1"
        }

        It 'refuses two destinations that differ only by a trailing separator' {
            $b = New-TestBundle
            $copy = @{} + $b.Map.entries[0]
            $copy.id = 'stack-env-2'; $copy.file = 'other.env'; $copy.destination = 'stack:.env/'
            $b.Map.entries += $copy
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #5 ('stack-env-2'): same destination as entry #1"
        }

        It 'refuses two bundle files that differ only by a trailing separator' {
            $b = New-TestBundle
            $copy = @{} + $b.Map.entries[0]
            $copy.id = 'stack-env-2'; $copy.file = 'stack.env\'; $copy.destination = 'stack:other.env'
            $b.Map.entries += $copy
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry #5 ('stack-env-2'): same bundle file as entry #1"
        }
    }

    Context 'completeness' {
        It 'refuses a map with no inventory block' {
            $b = New-TestBundle
            $b.Map.Remove('inventory')
            Save-TestMap $b
            (Invoke-Check $b).IsValid | Should -BeFalse
        }

        It 'refuses a map that leaves out a required inventory row' {
            $b = New-TestBundle
            $b.Map.inventory.required += 'ghost-row'
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "inventory: required row 'ghost-row' has no entry in the map"
        }

        It 'refuses a required inventory row marked optional in the map' {
            $b = New-TestBundle
            $b.Map.entries[0].required = $false
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "inventory: required row 'stack-env' is marked optional in the map"
        }

        It 'refuses a required entry the inventory does not list as required' {
            $b = New-TestBundle
            $b.Map.entries[3].required = $true
            Save-TestMap $b
            (Invoke-Check $b).Problems | Should -Contain "entry 'ntfy-user-db': required, but not a required row of the inventory"
        }

        It 'passes against the inventory it was collected from' {
            $b = New-TestBundle
            $inv = Save-TestInventory $b
            $r = & $script:Tool -MapPath $b.MapPath -RootsPath $script:Roots -InventoryPath $inv
            $r.Problems | Should -BeNullOrEmpty
            $r.Warnings | Should -BeNullOrEmpty
        }

        It 'refuses a map collected from a different inventory' {
            $b = New-TestBundle
            $inv = Save-TestInventory $b
            Add-Content -LiteralPath $inv -Value ' '
            $r = & $script:Tool -MapPath $b.MapPath -RootsPath $script:Roots -InventoryPath $inv
            $r.Problems | Should -Contain 'inventory: the map was collected from a different inventory'
        }

        It 'refuses a required row of the inventory file that the map does not have' {
            $b = New-TestBundle
            $inv = Save-TestInventory $b -Extra @([ordered]@{ id = 'new-secret'; required = $true })
            $r = & $script:Tool -MapPath $b.MapPath -RootsPath $script:Roots -InventoryPath $inv
            $r.Problems | Should -Contain "inventory: required row 'new-secret' has no entry in the map"
        }

        It 'warns about an optional row of the inventory file that the map does not have' {
            $b = New-TestBundle
            $inv = Save-TestInventory $b -Extra @([ordered]@{ id = 'spare-key'; required = $false })
            $r = & $script:Tool -MapPath $b.MapPath -RootsPath $script:Roots -InventoryPath $inv
            $r.IsValid | Should -BeTrue
            $r.Warnings | Should -Contain "inventory: optional row 'spare-key' is not in the map"
        }
    }

    Context 'the bundle' {
        It 'reports a missing required file' {
            $b = New-TestBundle
            Remove-Item -LiteralPath (Join-Path $b.Dir '01/stack.env')
            (Invoke-Check $b -WithBundle).Problems | Should -Contain "entry #1 ('stack-env'): missing from the bundle (required)"
        }

        It 'warns about a missing optional file and stays valid' {
            $b = New-TestBundle
            Remove-Item -LiteralPath (Join-Path $b.Dir '07/ntfy/user.db')
            $r = Invoke-Check $b -WithBundle
            $r.Problems | Should -BeNullOrEmpty
            $r.IsValid | Should -BeTrue
            $r.Warnings | Should -Be @("entry #4 ('ntfy-user-db'): missing from the bundle (optional, the restorer skips it)")
        }

        It 'refuses a bundle with no map of its own' {
            $b = New-TestBundle
            $elsewhere = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.json')
            Move-Item -LiteralPath $b.MapPath -Destination $elsewhere
            $r = & $script:Tool -MapPath $elsewhere -RootsPath $script:Roots -BundleRoot $b.Dir
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain 'bundle: 00-RESTORE-MAP.json is missing'
        }

        It 'refuses a bundle whose own map is not the map that was checked' {
            $b = New-TestBundle
            $elsewhere = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.json')
            Copy-Item -LiteralPath $b.MapPath -Destination $elsewhere
            $b.Map.entries[0].destination = 'stack:somewhere-else.env'
            Save-TestMap $b
            $r = & $script:Tool -MapPath $elsewhere -RootsPath $script:Roots -BundleRoot $b.Dir
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain 'bundle: 00-RESTORE-MAP.json differs from the map that was checked'
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

        It 'refuses <Root> path <Path> (<Why>)' -ForEach @(
            @{ Root = 'stack'; Path = 'ai\ollama'; Why = 'not an absolute PC path (E:\... or %VAR%\...)' }
            @{ Root = 'stack'; Path = '\ai\ollama'; Why = 'not an absolute PC path (E:\... or %VAR%\...)' }
            @{ Root = 'stack'; Path = 'E:\'; Why = 'a whole drive or filesystem root, which is too broad' }
            @{ Root = 'stack'; Path = '\\server\share\x'; Why = 'UNC or device path' }
            @{ Root = 'stack'; Path = 'E:\ai\..\x'; Why = "'..' segment" }
            @{ Root = 'stack'; Path = 'E:\ai\\x'; Why = 'empty segment (doubled separator)' }
            @{ Root = 'stack'; Path = 'E:\ai\x:y'; Why = 'colon after the drive' }
            @{ Root = 'stack'; Path = 'E:\ai\*'; Why = 'control or wildcard character' }
            @{ Root = 'vps-egress'; Path = 'home/liam/x'; Why = 'not an absolute VPS path (/...)' }
            @{ Root = 'vps-egress'; Path = 'C:\home\x'; Why = 'not an absolute VPS path (/...)' }
            @{ Root = 'vps-egress'; Path = '/home/../etc'; Why = "'..' segment" }
            @{ Root = 'vps-egress'; Path = '/home\liam'; Why = 'backslash in a VPS path' }
        ) {
            $b = New-TestBundle
            $r = Invoke-Check $b -RootsPath (Save-TestRoot $Root $Path)
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain "root '$Root': path refused ($Why)"
        }

        It 'accepts a /x PC root only off Windows, where tests stand in for the PC' {
            $b = New-TestBundle
            $r = Invoke-Check $b -RootsPath (Save-TestRoot 'stack' '/srv/stack')
            if ($IsWindows) { $r.Problems | Should -Contain "root 'stack': path refused (not an absolute PC path (E:\... or %VAR%\...))" }
            else { $r.Problems | Should -BeNullOrEmpty }
        }

        It 'refuses two roots that name <Why>' -ForEach @(
            @{ Why = 'the same folder'; Path = 'E:\ai\ollama\' }
            @{ Why = 'nested folders, in another case'; Path = 'E:\AI\Ollama\sub' }
            @{ Why = 'a folder that holds the other'; Path = 'E:\ai' }
        ) {
            # Two names for one place would let 'stack:.env' and 'dashboard:.env' collide (M1-03).
            $b = New-TestBundle
            $r = Invoke-Check $b -RootsPath (Save-TestRoot 'dashboard' $Path)
            $r.Problems | Should -Contain "roots 'dashboard' and 'stack' name the same or nested folders"
        }

        It 'refuses two roots that name the same volume' {
            $roots = Get-Content -LiteralPath $script:Roots -Raw | ConvertFrom-Json -AsHashtable
            $roots.roots['bolt-data'].volume = $roots.roots['ntfy-data'].volume
            $rootsPath = Join-Path $TestDrive 'roots-same-volume.json'
            $roots | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rootsPath
            $r = Invoke-Check (New-TestBundle) -RootsPath $rootsPath
            $r.Problems | Should -Contain "roots 'bolt-data' and 'ntfy-data' name the same volume"
        }

        It 'passes roots that only share a name prefix' {
            $b = New-TestBundle
            (Invoke-Check $b -RootsPath (Save-TestRoot 'dashboard' 'E:\ai\ollama-other')).Problems | Should -BeNullOrEmpty
        }

        It 'accepts %VAR% at the start of a PC path and a trailing separator' {
            $b = New-TestBundle
            (Invoke-Check $b -RootsPath (Save-TestRoot 'stack' '%USERPROFILE%\stack\')).Problems | Should -BeNullOrEmpty
        }
    }
}
