#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 2 (windows/stages/02-vps.ps1) on a fake PC: ssh, ssh-keyscan and
# tailscale answer from $global:CriaVps, and the VPS scripts from canned
# output (tests/Linux-Stages.Tests.ps1 runs the scripts themselves). Keys,
# addresses and names are made up at run time.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')
    Import-Module (Join-Path $script:RealRepo 'tools/RecoveryVps.psm1') -Force
    $script:Domain = 'example-tailnet' + '.ts' + '.net'
    $script:VpsName = "vps.$script:Domain"
    $script:VpsIp = @('100', '64', '0', '8') -join '.'

    function New-KeyBlob([string]$Type = 'ssh-ed25519') {
        # An SSH public key blob: the type, then random key bytes.
        $ms = [IO.MemoryStream]::new()
        foreach ($part in @([Text.Encoding]::ASCII.GetBytes($Type), [byte[]](1..32 | ForEach-Object { Get-Random -Maximum 256 }))) {
            $len = [BitConverter]::GetBytes([uint32]$part.Length)
            [Array]::Reverse($len)
            $ms.Write($len, 0, 4)
            $ms.Write($part, 0, $part.Length)
        }
        [Convert]::ToBase64String($ms.ToArray())
    }

    function New-Stage2([string]$Mode = 'Run', [string[]]$Accepted = @(), [switch]$WithFingerprint) {
        Reset-Fake
        $c = New-TestContext -Stage 2 -Mode $Mode -Accepted $Accepted
        Initialize-ProtectedFolder -Path $c.StagingRoot
        $ssh = Join-Path $c.Base 'live/ssh'
        $null = New-Item -ItemType Directory -Path $ssh -Force
        $c.RootsPath = Join-Path $c.Base 'recovery-roots.json'
        @{ roots = @{ ssh = @{ kind = 'path'; host = 'pc'; path = $ssh } } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $c.RootsPath
        $script:PcKey = New-KeyBlob
        Set-Content -LiteralPath (Join-Path $ssh 'liam-vps.pub') -Value "ssh-ed25519 $script:PcKey someone@pc"
        $global:CriaVps = @{
            HostName  = $script:VpsName
            Known     = Join-Path $ssh 'known_hosts'
            Ed25519   = New-KeyBlob
            Rsa       = New-KeyBlob 'ssh-rsa'
            LoginCode = 0
            Facts     = [ordered]@{
                'tailscale-ip' = 'match'; docker = '29.8.2'; compose = '5.6.0'; 'nonlocal-bind' = '1'; ufw = 'active'; 'ufw-defaults' = 'yes'
                'ufw-tailscale0' = 'yes'; 'ufw-41641' = 'yes'; 'ufw-other-allow' = '0'; 'ssh-listen' = 'tailnet-only'; 'ssh-password-off' = 'yes'; 'ssh-root-off' = 'yes'
            }
        }
        $script:Fingerprint = Get-SshKeyFingerprint -Blob $global:CriaVps.Ed25519
        if ($WithFingerprint) { $c['HostKey'] = $script:Fingerprint }
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            $v = $global:CriaVps
            switch ($Name) {
                'ssh' {
                    if ($Arguments[0] -eq '-G') { return New-ExecResult 0 @("hostname $($v.HostName)", 'port 22', "userknownhostsfile $($v.Known) $($v.Known)2") }
                    return New-ExecResult $v.LoginCode
                }
                'ssh-keyscan' { return New-ExecResult 0 @("# $($v.HostName):22 SSH-2.0-OpenSSH_9.6p1", "$($v.HostName) ssh-ed25519 $($v.Ed25519)", "$($v.HostName) ssh-rsa $($v.Rsa)") }
                'tailscale' { return New-ExecResult 0 @("pong from vps via DERP(lhr) in 21ms") }
            }
            return New-ExecResult -1
        }
        $global:CriaFake.Vps = {
            param($Call)
            if ($Call.Arguments[0] -eq 'run') { return New-ExecResult 0 @('STEP installed docker-ce=5:29.8.2-1~ubuntu.24.04~noble', 'STEP ufw rules checked', 'FACT docker 29.8.2') }
            return New-ExecResult 0 @($global:CriaVps.Facts.Keys | ForEach-Object { "FACT $_ $($global:CriaVps.Facts[$_])" })
        }
        return $c
    }

    function Get-Call([string]$Pattern) { @($global:CriaCalls | Where-Object { $_ -like $Pattern }) }
}

AfterAll {
    Remove-Variable -Name CriaFake, CriaCalls, CriaVps -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 2: the bootstrap' {
    It 'plans it without writing anything' {
        $c = New-Stage2 -Mode Plan
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'planned'
        $r.Steps | Should -Contain "would write the VPS bootstrap: $(Join-Path $c.StagingRoot 'vps-bootstrap.sh')"
        $r.Asks[0].Id | Should -Be 'vps-bootstrap'
        Test-Path -LiteralPath (Join-Path $c.StagingRoot 'vps-bootstrap.sh') | Should -BeFalse
    }

    It 'writes it owner-only with the PC''s public key, keeps the key out of the evidence, and asks for the console steps' {
        $c = New-Stage2
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Problems | Should -BeNullOrEmpty
        $path = Join-Path $c.StagingRoot 'vps-bootstrap.sh'
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match ([regex]::Escape("K='ssh-ed25519 $script:PcKey ollama-cria'"))
        $text | Should -Match "(?m)^U='liam'$"
        $text | Should -Match 'tailscale up --hostname=vps'
        $text | Should -Not -Match '\{\{|someone@pc|\r'
        Get-ProtectionProblem -Path $path | Should -BeNullOrEmpty
        $owned = @(Get-OwnedItem -State $c.State -Path $path)[0]
        $owned.plaintext | Should -BeTrue
        $owned.retry | Should -Be 'keep'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:PcKey))
        $r.Asks[0].Text | Should -Match 'Accept vps-bootstrap -HostKeyFingerprint'

        $again = Invoke-Stage '02-vps.ps1' (Copy-Context $c 'Run')
        $again.Status | Should -Be 'needs-user'
        $again.Problems | Should -BeNullOrEmpty
    }

    It 'refuses to replace a bootstrap file it did not write' {
        $c = New-Stage2
        Set-Content -LiteralPath (Join-Path $c.StagingRoot 'vps-bootstrap.sh') -Value 'mine'
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'a different file is already there'
    }

    It 'asks for the fingerprint once the bootstrap is done' {
        $c = New-Stage2 -Accepted 'vps-bootstrap'
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match 'host key fingerprint'
        Get-Call 'ssh-keyscan*' | Should -BeNullOrEmpty
    }
}

Describe 'Stage 2: trust and base' {
    It 'files the verified key in place of the old server''s, logs in, sets up the base and passes its checkpoint' {
        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $old = New-KeyBlob
        $other = New-KeyBlob
        [IO.File]::WriteAllText($global:CriaVps.Known, "$($script:VpsName) ssh-ed25519 $old`nother.example ssh-ed25519 $other`n")
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        $r.Data['HostKeyFingerprint'] | Should -Be $script:Fingerprint
        [IO.File]::ReadAllText($global:CriaVps.Known) | Should -Be "other.example ssh-ed25519 $other`n$($script:VpsName) ssh-ed25519 $($global:CriaVps.Ed25519)`n"
        $backup = @(Get-ChildItem -LiteralPath (Split-Path $global:CriaVps.Known) -Filter 'known_hosts.cria-*')
        $backup.Count | Should -Be 1
        [IO.File]::ReadAllText($backup[0].FullName) | Should -Match ([regex]::Escape($old))
        Get-Call 'vps vps 02-base.sh run *' | Should -Be @("vps vps 02-base.sh run liam $($script:VpsIp)")
        $r.Steps | Should -Contain '02-base.sh: ufw rules checked'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:VpsName))

        $check = Copy-Context $c 'Check'
        $check.Data = $r.Data
        $check.Remove('HostKey')
        $k = Invoke-Stage '02-vps.ps1' $check
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.What): $($_.Actual)" }) | Should -BeNullOrEmpty
        $k.Status | Should -Be 'passed'
        $k.Checks.Count | Should -Be 16
    }

    It 'creates known_hosts when there is none' {
        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'done'
        [IO.File]::ReadAllText($global:CriaVps.Known) | Should -Be "$($script:VpsName) ssh-ed25519 $($global:CriaVps.Ed25519)`n"
        (@(Get-OwnedItem -State $c.State -Path $global:CriaVps.Known)[0]).retry | Should -Be 'keep'
    }

    It 'stops on a host key without the fingerprint from the console, changing nothing' {
        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $global:CriaVps.Ed25519 = New-KeyBlob
        [IO.File]::WriteAllText($global:CriaVps.Known, "keep me`n")
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'none of the 2 host keys the VPS offers has the fingerprint'
        [IO.File]::ReadAllText($global:CriaVps.Known) | Should -Be "keep me`n"
        Get-Call 'vps *' | Should -BeNullOrEmpty
        Get-Call 'ssh -o*' | Should -BeNullOrEmpty
    }

    It 'asks when the alias points somewhere other than the new node' {
        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $global:CriaVps.HostName = 'old-vps.example'
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match 'points somewhere other than the new node'
        Get-Call 'ssh-keyscan*' | Should -BeNullOrEmpty
    }

    It 'asks when the VPS is not in the tailnet yet' {
        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $env:CRIA_FAKE_TAILSCALE = 'no-vps'
        try { $r = Invoke-Stage '02-vps.ps1' $c }
        finally { $env:CRIA_FAKE_TAILSCALE = $null }
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match "not in the tailnet as 'vps' yet"
    }

    It 'fails when the key logs in nowhere, and when the base script fails' {
        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $global:CriaVps.LoginCode = 255
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match "'ssh vps' does not log in"

        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $global:CriaFake.Vps = { param($Call) New-ExecResult 1 @('STEP installed curl', 'FAIL could not install nginx (see the log on the VPS)') }
        $r = Invoke-Stage '02-vps.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Be @('02-base.sh: could not install nginx (see the log on the VPS)')
    }

    It 'fails its checkpoint on a firewall that lets more in, or sshd listening everywhere' {
        $c = New-Stage2 -Accepted 'vps-bootstrap' -WithFingerprint
        $r = Invoke-Stage '02-vps.ps1' $c
        $check = Copy-Context $c 'Check'
        $check.Data = $r.Data
        $global:CriaVps.Facts['ufw-other-allow'] = '1'
        $global:CriaVps.Facts['ssh-listen'] = 'other'
        $k = Invoke-Stage '02-vps.ps1' $check
        $k.Status | Should -Be 'failed'
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object What) | Should -Be @('ufw lets in nothing else', 'sshd listens on the tailnet address only')
    }
}
