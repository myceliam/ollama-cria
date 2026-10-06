#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '../tools/Sync-StackFiles.ps1'
    $script:Fakes = Join-Path $PSScriptRoot 'fakes'
    $script:Tailscale = Join-Path $script:Fakes 'fake-tailscale.ps1'
    $script:Ssh = Join-Path $script:Fakes 'fake-ssh.ps1'

    # The same addresses and names tests/fakes/fake-tailscale.ps1 reports,
    # put together at run time so none is ever written to a file.
    $script:Domain = 'example-tailnet' + '.ts' + '.net'
    $script:PcIp = @('100', '64', '0', '7') -join '.'
    $script:VpsIp = @('100', '64', '0', '8') -join '.'
    $script:PcName = "pc.$script:Domain"
    $script:VpsName = "vps.$script:Domain"
    $script:StrayIp = @('100', '64', '9', '9') -join '.'

    # A fake PC source folder, an optional stand-in VPS folder, an empty repo
    # with a manifests folder, and a file list naming them.
    function New-Case {
        param([hashtable]$PcFiles = @{}, [hashtable]$VpsFiles = @{}, [string[]]$ExtraList = @())
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $c = [pscustomobject]@{
            Pc       = Join-Path $base 'pc'
            Vps      = Join-Path $base 'vps'
            Repo     = Join-Path $base 'repo'
            Manifest = Join-Path $base 'stack-files.json'
        }
        New-Item -ItemType Directory -Path $c.Pc, (Join-Path $c.Repo 'manifests') -Force | Out-Null
        foreach ($k in $PcFiles.Keys) {
            $p = Join-Path $c.Pc $k
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            if ($PcFiles[$k] -is [byte[]]) { [IO.File]::WriteAllBytes($p, $PcFiles[$k]) } else { [IO.File]::WriteAllText($p, $PcFiles[$k]) }
        }
        $sources = [Collections.Generic.List[object]]::new()
        $sources.Add([ordered]@{ name = 'stack'; host = 'pc'; root = $c.Pc; repoFolder = 'stack'; purpose = 'test'; files = @(@($PcFiles.Keys | Sort-Object) + $ExtraList) })
        if ($VpsFiles.Count) {
            foreach ($k in $VpsFiles.Keys) {
                $p = Join-Path $c.Vps $k
                New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
                [IO.File]::WriteAllText($p, $VpsFiles[$k])
            }
            $sources.Add([ordered]@{ name = 'vps-egress'; host = 'vps'; root = $c.Vps; repoFolder = 'vps/web-egress'; purpose = 'test'; files = @($VpsFiles.Keys | Sort-Object) })
        }
        [ordered]@{ formatVersion = 1; sources = $sources } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $c.Manifest
        return $c
    }

    function Invoke-Sync($Case, [switch]$Execute, [string]$TailscaleState = '') {
        $env:CRIA_FAKE_TAILSCALE = $TailscaleState
        try {
            & $script:Tool -ManifestPath $Case.Manifest -RepoPath $Case.Repo -Execute:$Execute -PassThru `
                -TailscaleCommand $script:Tailscale -SshCommand $script:Ssh
        }
        finally { $env:CRIA_FAKE_TAILSCALE = $null }
    }

    function Get-RepoText($Case, [string]$Rel) { [IO.File]::ReadAllText((Join-Path $Case.Repo $Rel)) }
}

Describe 'Sync-StackFiles.ps1 on the PC side' {
    It 'plans without writing, and names the placeholders each file will hold' {
        $c = New-Case -PcFiles @{ 'docker-compose.yml' = "ports:`n  - `"$($script:PcIp):3001:3001`"`n" }
        $r = Invoke-Sync $c
        $r.IsValid | Should -BeTrue
        $r.Mode | Should -Be 'Plan'
        $r.Rows[0].Status | Should -Be 'new'
        $r.Rows[0].Placeholders | Should -Be @('PC_TS_IP')
        Test-Path (Join-Path $c.Repo 'stack') | Should -BeFalse
        Test-Path (Join-Path $c.Repo 'manifests/endpoints.json') | Should -BeFalse
    }

    It 'writes templated files with the line endings .gitattributes wants, and the endpoint list' {
        $bom = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("`$vps = '$($script:VpsName)'`r`n`$ip = '$($script:VpsIp)'`r`n"))
        $c = New-Case -PcFiles @{
            'docker-compose.yml' = "CORS: `"https://$($script:PcName);http://127.0.0.1:3000`"`r`nVPS_HOST: `"$($script:VpsIp)`"`r`n"
            'tools/push-vps.ps1' = $bom
            'notes.txt'          = "*.$($script:Domain) and {{.Names}} stay {{.Names}}`n"
        }
        $r = Invoke-Sync $c -Execute
        $r.IsValid | Should -BeTrue
        @($r.Rows | Where-Object Status -EQ 'new').Count | Should -Be 3
        $compose = Get-RepoText $c 'stack/docker-compose.yml'
        $compose | Should -Be "CORS: `"https://{{PC_TS_NAME}};http://127.0.0.1:3000`"`nVPS_HOST: `"{{VPS_TS_IP}}`"`n"
        $ps = [IO.File]::ReadAllBytes((Join-Path $c.Repo 'stack/tools/push-vps.ps1'))
        $ps[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [Text.Encoding]::UTF8.GetString($ps, 3, $ps.Length - 3) | Should -Be "`$vps = '{{VPS_TS_NAME}}'`r`n`$ip = '{{VPS_TS_IP}}'`r`n"
        Get-RepoText $c 'stack/notes.txt' | Should -Be "*.{{TS_DOMAIN}} and {{.Names}} stay {{.Names}}`n"
        $list = Get-Content (Join-Path $c.Repo 'manifests/endpoints.json') -Raw | ConvertFrom-Json
        $list.files.file | Should -Be @('stack/docker-compose.yml', 'stack/notes.txt', 'stack/tools/push-vps.ps1')
        $list.files[0].placeholders | Should -Be @('PC_TS_NAME', 'VPS_TS_IP')
        $r.EndpointsWritten | Should -BeTrue
    }

    It 'reports nothing to do on a second run, and ignores a checkout''s CRLF line endings' {
        $c = New-Case -PcFiles @{ 'a.yml' = "host: $($script:PcIp)`nb: 1`n" }
        (Invoke-Sync $c -Execute).IsValid | Should -BeTrue
        $p = Join-Path $c.Repo 'stack/a.yml'
        [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace "`n", "`r`n"))
        $r = Invoke-Sync $c -Execute
        $r.Rows[0].Status | Should -Be 'unchanged'
        $r.EndpointsWritten | Should -BeFalse
        [IO.File]::ReadAllText($p) | Should -Match "`r`n"
    }

    It 'marks a changed file and rewrites it' {
        $c = New-Case -PcFiles @{ 'a.yml' = "b: 1`n" }
        (Invoke-Sync $c -Execute).IsValid | Should -BeTrue
        [IO.File]::WriteAllText((Join-Path $c.Pc 'a.yml'), "b: 2`n")
        $r = Invoke-Sync $c -Execute
        $r.Rows[0].Status | Should -Be 'changed'
        Get-RepoText $c 'stack/a.yml' | Should -Be "b: 2`n"
    }

    It 'stops on a secret-shaped value, names the file, line and rule, and writes nothing' {
        $secret = 'sk-' + ('Q' * 40)
        $c = New-Case -PcFiles @{ 'ok.yml' = "a: 1`n"; 'bad.py' = "x = 1`nkey = '$secret'`n" }
        $r = Invoke-Sync $c -Execute
        $r.IsValid | Should -BeFalse
        $r.Problems | Should -Contain 'stack/bad.py:2: API key (sk-)'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($secret))
        Test-Path (Join-Path $c.Repo 'stack') | Should -BeFalse
    }

    It 'stops on a tailnet address that is no node any more' {
        $c = New-Case -PcFiles @{ 'relay.py' = "VPS = '$($script:StrayIp)'`n" }
        $r = Invoke-Sync $c -Execute
        $r.IsValid | Should -BeFalse
        $r.Problems | Should -Contain 'stack/relay.py:1: tailnet IP (use {{PC_TS_IP}} or {{VPS_TS_IP}})'
    }

    It 'does not template part of a longer address' {
        $longer = $script:PcIp + '0'
        $c = New-Case -PcFiles @{ 'a.yml' = "x: $longer`n" }
        $r = Invoke-Sync $c
        $r.IsValid | Should -BeFalse
        $r.Problems | Should -Contain 'stack/a.yml:1: tailnet IP (use {{PC_TS_IP}} or {{VPS_TS_IP}})'
    }

    It 'refuses a file that already holds an endpoint placeholder' {
        $c = New-Case -PcFiles @{ 'a.yml' = "x: '{{VPS_TS_IP}}'`n" }
        $r = Invoke-Sync $c
        $r.Problems | Should -Contain 'stack/a.yml: it already holds {{VPS_TS_IP}}, which would be filled in at restore time'
    }

    It 'refuses a missing file, text that is not UTF-8, UTF-16 text and a file the scan forbids by name' {
        $c = New-Case -PcFiles @{
            'latin.txt' = [byte[]](0x63, 0x61, 0x66, 0xE9)
            'wide.ps1'  = [byte[]](0xFF, 0xFE, 0x61, 0x00)
        } -ExtraList @('gone.yml')
        $r = Invoke-Sync $c
        $r.Problems | Should -Contain 'stack/gone.yml: not found on the PC'
        (Invoke-Sync (New-Case -PcFiles @{ 'latin.txt' = [byte[]](0x63, 0x61, 0x66, 0xE9) })).Problems | Should -Contain 'stack/latin.txt: not UTF-8 text'
        (Invoke-Sync (New-Case -PcFiles @{ 'wide.ps1' = [byte[]](0xFF, 0xFE, 0x61, 0x00) })).Problems | Should -Contain 'stack/wide.ps1: UTF-16 text; save it as UTF-8 and run again'
        (Invoke-Sync (New-Case -PcFiles @{ 'state.db' = 'x' })).Problems | Should -Contain 'stack/state.db: forbidden file: database file'
    }

    It 'refuses a symbolic link' -Skip:$IsWindows {
        $c = New-Case -PcFiles @{ 'real.yml' = "a: 1`n" } -ExtraList @('link.yml')
        New-Item -ItemType SymbolicLink -Path (Join-Path $c.Pc 'link.yml') -Target (Join-Path $c.Pc 'real.yml') | Out-Null
        $r = Invoke-Sync $c
        $r.IsValid | Should -BeFalse
        @($r.Problems | Where-Object { $_ -like 'stack/link.yml: *' }).Count | Should -Be 1
    }

    It 'leaves a repo file the list no longer names, and says so' {
        $c = New-Case -PcFiles @{ 'a.yml' = "a: 1`n" }
        New-Item -ItemType Directory -Path (Join-Path $c.Repo 'stack') | Out-Null
        Set-Content -LiteralPath (Join-Path $c.Repo 'stack/old.yml') -Value 'x'
        $r = Invoke-Sync $c -Execute
        $r.IsValid | Should -BeTrue
        $r.Warnings | Should -Contain 'stack/old.yml: in the repo but not in the file list; left as it is'
        Test-Path (Join-Path $c.Repo 'stack/old.yml') | Should -BeTrue
    }

    It 'stops when Tailscale cannot be read or the VPS is not in the tailnet' {
        $c = New-Case -PcFiles @{ 'a.yml' = "a: 1`n" }
        (Invoke-Sync $c -TailscaleState 'down').Problems | Should -Contain 'tailnet: ''tailscale status --json'' failed; is Tailscale running and signed in?'
        (Invoke-Sync $c -TailscaleState 'no-vps').Problems | Should -Contain 'tailnet: expected one node named ''vps'' in the tailnet, found 0'
    }

    It 'refuses a file list with two sources in one repo folder, or names that differ only in case' {
        $c = New-Case -PcFiles @{ 'a.yml' = "a: 1`n" }
        $doc = Get-Content $c.Manifest -Raw | ConvertFrom-Json -AsHashtable
        $doc.sources += [ordered]@{ name = 'more'; host = 'pc'; root = $c.Pc; repoFolder = 'stack/sub'; purpose = 'test'; files = @('a.yml', 'A.yml') }
        $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $c.Manifest
        $r = Invoke-Sync $c
        $r.Problems | Should -Contain 'file list: source ''more'' shares its repo folder with another source'
        $r.Problems | Should -Contain 'file list: ''stack/sub/A.yml'' is listed twice (names differ only in case)'
    }
}

Describe 'Sync-StackFiles.ps1 on the VPS side' -Skip:$IsWindows {
    It 'reads VPS files through ssh and templates them' {
        $c = New-Case -PcFiles @{ 'a.yml' = "a: 1`n" } -VpsFiles @{ 'guard.nft' = "ip saddr $($script:PcIp) accept`n"; 'engines/x.py' = "x = 1`n" }
        $r = Invoke-Sync $c -Execute
        $r.IsValid | Should -BeTrue
        Get-RepoText $c 'vps/web-egress/guard.nft' | Should -Be "ip saddr {{PC_TS_IP}} accept`n"
        Get-RepoText $c 'vps/web-egress/engines/x.py' | Should -Be "x = 1`n"
    }

    It 'refuses a missing VPS file and a link on the VPS' {
        $c = New-Case -PcFiles @{ 'a.yml' = "a: 1`n" } -VpsFiles @{ 'real.yml' = "a: 1`n" }
        New-Item -ItemType SymbolicLink -Path (Join-Path $c.Vps 'link.yml') -Target (Join-Path $c.Vps 'real.yml') | Out-Null
        $doc = Get-Content $c.Manifest -Raw | ConvertFrom-Json -AsHashtable
        $doc.sources[1].files = @('gone.yml', 'link.yml', 'real.yml')
        $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $c.Manifest
        $r = Invoke-Sync $c
        $r.Problems | Should -Contain 'vps/web-egress/gone.yml: not found on the VPS'
        $r.Problems | Should -Contain 'vps/web-egress/link.yml: a symbolic link on the way on the VPS'
    }

    It 'stops when ssh fails' {
        $c = New-Case -PcFiles @{ 'a.yml' = "a: 1`n" } -VpsFiles @{ 'b.yml' = "b: 1`n" }
        $env:CRIA_FAKE_TAILSCALE = ''
        try {
            $r = & $script:Tool -ManifestPath $c.Manifest -RepoPath $c.Repo -PassThru -TailscaleCommand $script:Tailscale -SshCommand (Join-Path $script:Fakes 'fake-ssh-fails.ps1')
        }
        finally { $env:CRIA_FAKE_TAILSCALE = $null }
        @($r.Problems | Where-Object { $_ -like 'vps-egress: the VPS read failed*' }).Count | Should -Be 1
    }
}

Describe 'StackCapture.psm1' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../tools/StackCapture.psm1') -Force
        $script:Endpoint = [ordered]@{ PC_TS_IP = $script:PcIp; VPS_TS_IP = $script:VpsIp; PC_TS_NAME = $script:PcName; VPS_TS_NAME = $script:VpsName; TS_DOMAIN = $script:Domain }
    }

    It 'templates whole addresses and names only, in any case, and renders them back' {
        $text = "a $($script:PcIp) b $($script:PcIp)0 c $($script:PcName.ToUpperInvariant()) d my$($script:PcName) e"
        $t = ConvertTo-StackTemplate -Text $text -Endpoint $script:Endpoint
        $t.Text | Should -Be "a {{PC_TS_IP}} b $($script:PcIp)0 c {{PC_TS_NAME}} d mypc.{{TS_DOMAIN}} e"
        $t.Placeholders | Should -Be @('PC_TS_IP', 'PC_TS_NAME', 'TS_DOMAIN')
        ConvertFrom-StackTemplate -Text $t.Text -Endpoint $script:Endpoint | Should -Be "a $($script:PcIp) b $($script:PcIp)0 c $($script:PcName) d my$($script:PcName) e"
    }

    It 'renders only endpoint placeholders and fails on one with no value' {
        ConvertFrom-StackTemplate -Text '{{.Names}} {{OTHER}} {{PC_TS_IP}}' -Endpoint $script:Endpoint | Should -Be "{{.Names}} {{OTHER}} $($script:PcIp)"
        { ConvertFrom-StackTemplate -Text '{{FOLD_TS_IP}}' -Endpoint $script:Endpoint } | Should -Throw '*{{FOLD_TS_IP}} has no value*'
    }

    It 'names nodes the same way the collector always has' {
        $env:CRIA_FAKE_TAILSCALE = ''
        try { $e = Get-TailnetEndpoint -SshHost 'vps' -TailscaleCommand $script:Tailscale }
        finally { $env:CRIA_FAKE_TAILSCALE = $null }
        @($e.Keys) | Should -Be @('PC_TS_IP', 'PC_TS_IP6', 'PC_TS_NAME', 'VPS_TS_IP', 'VPS_TS_IP6', 'VPS_TS_NAME', 'FOLD_TS_IP', 'FOLD_TS_IP6', 'FOLD_TS_NAME', 'EXT_GB_LON_WG_001_TS_IP', 'EXT_GB_LON_WG_001_TS_NAME', 'TS_DOMAIN')
    }
}

Describe 'This repo' {
    It 'has a stack file list that matches its schema and names no secret files' {
        $list = Join-Path $PSScriptRoot '../manifests/stack-files.json'
        Test-Json -Path $list -SchemaFile (Join-Path $PSScriptRoot '../manifests/schemas/stack-files.schema.json') | Should -BeTrue
        $files = (Get-Content $list -Raw | ConvertFrom-Json).sources.files
        @($files | Where-Object { $_ -match '(^|/)(\.env|secrets/)|\.(db|sqlite|key|pem|zip)$|kais_chat_tidy' }) | Should -BeNullOrEmpty
    }

    It 'has a current manifests/endpoints.json' {
        Import-Module (Join-Path $PSScriptRoot '../tools/StackCapture.psm1') -Force
        Export-EndpointManifest -RepoPath (Join-Path $PSScriptRoot '..') -Check | Should -BeTrue
    }
}
