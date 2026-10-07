#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 7 (windows/stages/07-state.ps1) against a small fake repo with a
# made-up seed, the fake tailnet and bundle restorer, and a fake Docker and
# OWUI that answer from $global:CriaDocker. Keys and addresses are made up
# at run time.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')
    $script:Digest = 'ghcr.io/open-webui/open-webui@sha256:' + ('e' * 64)
    $script:Counts = [ordered]@{ tool = 15; function = 5; model = 33; skill = 21; prompt = 5; group = 1; group_member = 0; access_grant = 15 }
    $script:PcIp = @('100', '64', '0', '7') -join '.'

    function Write-Text([string]$Path, [string]$Text) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, $Text)
    }

    function Write-Json([string]$Path, $Object) { Write-Text $Path ($Object | ConvertTo-Json -Depth 6) }

    function New-Stage7([string]$Mode = 'Run', [switch]$NoSeed) {
        Reset-Fake
        $env:CRIA_FAKE_TAILSCALE = $null
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $repo = Join-Path $base 'repo'
        foreach ($f in 'manifests/images.json', 'manifests/owui-api-consumers.json', 'manifests/owui-seed/schema.json', 'tools/Import-OwuiSeed.py') {
            Write-Text (Join-Path $repo $f) ([IO.File]::ReadAllText((Join-Path $script:RealRepo $f)))
        }
        if (-not $NoSeed) {
            foreach ($n in 'access_grant', 'config', 'function', 'group', 'group_member', 'model', 'prompt', 'secret_refs', 'skill', 'tool', 'user_settings') {
                Write-Text (Join-Path $repo "manifests/owui-seed/seed/$n.json") '[]'
            }
            Write-Json (Join-Path $repo 'manifests/owui-seed/seed/provenance.json') @{
                seed_format = 1; owui_version = '0.11.4'; alembic_revision = 'd4c1a8e37b62'; image_digest = $script:Digest
                endpoints = @('PC_TS_IP'); counts = $script:Counts
            }
        }
        $live = Join-Path $base 'live/ollama'
        $script:Old = 'old' + 'value'
        Write-Text (Join-Path $live 'gcal-owui-bridge/.env') "OWUI_BASE_URL=http://host.docker.internal:3000`r`nOWUI_API_KEY=$($script:Old)`r`nTZ=Europe/London`r`n"

        $state = Read-RecoveryState -Path (Join-Path $base 'state/state.json')
        $bundleRoot = Join-Path $base 'staging/stack-secrets-2026-10-07'
        Write-Json (Join-Path $bundleRoot '00-RESTORE-MAP.json') @{ entries = @(
                @{ id = 'owui-seed-secrets'; folder = '03'; file = 'values.json'; destination = 'owui-secrets:values.json'; sha256 = ('b' * 64) }
            ) }
        $script:Secrets = '{"owui_seed_secrets": 1, "refs": {}}'
        Write-Text (Join-Path $bundleRoot '03/values.json') $script:Secrets
        $state.stages['1'] = @{ status = 'done'; data = @{ BundlePath = "$bundleRoot.zip"; BundleSha256 = ('a' * 64); BundleRoot = $bundleRoot } }
        $c = New-TestContext -Stage 7 -Mode $Mode -RepoRoot $repo -Base $base -State $state
        Initialize-ProtectedFolder -Path $c.StagingRoot
        $c.Topology['composeProjects'] = @(
            @{ name = 'ollama'; root = 'stack'; file = 'docker-compose.yml' }
            @{ name = 'gmail-owui-bridge'; root = 'stack'; file = 'gmail-owui-bridge/docker-compose.yml' }
            @{ name = 'cline-dashboard'; root = 'dashboard'; file = 'docker-compose.yml' }
            @{ name = 'owui-web-egress'; root = 'vps-egress'; file = 'compose.yml' }
        )
        Write-Json (Join-Path $base 'recovery-roots.json') @{ roots = @{ stack = @{ kind = 'path'; host = 'pc'; path = $live } } }
        $c.RootsPath = Join-Path $base 'recovery-roots.json'
        $c['Live'] = $live

        $global:CriaRestore = @{
            Calls    = [Collections.Generic.List[object]]::new()
            Rows     = @(
                [pscustomobject]@{ Id = 'ntfy-user-db'; Folder = '07'; Destination = 'ntfy-data:user.db'; Status = 'placed' }
                [pscustomobject]@{ Id = 'bolt-server-keys'; Folder = '07'; Destination = 'bolt-data:server-keys.json'; Status = 'placed' }
            )
            Problems = @()
            Files    = @()
        }
        $global:CriaDocker = @{
            Images   = [Collections.Generic.HashSet[string]]::new()
            Volume   = $null
            Running  = $false
            Admin    = $false
            Imported = $false
            Key      = $null
            Counts   = $script:Counts
            Import   = $null
            ImportOutput = $null
            Projects = @{
                'ollama'            = @{ Pulled = @('ghcr.io/open-webui/open-webui:latest', 'apache/tika:latest-full', 'python@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf'); Built = @('mcpo-core-baked:pinned', 'ollama-gcal-owui-bridge') }
                'gmail-owui-bridge' = @{ Pulled = @(); Built = @('gmail-owui-bridge-gmail-owui-bridge') }
                'cline-dashboard'   = @{ Pulled = @(); Built = @('cline-dashboard-dashboard') }
            }
        }
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            $d = $global:CriaDocker
            if ($Name -ne 'docker') { return New-ExecResult -1 }
            $a = @($Arguments)
            if ($a[0] -eq 'compose') {
                $p = $d.Projects[$a[2]]
                switch ($a[7]) {
                    'config' { return New-ExecResult 0 @($p.Pulled + $p.Built) }
                    'build' { foreach ($i in $p.Built) { [void]$d.Images.Add($i) }; return New-ExecResult 0 }
                    'create' { return New-ExecResult 0 }
                    'up' { $d.Running = $true; return New-ExecResult 0 }
                    'stop' { $d.Running = $false; return New-ExecResult 0 }
                    'run' {
                        $in = $global:CriaFake.Input['docker']
                        if ($a[-1] -like '*exec(sys.stdin.read())*') {
                            $counts = [ordered]@{}
                            foreach ($k in $d.Counts.Keys) { $counts[$k] = $(if ($d.Imported) { $d.Counts[$k] } else { 0 }) }
                            return New-ExecResult 0 @((@{ counts = $counts; left = 0; users = 1; integrity = 'ok'; fk = 0 } | ConvertTo-Json -Compress -Depth 4))
                        }
                        $d.Import = $in | ConvertFrom-Json -AsHashtable
                        if ($d.ImportOutput) { return New-ExecResult 1 $d.ImportOutput }
                        $d.Imported = $true
                        return New-ExecResult 0 @('WARN    tool brave_search: a valve is blank', 'OK      seed imported: tool 15, function 5; 0 secret reference(s) filled; owner is the new admin')
                    }
                }
                return New-ExecResult 2
            }
            switch ($a[0]) {
                'image' { return New-ExecResult $(if ($d.Images.Contains($a[-1])) { 0 } else { 1 }) }
                'pull' { [void]$d.Images.Add($a[-1]); return New-ExecResult 0 }
                'tag' { [void]$d.Images.Add($a[-1]); return New-ExecResult 0 }
                'volume' {
                    if ($a[1] -eq 'create') { $d.Volume = @{ 'ollama-cria.stage' = '7' }; return New-ExecResult 0 }
                    if ($null -eq $d.Volume) { return New-ExecResult 1 @('Error: no such volume') }
                    return New-ExecResult 0 @(($d.Volume | ConvertTo-Json -Compress))
                }
            }
            return New-ExecResult 2
        }
        $global:CriaFake.Http = {
            param($Uri)
            $d = $global:CriaDocker
            if (-not $d.Running) { return $null }
            if ($Uri -like '*/health') { return [pscustomobject]@{ status = $true } }
            if ($Uri -like '*/api/config') { return [pscustomobject]@{ name = 'Open WebUI'; onboarding = (-not $d.Admin) } }
            return $null
        }
        $global:CriaFake.Status = {
            param($Uri, $Headers)
            $d = $global:CriaDocker
            if (-not $d.Running) { return 0 }
            if ($Headers['Authorization'] -eq "Bearer $($d.Key)") { return 200 }
            return 401
        }
        return $c
    }

    function Invoke-Visit($Context) {
        $r = Invoke-Stage '07-state.ps1' $Context
        $Context.Data = $r.Data
        return $r
    }

    function Get-Call([string]$Pattern) { @($global:CriaCalls | Where-Object { $_ -like $Pattern }) }
    function Get-KeyFile($Context) { Join-Path $Context.StagingRoot 'owui-api-key.txt' }
}

AfterAll {
    $env:CRIA_FAKE_TAILSCALE = $null
    Remove-Variable -Name CriaFake, CriaCalls, CriaRestore, CriaDocker -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 7: run' {
    It 'plans it without touching Docker' {
        $c = New-Stage7 -Mode Plan
        $r = Invoke-Stage '07-state.ps1' $c
        $r.Status | Should -Be 'planned'
        $r.Problems | Should -BeNullOrEmpty
        $r.Steps[0] | Should -Be "would build the images of ollama, gmail-owui-bridge, cline-dashboard and pull the rest at their digests, OWUI 0.11.4 at the seed's"
        $r.Steps.Count | Should -Be 3
        Get-Call 'docker *' | Should -BeNullOrEmpty
    }

    It 'builds and pulls every image before creating anything, then asks for the admin account' {
        $c = New-Stage7
        $r = Invoke-Visit $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match 'create the admin account'

        Get-Call 'docker pull *' | Should -Be @(
            'docker pull --quiet apache/tika@sha256:80072bb73dd320a9de9709beb0b16d14dd6d2680376f8d31e498f55b633ba593'
            "docker pull --quiet $($script:Digest)"
            'docker pull --quiet python@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf')
        Get-Call 'docker tag *' | Should -Be @(
            'docker tag apache/tika@sha256:80072bb73dd320a9de9709beb0b16d14dd6d2680376f8d31e498f55b633ba593 apache/tika:latest-full'
            "docker tag $($script:Digest) ghcr.io/open-webui/open-webui:latest")
        @(Get-Call 'docker compose * build --quiet').Count | Should -Be 3
        $firstCreate = $global:CriaCalls.IndexOf((Get-Call 'docker compose * create *')[0])
        $lastImage = [Linq.Enumerable]::Max([int[]]@(Get-Call 'docker pull *' | ForEach-Object { $global:CriaCalls.IndexOf($_) }))
        $firstCreate | Should -BeGreaterThan $lastImage
        Get-Call 'docker volume create *' | Should -Be @('docker volume create --label ollama-cria.stage=7 owui-data')
        Get-Call 'docker compose -p owui-web-egress *' | Should -BeNullOrEmpty
        $global:CriaRestore.Calls[0].Folder | Should -Be '07'
        $global:CriaRestore.Calls[0].HelperImage | Should -Be 'python@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf'
        Get-Call 'docker compose -p ollama * up -d --no-deps --pull never open-webui' | Should -Not -BeNullOrEmpty
        $global:CriaDocker.Imported | Should -BeFalse
    }

    It 'imports the seed with the secrets and addresses on stdin only, then asks for an API key and places it' {
        $c = New-Stage7
        $null = Invoke-Visit $c
        $global:CriaDocker.Admin = $true

        $r = Invoke-Visit $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'needs-user'
        $global:CriaDocker.Imported | Should -BeTrue
        $r.Steps | Should -Contain 'seed: seed imported: tool 15, function 5; 0 secret reference(s) filled; owner is the new admin'
        $r.Warnings | Should -Contain 'seed: tool brave_search: a valve is blank'
        $envelope = $global:CriaDocker.Import
        @($envelope['seed'].Keys).Count | Should -Be 12
        $envelope['secrets'] | Should -Be $script:Secrets
        $envelope['argv'] | Should -Contain "PC_TS_IP=$($script:PcIp)"
        $envelope['script'] | Should -Match 'def main'
        ($global:CriaCalls -join "`n") | Should -Not -Match ([regex]::Escape($script:PcIp))
        ($global:CriaCalls -join "`n") | Should -Not -Match 'owui_seed_secrets'
        $stopAt = $global:CriaCalls.IndexOf((Get-Call 'docker compose -p ollama * stop open-webui')[0])
        $importAt = $global:CriaCalls.LastIndexOf((Get-Call 'docker compose -p ollama * run *')[-1])
        $stopAt | Should -BeLessThan $importAt

        $keyFile = Get-KeyFile $c
        $r.Asks[0].Text | Should -Match ([regex]::Escape($keyFile))
        Get-ProtectionProblem -Path $keyFile | Should -BeNullOrEmpty
        (@(Get-OwnedItem -State $c.State -Path $keyFile)[0]).plaintext | Should -BeTrue

        $key = 'sk-' + ('a1' * 16)
        $global:CriaDocker.Key = $key
        [IO.File]::WriteAllText($keyFile, "$key`r`n")
        $r = Invoke-Visit $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        [IO.File]::ReadAllText((Join-Path $c.Live 'gcal-owui-bridge/.env')) | Should -Be "OWUI_BASE_URL=http://host.docker.internal:3000`r`nOWUI_API_KEY=$key`r`nTZ=Europe/London`r`n"
        $global:CriaDocker.Running | Should -BeFalse
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match $key
        Get-Call 'docker compose * run *' | Where-Object { $_ -notlike '*exec(sys.stdin.read())*' } | Should -HaveCount 1

        $check = Copy-Context $c 'Check'
        $k = Invoke-Stage '07-state.ps1' $check
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.What): $($_.Actual)" }) | Should -BeNullOrEmpty
        $k.Status | Should -Be 'passed'
        $k.Checks.Count | Should -Be 10
    }

    It 'run again after Stage 8 places nothing twice and leaves OWUI running' {
        $c = New-Stage7
        $null = Invoke-Visit $c
        $global:CriaDocker.Admin = $true
        $null = Invoke-Visit $c
        $global:CriaDocker.Key = 'sk-' + ('d4' * 16)
        [IO.File]::WriteAllText((Get-KeyFile $c), $global:CriaDocker.Key)
        (Invoke-Visit $c).Status | Should -Be 'done'
        $global:CriaRestore.Calls.Clear()
        # Stage 8 started the stack; ntfy has changed its user.db since.
        $global:CriaDocker.Running = $true
        $global:CriaRestore.Rows = @([pscustomobject]@{ Id = 'ntfy-user-db'; Folder = '07'; Destination = 'ntfy-data:user.db'; Status = 'refused' })
        $global:CriaCalls.Clear()
        $r = Invoke-Visit $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        $r.Steps | Should -Contain 'service state: placed by an earlier attempt'
        $global:CriaRestore.Calls | Should -HaveCount 0
        $global:CriaDocker.Running | Should -BeTrue
        Get-Call 'docker compose * stop *' | Should -HaveCount 0
        Get-Call 'docker compose * up *' | Should -HaveCount 0
    }

    It 'asks again for a key OWUI refuses, and leaves the consumers alone' {
        $c = New-Stage7
        $null = Invoke-Visit $c
        $global:CriaDocker.Admin = $true
        $null = Invoke-Visit $c
        $global:CriaDocker.Key = 'sk-' + ('b2' * 16)
        [IO.File]::WriteAllText((Get-KeyFile $c), 'sk-' + ('c3' * 16))
        $r = Invoke-Visit $c
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match 'OWUI refused the key .* \(HTTP 401\)'
        [IO.File]::ReadAllText((Join-Path $c.Live 'gcal-owui-bridge/.env')) | Should -Match "OWUI_API_KEY=$($script:Old)"

        [IO.File]::WriteAllText((Get-KeyFile $c), 'not a key')
        (Invoke-Visit $c).Asks[0].Text | Should -Match 'does not hold one OWUI API key'
    }

    It 'does not import twice when the seed is already in' {
        $c = New-Stage7
        $null = Invoke-Visit $c
        $global:CriaDocker.Admin = $true
        $global:CriaDocker.Imported = $true
        $r = Invoke-Visit $c
        $r.Steps | Should -Contain 'seed: already in OWUI''s database'
        $global:CriaDocker.Import | Should -BeNullOrEmpty
        $r.Data['SeedImported'] | Should -BeTrue
    }

    It 'reports what the importer refused, and keeps the seed unimported' {
        $c = New-Stage7
        $null = Invoke-Visit $c
        $global:CriaDocker.Admin = $true
        $global:CriaDocker.ImportOutput = @('PROBLEM expected exactly one admin user (the new account), found 2', 'STOPPED nothing was written')
        $r = Invoke-Visit $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Be @('seed: expected exactly one admin user (the new account), found 2')
        $r.Data['SeedImported'] | Should -BeNullOrEmpty
    }

    It 'refuses an owui-data volume it did not create, and creates nothing' {
        $c = New-Stage7
        $global:CriaDocker.Volume = @{}
        $r = Invoke-Visit $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'owui-data already exists and this stage did not create it'
        Get-Call 'docker compose * create *' | Should -BeNullOrEmpty
        Get-Call 'docker volume rm*' | Should -BeNullOrEmpty
        $global:CriaRestore.Calls.Count | Should -Be 0
    }

    It 'stops before Docker when the seed is not committed' {
        $c = New-Stage7 -NoSeed
        $r = Invoke-Visit $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Be @('manifests/owui-seed/seed is not in the repo yet: commit the seed from the first capture (docs/RESTORE.md 7d)')
        Get-Call 'docker *' | Should -BeNullOrEmpty
    }

    It 'stops on an image with nothing to build it from and no pinned digest' {
        $c = New-Stage7
        $global:CriaDocker.Projects['cline-dashboard'].Pulled = @('example/unpinned:latest')
        $r = Invoke-Visit $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain 'example/unpinned:latest: not built by its project and no pinned digest to pull (manifests/images.json)'
        Get-Call 'docker compose * create *' | Should -BeNullOrEmpty
    }
}
