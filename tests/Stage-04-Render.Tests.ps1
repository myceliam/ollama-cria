#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 4 (windows/stages/04-render.ps1) against a small fake repo, the
# fake tailnet (tests/fakes/fake-tailscale.ps1) and the fake bundle
# restorer. Every tailnet address is put together at run time.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')
    $script:NewPcIp = @('100', '64', '0', '7') -join '.'
    $script:OldIp = @('100', '101', '7', '9') -join '.'
    $script:SecretText = 'x'
    $script:SecretSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:SecretText))).ToLowerInvariant()

    function Write-Text([string]$Path, [string]$Text, [switch]$Bom) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new([bool]$Bom))
    }

    function Write-Json([string]$Path, $Object) { Write-Text $Path ($Object | ConvertTo-Json -Depth 6) }

    function New-Stage4([string]$Mode = 'Run') {
        Reset-Fake
        $env:CRIA_FAKE_TAILSCALE = $null
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $repo = Join-Path $base 'repo'
        $live = Join-Path $base 'live/ollama'
        $null = New-Item -ItemType Directory -Path $live -Force
        Write-Json (Join-Path $repo 'manifests/stack-files.json') @{
            '$schema'     = './schemas/stack-files.schema.json'
            formatVersion = 1
            sources       = @(
                @{ name = 'stack'; host = 'pc'; root = $live; repoFolder = 'stack'; files = @('compose.yml', 'sub/plain.txt') }
                @{ name = 'comfyui-startup'; host = 'pc'; root = (Join-Path $base 'startup'); repoFolder = 'windows/startup'; files = @('start.vbs') }
                @{ name = 'vps-egress'; host = 'vps'; root = '/home/liam/owui-web-egress'; repoFolder = 'vps/web-egress'; files = @('compose.yml') }
            )
        }
        Write-Json (Join-Path $repo 'manifests/endpoints.json') @{
            '$schema'     = './schemas/endpoints.schema.json'
            formatVersion = 1
            files         = @(
                @{ file = 'stack/compose.yml'; placeholders = @('PC_TS_IP') }
                @{ file = 'vps/web-egress/compose.yml'; placeholders = @('VPS_TS_IP') }
            )
        }
        Write-Text (Join-Path $repo 'stack/compose.yml') "services:`n  ollama:`n    host: '{{PC_TS_IP}}'`n" -Bom
        Write-Text (Join-Path $repo 'stack/sub/plain.txt') "plain`n"
        Write-Text (Join-Path $repo 'windows/startup/start.vbs') "' start`n"
        Write-Text (Join-Path $repo 'vps/web-egress/compose.yml') "bind: '{{VPS_TS_IP}}'`n"

        $state = Read-RecoveryState -Path (Join-Path $base 'state/state.json')
        $bundleRoot = Join-Path $base 'staging/stack-secrets-2026-10-07'
        Write-Json (Join-Path $bundleRoot '00-RESTORE-MAP.json') @{ entries = @(
                @{ id = 'stack-env'; folder = '01'; destination = 'stack:.env'; sha256 = $script:SecretSha }
                @{ id = 'egress-env'; folder = '05'; destination = 'vps-egress:.env'; sha256 = $script:SecretSha; mode = '0600'; owner = 'liam' }
            ) }
        $state.stages['1'] = @{ status = 'done'; data = @{ BundlePath = "$bundleRoot.zip"; BundleSha256 = ('a' * 64); BundleRoot = $bundleRoot } }
        $c = New-TestContext -Stage 4 -Mode $Mode -RepoRoot $repo -Base $base -State $state
        Write-Json (Join-Path $base 'recovery-roots.json') @{ roots = @{
                stack        = @{ kind = 'path'; host = 'pc'; path = $live }
                'vps-egress' = @{ kind = 'path'; host = 'vps'; path = '/home/liam/owui-web-egress' }
            } }
        $c.RootsPath = Join-Path $base 'recovery-roots.json'
        $c['Live'] = $live
        $global:CriaRestore = @{
            Calls    = [Collections.Generic.List[object]]::new()
            Rows     = @(
                [pscustomobject]@{ Id = 'stack-env'; Folder = '01'; Destination = 'stack:.env'; Status = 'placed' }
                [pscustomobject]@{ Id = 'egress-env'; Folder = '05'; Destination = 'vps-egress:.env'; Status = 'placed' }
            )
            Problems = @()
            Files    = @()
        }
        $global:CriaVpsStat = '600 liam'
        $global:CriaVpsSha = $script:SecretSha
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            if ($Name -eq 'ssh') { return New-ExecResult 0 @($global:CriaVpsStat, "$global:CriaVpsSha  /home/liam/owui-web-egress/.env") }
            return New-ExecResult -1
        }
        return $c
    }

    function Invoke-Run($Context) {
        $r = Invoke-Stage '04-render.ps1' $Context
        $Context.Data = $r.Data
        # The fake restorer places the PC secret as the real one would.
        $secretFile = Join-Path $Context.Live '.env'
        if (-not (Test-Path -LiteralPath $secretFile)) {
            $s = Open-NewOwnerOnlyFile -Path $secretFile
            try { $b = [Text.Encoding]::UTF8.GetBytes($script:SecretText); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
        }
        return $r
    }
}

AfterAll {
    $env:CRIA_FAKE_TAILSCALE = $null
    Remove-Variable -Name CriaFake, CriaCalls, CriaRestore, CriaVpsStat, CriaVpsSha -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 4: plan' {
    It 'lists what it would write and place, and writes nothing' {
        $c = New-Stage4 -Mode Plan
        $r = Invoke-Stage '04-render.ps1' $c
        $r.Status | Should -Be 'planned'
        $r.Problems | Should -BeNullOrEmpty
        ($r.Steps -join "`n") | Should -Match 'stack -> .*2 would write'
        ($r.Steps -join "`n") | Should -Match 'comfyui-startup: placed in Stage 8'
        ($r.Steps -join "`n") | Should -Match 'would place bundle folders 01, 02, 05'
        Test-Path -LiteralPath (Join-Path $c.Live 'compose.yml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $c.StateRoot 'rendered') | Should -BeFalse
        $global:CriaRestore.Calls.Count | Should -Be 0
    }

    It 'says the tailnet is down without failing the plan' {
        $c = New-Stage4 -Mode Plan
        $env:CRIA_FAKE_TAILSCALE = 'down'
        $r = Invoke-Stage '04-render.ps1' $c
        $r.Status | Should -Be 'planned'
        ($r.Steps -join "`n") | Should -Match 'would render the stack files once the tailnet answers'
    }
}

Describe 'Stage 4: run and check' {
    It 'renders for the new tailnet, keeps a BOM, copies plain files, places the secrets, and passes' {
        $c = New-Stage4
        $r = Invoke-Run $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        $compose = [IO.File]::ReadAllBytes((Join-Path $c.Live 'compose.yml'))
        $compose[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [Text.Encoding]::UTF8.GetString($compose, 3, $compose.Length - 3) | Should -Match ([regex]::Escape("host: '$script:NewPcIp'"))
        Get-Content -LiteralPath (Join-Path $c.Live 'sub/plain.txt') | Should -Be 'plain'
        Get-Content -LiteralPath (Join-Path $c.StateRoot 'rendered/vps-egress/compose.yml') | Should -Not -Match '\{\{'
        Test-Path -LiteralPath (Join-Path $c.Base 'startup') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $c.Live -Recurse -Filter '*.cria-*').Count | Should -Be 0
        (@(Get-OwnedItem -State $c.State -Path (Join-Path $c.Live 'compose.yml'))[0]).retry | Should -Be 'wipe'
        $global:CriaRestore.Calls[0].Folder | Should -Be '01,02,05'
        $r.Data.Placed | Should -Be @('stack-env', 'egress-env')
        $r.Data.Rendered.Count | Should -Be 3

        $k = Invoke-Stage '04-render.ps1' (Copy-Context $c 'Check')
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.What): $($_.Actual)" }) | Should -BeNullOrEmpty
        $k.Status | Should -Be 'passed'
        @($global:CriaCalls | Where-Object { $_ -like 'ssh *' })[0] | Should -Match "stat -c '%a %U' -- '/home/liam/owui-web-egress/.env'"
    }

    It 'leaves files with the same bytes alone, and replaces only what it wrote and nobody changed' {
        $c = New-Stage4
        $null = Invoke-Run $c
        $r = Invoke-Run $c
        ($r.Steps -join "`n") | Should -Match 'stack -> .*2 unchanged'
        Write-Text (Join-Path $c.RepoRoot 'stack/sub/plain.txt') "plain, newer`n"
        $r = Invoke-Run $c
        $r.Problems | Should -BeNullOrEmpty
        ($r.Steps -join "`n") | Should -Match '1 changed'
        Get-Content -LiteralPath (Join-Path $c.Live 'sub/plain.txt') | Should -Be 'plain, newer'
        # Edited by hand since: never overwritten.
        Set-Content -LiteralPath (Join-Path $c.Live 'sub/plain.txt') -Value 'mine'
        Write-Text (Join-Path $c.RepoRoot 'stack/sub/plain.txt') "plain, newest`n"
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'a different file is already there'
        Get-Content -LiteralPath (Join-Path $c.Live 'sub/plain.txt') | Should -Be 'mine'
    }

    It 'never overwrites a file it did not write' {
        $c = New-Stage4
        Write-Text (Join-Path $c.Live 'compose.yml') 'theirs'
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        Get-Content -LiteralPath (Join-Path $c.Live 'compose.yml') | Should -Be 'theirs'
        $global:CriaRestore.Calls.Count | Should -Be 0
    }

    It 'refuses a placeholder in a file that endpoints.json does not list' {
        $c = New-Stage4
        Write-Text (Join-Path $c.RepoRoot 'stack/sub/plain.txt') "{{PC_TS_IP}}`n"
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'stack/sub/plain.txt: holds endpoint placeholders but is not in manifests/endpoints.json'
        Test-Path -LiteralPath (Join-Path $c.Live 'sub/plain.txt') | Should -BeFalse
    }

    It 'fails when the tailnet does not answer' {
        $c = New-Stage4
        $env:CRIA_FAKE_TAILSCALE = 'down'
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match '^tailnet: '
        $global:CriaRestore.Calls.Count | Should -Be 0
    }

    It "fails its checkpoint on an old tailnet address or a VPS secret with the wrong mode" {
        $c = New-Stage4
        $null = Invoke-Run $c
        Set-Content -LiteralPath (Join-Path $c.Live 'sub/plain.txt') -Value "old: $script:OldIp"
        $global:CriaVpsStat = '644 liam'
        $k = Invoke-Stage '04-render.ps1' (Copy-Context $c 'Check')
        $k.Status | Should -Be 'failed'
        ($k.Problems -join ' ') | Should -Match 'plain.txt: holds 1 tailnet address'
        ($k.Problems -join ' ') | Should -Match 'vps-egress:.env: on the VPS, missing, changed, or not mode 600 owner liam'
        ($k.Problems -join ' ') | Should -Not -Match ([regex]::Escape($script:OldIp))
    }
}
