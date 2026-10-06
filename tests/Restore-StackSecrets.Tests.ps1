#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    # The volume tests need a Linux Docker engine (GitHub's ubuntu runner has one).
    $DockerReady = $false
    if ($IsLinux -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        docker info *> $null
        $DockerReady = ($LASTEXITCODE -eq 0)
    }
}

BeforeAll {
    $script:Collector = Join-Path $PSScriptRoot '../tools/Collect-StackSecrets.ps1'
    $script:Tool = Join-Path $PSScriptRoot '../tools/Restore-StackSecrets.ps1'
    $script:Fakes = Join-Path $PSScriptRoot 'fakes'
    $script:Image = 'python:3.12-slim'
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    # Collects a real bundle with the collector from an 'old' tree under
    # TestDrive (and, off Windows, a stand-in VPS through the ssh fake or a
    # Docker volume), and writes a second roots file pointing at an empty
    # 'new' tree with the same root names. Content is always 'fake-' plus a
    # GUID: nothing secret-shaped is ever written.
    function New-Bundle {
        param([switch]$WithVps, [string]$OldVolume, [string]$NewVolume)
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $s = [pscustomobject]@{
            Old          = Join-Path $base 'old'
            New          = Join-Path $base 'new'
            Staging      = Join-Path $base 'staging'
            ManifestPath = Join-Path $base 'secrets.json'
            OldRoots     = Join-Path $base 'roots-old.json'
            NewRoots     = Join-Path $base 'roots-new.json'
            Content      = @{}
            ZipPath      = $null
            Sha256       = $null
        }
        $files = [Collections.Generic.List[object]]@(
            @{ Id = 'stack-env'; Path = 'stack/.env' }
            @{ Id = 'ntfy-pc-token'; Path = 'stack/secrets/ntfy-pc.token' }
            @{ Id = 'gcal-oauth-token'; Path = 'stack/gcal/data/token.json' }
            @{ Id = 'ssh-key'; Path = 'ssh/test-key' }
        )
        if ($WithVps) { $files.Add(@{ Id = 'vps-egress-env'; Path = 'vps/egress/.env' }) }
        foreach ($f in $files) {
            $p = Join-Path $s.Old $f.Path
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            $c = 'fake-' + [guid]::NewGuid().ToString('n')
            Set-Content -LiteralPath $p -Value $c -NoNewline
            $s.Content[$f.Id] = $c
        }
        $rows = [Collections.Generic.List[object]]@(
            [ordered]@{ id = 'stack-env'; folder = '01'; location = 'stack:.env'; kind = 'file'; required = $true; purpose = 'test' }
            [ordered]@{ id = 'ntfy-pc-token'; folder = '01'; location = 'stack:secrets/ntfy-pc.token'; kind = 'file'; required = $true; purpose = 'test' }
            [ordered]@{ id = 'gcal-oauth-token'; folder = '02'; location = 'stack:gcal/data/token.json'; kind = 'file'; required = $false; purpose = 'test' }
            [ordered]@{ id = 'ssh-key'; folder = '04'; location = 'ssh:test-key'; kind = 'file'; required = $true; purpose = 'test' }
        )
        $old = [ordered]@{
            stack = [ordered]@{ kind = 'path'; host = 'pc'; path = (Join-Path $s.Old 'stack'); purpose = 'test' }
            ssh   = [ordered]@{ kind = 'path'; host = 'pc'; path = (Join-Path $s.Old 'ssh'); purpose = 'test' }
        }
        $new = [ordered]@{
            stack = [ordered]@{ kind = 'path'; host = 'pc'; path = (Join-Path $s.New 'stack'); purpose = 'test' }
            ssh   = [ordered]@{ kind = 'path'; host = 'pc'; path = (Join-Path $s.New 'ssh'); purpose = 'test' }
        }
        if ($WithVps) {
            # The ssh fake runs the remote script here, as the current user.
            $rows.Add([ordered]@{ id = 'vps-egress-env'; folder = '05'; location = 'vps-egress:.env'; kind = 'file'; required = $true; mode = '0600'; owner = (& id -un); purpose = 'test' })
            $old['vps-egress'] = [ordered]@{ kind = 'path'; host = 'vps'; path = (Join-Path $s.Old 'vps/egress'); purpose = 'test' }
            $new['vps-egress'] = [ordered]@{ kind = 'path'; host = 'vps'; path = (Join-Path $s.New 'vps/egress'); purpose = 'test' }
        }
        if ($OldVolume) {
            $rows.Add([ordered]@{ id = 'bolt-server-keys'; folder = '07'; location = 'bolt-data:server-keys.json'; kind = 'file'; required = $true; purpose = 'test' })
            $old['bolt-data'] = [ordered]@{ kind = 'volume'; host = 'pc'; volume = $OldVolume; purpose = 'test' }
            $new['bolt-data'] = [ordered]@{ kind = 'volume'; host = 'pc'; volume = $NewVolume; purpose = 'test' }
        }
        [ordered]@{ formatVersion = 1; rows = $rows; audits = @([ordered]@{ location = 'stack:secrets'; purpose = 'test' }) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $s.ManifestPath
        [ordered]@{ formatVersion = 1; roots = $old } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $s.OldRoots
        [ordered]@{ formatVersion = 1; roots = $new } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $s.NewRoots

        $r = & $script:Collector -Execute -PassThru -ManifestPath $s.ManifestPath -RootsPath $s.OldRoots -StagingRoot $s.Staging `
            -AllowUnencryptedStaging -SshCommand (Join-Path $script:Fakes 'fake-ssh.ps1') -ScpCommand (Join-Path $script:Fakes 'fake-scp.ps1') `
            -TailscaleCommand (Join-Path $script:Fakes 'fake-tailscale.ps1') -SeedOut (Join-Path $base 'seed')
        if (-not $r.IsValid) { throw "the collector failed: $($r.Problems -join '; ')" }
        $s.ZipPath = $r.ZipPath
        $s.Sha256 = $r.ZipSha256
        return $s
    }

    function Invoke-Restore {
        param($S, [string[]]$Folder, [switch]$Execute, [string]$ZipPath, [string]$Sha256)
        $params = @{
            ZipPath      = if ($ZipPath) { $ZipPath } else { $S.ZipPath }
            Sha256       = if ($Sha256) { $Sha256 } else { $S.Sha256 }
            Folder       = $Folder
            Execute      = $Execute
            ManifestPath = $S.ManifestPath
            RootsPath    = $S.NewRoots
            PassThru     = $true
            SshCommand   = (Join-Path $script:Fakes 'fake-ssh.ps1')
        }
        & $script:Tool @params
    }

    function Get-Status($Result, [string]$Id) { ($Result.Rows | Where-Object Id -EQ $Id).Status }

    function Assert-OwnerOnly([string]$Path) {
        if ($IsWindows) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = Get-Acl -LiteralPath $Path
            $acl.AreAccessRulesProtected | Should -BeTrue
            $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
            @($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference -ne $sid }) | Should -BeNullOrEmpty
        }
        else {
            ((Get-Item -LiteralPath $Path -Force).UnixFileMode -band [IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute') |
                Should -Be ([IO.UnixFileMode]::None)
        }
    }

    # A copy of the bundle with one more member, beside it in the protected run folder.
    function Copy-ZipWithExtra($S, [string]$Member) {
        $zip = Join-Path (Split-Path $S.ZipPath -Parent) ('stack-secrets-copy-' + [guid]::NewGuid().ToString('n').Substring(0, 8) + '.zip')
        Copy-Item -LiteralPath $S.ZipPath -Destination $zip
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $writer = [IO.StreamWriter]::new($archive.CreateEntry($Member).Open())
            try { $writer.Write('fake-extra') } finally { $writer.Dispose() }
        }
        finally { $archive.Dispose() }
        return $zip
    }
}

Describe 'Restore-StackSecrets' {

    Context 'checking and unpacking the bundle' {
        It 'checks and unpacks the bundle and plans without placing anything' {
            $s = New-Bundle
            $r = Invoke-Restore $s -Folder 01, 02, 04
            $r.Problems | Should -BeNullOrEmpty
            $r.IsValid | Should -BeTrue
            $r.Mode | Should -Be 'Plan'
            @($r.Rows | Where-Object Status -EQ 'would place') | Should -HaveCount 4
            Test-Path -LiteralPath $s.New | Should -BeFalse
            $r.BundleRoot | Should -Be (Join-Path (Split-Path $s.ZipPath -Parent) ([IO.Path]::GetFileNameWithoutExtension($s.ZipPath)))
            Get-Content -LiteralPath (Join-Path $r.BundleRoot '01/stack/.env') -Raw | Should -BeExactly $s.Content['stack-env']
            Assert-OwnerOnly $r.BundleRoot
            Assert-OwnerOnly (Join-Path $r.BundleRoot '01/stack/.env')
        }

        It 'refuses a ZIP whose SHA-256 is not the one given, before unpacking anything' {
            $s = New-Bundle
            $r = Invoke-Restore $s -Folder 01 -Sha256 ('0' * 64)
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain 'zip: its SHA-256 does not match the value given; download the bundle again and check the value stored with it'
            $r.BundleRoot | Should -BeNullOrEmpty
            Test-Path -LiteralPath ($s.ZipPath -replace '\.zip$', '') | Should -BeFalse
        }

        It 'refuses a ZIP in a folder other accounts can reach' -Skip:$IsWindows {
            $s = New-Bundle
            $open = Join-Path $TestDrive ('open-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
            New-Item -ItemType Directory -Path $open | Out-Null
            & chmod 0755 $open
            $zip = Join-Path $open 'stack-secrets-open.zip'
            Copy-Item -LiteralPath $s.ZipPath -Destination $zip
            $r = Invoke-Restore $s -Folder 01 -ZipPath $zip
            $r.IsValid | Should -BeFalse
            ($r.Problems -join "`n") | Should -Match 'its folder is not protected \(group or others have access\)'
        }

        It 'refuses a member that climbs out of the bundle' {
            $s = New-Bundle
            $zip = Copy-ZipWithExtra $s '../escaped.txt'
            $r = Invoke-Restore $s -Folder 01 -ZipPath $zip -Sha256 (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            $r.IsValid | Should -BeFalse
            ($r.Problems -join "`n") | Should -Match "zip: a member name is refused \('\.\.' segment\)"
            Test-Path -LiteralPath (Join-Path (Split-Path $zip -Parent) 'escaped.txt') | Should -BeFalse
            Test-Path -LiteralPath ($zip -replace '\.zip$', '') | Should -BeFalse
        }

        It 'refuses a bundle holding a file its map does not list' {
            $s = New-Bundle
            $zip = Copy-ZipWithExtra $s '01/stack/extra.env'
            $r = Invoke-Restore $s -Folder 01 -Execute -ZipPath $zip -Sha256 (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            $r.IsValid | Should -BeFalse
            ($r.Problems -join "`n") | Should -Match '^map: '
            Test-Path -LiteralPath $s.New | Should -BeFalse
        }

        It 'refuses a bundle collected from another inventory' {
            $s = New-Bundle
            $manifest = Get-Content -LiteralPath $s.ManifestPath -Raw | ConvertFrom-Json
            $manifest.rows[2].purpose = 'changed after the collection'
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $s.ManifestPath
            $r = Invoke-Restore $s -Folder 01 -Execute
            $r.IsValid | Should -BeFalse
            ($r.Problems -join "`n") | Should -Match '^map: '
            Test-Path -LiteralPath $s.New | Should -BeFalse
        }

        It 'reuses an earlier unpack of the same bundle, and refuses one that was changed' {
            $s = New-Bundle
            (Invoke-Restore $s -Folder 01).IsValid | Should -BeTrue
            (Invoke-Restore $s -Folder 01).IsValid | Should -BeTrue
            $r = Invoke-Restore $s -Folder 01
            Set-Content -LiteralPath (Join-Path $r.BundleRoot '01/stack/.env') -Value 'fake-tampered' -NoNewline
            $again = Invoke-Restore $s -Folder 01 -Execute
            $again.IsValid | Should -BeFalse
            ($again.Problems -join "`n") | Should -Match '^map: '
            Test-Path -LiteralPath $s.New | Should -BeFalse
        }
    }

    Context 'placing on the PC' {
        It 'places the chosen folders, owner-only, with the exact bytes, and leaves the rest' {
            $s = New-Bundle
            $r = Invoke-Restore $s -Folder 01, 04 -Execute
            $r.Problems | Should -BeNullOrEmpty
            $r.IsValid | Should -BeTrue
            foreach ($f in @(
                    @{ Id = 'stack-env'; Path = 'stack/.env' }
                    @{ Id = 'ntfy-pc-token'; Path = 'stack/secrets/ntfy-pc.token' }
                    @{ Id = 'ssh-key'; Path = 'ssh/test-key' })) {
                Get-Status $r $f.Id | Should -Be 'placed'
                $p = Join-Path $s.New $f.Path
                Get-Content -LiteralPath $p -Raw | Should -BeExactly $s.Content[$f.Id]
                Assert-OwnerOnly $p
            }
            Get-Status $r 'gcal-oauth-token' | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $s.New 'stack/gcal') | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Join-Path $s.New 'stack') -Force -Filter '.cria-restore-*') | Should -BeNullOrEmpty
        }

        It 'leaves a file that is already in place alone, so a run can be repeated' {
            $s = New-Bundle
            (Invoke-Restore $s -Folder 01 -Execute).IsValid | Should -BeTrue
            $r = Invoke-Restore $s -Folder 01, 02 -Execute
            $r.IsValid | Should -BeTrue
            Get-Status $r 'stack-env' | Should -Be 'already in place'
            Get-Status $r 'ntfy-pc-token' | Should -Be 'already in place'
            Get-Status $r 'gcal-oauth-token' | Should -Be 'placed'
        }

        It 'never overwrites a different file' {
            $s = New-Bundle
            New-Item -ItemType Directory -Path (Join-Path $s.New 'stack') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $s.New 'stack/.env') -Value 'fake-already-here' -NoNewline
            $r = Invoke-Restore $s -Folder 01 -Execute
            $r.IsValid | Should -BeFalse
            $r.Problems | Should -Contain "row 'stack-env': stack:.env refused (a different file is already there; move it away and run again)"
            Get-Content -LiteralPath (Join-Path $s.New 'stack/.env') -Raw | Should -BeExactly 'fake-already-here'
            Get-Status $r 'ntfy-pc-token' | Should -Be 'placed'
        }

        It 'refuses a destination reached through a link' {
            $s = New-Bundle
            $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
            New-Item -ItemType Directory -Path $elsewhere, (Join-Path $s.New 'stack') | Out-Null
            if ($IsWindows) { New-Item -ItemType Junction -Path (Join-Path $s.New 'stack/secrets') -Target $elsewhere | Out-Null }
            else { New-Item -ItemType SymbolicLink -Path (Join-Path $s.New 'stack/secrets') -Target $elsewhere | Out-Null }
            $r = Invoke-Restore $s -Folder 01 -Execute
            $r.IsValid | Should -BeFalse
            (Get-Status $r 'ntfy-pc-token') | Should -Match '^refused \('
            @(Get-ChildItem -LiteralPath $elsewhere -Force) | Should -BeNullOrEmpty
        }

        It 'prints statuses and counts, never a secret value or a hash' {
            $s = New-Bundle
            $text = & $script:Tool -ZipPath $s.ZipPath -Sha256 $s.Sha256 -Folder 01, 02, 04 -Execute -ManifestPath $s.ManifestPath -RootsPath $s.NewRoots *>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $text | Should -Match 'Result: COMPLETE'
            $text | Should -Match 'Rows: 4 \(4 placed\)'
            foreach ($value in $s.Content.Values) { $text | Should -Not -Match ([regex]::Escape($value)) }
            $text | Should -Not -Match '[0-9a-f]{64}'
        }
    }

    Context 'placing on the VPS' -Skip:$IsWindows {
        It 'places the file with its mode, leaves it alone when it is in place, and never overwrites' {
            $s = New-Bundle -WithVps
            $r = Invoke-Restore $s -Folder 05
            Get-Status $r 'vps-egress-env' | Should -Be 'checked when placing'
            $r = Invoke-Restore $s -Folder 05 -Execute
            $r.Problems | Should -BeNullOrEmpty
            Get-Status $r 'vps-egress-env' | Should -Be 'placed'
            $p = Join-Path $s.New 'vps/egress/.env'
            Get-Content -LiteralPath $p -Raw | Should -BeExactly $s.Content['vps-egress-env']
            (Get-Item -LiteralPath $p -Force).UnixFileMode | Should -Be ([IO.UnixFileMode]'UserRead, UserWrite')
            @(Get-ChildItem -LiteralPath (Split-Path $p -Parent) -Force -Filter '.cria-restore*') | Should -BeNullOrEmpty

            Get-Status (Invoke-Restore $s -Folder 05 -Execute) 'vps-egress-env' | Should -Be 'already in place'

            Set-Content -LiteralPath $p -Value 'fake-changed-on-the-vps' -NoNewline
            $r = Invoke-Restore $s -Folder 05 -Execute
            $r.IsValid | Should -BeFalse
            Get-Status $r 'vps-egress-env' | Should -Be 'refused (a different file is already there; move it away and run again)'
            Get-Content -LiteralPath $p -Raw | Should -BeExactly 'fake-changed-on-the-vps'
        }

        It 'refuses a VPS destination reached through a link' {
            $s = New-Bundle -WithVps
            $elsewhere = Join-Path $TestDrive ('vps-elsewhere-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
            New-Item -ItemType Directory -Path $elsewhere, (Join-Path $s.New 'vps') | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $s.New 'vps/egress') -Target $elsewhere | Out-Null
            $r = Invoke-Restore $s -Folder 05 -Execute
            Get-Status $r 'vps-egress-env' | Should -Be 'refused (a symbolic link on the way)'
            @(Get-ChildItem -LiteralPath $elsewhere -Force) | Should -BeNullOrEmpty
        }
    }

    Context 'placing into Docker volumes' -Skip:(-not $DockerReady) {
        BeforeAll {
            docker image inspect $script:Image *> $null
            if ($LASTEXITCODE -ne 0) { docker pull -q $script:Image | Out-Null }
            $tag = [guid]::NewGuid().ToString('n').Substring(0, 8)
            $script:OldVolume = "cria-test-old-$tag"
            $script:NewVolume = "cria-test-new-$tag"
            $script:Content = 'fake-' + [guid]::NewGuid().ToString('n')
            docker volume create $script:OldVolume | Out-Null
            docker volume create $script:NewVolume | Out-Null
            docker run --rm -v "$($script:OldVolume):/v" $script:Image python3 -c "import os; open('/v/server-keys.json', 'w').write('$($script:Content)'); os.chown('/v/server-keys.json', 1000, 1001); os.chmod('/v/server-keys.json', 0o640)" | Out-Null
        }

        AfterAll {
            docker rm -f "cria-test-user-$($script:NewVolume)" *> $null
            docker volume rm -f $script:OldVolume $script:NewVolume *> $null
        }

        It 'puts the file back with its mode and owner, and leaves it alone when it is in place' {
            $s = New-Bundle -OldVolume $script:OldVolume -NewVolume $script:NewVolume
            $r = Invoke-Restore $s -Folder 07 -Execute
            $r.Problems | Should -BeNullOrEmpty
            Get-Status $r 'bolt-server-keys' | Should -Be 'placed'
            $seen = docker run --rm --network none -v "$($script:NewVolume):/v:ro" $script:Image python3 -c "import os; s = os.stat('/v/server-keys.json'); print(open('/v/server-keys.json').read(), oct(s.st_mode & 0o777), s.st_uid, s.st_gid, sorted(os.listdir('/v')))"
            $seen | Should -Be "$($script:Content) 0o640 1000 1001 ['server-keys.json']"
            Get-Status (Invoke-Restore $s -Folder 07 -Execute) 'bolt-server-keys' | Should -Be 'already in place'
            @(docker ps -a --filter 'label=cria.restorer=helper' --format '{{.Names}}') | Should -BeNullOrEmpty
        }

        It 'refuses a volume a running container uses, and one that does not exist' {
            $s = New-Bundle -OldVolume $script:OldVolume -NewVolume $script:NewVolume
            docker run -d --name "cria-test-user-$($script:NewVolume)" --network none -v "$($script:NewVolume):/v" $script:Image sleep 300 | Out-Null
            try {
                Get-Status (Invoke-Restore $s -Folder 07 -Execute) 'bolt-server-keys' | Should -Be 'refused (a running container uses the volume; stop it first)'
            }
            finally { docker rm -f "cria-test-user-$($script:NewVolume)" *> $null }

            $roots = Get-Content -LiteralPath $s.NewRoots -Raw | ConvertFrom-Json
            $roots.roots.'bolt-data'.volume = 'cria-test-absent-' + [guid]::NewGuid().ToString('n').Substring(0, 8)
            $roots | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $s.NewRoots
            Get-Status (Invoke-Restore $s -Folder 07 -Execute) 'bolt-server-keys' | Should -Be 'refused (the volume does not exist yet; create it first)'
        }
    }
}
