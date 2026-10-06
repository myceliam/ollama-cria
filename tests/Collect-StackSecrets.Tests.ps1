#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    # The volume tests need a Linux Docker engine (GitHub's ubuntu runner has one).
    $DockerReady = $false
    if ($IsLinux -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        docker info *> $null
        $DockerReady = ($LASTEXITCODE -eq 0)
    }
    # The seed tests run the real exporter with the local Python (CI sets up 3.11).
    $PythonReady = [bool](Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '../tools/Collect-StackSecrets.ps1'
    $script:MapTool = Join-Path $PSScriptRoot '../tools/Test-RestoreMap.ps1'
    $script:Manifests = Join-Path $PSScriptRoot '../manifests'
    $script:Fakes = Join-Path $PSScriptRoot 'fakes'
    $script:Missing = Join-Path $TestDrive 'no-such-program'

    # Builds a PC tree (and optionally a stand-in VPS tree and Docker volumes)
    # under TestDrive, with a manifest and roots file pointing at it. Content is
    # always 'fake-' plus a GUID: nothing secret-shaped is ever written.
    function New-TestSetup {
        param([switch]$WithVps, [string]$NtfyVolume, [string]$BoltVolume, [switch]$WithOwui)
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $setup = [pscustomobject]@{
            Pc           = Join-Path $base 'pc'
            Vps          = Join-Path $base 'vps'
            Staging      = Join-Path $base 'staging'
            SeedOut      = Join-Path $base 'seed'
            OwuiDb       = $null
            ManifestPath = Join-Path $base 'secrets.json'
            RootsPath    = Join-Path $base 'roots.json'
            Content      = @{}
            Manifest     = $null
            Roots        = $null
        }
        $files = [Collections.Generic.List[object]]@(
            @{ Id = 'stack-env'; Path = 'pc/stack/.env' }
            @{ Id = 'ntfy-pc-token'; Path = 'pc/stack/secrets/ntfy-pc.token' }
            @{ Id = 'gcal-oauth-token'; Path = 'pc/stack/gcal/data/token.json' }
            @{ Id = 'ssh-key'; Path = 'pc/ssh/test-key' }
        )
        if ($WithVps) { $files.Add(@{ Id = 'vps-egress-env'; Path = 'vps/egress/.env' }) }
        foreach ($f in $files) {
            $p = Join-Path $base $f.Path
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            $c = 'fake-' + [guid]::NewGuid().ToString('n')
            Set-Content -LiteralPath $p -Value $c -NoNewline
            $setup.Content[$f.Id] = $c
        }
        $rows = [Collections.Generic.List[object]]@(
            [ordered]@{ id = 'stack-env'; folder = '01'; location = 'stack:.env'; kind = 'file'; required = $true; purpose = 'test' }
            [ordered]@{ id = 'ntfy-pc-token'; folder = '01'; location = 'stack:secrets/ntfy-pc.token'; kind = 'file'; required = $true; purpose = 'test' }
            [ordered]@{ id = 'gcal-oauth-token'; folder = '02'; location = 'stack:gcal/data/token.json'; kind = 'file'; required = $false; purpose = 'test' }
            [ordered]@{ id = 'ssh-key'; folder = '04'; location = 'ssh:test-key'; kind = 'file'; required = $true; purpose = 'test' }
        )
        $roots = [ordered]@{
            stack = [ordered]@{ kind = 'path'; host = 'pc'; path = (Join-Path $setup.Pc 'stack'); purpose = 'test' }
            ssh   = [ordered]@{ kind = 'path'; host = 'pc'; path = (Join-Path $setup.Pc 'ssh'); purpose = 'test' }
        }
        if ($WithVps) {
            # The plan never touches the VPS, so on Windows any Linux path will do.
            $vpsRoot = if ($IsWindows) { '/home/test/egress' } else { Join-Path $setup.Vps 'egress' }
            $rows.Add([ordered]@{ id = 'vps-egress-env'; folder = '05'; location = 'vps-egress:.env'; kind = 'file'; required = $true; mode = '0600'; owner = 'liam'; purpose = 'test' })
            $roots['vps-egress'] = [ordered]@{ kind = 'path'; host = 'vps'; path = $vpsRoot; purpose = 'test' }
        }
        if ($NtfyVolume) {
            $rows.Add([ordered]@{ id = 'ntfy-user-db'; folder = '07'; location = 'ntfy-data:user.db'; kind = 'sqlite'; required = $true; purpose = 'test' })
            $roots['ntfy-data'] = [ordered]@{ kind = 'volume'; host = 'pc'; volume = $NtfyVolume; purpose = 'test' }
        }
        if ($BoltVolume) {
            $rows.Add([ordered]@{ id = 'bolt-server-keys'; folder = '07'; location = 'bolt-data:server-keys.json'; kind = 'file'; required = $true; purpose = 'test' })
            $roots['bolt-data'] = [ordered]@{ kind = 'volume'; host = 'pc'; volume = $BoltVolume; purpose = 'test' }
        }
        if ($WithOwui) {
            $rows.Add([ordered]@{ id = 'owui-seed-secrets'; folder = '03'; location = 'owui-secrets:values.json'; kind = 'owui-seed'; required = $true; purpose = 'test' })
            $roots['owui-secrets'] = [ordered]@{ kind = 'consumed'; host = 'pc'; consumer = 'test'; purpose = 'test' }
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            $setup.OwuiDb = Join-Path $base 'webui.db'
            New-FakeOwuiDb $setup.OwuiDb
        }
        $setup.Manifest = [ordered]@{
            formatVersion = 1
            rows          = $rows
            audits        = @([ordered]@{ location = 'stack:secrets'; purpose = 'test' })
        }
        $setup.Roots = [ordered]@{ formatVersion = 1; roots = $roots }
        Save-TestSetup $setup
        return $setup
    }

    # A fake OWUI 0.11.4 database, built by the Python tests' own builder
    # (tests/python/test_export_owui_seed.py), with fake secrets made at run time.
    function Get-TestPython {
        @(if ($IsWindows) { 'python', 'python3' } else { 'python3', 'python' }) |
            ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } |
            Select-Object -First 1 -ExpandProperty Source
    }

    function New-FakeOwuiDb([string]$Path) {
        $code = 'import sys; sys.path.insert(0, sys.argv[1]); import test_export_owui_seed as t; t.build_db(t.Path(sys.argv[2]), t.load_schema())'
        & (Get-TestPython) -c $code (Join-Path $PSScriptRoot 'python') $Path
        if ($LASTEXITCODE -ne 0) { throw 'could not build the fake OWUI database' }
    }

    function Save-TestSetup($Setup) {
        $Setup.Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Setup.ManifestPath
        $Setup.Roots | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Setup.RootsPath
    }

    function Invoke-Collector {
        param($Setup, [switch]$Execute, [switch]$KeepOnFailure, [hashtable]$Extra = @{})
        $params = @{
            ManifestPath            = $Setup.ManifestPath
            RootsPath               = $Setup.RootsPath
            StagingRoot             = $Setup.Staging
            AllowUnencryptedStaging = $true
            PassThru                = $true
            Execute                 = $Execute
            KeepOnFailure           = $KeepOnFailure
            SshCommand              = (Join-Path $script:Fakes 'fake-ssh.ps1')
            ScpCommand              = (Join-Path $script:Fakes 'fake-scp.ps1')
            TailscaleCommand        = (Join-Path $script:Fakes 'fake-tailscale.ps1')
            SeedOut                 = $Setup.SeedOut
        }
        foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
        & $script:Tool @params
    }

    function New-TestLink {
        param([string]$LinkPath, [string]$Target)
        if ($IsWindows) { New-Item -ItemType Junction -Path $LinkPath -Target $Target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target | Out-Null }
    }

    # Runs the collector with the docker stand-in in the given mode.
    function Invoke-WithFakeDocker {
        param($Setup, [string]$Mode, [switch]$KeepOnFailure)
        $env:CRIA_FAKE_DOCKER = $Mode
        $env:CRIA_FAKE_STAGING = $Setup.Staging
        $env:CRIA_FAKE_OWUI_DB = $Setup.OwuiDb
        # The key the Python tests' builder encrypts Valves with (KEY there).
        $env:FAKE_OWUI_KEY = 'test-only-key-' + ('k' * 20)
        try { Invoke-Collector $Setup -Execute -KeepOnFailure:$KeepOnFailure -Extra @{ DockerCommand = (Join-Path $script:Fakes 'fake-docker.ps1') } }
        finally { Remove-Item Env:CRIA_FAKE_DOCKER, Env:CRIA_FAKE_STAGING, Env:CRIA_FAKE_OWUI_DB, Env:FAKE_OWUI_KEY -ErrorAction SilentlyContinue }
    }

    # Loads chosen functions from the collector without running it, so a
    # test can drive one step with an input a whole run cannot produce.
    function Import-CollectorFunction([string[]]$Name) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$null, [ref]$null)
        $found = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $Name -contains $n.Name }, $true)
        @($found | ForEach-Object { $_.Extent.Text }) -join "`n"
    }

    function Get-ZipEntryName([string]$ZipPath) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try { @($zip.Entries | ForEach-Object FullName) } finally { $zip.Dispose() }
    }
}

Describe 'Collect-StackSecrets' {

    Context 'the repo''s own manifests' {
        It 'secrets.json matches its schema' {
            Test-Json -Path (Join-Path $script:Manifests 'secrets.json') -SchemaFile (Join-Path $script:Manifests 'schemas/secrets.schema.json') |
                Should -BeTrue
        }

        It 'bundle-folders.json matches its schema' {
            Test-Json -Path (Join-Path $script:Manifests 'bundle-folders.json') -SchemaFile (Join-Path $script:Manifests 'schemas/bundle-folders.schema.json') |
                Should -BeTrue
        }

        It 'the real inventory breaks no manifest rule' {
            $r = & $script:Tool -PassThru -SshCommand $script:Missing -ScpCommand $script:Missing -DockerCommand $script:Missing
            $r.Mode | Should -Be 'Plan'
            $expected = @((Get-Content -LiteralPath (Join-Path $script:Manifests 'secrets.json') -Raw | ConvertFrom-Json).rows).Count
            $expected | Should -BeGreaterThan 0
            $r.Rows | Should -HaveCount $expected
            @($r.Problems | Where-Object { $_ -match '^(manifest|roots file|folders file|stopped)' }) | Should -BeNullOrEmpty
        }
    }

    Context 'plan (the default)' {
        It 'lists every row and never calls ssh, scp or docker' {
            $s = New-TestSetup -WithVps
            $r = Invoke-Collector $s -Extra @{ SshCommand = $script:Missing; ScpCommand = $script:Missing; DockerCommand = $script:Missing }
            $r.Problems | Should -BeNullOrEmpty
            $r.IsValid | Should -BeTrue
            $r.Mode | Should -Be 'Plan'
            ($r.Rows | Where-Object Id -EQ 'stack-env').Status | Should -Be 'present'
            ($r.Rows | Where-Object Id -EQ 'vps-egress-env').Status | Should -Be 'checked when collecting'
            Test-Path -LiteralPath $s.Staging | Should -BeFalse
        }

        It 'reports a missing required row as a problem and a missing optional row as a warning' {
            $s = New-TestSetup
            Remove-Item -LiteralPath (Join-Path $s.Pc 'stack/.env') -Force
            Remove-Item -LiteralPath (Join-Path $s.Pc 'stack/gcal/data/token.json')
            $r = Invoke-Collector $s
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain "row 'stack-env': stack:.env is missing (required)"
            # Windows adds a BitLocker warning, so look for this one among the rest.
            $r.Warnings | Where-Object { $_ -match "row 'gcal-oauth-token'.*optional" } | Should -HaveCount 1
        }

        It 'fails the audit when a Docker secret has no row' {
            $s = New-TestSetup
            Set-Content -LiteralPath (Join-Path $s.Pc 'stack/secrets/new-service.pw') -Value ('fake-' + [guid]::NewGuid())
            (Invoke-Collector $s).Problems | Should -Contain "audit 'stack:secrets': 'stack:secrets/new-service.pw' has no row in the manifest"
        }

        It 'audits a whole root, subfolders included, when nothing follows the colon' {
            $s = New-TestSetup
            $s.Manifest.audits += [ordered]@{ location = 'ssh:'; purpose = 'test' }
            $extra = Join-Path $s.Pc 'ssh/kit dir/extra.key'
            New-Item -ItemType Directory -Path (Split-Path $extra -Parent) | Out-Null
            Set-Content -LiteralPath $extra -Value ('fake-' + [guid]::NewGuid())
            Save-TestSetup $s
            $r = Invoke-Collector $s
            $r.Problems | Should -Be @("audit 'ssh:': 'ssh:kit dir/extra.key' has no row in the manifest")

            $s.Manifest.rows.Add([ordered]@{ id = 'ssh-extra'; folder = '04'; location = 'ssh:kit dir/extra.key'; kind = 'file'; required = $false; purpose = 'test' })
            Save-TestSetup $s
            $r = Invoke-Collector $s
            $r.Problems | Should -BeNullOrEmpty
            ($r.Rows | Where-Object Id -EQ 'ssh-extra').Status | Should -Be 'present'
        }

        It 'refuses a source that passes through a junction or link' {
            $s = New-TestSetup
            $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $outside | Out-Null
            Set-Content -LiteralPath (Join-Path $outside 'x.json') -Value 'fake'
            New-TestLink -LinkPath (Join-Path $s.Pc 'stack/linked') -Target $outside
            $s.Manifest.rows.Add([ordered]@{ id = 'linked'; folder = '01'; location = 'stack:linked/x.json'; kind = 'file'; required = $true; purpose = 'test' })
            Save-TestSetup $s
            ($r = Invoke-Collector $s).IsValid | Should -BeFalse
            ($r.Rows | Where-Object Id -EQ 'linked').Status | Should -Be 'refused (a junction or symbolic link on the way)'
        }
    }

    Context 'manifest rules' {
        BeforeEach { $script:S = New-TestSetup -WithVps }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'an unknown root'; Add = @{ id = 'x1'; folder = '01'; location = 'nowhere:.env'; kind = 'file' }; Expect = "unknown root 'nowhere'" }
            @{ Why = 'a location used twice, ignoring case'; Add = @{ id = 'x1'; folder = '01'; location = 'stack:.ENV'; kind = 'file' }; Expect = "location already used by row 'stack-env'" }
            @{ Why = 'an id used twice'; Add = @{ id = 'stack-env'; folder = '01'; location = 'stack:other'; kind = 'file' }; Expect = 'id already used' }
            @{ Why = 'a folder sent to the wrong kind of root'; Add = @{ id = 'x1'; folder = '05'; location = 'stack:other'; kind = 'file' }; Expect = "folder 05 must come from a vps 'path' root" }
            @{ Why = 'sqlite outside a Docker volume'; Add = @{ id = 'x1'; folder = '01'; location = 'stack:other.db'; kind = 'sqlite' }; Expect = "kind 'sqlite' is only for Docker volume roots" }
            @{ Why = 'mode and owner on a PC row'; Add = @{ id = 'x1'; folder = '01'; location = 'stack:other'; kind = 'file'; mode = '0600' }; Expect = 'mode and owner are only for VPS rows' }
            @{ Why = 'a VPS location with a space'; Add = @{ id = 'x1'; folder = '05'; location = 'vps-egress:my file'; kind = 'file' }; Expect = 'may only use letters, digits' }
            @{ Why = 'a location that climbs out of its root'; Add = @{ id = 'x1'; folder = '01'; location = 'stack:../x'; kind = 'file' }; Expect = "location refused \('\.\.' segment\)" }
        ) {
            $newRow = [ordered]@{ required = $true; purpose = 'test' }
            foreach ($k in $Add.Keys) { $newRow[$k] = $Add[$k] }
            $script:S.Manifest.rows.Add($newRow)
            Save-TestSetup $script:S
            $r = Invoke-Collector $script:S
            $r.IsValid | Should -BeFalse
            ($r.Problems -join "`n") | Should -Match $Expect
            $r.Rows | Should -BeNullOrEmpty
        }

        It 'refuses <Why>, since only the seed export fills the OWUI secrets root' -ForEach @(
            @{ Why = 'a file row for the OWUI secrets root'; Rows = @(@{ id = 'owui-key'; folder = '03'; location = 'owui-secrets:openai'; kind = 'file' }); Expect = "its row must have kind 'owui-seed'" }
            @{ Why = 'a seed row on another root'; Rows = @(@{ id = 'owui-x'; folder = '01'; location = 'stack:seed.json'; kind = 'owui-seed' }); Expect = "kind 'owui-seed' is only for a 'consumed' root" }
            @{ Why = 'two seed rows'; Rows = @(@{ id = 'owui-a'; folder = '03'; location = 'owui-secrets:a.json'; kind = 'owui-seed' }, @{ id = 'owui-b'; folder = '03'; location = 'owui-secrets:b.json'; kind = 'owui-seed' }); Expect = "only one row may have kind 'owui-seed'" }
        ) {
            $script:S.Roots.roots['owui-secrets'] = [ordered]@{ kind = 'consumed'; host = 'pc'; consumer = 'tools/Import-OwuiSeed.py'; purpose = 'test' }
            foreach ($row in $Rows) {
                $newRow = [ordered]@{ required = $true; purpose = 'test' }
                foreach ($k in $row.Keys) { $newRow[$k] = $row[$k] }
                $script:S.Manifest.rows.Add($newRow)
            }
            Save-TestSetup $script:S
            $r = Invoke-Collector $script:S
            $r.IsValid | Should -BeFalse
            ($r.Problems -join "`n") | Should -Match ([regex]::Escape($Expect))
        }

        It 'refuses an unknown field (no free text that could carry a secret)' {
            $script:S.Manifest.rows[0].value = 'anything'
            Save-TestSetup $script:S
            $r = Invoke-Collector $script:S
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Match '^manifest:'
        }
    }

    Context 'collecting from the PC' {
        It 'builds a bundle whose map passes the restore check, and a ZIP beside it' {
            $s = New-TestSetup
            $r = Invoke-Collector $s -Execute
            $r.Problems | Should -BeNullOrEmpty
            $r.IsValid | Should -BeTrue
            @($r.Rows | Where-Object Status -EQ 'collected') | Should -HaveCount 4

            $bundle = Join-Path $r.RunFolder 'bundle'
            $check = & $script:MapTool -MapPath (Join-Path $bundle '00-RESTORE-MAP.json') -RootsPath $s.RootsPath -InventoryPath $s.ManifestPath -BundleRoot $bundle
            $check.Problems | Should -BeNullOrEmpty
            $map = Get-Content -LiteralPath (Join-Path $bundle '00-RESTORE-MAP.json') -Raw | ConvertFrom-Json
            $map.inventory.sha256 | Should -Be (Get-FileHash -LiteralPath $s.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $map.inventory.required | Sort-Object | Should -Be @('ntfy-pc-token', 'ssh-key', 'stack-env')
            Get-Content -LiteralPath (Join-Path $bundle '01/stack/.env') -Raw | Should -BeExactly $s.Content['stack-env']

            (Split-Path $r.ZipPath -Parent) | Should -Be $r.RunFolder
            (Get-FileHash -LiteralPath $r.ZipPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $r.ZipSha256
            $expected = @(
                '00-RESTORE-MAP.json'
                '01/stack/.env'
                '01/stack/secrets/ntfy-pc.token'
                '02/stack/gcal/data/token.json'
                '04/ssh/test-key'
            )
            Get-ZipEntryName $r.ZipPath | Sort-Object | Should -Be ($expected | Sort-Object)
        }

        It 'protects the run folder and everything in it' {
            $s = New-TestSetup
            $r = Invoke-Collector $s -Execute
            $r.IsValid | Should -BeTrue
            if ($IsWindows) {
                $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
                $acl = Get-Acl -LiteralPath $r.RunFolder
                $acl.AreAccessRulesProtected | Should -BeTrue
                foreach ($item in @(Get-Item -LiteralPath $r.RunFolder) + @(Get-ChildItem -LiteralPath $r.RunFolder -Recurse -Force)) {
                    $rules = (Get-Acl -LiteralPath $item.FullName).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
                    @($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference -ne $sid }) | Should -BeNullOrEmpty
                }
            }
            else {
                (Get-Item -LiteralPath $r.RunFolder).UnixFileMode | Should -Be ([IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
                foreach ($item in Get-ChildItem -LiteralPath $r.RunFolder -Recurse -Force) {
                    ($item.UnixFileMode -band [IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute') |
                        Should -Be ([IO.UnixFileMode]::None)
                }
            }
        }

        It 'leaves out a missing optional row and still completes' {
            $s = New-TestSetup
            Remove-Item -LiteralPath (Join-Path $s.Pc 'stack/gcal/data/token.json')
            $r = Invoke-Collector $s -Execute
            $r.IsValid | Should -BeTrue
            $map = Get-Content -LiteralPath (Join-Path $r.RunFolder 'bundle/00-RESTORE-MAP.json') -Raw | ConvertFrom-Json
            $map.entries.id | Should -Not -Contain 'gcal-oauth-token'
            $map.entries.id | Should -HaveCount 3
        }

        It 'stops on a missing required row before it creates anything' {
            $s = New-TestSetup
            Remove-Item -LiteralPath (Join-Path $s.Pc 'ssh/test-key')
            $r = Invoke-Collector $s -Execute
            $r.IsValid | Should -BeFalse
            $r.RunFolder | Should -BeNullOrEmpty
            Test-Path -LiteralPath $s.Staging | Should -BeFalse
        }

        It 'deletes the run folder it created when a later step fails' {
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $r = Invoke-WithFakeDocker $s 'run-fails'
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain "row 'bolt-server-keys': failed (helper exit 1)"
            $r.RunFolder | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $s.Staging -Force) | Should -BeNullOrEmpty
        }

        It 'keeps the failed run folder with -KeepOnFailure' {
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $r = Invoke-WithFakeDocker $s 'run-fails' -KeepOnFailure
            $r.IsValid | Should -BeFalse
            Test-Path -LiteralPath $r.RunFolder -PathType Container | Should -BeTrue
        }

        It 'reports a run folder it could not fully delete, and names it' -Skip:($IsWindows -or [Environment]::UserName -eq 'root') {
            # M2-05: a failed delete is reported, not thrown past the summary.
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $r = Invoke-WithFakeDocker $s 'lock'
            try {
                $r.IsValid | Should -BeFalse
                $r.Problems | Should -Contain 'cleanup: the run folder could not be fully removed and may hold plaintext secrets; delete it by hand'
                $r.RunFolder | Should -Not -BeNullOrEmpty
                Test-Path -LiteralPath $r.RunFolder | Should -BeTrue
            }
            finally {
                Get-ChildItem -LiteralPath $s.Staging -Directory | ForEach-Object { & chmod -R u+rwx $_.FullName }
            }
        }

        It 'refuses a staging root that is a junction or link' {
            $s = New-TestSetup
            $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $elsewhere | Out-Null
            New-TestLink -LinkPath $s.Staging -Target $elsewhere
            $r = Invoke-Collector $s -Execute
            $r.Problems | Should -Contain 'staging: -StagingRoot refused (the root is a junction or symbolic link)'
            @(Get-ChildItem -LiteralPath $elsewhere -Force) | Should -BeNullOrEmpty
        }

        It 'refuses a staging root reached through a linked folder' {
            # M2-03: the staging root is ordinary, but a folder above it is a link.
            $s = New-TestSetup
            $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path (Join-Path $elsewhere 'stage') -Force | Out-Null
            $link = Join-Path $TestDrive ('link-' + [guid]::NewGuid().ToString('n'))
            New-TestLink -LinkPath $link -Target $elsewhere
            $r = Invoke-Collector $s -Execute -Extra @{ StagingRoot = (Join-Path $link 'stage') }
            $r.Problems | Should -Contain 'staging: -StagingRoot refused (a folder above the root is a junction or symbolic link)'
            @(Get-ChildItem -LiteralPath (Join-Path $elsewhere 'stage') -Force) | Should -BeNullOrEmpty
        }

        It 'refuses an existing staging root that another account can change' {
            $s = New-TestSetup
            New-Item -ItemType Directory -Path $s.Staging | Out-Null
            if ($IsWindows) {
                $acl = Get-Acl -LiteralPath $s.Staging
                $users = [Security.Principal.SecurityIdentifier]'S-1-5-32-545'
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'Modify, DeleteSubdirectoriesAndFiles', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
                Set-Acl -LiteralPath $s.Staging -AclObject $acl
            }
            else {
                [IO.File]::SetUnixFileMode($s.Staging, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, OtherRead, OtherWrite, OtherExecute')
            }
            $r = Invoke-Collector $s -Execute
            $r.IsValid | Should -BeFalse
            @($r.Problems | Where-Object { $_ -like 'staging: -StagingRoot can be changed by *' }) | Should -HaveCount 1
            @(Get-ChildItem -LiteralPath $s.Staging -Force) | Should -BeNullOrEmpty
        }

        It 'refuses a staging root below a folder another account can change' -Skip:$IsWindows {
            # R2-02: a writable parent without the sticky bit lets others rename the stage.
            $s = New-TestSetup
            $open = Join-Path $TestDrive ('open-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $open | Out-Null
            [IO.File]::SetUnixFileMode($open, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, OtherRead, OtherWrite, OtherExecute')
            $r = Invoke-Collector $s -Execute -Extra @{ StagingRoot = (Join-Path $open 'stage') }
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain "staging: '$open' can be changed by everyone (other write), who could move or replace the staging folder; use a -StagingRoot whose parent folders only your account and administrators can change"
            Test-Path -LiteralPath (Join-Path $open 'stage') | Should -BeFalse
        }

        It 'refuses a protected staging root whose parent grants another account <Right>' -Skip:(-not $IsWindows) -ForEach @(
            @{ Right = 'DeleteSubdirectoriesAndFiles' }
            @{ Right = 'Delete' }
            @{ Right = 'ChangePermissions' }
            @{ Right = 'TakeOwnership' }
        ) {
            # R2-02: the stage itself is owner-only; the risk is one level up.
            $s = New-TestSetup
            $parent = Join-Path $TestDrive ('parent-' + [guid]::NewGuid().ToString('n'))
            $stage = Join-Path $parent 'stage'
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            $acl = Get-Acl -LiteralPath $parent
            $everyone = [Security.Principal.SecurityIdentifier]'S-1-1-0'
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, $Right, 'None', 'None', 'Allow'))
            Set-Acl -LiteralPath $parent -AclObject $acl
            $r = Invoke-Collector $s -Execute -Extra @{ StagingRoot = $stage }
            $r.IsValid | Should -BeFalse
            @($r.Problems | Where-Object { $_ -like "staging: '$parent' can be changed by *, who could move or replace the staging folder*" }) | Should -HaveCount 1
            @(Get-ChildItem -LiteralPath $stage -Force) | Should -BeNullOrEmpty
        }

        It 'refuses an existing staging root that grants another account the mapped Write right' -Skip:(-not $IsWindows) {
            # R2-02: 'Write' is 0x116 once mapped, with no generic bit left to see.
            $s = New-TestSetup
            New-Item -ItemType Directory -Path $s.Staging | Out-Null
            $acl = Get-Acl -LiteralPath $s.Staging
            $everyone = [Security.Principal.SecurityIdentifier]'S-1-1-0'
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Write', 'None', 'None', 'Allow'))
            Set-Acl -LiteralPath $s.Staging -AclObject $acl
            $r = Invoke-Collector $s -Execute
            $r.IsValid | Should -BeFalse
            @($r.Problems | Where-Object { $_ -like 'staging: -StagingRoot can be changed by *' }) | Should -HaveCount 1
        }

        It 'counts each right where it matters: drive root, folder above, staging root' -Skip:(-not $IsWindows) {
            # R2-02: creating folders on a drive root is normal; DELETE there means nothing.
            . ([scriptblock]::Create((Import-CollectorFunction 'Get-ChangeableBy', 'Get-CurrentUserSid')))
            $onWindows = $true
            $everyone = [Security.Principal.SecurityIdentifier]'S-1-1-0'
            $folder = Join-Path $TestDrive ('rights-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $folder | Out-Null
            $acl = Get-Acl -LiteralPath $folder
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, 'CreateDirectories, Delete', 'None', 'None', 'Allow'))
            Set-Acl -LiteralPath $folder -AclObject $acl
            @(Get-ChangeableBy $folder -IsDriveRoot) | Should -BeNullOrEmpty
            @(Get-ChangeableBy $folder) | Should -HaveCount 1
            $acl = Get-Acl -LiteralPath $folder
            $acl.RemoveAccessRuleAll([Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Delete', 'None', 'None', 'Allow'))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, 'CreateDirectories', 'None', 'None', 'Allow'))
            Set-Acl -LiteralPath $folder -AclObject $acl
            @(Get-ChangeableBy $folder) | Should -BeNullOrEmpty
            @(Get-ChangeableBy $folder -IsStagingRoot) | Should -HaveCount 1
        }

        It 'refuses a staging root that appears after it was checked' {
            # R2-02: absent at the check, there before the run folder: never adopted.
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $r = Invoke-WithFakeDocker $s 'appear'
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain 'staging: -StagingRoot appeared after it was checked; find out what made it, then run again'
            $r.RunFolder | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $s.Staging -Force) | Should -BeNullOrEmpty
        }

        It 'refuses a staging root it created that does not come out protected' {
            # R2-02: if another account wins the race to create it, the create is a no-op.
            . ([scriptblock]::Create((Import-CollectorFunction 'Initialize-RunFolder', 'Get-ProtectionProblem', 'Get-CurrentUserSid')))
            function Initialize-ProtectedFolder([string]$Path) {
                New-Item -ItemType Directory -Path $Path | Out-Null
                if (-not $IsWindows) { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, OtherRead, OtherWrite, OtherExecute') }
            }
            function Test-StagingRoot { throw 'not reached' }
            $onWindows = $IsWindows
            $problems = [Collections.Generic.List[string]]::new()
            $root = Join-Path $TestDrive ('raced-' + [guid]::NewGuid().ToString('n'))
            Initialize-RunFolder $root $false | Should -BeNullOrEmpty
            @($problems | Where-Object { $_ -like 'staging: the new -StagingRoot is not protected (*)' }) | Should -HaveCount 1
            @(Get-ChildItem -LiteralPath $root -Force) | Should -BeNullOrEmpty
        }

        It 'checks the staging root again after creating it' {
            . ([scriptblock]::Create((Import-CollectorFunction 'Initialize-RunFolder', 'Initialize-ProtectedFolder', 'Get-ProtectionProblem', 'Get-CurrentUserSid')))
            function Test-StagingRoot { $problems.Add('staging: re-checked'); return $null }
            $onWindows = $IsWindows
            $problems = [Collections.Generic.List[string]]::new()
            $root = Join-Path $TestDrive ('recheck-' + [guid]::NewGuid().ToString('n'))
            Initialize-RunFolder $root $false | Should -BeNullOrEmpty
            $problems | Should -Be @('staging: re-checked')
            @(Get-ChildItem -LiteralPath $root -Force) | Should -BeNullOrEmpty
        }

        It 'refuses a relative staging root' {
            $s = New-TestSetup
            $r = Invoke-Collector $s -Execute -Extra @{ StagingRoot = 'relative/staging' }
            $r.Problems | Should -Contain 'staging: -StagingRoot must be an absolute local path'
        }

        It 'never prints a secret value' {
            $s = New-TestSetup
            $params = @{
                ManifestPath = $s.ManifestPath; RootsPath = $s.RootsPath; StagingRoot = $s.Staging
                AllowUnencryptedStaging = $true; Execute = $true
            }
            $out = (& $script:Tool @params *>&1 | Out-String)
            $out | Should -Match 'Result: complete'
            foreach ($c in $s.Content.Values) { $out | Should -Not -Match ([regex]::Escape($c)) }
        }
    }

    Context 'where the helper''s memory can be paged' {
        BeforeAll {
            $script:PagingFunctions = Import-CollectorFunction 'Test-PagingBoundary', 'Get-PagingLocation'
        }

        It 'refuses a paging drive without BitLocker, and names it' -Skip:(-not $IsWindows) {
            # R2-04: a tmpfs is memory, and the Docker VM's memory can reach these drives.
            . ([scriptblock]::Create($script:PagingFunctions))
            function Get-PagingLocation { 'C:\pagefile.sys'; 'D:\vm\swap.vhdx' }
            function Get-BitLockerState([string]$Path) { if ($Path -eq 'D:\') { 'Off' } else { 'On' } }
            $onWindows = $true
            $AllowUnencryptedStaging = $false
            $problems = [Collections.Generic.List[string]]::new()
            $warnings = [Collections.Generic.List[string]]::new()
            Test-PagingBoundary
            $problems | Should -Be @("docker: memory can be paged to drive 'D:\', where BitLocker is 'Off'")
            $warnings | Should -BeNullOrEmpty
        }

        It 'reads the WSL swap file from .wslconfig, and leaves it out when swap is 0' {
            . ([scriptblock]::Create($script:PagingFunctions))
            $saved = $env:USERPROFILE
            $env:USERPROFILE = Join-Path $TestDrive ('profile-' + [guid]::NewGuid().ToString('n'))
            try {
                New-Item -ItemType Directory -Path $env:USERPROFILE | Out-Null
                $config = Join-Path $env:USERPROFILE '.wslconfig'
                Set-Content -LiteralPath $config -Value "[wsl2]`nmemory=8GB`nswapfile=D:\\vm\\swap.vhdx # moved`n[experimental]`nswap=0"
                @(Get-PagingLocation) | Should -Contain 'D:\vm\swap.vhdx'
                Set-Content -LiteralPath $config -Value "[wsl2]`nswap=0"
                @(Get-PagingLocation | Where-Object { $_ -like '*swap.vhdx' }) | Should -BeNullOrEmpty
                Remove-Item -LiteralPath $config -Force
                @(Get-PagingLocation) | Should -Contain (Join-Path $env:USERPROFILE 'AppData\Local\Temp\swap.vhdx')
            }
            finally { $env:USERPROFILE = $saved }
        }
    }

    Context 'the volume helper, with a stand-in for docker' {
        It 'fails the row and deletes the run folder when the helper cannot be removed' {
            # M2-01: a helper left behind is never reported as collected.
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $r = Invoke-WithFakeDocker $s 'stuck'
            $r.IsValid | Should -BeFalse
            @($r.Problems | Where-Object { $_ -match "^row 'bolt-server-keys': failed \(the helper container cria-collect-[0-9a-f]{12} could not be removed; remove it with: docker rm -f cria-collect-[0-9a-f]{12}\)$" }) | Should -HaveCount 1
            $r.RunFolder | Should -BeNullOrEmpty
        }

        It 'fails the row when the helper exits with an error after a good-looking answer' {
            # M2-04: the exit code counts, not just the output.
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $r = Invoke-WithFakeDocker $s 'bad-exit'
            $r.Problems | Should -Contain "row 'bolt-server-keys': failed (helper exit 1)"
        }

        It 'fails the row when the data does not match the hash the helper reports' {
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $r = Invoke-WithFakeDocker $s 'mismatch'
            $r.Problems | Should -Contain "row 'bolt-server-keys': failed (the copy does not match the volume file)"
        }

        It 'records the volume file''s mode, owner and group in the map' {
            $s = New-TestSetup -BoltVolume 'cria-test-not-used'
            $env:CRIA_FAKE_DOCKER = 'good'
            try { $r = Invoke-Collector $s -Execute -Extra @{ DockerCommand = (Join-Path $script:Fakes 'fake-docker.ps1') } }
            finally { Remove-Item Env:CRIA_FAKE_DOCKER -ErrorAction SilentlyContinue }
            $r.Problems | Should -BeNullOrEmpty
            $map = Get-Content -LiteralPath (Join-Path $r.RunFolder 'bundle/00-RESTORE-MAP.json') -Raw | ConvertFrom-Json
            $row = $map.entries | Where-Object id -EQ 'bolt-server-keys'
            $row.mode | Should -Be '0640'
            $row.owner | Should -Be '1000'
            $row.group | Should -Be '1000'
        }
    }

    Context 'capturing the OWUI seed, with stand-ins for docker and tailscale' -Skip:(-not $PythonReady) {
        BeforeAll {
            # Built at run time, as in the Python tests, so no literal lands in a file.
            $script:OpenAi = 'sk-' + ('A' * 40)
            $script:PcIp = @('100', '64', '0', '7') -join '.'
            $script:NoTools = @{ DockerCommand = $script:Missing; TailscaleCommand = $script:Missing; SshCommand = $script:Missing; ScpCommand = $script:Missing }
        }
        BeforeEach { $script:S = New-TestSetup -WithOwui }

        It 'puts the seed secrets in folder 03 and writes a seed that holds none of them' {
            $r = Invoke-WithFakeDocker $script:S 'good'
            $r.Problems | Should -BeNullOrEmpty
            ($r.Rows | Where-Object Id -EQ 'owui-seed-secrets').Status | Should -Be 'collected'
            Get-ZipEntryName $r.ZipPath | Should -Contain '03/owui-secrets/values.json'
            $secrets = Get-Content -LiteralPath (Join-Path $r.RunFolder 'bundle/03/owui-secrets/values.json') -Raw | ConvertFrom-Json -AsHashtable
            $secrets.owui_seed_secrets | Should -Be 1
            $secrets.refs['config/openai.api_keys'][0] | Should -BeExactly $script:OpenAi
            $r.SeedOut | Should -Be $script:S.SeedOut
            $r.SeedFiles | Should -Be 12
            $r.SeedSummary | Should -Match '^seed exported: config [0-9]+'
            $files = @(Get-ChildItem -LiteralPath $script:S.SeedOut -File)
            $files | Should -HaveCount 12
            $text = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
            $text | Should -Not -Match ([regex]::Escape($script:OpenAi))
            $text | Should -Not -Match ([regex]::Escape($script:PcIp))
            $text | Should -Match '\{\{PC_TS_IP\}\}'
            $provenance = Get-Content -LiteralPath (Join-Path $script:S.SeedOut 'provenance.json') -Raw | ConvertFrom-Json
            $provenance.image_digest | Should -Match '^ghcr\.io/open-webui/open-webui@sha256:f{64}$'
            foreach ($name in 'PC_TS_IP', 'PC_TS_IP6', 'PC_TS_NAME', 'VPS_TS_IP', 'FOLD_TS_NAME', 'TS_DOMAIN') { $provenance.endpoints | Should -Contain $name }
            # A node from another domain (an exit node here) gets its own placeholders.
            foreach ($name in 'EXT_GB_LON_WG_001_TS_IP', 'EXT_GB_LON_WG_001_TS_NAME') { $provenance.endpoints | Should -Contain $name }
            @($provenance.endpoints | Where-Object { $_ -like 'GB_*' -or $_ -like 'EXIT*' }) | Should -BeNullOrEmpty
            # The same check a restore runs, over the bundle as written.
            $check = & $script:MapTool -MapPath (Join-Path $r.RunFolder 'bundle/00-RESTORE-MAP.json') -RootsPath $script:S.RootsPath `
                -FoldersPath (Join-Path $script:Manifests 'bundle-folders.json') -InventoryPath $script:S.ManifestPath -BundleRoot (Join-Path $r.RunFolder 'bundle')
            $check.Problems | Should -BeNullOrEmpty
        }

        It 'replaces an earlier seed and leaves none of its files behind' {
            New-Item -ItemType Directory -Path $script:S.SeedOut | Out-Null
            Set-Content -LiteralPath (Join-Path $script:S.SeedOut 'old_table.json') -Value '[]'
            Set-Content -LiteralPath (Join-Path $script:S.SeedOut 'tool.json') -Value 'old'
            $r = Invoke-WithFakeDocker $script:S 'good'
            $r.Problems | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $script:S.SeedOut 'old_table.json') | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $script:S.SeedOut 'tool.json') -Raw | Should -Match 'brave_search'
            @(Get-ChildItem -LiteralPath $script:S.SeedOut) | Should -HaveCount 12
        }

        It 'plans without docker or tailscale, and refuses a -SeedOut that holds anything else' {
            $r = Invoke-Collector $script:S -Extra $script:NoTools
            $r.Problems | Should -BeNullOrEmpty
            ($r.Rows | Where-Object Id -EQ 'owui-seed-secrets').Status | Should -Be 'checked when collecting'
            New-Item -ItemType Directory -Path $script:S.SeedOut | Out-Null
            Set-Content -LiteralPath (Join-Path $script:S.SeedOut 'notes.txt') -Value 'mine'
            $r = Invoke-Collector $script:S -Extra $script:NoTools
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain "seed: -SeedOut holds 'notes.txt', which is not part of a seed; move it, or choose another -SeedOut"
        }

        It 'stops when the export stops, passes its problems on, and writes nothing' {
            $r = Invoke-WithFakeDocker $script:S 'seed-stop'
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain 'seed: OWUI version is 0.0.1, schema.json is for 0.11.4 (C-40)'
            $r.Problems | Should -Contain "row 'owui-seed-secrets': failed (the seed export stopped; see its problems)"
            Test-Path -LiteralPath $script:S.SeedOut | Should -BeFalse
            $r.RunFolder | Should -BeNullOrEmpty
        }

        It 'counts any other error output from the export and never shows it' {
            $r = Invoke-WithFakeDocker $script:S 'seed-noise'
            $r.Problems | Should -BeNullOrEmpty
            $r.Warnings | Should -Contain 'seed: 1 other line(s) of error output from the export were not shown, because they could hold a value'
            ($r | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape('sk-' + ('N' * 40)))
        }

        It 'refuses a seed that holds a value from the secrets file' {
            $r = Invoke-WithFakeDocker $script:S 'seed-leak'
            $r.Problems | Should -Contain "row 'owui-seed-secrets': failed (seed file prompt.json holds the value of a secret reference)"
            Test-Path -LiteralPath $script:S.SeedOut | Should -BeFalse
            $r.RunFolder | Should -BeNullOrEmpty
        }

        It 'writes no seed, and keeps no bundle, when the repo secret scan finds something in it' {
            $r = Invoke-WithFakeDocker $script:S 'seed-scan'
            ($r.Problems -join "`n") | Should -Match "seed: the secret scan found 'GitHub token' in prompt\.json line [0-9]+; the seed was not written to -SeedOut"
            Test-Path -LiteralPath $script:S.SeedOut | Should -BeFalse
            $r.RunFolder | Should -BeNullOrEmpty
        }

        It 'does not start when OWUI is not running' {
            $r = Invoke-WithFakeDocker $script:S 'owui-stopped'
            $r.Problems | Should -Contain "seed: container 'open-webui' is not running; the seed is read from the running OWUI"
            Test-Path -LiteralPath $script:S.Staging | Should -BeFalse
        }

        It 'does not start when <Why>' -ForEach @(
            @{ Why = 'Tailscale is not running'; Mode = 'down'; Expect = "seed: 'tailscale status --json' failed; is Tailscale running and signed in?" }
            @{ Why = 'the VPS is not in the tailnet'; Mode = 'no-vps'; Expect = "seed: expected one node named 'vps' in the tailnet, found 0" }
        ) {
            $env:CRIA_FAKE_TAILSCALE = $Mode
            try { $r = Invoke-WithFakeDocker $script:S 'good' } finally { Remove-Item Env:CRIA_FAKE_TAILSCALE }
            $r.Problems | Should -Contain $Expect
            Test-Path -LiteralPath $script:S.Staging | Should -BeFalse
        }
    }

    Context 'the ZIP check' {
        BeforeAll {
            $script:ZipFunctions = Import-CollectorFunction 'Get-StreamDigest', 'Write-BundleZip', 'Get-Sha256', 'Protect-BundleFile'
        }

        It 'refuses a ZIP whose member changed after the map was checked' {
            # M2-02: same length, different bytes, so only reading the member back catches it.
            . ([scriptblock]::Create($script:ZipFunctions))
            $problems = [Collections.Generic.List[string]]::new()
            $run = [pscustomobject]@{ ZipPath = $null; ZipSha256 = $null }
            $onWindows = $IsWindows
            $runFolder = Join-Path $TestDrive ('zip-' + [guid]::NewGuid().ToString('n'))
            $bundle = Join-Path $runFolder 'bundle'
            New-Item -ItemType Directory -Path (Join-Path $bundle '01') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bundle '01/payload.txt') -Value 'AAAA' -NoNewline
            $checked = (Get-FileHash -LiteralPath (Join-Path $bundle '01/payload.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
            Set-Content -LiteralPath (Join-Path $bundle '01/payload.txt') -Value 'BBBB' -NoNewline
            Write-BundleZip $runFolder $bundle @('01/payload.txt') @{ '01/payload.txt' = [pscustomobject]@{ Sha256 = $checked; Bytes = 4 } }
            $problems | Should -Contain "zip: '01/payload.txt' does not match the map"
            $run.ZipPath | Should -BeNullOrEmpty
        }

        It 'refuses a ZIP member the map does not promise' {
            . ([scriptblock]::Create($script:ZipFunctions))
            $problems = [Collections.Generic.List[string]]::new()
            $run = [pscustomobject]@{ ZipPath = $null; ZipSha256 = $null }
            $onWindows = $IsWindows
            $runFolder = Join-Path $TestDrive ('zip-' + [guid]::NewGuid().ToString('n'))
            $bundle = Join-Path $runFolder 'bundle'
            New-Item -ItemType Directory -Path (Join-Path $bundle '01') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bundle '01/extra.txt') -Value 'fake' -NoNewline
            Write-BundleZip $runFolder $bundle @('01/extra.txt') @{}
            $problems | Should -Contain "zip: unexpected entry '01/extra.txt'"
        }
    }

    Context 'collecting from the VPS' -Skip:$IsWindows {
        It 'copies the file over ssh and scp and checks its hash' {
            $s = New-TestSetup -WithVps
            $r = Invoke-Collector $s -Execute
            $r.Problems | Should -BeNullOrEmpty
            Get-Content -LiteralPath (Join-Path $r.RunFolder 'bundle/05/vps-egress/.env') -Raw | Should -BeExactly $s.Content['vps-egress-env']
            $map = Get-Content -LiteralPath (Join-Path $r.RunFolder 'bundle/00-RESTORE-MAP.json') -Raw | ConvertFrom-Json
            $row = $map.entries | Where-Object id -EQ 'vps-egress-env'
            $row.mode | Should -Be '0600'
            $row.owner | Should -Be 'liam'
        }

        It 'refuses a VPS file that is a symbolic link' {
            $s = New-TestSetup -WithVps
            $envFile = Join-Path $s.Vps 'egress/.env'
            Move-Item -LiteralPath $envFile -Force -Destination (Join-Path $s.Vps 'real.env')
            New-Item -ItemType SymbolicLink -Path $envFile -Target (Join-Path $s.Vps 'real.env') | Out-Null
            $r = Invoke-Collector $s -Execute
            $r.IsValid | Should -BeFalse
            ($r.Rows | Where-Object Id -EQ 'vps-egress-env').Status | Should -Be 'refused (a symbolic link on the way)'
            $r.RunFolder | Should -BeNullOrEmpty
        }

        It 'refuses a VPS file reached through a linked folder' {
            $s = New-TestSetup -WithVps
            $real = Join-Path $s.Vps 'real-egress'
            Move-Item -LiteralPath (Join-Path $s.Vps 'egress') -Destination $real
            New-Item -ItemType SymbolicLink -Path (Join-Path $s.Vps 'egress') -Target $real | Out-Null
            ($r = Invoke-Collector $s -Execute).IsValid | Should -BeFalse
            ($r.Rows | Where-Object Id -EQ 'vps-egress-env').Status | Should -Be 'refused (a symbolic link on the way)'
        }

        It 'reports a missing required VPS file' {
            $s = New-TestSetup -WithVps
            Remove-Item -LiteralPath (Join-Path $s.Vps 'egress/.env') -Force
            $r = Invoke-Collector $s -Execute
            $r.Problems | Should -Contain "row 'vps-egress-env': vps-egress:.env is missing (required)"
        }

        It 'refuses a VPS file that changes between the check and the copy' {
            $s = New-TestSetup -WithVps
            $env:CRIA_FAKE_SCP = 'mutate'
            try { $r = Invoke-Collector $s -Execute }
            finally { Remove-Item Env:CRIA_FAKE_SCP -ErrorAction SilentlyContinue }
            $r.Problems | Should -Contain "row 'vps-egress-env': failed (the copy does not match the VPS file)"
            $r.RunFolder | Should -BeNullOrEmpty
        }

        It 'fails cleanly when ssh cannot connect' {
            $s = New-TestSetup -WithVps
            $r = Invoke-Collector $s -Execute -Extra @{ SshCommand = (Join-Path $script:Fakes 'fake-ssh-fails.ps1') }
            $r.Problems | Should -Contain "row 'vps-egress-env': failed (VPS check: ssh exit 255)"
            $r.RunFolder | Should -BeNullOrEmpty
        }
    }

    Context 'collecting from Docker volumes' -Skip:(-not $DockerReady) {
        BeforeAll {
            $script:Image = 'python:3.12-slim'
            docker image inspect $script:Image *> $null
            if ($LASTEXITCODE -ne 0) { docker pull -q $script:Image | Out-Null }
            $tag = [guid]::NewGuid().ToString('n').Substring(0, 8)
            $script:NtfyVolume = "cria-test-ntfy-$tag"
            $script:BoltVolume = "cria-test-bolt-$tag"
            $script:BoltContent = 'fake-' + [guid]::NewGuid().ToString('n')
            docker volume create $script:NtfyVolume | Out-Null
            docker volume create $script:BoltVolume | Out-Null
            docker run --rm -v "$($script:NtfyVolume):/v" $script:Image python3 -c 'import sqlite3; c = sqlite3.connect("/v/user.db"); c.execute("pragma journal_mode=wal"); c.execute("create table user (name text)"); c.execute("insert into user values (''fake'')"); c.commit(); c.close()' | Out-Null
            docker run --rm -v "$($script:BoltVolume):/v" $script:Image python3 -c "import os; open('/v/server-keys.json', 'w').write('$($script:BoltContent)'); os.symlink('/etc/hostname', '/v/link.json')" | Out-Null
        }

        AfterAll {
            docker volume rm -f $script:NtfyVolume $script:BoltVolume *> $null
        }

        It 'copies SQLite with the backup API and a plain file as it is' {
            $s = New-TestSetup -NtfyVolume $script:NtfyVolume -BoltVolume $script:BoltVolume
            $r = Invoke-Collector $s -Execute
            $r.Problems | Should -BeNullOrEmpty
            $db = [IO.File]::ReadAllBytes((Join-Path $r.RunFolder 'bundle/07/ntfy-data/user.db'))
            [Text.Encoding]::ASCII.GetString($db, 0, 15) | Should -Be 'SQLite format 3'
            Get-Content -LiteralPath (Join-Path $r.RunFolder 'bundle/07/bolt-data/server-keys.json') -Raw | Should -BeExactly $script:BoltContent
            $map = Get-Content -LiteralPath (Join-Path $r.RunFolder 'bundle/00-RESTORE-MAP.json') -Raw | ConvertFrom-Json
            ($map.entries | Where-Object id -EQ 'bolt-server-keys').owner | Should -Be '0'
            ($map.entries | Where-Object id -EQ 'bolt-server-keys').mode | Should -Match '^0[0-7]{3}$'
        }

        It 'copies a live database whose changes are still only in its WAL file' {
            # A writer keeps the database open with checkpoints off, so the rows
            # exist only in user.db-wal while the collector runs.
            $writer = 'cria-test-writer-' + [guid]::NewGuid().ToString('n').Substring(0, 8)
            $program = 'import sqlite3, time; c = sqlite3.connect("/v/live.db"); c.execute("pragma journal_mode=wal"); c.execute("pragma wal_autocheckpoint=0"); c.execute("create table user (name text)"); [c.execute("insert into user values (?)", ("fake%d" % i,)) for i in range(50)]; c.commit(); open("/v/ready", "w").close(); time.sleep(300)'
            docker run -d --name $writer --network none -v "$($script:NtfyVolume):/v" $script:Image python3 -c $program | Out-Null
            try {
                for ($i = 0; $i -lt 50; $i++) {
                    docker exec $writer test -f /v/ready *> $null
                    if ($LASTEXITCODE -eq 0) { break }
                    Start-Sleep -Milliseconds 200
                }
                $s = New-TestSetup -NtfyVolume $script:NtfyVolume
                $s.Manifest.rows[$s.Manifest.rows.Count - 1].location = 'ntfy-data:live.db'
                Save-TestSetup $s
                $r = Invoke-Collector $s -Execute
                $r.Problems | Should -BeNullOrEmpty
                $dir = Join-Path $r.RunFolder 'bundle/07/ntfy-data'
                $count = docker run --rm --network none -v "$($dir):/c:ro" $script:Image python3 -c 'import sqlite3; print(sqlite3.connect("file:/c/live.db?mode=ro", uri=True).execute("select count(*) from user").fetchone()[0])'
                $count | Should -Be '50'
            }
            finally {
                docker rm -f $writer *> $null
            }
        }

        It 'refuses a symbolic link inside a volume' {
            $s = New-TestSetup -BoltVolume $script:BoltVolume
            $s.Manifest.rows.Add([ordered]@{ id = 'bolt-link'; folder = '07'; location = 'bolt-data:link.json'; kind = 'file'; required = $true; purpose = 'test' })
            Save-TestSetup $s
            $r = Invoke-Collector $s -Execute
            $r.IsValid | Should -BeFalse
            ($r.Rows | Where-Object Id -EQ 'bolt-link').Status | Should -Be 'refused (a symbolic link on the way)'
        }

        It 'reports a missing volume without creating it' {
            $absent = 'cria-test-absent-' + [guid]::NewGuid().ToString('n').Substring(0, 8)
            $s = New-TestSetup -BoltVolume $absent
            $r = Invoke-Collector $s -Execute
            $r.Problems | Should -Contain "row 'bolt-server-keys': bolt-data:server-keys.json is missing (required)"
            docker volume inspect $absent *> $null
            $LASTEXITCODE | Should -Not -Be 0
        }

        It 'leaves no helper container behind, running or stopped' {
            @(docker ps -a --filter 'name=cria-collect-' --format '{{.Names}}') | Should -BeNullOrEmpty
            @(docker ps -a --filter 'label=cria.collector=helper' --format '{{.Names}}') | Should -BeNullOrEmpty
        }
    }
}
