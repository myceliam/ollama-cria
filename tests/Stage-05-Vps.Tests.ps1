#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 5 (windows/stages/05-vps.ps1) on a fake PC: the VPS scripts answer
# from canned output and their input is decoded here, curl answers per URL.
# tests/Linux-Stages.Tests.ps1 runs the scripts themselves. Addresses are
# made up at run time.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')
    $script:VpsIp = @('100', '64', '0', '8') -join '.'
    $script:Egress = '/home/liam/owui-web-egress'

    function New-Stage5([string]$Mode = 'Run', [string[]]$Skip = @()) {
        # A context whose state root holds every VPS file Stage 4 renders.
        Reset-Fake
        $c = New-TestContext -Stage 5 -Mode $Mode
        $manifest = Get-Content -LiteralPath (Join-Path $script:RealRepo 'manifests/stack-files.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($s in @($manifest['sources'] | Where-Object { $_['host'] -eq 'vps' })) {
            foreach ($f in @($s['files'])) {
                if ("$($s['name'])/$f" -in $Skip) { continue }
                $p = Join-Path (Join-Path (Join-Path $c.StateRoot 'rendered') $s['name']) $f
                $null = New-Item -ItemType Directory -Path (Split-Path $p) -Force
                [IO.File]::WriteAllText($p, "rendered $($s['name'])/$f`n")
            }
        }
        $global:CriaPlaced = [ordered]@{}
        $global:CriaImages = @()
        $global:CriaSearch = '{"results":[{"title":"one"},{"title":"two"}]}'
        $global:CriaFacts = [ordered]@{
            'guard-enabled' = 'yes'; 'guard-active' = 'yes'; 'nft-table' = 'yes'; 'ip-rule' = 'yes'; 'docker-needs-guard' = 'yes'
            'egress-running' = '6/6'; 'gluetun-health' = 'healthy'; 'kokoro-running' = '1/1'; 'exit-ip' = 'differs'
            'listen-8880' = 'tailnet-only'; 'listen-18099' = 'tailnet-only'; 'listen-13100' = 'tailnet-only'; 'nginx-site' = 'yes'; 'nginx-test' = 'ok'
        }
        $global:CriaFake.Vps = {
            param($Call, $InputLines)
            switch ($Call.Name) {
                '05-place.sh' {
                    $out = foreach ($l in $InputLines) {
                        $pb64, $mode, $owner, $sha, $cb64 = $l -split ' '
                        $path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pb64))
                        $global:CriaPlaced[$path] = [pscustomobject]@{ Mode = $mode; Owner = $owner; Sha = $sha; Bytes = [Convert]::FromBase64String($cb64) }
                        "PLACED new $path"
                    }
                    return New-ExecResult 0 @($out)
                }
                '05-services.sh' {
                    if ($Call.Arguments[0] -eq 'run') {
                        $global:CriaImages = @($InputLines)
                        return New-ExecResult 0 @('STEP guard: nftables table and routing rules loaded', 'STEP /home/liam/owui-web-egress: 6/6 services running')
                    }
                    return New-ExecResult 0 @($global:CriaFacts.Keys | ForEach-Object { "FACT $_ $($global:CriaFacts[$_])" })
                }
            }
            return New-ExecResult 1 @("FAIL unexpected script $($Call.Name)")
        }
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            if ($Name -ne 'curl') { return New-ExecResult -1 }
            switch -Wildcard ($Arguments[-1]) {
                '*:13100/health' { return New-ExecResult 0 @('{"status":"ok"}') }
                '*:8880/v1/models' { return New-ExecResult 0 @('{"data":[{"id":"kokoro","object":"model"}]}') }
                '*:18080/search*' { return New-ExecResult 0 @($global:CriaSearch) }
            }
            return New-ExecResult 7
        }
        return $c
    }

    function Get-Call([string]$Pattern) { @($global:CriaCalls | Where-Object { $_ -like $Pattern }) }
}

AfterAll {
    Remove-Variable -Name CriaFake, CriaCalls, CriaPlaced, CriaImages, CriaFacts, CriaSearch -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 5: run' {
    It 'plans it without touching the VPS' {
        $c = New-Stage5 -Mode Plan
        $r = Invoke-Stage '05-vps.ps1' $c
        $r.Status | Should -Be 'planned'
        $r.Problems | Should -BeNullOrEmpty
        $r.Steps | Should -Be @(
            'would place 18 files on the VPS, never over one this stage did not write'
            'would load the guard and make Docker need it, then pull 5 images at their digests and build 2'
            'would start owui-web-egress and kokoro with nothing else pulled, then switch on only the Groq relay site in nginx')
        Get-Call 'vps *' | Should -BeNullOrEmpty
    }

    It 'places every rendered file, the guard unit twice and the restore-only build, then starts the services' {
        $c = New-Stage5
        $r = Invoke-Stage '05-vps.ps1' $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        Get-Call 'vps *' | Should -Be @('vps vps 05-place.sh liam', "vps vps 05-services.sh run liam $($script:VpsIp) guard-changed")

        $global:CriaPlaced.Count | Should -Be 18
        foreach ($p in $global:CriaPlaced.Keys) {
            $f = $global:CriaPlaced[$p]
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($f.Bytes)).ToLowerInvariant() | Should -Be $f.Sha
        }
        $global:CriaPlaced["$($script:Egress)/guard.sh"].Mode | Should -Be '0755'
        $global:CriaPlaced["$($script:Egress)/rollback.sh"].Mode | Should -Be '0755'
        $global:CriaPlaced["$($script:Egress)/compose.yml"].Mode | Should -Be '0644'
        $global:CriaPlaced["$($script:Egress)/compose.yml"].Owner | Should -Be 'liam'
        $global:CriaPlaced['/home/liam/kokoro/compose.yml'].Owner | Should -Be 'liam'
        foreach ($p in '/etc/systemd/system/owui-web-egress-guard.service', '/etc/systemd/system/docker.service.d/owui-web-egress.conf', '/etc/nginx/sites-available/groq-relay') {
            $global:CriaPlaced[$p].Owner | Should -Be 'root'
            $global:CriaPlaced[$p].Mode | Should -Be '0644'
        }
        [Text.Encoding]::UTF8.GetString($global:CriaPlaced['/etc/systemd/system/owui-web-egress-guard.service'].Bytes) | Should -Be "rendered vps-egress/owui-web-egress-guard.service`n"
        $global:CriaPlaced.Contains("$($script:Egress)/owui-web-egress-guard.service") | Should -BeTrue
        $repoDockerfile = [IO.File]::ReadAllBytes((Join-Path $script:RealRepo 'linux/files/web-egress/searxng-mcp/Dockerfile'))
        $global:CriaPlaced["$($script:Egress)/searxng-mcp/Dockerfile"].Bytes | Should -Be $repoDockerfile
        $global:CriaPlaced.Contains("$($script:Egress)/compose.override.yml") | Should -BeTrue

        $images = $global:CriaImages
        $images.Count | Should -Be 7
        $images | Should -Contain "build jina-reader-official-hardened:2026-09-24 $($script:Egress)/jina-official"
        $images | Should -Contain "build searxng-mcp:1.6.0 $($script:Egress)/searxng-mcp"
        @($images -match '^pull qmcgaw/gluetun@sha256:[0-9a-f]{64} qmcgaw/gluetun:v3$').Count | Should -Be 1
        @($images -match '^pull python@sha256:[0-9a-f]{64} -$').Count | Should -Be 1
        @($images -match '^pull ghcr\.io/remsky/kokoro-fastapi-cpu@sha256:[0-9a-f]{64} ghcr\.io/remsky/kokoro-fastapi-cpu:v0\.5\.0$').Count | Should -Be 1
        @($images -match 'mcpo-core-baked|jina-ai/reader').Count | Should -Be 0

        $r.Steps | Should -Contain 'placed 18 files on the VPS: 18 new'
        $r.Steps | Should -Contain "05-services.sh: $($script:Egress): 6/6 services running"
        $r.Data['Placed'] | Should -Be 18
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:VpsIp))
    }

    It 'leaves a running guard alone when none of its files changed' {
        $c = New-Stage5
        $global:CriaFake.Vps = {
            param($Call, $InputLines)
            if ($Call.Name -eq '05-services.sh') { return New-ExecResult 0 @() }
            New-ExecResult 0 @($InputLines | ForEach-Object { 'PLACED same ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($_ -split ' ')[0])) })
        }
        $r = Invoke-Stage '05-vps.ps1' $c
        $r.Status | Should -Be 'done'
        $r.Steps | Should -Contain 'placed 18 files on the VPS: 18 same'
        Get-Call 'vps vps 05-services.sh *' | Should -Be @("vps vps 05-services.sh run liam $($script:VpsIp)")
    }

    It 'touches nothing when a file was not rendered' {
        $c = New-Stage5 -Skip 'vps-egress/guard.nft'
        $r = Invoke-Stage '05-vps.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'guard\.nft: not rendered; Stage 4 writes it'
        Get-Call 'vps *' | Should -BeNullOrEmpty
    }

    It 'starts nothing when a file could not be placed' {
        $c = New-Stage5
        $global:CriaFake.Vps = { param($Call) New-ExecResult 1 @('PLACED new /home/liam/kokoro/compose.yml', 'FAIL /home/liam/owui-web-egress/compose.yml: a different file is already there, not one this stage wrote; move it away and run again') }
        $r = Invoke-Stage '05-vps.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Be @("05-place.sh: $($script:Egress)/compose.yml: a different file is already there, not one this stage wrote; move it away and run again")
        $r.Steps | Should -Contain 'placed 18 files on the VPS: 1 new'
        Get-Call 'vps vps 05-services.sh *' | Should -BeNullOrEmpty
    }

    It 'touches nothing when the VPS is not in the tailnet' {
        $c = New-Stage5
        $env:CRIA_FAKE_TAILSCALE = 'no-vps'
        try { $r = Invoke-Stage '05-vps.ps1' $c }
        finally { $env:CRIA_FAKE_TAILSCALE = $null }
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match '^tailnet: '
        Get-Call 'vps *' | Should -BeNullOrEmpty
    }
}

Describe 'Stage 5: checkpoint' {
    It 'passes on a healthy VPS, with the gateway, Kokoro and a search answering this PC' {
        $c = New-Stage5 -Mode Check
        $k = Invoke-Stage '05-vps.ps1' $c
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.What): $($_.Actual)" }) | Should -BeNullOrEmpty
        $k.Status | Should -Be 'passed'
        $k.Checks.Count | Should -Be 14
        Get-Call 'vps *' | Should -Be @("vps vps 05-services.sh check liam $($script:VpsIp)")
        @(Get-Call 'curl *').Count | Should -Be 3
        ($k | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:VpsIp))
    }

    It 'fails on traffic leaving by the VPS''s own address, a stopped service, a public listener and an empty search' {
        $c = New-Stage5 -Mode Check
        $global:CriaFacts['exit-ip'] = 'same'
        $global:CriaFacts['egress-running'] = '5/6'
        $global:CriaFacts['listen-8880'] = 'other'
        $global:CriaSearch = '{"results":[]}'
        $k = Invoke-Stage '05-vps.ps1' $c
        $k.Status | Should -Be 'failed'
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object What) | Should -Be @(
            'owui-web-egress: every service running'
            "exit address inside the tunnel vs the VPS's own"
            'Kokoro (8880) listens on the tailnet address only'
            'from this PC: a SearXNG search returns results')
    }

    It 'fails at once when the VPS does not run the check as root' {
        $c = New-Stage5 -Mode Check
        $global:CriaFake.Vps = { param($Call) New-ExecResult 1 @('sudo: a password is required') }
        $k = Invoke-Stage '05-vps.ps1' $c
        $k.Status | Should -Be 'failed'
        @($k.Checks | ForEach-Object What) | Should -Be @('the VPS answers over ssh as root (sudo -n)')
        Get-Call 'curl *' | Should -BeNullOrEmpty
    }
}
