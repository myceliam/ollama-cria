#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../tools/RecoveryVps.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../tools/RecoveryState.psm1') -Force

    function New-HostKey {
        # A real key pair from ssh-keygen, in the test drive.
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        & ssh-keygen -q -t ed25519 -N '' -C test -f $p | Out-Null
        $type, $blob, $null = (Get-Content -LiteralPath "$p.pub" -Raw).Trim() -split ' '
        [pscustomobject]@{ Path = $p; Type = $type; Blob = $blob }
    }
}

Describe 'RecoveryVps.psm1: keys and known_hosts' {
    It 'computes a fingerprint the way ssh-keygen does' -Skip:(-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        $k = New-HostKey
        $expected = ((& ssh-keygen -l -E sha256 -f "$($k.Path).pub") -split ' ')[1]
        Get-SshKeyFingerprint -Blob $k.Blob | Should -BeExactly $expected
    }

    It 'finds keys filed under a hashed host name' -Skip:(-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        $k = New-HostKey
        $known = Join-Path $TestDrive 'hashed_known_hosts'
        Set-Content -LiteralPath $known -Value "vps.example $($k.Type) $($k.Blob)`nother.example $($k.Type) $($k.Blob)"
        & ssh-keygen -q -H -f $known 2>$null | Out-Null
        $text = Get-Content -LiteralPath $known -Raw
        $text | Should -Not -Match 'vps\.example'
        @(Get-KnownHostKey -Text $text -Token 'vps.example').Count | Should -Be 1
        @(Get-KnownHostKey -Text $text -Token 'VPS.example').Count | Should -Be 1
        @(Get-KnownHostKey -Text $text -Token 'nowhere.example').Count | Should -Be 0
    }

    It 'reads ssh-keyscan output, skipping comments and lines that are not keys' {
        $keys = @(Read-ScannedHostKey -Line @('# vps:22 SSH-2.0-OpenSSH_9.6', 'vps ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA==', 'vps ssh-dss AAAA', 'garbage'))
        $keys.Count | Should -Be 1
        $keys[0].Type | Should -Be 'ssh-ed25519'
        $keys[0].Fingerprint | Should -Match '^SHA256:[A-Za-z0-9+/]{43}$'
    }

    It 'files a host under its alias, its name, or [name]:port' {
        Get-KnownHostToken -Config @{ HostName = 'vps.example'; Port = 22; HostKeyAlias = $null } | Should -Be 'vps.example'
        Get-KnownHostToken -Config @{ HostName = 'vps.example'; Port = 2222; HostKeyAlias = $null } | Should -Be '[vps.example]:2222'
        Get-KnownHostToken -Config @{ HostName = 'vps.example'; Port = 2222; HostKeyAlias = 'vps' } | Should -Be 'vps'
    }

    It 'swaps only the keys filed under the host, keeps everything else and its line endings, and backs up' {
        $path = Join-Path $TestDrive 'known_hosts'
        $backup = "$path.bak"
        $new = [pscustomobject]@{ Type = 'ssh-ed25519'; Blob = 'TkVX' }
        $before = "# mine`r`n@cert-authority *.example ssh-ed25519 Q0E=`r`nvps.example,old.example ssh-ed25519 T0xE`r`nother.example ssh-ed25519 T1RI`r`n"
        [IO.File]::WriteAllText($path, $before)
        $plan = Update-KnownHostFile -Path $path -Token 'vps.example' -Key $new -BackupPath $backup -WhatIf
        $plan.Removed | Should -Be 1
        $plan.Added | Should -Be 1
        [IO.File]::ReadAllText($path) | Should -Be $before

        $u = Update-KnownHostFile -Path $path -Token 'vps.example' -Key $new -BackupPath $backup
        $u.Changed | Should -BeTrue
        [IO.File]::ReadAllText($path) | Should -Be "# mine`r`n@cert-authority *.example ssh-ed25519 Q0E=`r`nother.example ssh-ed25519 T1RI`r`nvps.example ssh-ed25519 TkVX`r`n"
        [IO.File]::ReadAllText($backup) | Should -Be $before
        (Update-KnownHostFile -Path $path -Token 'vps.example' -Key $new -BackupPath "$path.bak2").Changed | Should -BeFalse
        Test-Path "$path.bak2" | Should -BeFalse
    }

    It 'reads the alias from ssh -G' {
        $machine = @{ Exec = { param($Name, $Arguments) [pscustomobject]@{ ExitCode = 0; Output = @('user liam', 'hostname vps.example', 'port 2222', 'hostkeyalias none', 'userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2') } } }
        $c = Get-SshHostConfig -Machine $machine -Alias 'vps'
        $c.HostName | Should -Be 'vps.example'
        $c.Port | Should -Be 2222
        $c.HostKeyAlias | Should -BeNullOrEmpty
        $c.KnownHosts | Should -Be ([IO.Path]::GetFullPath((Join-Path $HOME '.ssh/known_hosts')))
        $failing = @{ Exec = { param($Name, $Arguments) [pscustomobject]@{ ExitCode = 255; Output = @() } } }
        Get-SshHostConfig -Machine $failing -Alias 'vps' | Should -BeNullOrEmpty
    }
}

Describe 'RecoveryVps.psm1: running scripts on the VPS' {
    It 'refuses an argument that is not a plain word' {
        $machine = @{ Ssh = { throw 'not reached' } }
        $script = Join-Path $TestDrive 'x.sh'
        Set-Content -LiteralPath $script -Value 'echo hi'
        { Invoke-VpsScript -Machine $machine -Alias vps -Path $script -Arguments 'a b' } | Should -Throw '*not a plain word*'
        { Invoke-VpsScript -Machine $machine -Alias vps -Path $script -Arguments "a'b" } | Should -Throw '*not a plain word*'
    }

    It 'runs the script as root with its arguments and input, and removes it afterwards' -Skip:$IsWindows {
        # bash stands in for ssh; a sudo on PATH drops -n and runs the rest.
        $bin = Join-Path $TestDrive 'sudo-bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        [IO.File]::WriteAllText((Join-Path $bin 'sudo'), "#!/usr/bin/env bash`n[ `"`$1`" = -n ] && shift`nexec `"`$@`"`n")
        & chmod 755 (Join-Path $bin 'sudo')
        $script = Join-Path $TestDrive 'probe.sh'
        [IO.File]::WriteAllText($script, "set -eu`r`nprintf 'STEP args %s\n' `"`$*`"`r`nwhile read -r l; do printf 'STEP input %s\n' `"`$(printf '%s' `"`$l`" | tr -d '\r')`"; done`r`nprintf 'FACT self %s\n' `"`$0`"`r`n")
        $machine = @{
            Ssh = {
                param($Alias, $Remote, $InputLines)
                $saved = $env:PATH
                $env:PATH = "${bin}:$saved"
                try { $out = @(@($InputLines) | & bash -c $Remote 2>&1 | ForEach-Object { "$_" }) } finally { $env:PATH = $saved }
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
            }.GetNewClosure()
        }
        $ip = @('100', '64', '0', '8') -join '.'
        $r = Invoke-VpsScript -Machine $machine -Alias vps -Path $script -Arguments 'run', 'liam', $ip -InputLines 'one', 'two'
        $r.ExitCode | Should -Be 0
        $result = New-StageResult
        $facts = Add-VpsOutput -Result $result -Run $r -Label 'probe'
        $result.Steps | Should -Be @("probe: args run liam $ip", 'probe: input one', 'probe: input two')
        Test-Path -LiteralPath $facts['self'] | Should -BeFalse
    }

    It 'turns STEP, WARN, FAIL and FACT lines into a stage result' {
        $result = New-StageResult
        $facts = Add-VpsOutput -Result $result -Label 's' -Run ([pscustomobject]@{ ExitCode = 1; Output = @('noise', 'STEP did a', 'WARN odd b', 'FACT docker 29.8.2', 'FAIL broke c') })
        $result.Steps | Should -Be @('s: did a')
        $result.Warnings | Should -Be @('s: odd b')
        $result.Problems | Should -Be @('s: broke c')
        $facts['docker'] | Should -Be '29.8.2'

        $result = New-StageResult
        $null = Add-VpsOutput -Result $result -Label 's' -Run ([pscustomobject]@{ ExitCode = 1; Output = @('sudo: a password is required') })
        $result.Problems | Should -Be @('s: the VPS script stopped (sudo -n refused; does the account have passwordless sudo (the bootstrap gives it)?)')
    }
}
