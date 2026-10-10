#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The VPS stage scripts (linux/stages/*.sh) run with bash against a fake
# machine: every system tool they call is tests/fakes/fake-linux-tools.sh,
# and every file they write lands under CRIA_ROOT in the test drive. Linux
# only (they need bash and its tools).

BeforeAll {
    $script:Stages = Join-Path $PSScriptRoot '../linux/stages'
    $script:FakeTools = Join-Path $PSScriptRoot 'fakes/fake-linux-tools.sh'
    $script:TsIp = @('100', '64', '0', '8') -join '.'
    $script:Tools = 'id', 'tailscale', 'dpkg-query', 'apt-get', 'curl', 'gpg', 'systemctl', 'sysctl', 'ufw', 'sshd', 'docker', 'ss', 'chown', 'nft', 'ip', 'nginx',
    'systemd-run', 'timeout'

    function New-Box {
        # A fresh Ubuntu 24.04 server with the account and Tailscale up.
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $bin = Join-Path $root 'fakebin'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'etc'), (Join-Path $root 'fake'), $bin -Force
        foreach ($t in $script:Tools) {
            $w = Join-Path $bin $t
            [IO.File]::WriteAllText($w, "#!/usr/bin/env bash`nexec bash '$($script:FakeTools)' $t `"`$@`"`n")
            & chmod 755 $w
        }
        Set-Content -LiteralPath (Join-Path $root 'etc/os-release') -Value "ID=ubuntu`nVERSION_ID=24.04`nPRETTY_NAME=`"Ubuntu 24.04.5 LTS`""
        $box = [pscustomobject]@{ Root = $root; Bin = $bin; Fake = (Join-Path $root 'fake') }
        Set-Fake $box 'users' 'liam'
        Set-Fake $box 'tailscale-ip' $script:TsIp
        Set-Fake $box 'download' 'GOOD-KEY'
        Set-Fake $box 'installed' "ca-certificates ubuntu`niproute2 ubuntu"
        Set-Fake $box 'docker-version' '29.8.2'
        Set-Fake $box 'ssh-listen' $script:TsIp
        # Ubuntu 24.04 listens for SSH through ssh.socket.
        Set-Fake $box 'enabled' 'ssh.socket'
        return $box
    }

    function Set-Fake($Box, [string]$Name, [string]$Text) { Set-Content -LiteralPath (Join-Path $Box.Fake $Name) -Value $Text }
    function Get-Fake($Box, [string]$Name) { $p = Join-Path $Box.Fake $Name; if (Test-Path $p) { @(Get-Content -LiteralPath $p) } else { @() } }

    function Invoke-Box($Box, [string]$Script, [string[]]$Arguments, [string[]]$InputLines = @()) {
        $saved = $env:PATH
        $env:PATH = "$($Box.Bin):$saved"
        $env:CRIA_ROOT = $Box.Root
        try { $out = @(@($InputLines) | & bash (Join-Path $script:Stages $Script) @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
        finally { $env:PATH = $saved; $env:CRIA_ROOT = $null }
        [pscustomobject]@{ ExitCode = $code; Output = $out; Steps = @($out | Where-Object { $_ -like 'STEP *' }) }
    }

    function Get-BoxFile($Box, [string]$Path) { [IO.File]::ReadAllText((Join-Path $Box.Root $Path.TrimStart('/'))) }

    function Set-BoxFile($Box, [string]$Path, [string]$Text) {
        $p = Join-Path $Box.Root $Path.TrimStart('/')
        $null = New-Item -ItemType Directory -Path (Split-Path $p) -Force
        [IO.File]::WriteAllText($p, $Text)
    }

    function New-PlaceLine([string]$Path, [string]$Text, [string]$Mode = '0644', [string]$Owner = 'liam') {
        # One input line for 05-place.sh, as windows/stages/05-vps.ps1 builds it.
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        "$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Path))) $Mode $Owner $sha $([Convert]::ToBase64String($bytes))"
    }

    function New-PlacedBox {
        # A box after 05-place.sh: every file 05-services.sh needs.
        $b = New-Box
        $egress = '/home/liam/owui-web-egress'
        foreach ($f in '.env', 'compose.yml', 'guard.sh', 'guard.nft', 'jina-official/Dockerfile', 'searxng-mcp/Dockerfile') { Set-BoxFile $b "$egress/$f" 'x' }
        foreach ($f in '/home/liam/kokoro/compose.yml', '/etc/systemd/system/owui-web-egress-guard.service',
            '/etc/systemd/system/docker.service.d/owui-web-egress.conf', '/etc/nginx/sites-available/groq-relay', '/dev/net/tun') { Set-BoxFile $b $f 'x' }
        $null = New-Item -ItemType Directory -Path (Join-Path $b.Root 'etc/nginx/sites-enabled') -Force
        & ln -s /etc/nginx/sites-available/default (Join-Path $b.Root 'etc/nginx/sites-enabled/default')
        Set-Fake $b 'services-owui-web-egress' "gluetun`nsearxng`njina-reader"
        Set-Fake $b 'services-kokoro' 'kokoro-tts'
        return $b
    }

    $script:Digest = 'ab' * 32
    $script:Images = @(
        "pull qmcgaw/gluetun@sha256:$($script:Digest) qmcgaw/gluetun:v3"
        "pull python@sha256:$('cd' * 32) -"
        'build jina-reader-official-hardened:2026-09-24 /home/liam/owui-web-egress/jina-official'
        'build searxng-mcp:1.6.0 /home/liam/owui-web-egress/searxng-mcp'
    )
}

Describe '02-base.sh run' -Skip:$IsWindows {
    It 'sets up a fresh server as the live VPS is, then changes nothing on a second run' {
        $b = New-Box
        $r = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        $r.Output | Should -Not -Match '^FAIL'
        $r.ExitCode | Should -Be 0
        $installed = Get-Fake $b 'installed'
        $installed | Should -Contain 'docker-ce 5:29.8.2-1~ubuntu.24.04~noble'
        $installed | Should -Contain 'docker-compose-plugin 5.6.0-1~ubuntu.24.04~noble'
        foreach ($p in 'nftables', 'nginx', 'jq', 'unattended-upgrades', 'ufw', 'curl', 'gnupg') { ($installed -match "^$p ") | Should -Not -BeNullOrEmpty }
        ($installed -match '^sqlite3 ') | Should -BeNullOrEmpty
        Get-BoxFile $b '/etc/apt/keyrings/docker.asc' | Should -Match 'GOOD-KEY'
        Get-BoxFile $b '/etc/apt/sources.list.d/docker.sources' | Should -Match 'Signed-By: /etc/apt/keyrings/docker.asc'
        Get-BoxFile $b '/etc/sysctl.d/99-nginx-tailnet-bind.conf' | Should -Be "net.ipv4.ip_nonlocal_bind = 1`n"
        Get-BoxFile $b '/etc/systemd/networkd.conf.d/10-ollama-cria.conf' | Should -Match '(?m)^\[Network\]\nManageForeignRoutingPolicyRules=no$'
        $sshd = Get-BoxFile $b '/etc/ssh/sshd_config.d/00-liam-hardening.conf'
        $sshd | Should -Match "(?m)^ListenAddress $([regex]::Escape($script:TsIp))$"
        $sshd | Should -Match '(?m)^PasswordAuthentication no$'
        $sshd | Should -Match '(?m)^PermitRootLogin no$'
        Get-Fake $b 'ufw-defaults' | Should -Be 'deny (incoming), allow (outgoing), deny (routed)'
        Get-Fake $b 'ufw-rules' | Should -HaveCount 2
        Test-Path (Join-Path $b.Fake 'ufw-active') | Should -BeTrue
        Get-Fake $b 'active' | Should -Contain 'ssh.socket' -Because 'ssh.socket reads ListenAddress when it starts'
        $r.Output | Should -Contain 'FACT docker 29.8.2'

        $again = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        $again.ExitCode | Should -Be 0
        $again.Steps | Should -Be @('STEP ufw rules checked')
    }

    It 'stops before changing anything on a server whose tailnet address is not the one the PC sees' {
        $b = New-Box
        Set-Fake $b 'tailscale-ip' (@('100', '64', '0', '99') -join '.')
        $r = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        $r.ExitCode | Should -Be 1
        $r.Output[-1] | Should -Match '^FAIL .*not the one the PC sees'
        Get-Fake $b 'calls' | Where-Object { $_ -notmatch '^(id|tailscale) ' } | Should -BeNullOrEmpty
    }

    It 'refuses an apt key without Docker''s fingerprint' {
        $b = New-Box
        Set-Fake $b 'download' 'SOMEONE-ELSES-KEY'
        $r = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        $r.ExitCode | Should -Be 1
        $r.Output[-1] | Should -Match "^FAIL Docker's apt key does not have Docker's fingerprint"
        Test-Path (Join-Path $b.Root 'etc/apt/keyrings/docker.asc') | Should -BeFalse
        Test-Path (Join-Path $b.Root 'etc/apt/keyrings/docker.asc.new') | Should -BeFalse
    }

    It 'puts the old sshd settings back when sshd rejects the new ones' {
        $b = New-Box
        $dir = Join-Path $b.Root 'etc/ssh/sshd_config.d'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir '00-liam-hardening.conf') -Value 'PermitRootLogin no'
        Set-Fake $b 'sshd-t' '1'
        $r = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        $r.ExitCode | Should -Be 1
        $r.Output[-1] | Should -Match '^FAIL sshd rejected the new settings'
        Get-BoxFile $b '/etc/ssh/sshd_config.d/00-liam-hardening.conf' | Should -Be "PermitRootLogin no`n"
        Get-Fake $b 'active' | Should -Not -Contain 'ssh.socket'
    }

    It 'leaves a Docker that is already at another version, with a warning' {
        $b = New-Box
        Set-Fake $b 'installed' "ca-certificates ubuntu`ncurl ubuntu`ngnupg ubuntu`ndocker-ce 5:30.0.0-1~ubuntu.24.04~noble"
        $r = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Contain 'WARN docker-ce is at 5:30.0.0-1~ubuntu.24.04~noble, not 5:29.8.2-1~ubuntu.24.04~noble as on the live VPS; left as it is'
        Get-Fake $b 'installed' | Should -Not -Contain 'docker-ce 5:29.8.2-1~ubuntu.24.04~noble'
    }

    It 'refuses bad arguments' {
        $b = New-Box
        (Invoke-Box $b '02-base.sh' @('run', 'liam', '10.0.0.1')).Output[-1] | Should -Be 'FAIL not a tailnet IPv4 address'
        (Invoke-Box $b '02-base.sh' @('run', 'Liam Rooney', $script:TsIp)).Output[-1] | Should -Be 'FAIL not an account name'
        (Invoke-Box $b '02-base.sh' @('go', 'liam', $script:TsIp)).Output[-1] | Should -Match '^FAIL usage'
        (Invoke-Box $b '02-base.sh' @('run', 'kai', $script:TsIp)).Output[-1] | Should -Match '^FAIL there is no account kai'
    }
}

Describe '02-base.sh check' -Skip:$IsWindows {
    It 'reports the facts the checkpoint reads, and changes nothing' {
        $b = New-Box
        $null = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        Remove-Item -LiteralPath (Join-Path $b.Fake 'calls')
        $r = Invoke-Box $b '02-base.sh' @('check', 'liam', $script:TsIp)
        $r.ExitCode | Should -Be 0
        $facts = @{}
        foreach ($l in $r.Output) { if ($l -match '^FACT (\S+) ?(.*)$') { $facts[$Matches[1]] = $Matches[2] } }
        $facts['docker'] | Should -Be '29.8.2'
        $facts['ufw'] | Should -Be 'active'
        $facts['ufw-defaults'] | Should -Be 'yes'
        $facts['ufw-tailscale0'] | Should -Be 'yes'
        $facts['ufw-41641'] | Should -Be 'yes'
        $facts['ufw-other-allow'] | Should -Be '0'
        $facts['ssh-listen'] | Should -Be 'tailnet-only'
        $facts['ssh-password-off'] | Should -Be 'yes'
        $facts['nonlocal-bind'] | Should -Be '1'
        $facts['networkd-keeps-rules'] | Should -Be 'yes'
        $facts.ContainsKey('missing') | Should -BeFalse
        Get-Fake $b 'calls' | Where-Object { $_ -match '^(apt-get|ufw (allow|default|--force)|systemctl (enable|start|restart)|curl) ' } | Should -BeNullOrEmpty
    }

    It 'notices another open port and sshd listening everywhere' {
        $b = New-Box
        $null = Invoke-Box $b '02-base.sh' @('run', 'liam', $script:TsIp)
        Add-Content -LiteralPath (Join-Path $b.Fake 'ufw-rules') -Value '22/tcp                     ALLOW IN    Anywhere'
        Set-Fake $b 'ssh-listen' "0.0.0.0`n$($script:TsIp)"
        $r = Invoke-Box $b '02-base.sh' @('check', 'liam', $script:TsIp)
        $r.Output | Should -Contain 'FACT ufw-other-allow 1'
        $r.Output | Should -Contain 'FACT ssh-listen other'
    }
}

Describe '05-place.sh' -Skip:$IsWindows {
    It 'places new files with their mode, then leaves the same, replaces its own, and refuses one changed on the VPS' {
        $b = New-Box
        $null = New-Item -ItemType Directory -Path (Join-Path $b.Root 'home/liam') -Force
        $lines = @(
            (New-PlaceLine '/home/liam/owui-web-egress/compose.yml' "name: x`n")
            (New-PlaceLine '/home/liam/owui-web-egress/guard.sh' "#!/bin/bash`n" '0755')
            (New-PlaceLine '/home/liam/owui-web-egress/searxng-mcp/Dockerfile' "FROM x`n")
            (New-PlaceLine '/etc/systemd/system/docker.service.d/owui-web-egress.conf' "[Unit]`n" '0644' 'root')
        )
        $r = Invoke-Box $b '05-place.sh' @('liam') $lines
        $r.ExitCode | Should -Be 0
        @($r.Output -like 'PLACED new *').Count | Should -Be 4
        Get-BoxFile $b '/home/liam/owui-web-egress/searxng-mcp/Dockerfile' | Should -Be "FROM x`n"
        (& stat -c '%a' (Join-Path $b.Root 'home/liam/owui-web-egress/guard.sh')) | Should -Be '755'
        (& stat -c '%a' (Join-Path $b.Root 'home/liam/owui-web-egress/compose.yml')) | Should -Be '644'
        (& stat -c '%a' (Join-Path $b.Root 'var/lib/ollama-cria/placed')) | Should -Be '600'
        @(Get-Content (Join-Path $b.Root 'var/lib/ollama-cria/placed')).Count | Should -Be 4
        @(Get-ChildItem -LiteralPath (Join-Path $b.Root 'home/liam/owui-web-egress') -Force -Filter '.cria-place.*') | Should -BeNullOrEmpty

        (Invoke-Box $b '05-place.sh' @('liam') $lines).Output | Should -Be @(
            'PLACED same /home/liam/owui-web-egress/compose.yml', 'PLACED same /home/liam/owui-web-egress/guard.sh',
            'PLACED same /home/liam/owui-web-egress/searxng-mcp/Dockerfile', 'PLACED same /etc/systemd/system/docker.service.d/owui-web-egress.conf')

        $r = Invoke-Box $b '05-place.sh' @('liam') @(New-PlaceLine '/home/liam/owui-web-egress/compose.yml' "name: y`n")
        $r.Output | Should -Be @('PLACED replaced /home/liam/owui-web-egress/compose.yml')
        Get-BoxFile $b '/home/liam/owui-web-egress/compose.yml' | Should -Be "name: y`n"

        Set-BoxFile $b '/home/liam/owui-web-egress/compose.yml' "edited by hand`n"
        $r = Invoke-Box $b '05-place.sh' @('liam') @(New-PlaceLine '/home/liam/owui-web-egress/compose.yml' "name: z`n")
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Be @('FAIL /home/liam/owui-web-egress/compose.yml: a different file is already there, not one this stage wrote; move it away and run again')
        Get-BoxFile $b '/home/liam/owui-web-egress/compose.yml' | Should -Be "edited by hand`n"
    }

    It 'refuses places it does not write, content that arrived changed, and links on the way' {
        $b = New-Box
        $null = New-Item -ItemType Directory -Path (Join-Path $b.Root 'home/liam/real') -Force
        & ln -s (Join-Path $b.Root 'home/liam/real') (Join-Path $b.Root 'home/liam/kokoro')
        $bad = (New-PlaceLine '/home/liam/x.yml' "a`n") -replace ' [0-9a-f]{64} ', " $('0' * 64) "
        $r = Invoke-Box $b '05-place.sh' @('liam') @(
            (New-PlaceLine '/etc/passwd' "root`n" '0644' 'root')
            (New-PlaceLine '/home/liam/../root/x' "a`n")
            (New-PlaceLine '/home/kai/x' "a`n")
            $bad
            (New-PlaceLine '/home/liam/kokoro/compose.yml' "a`n")
        )
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Be @(
            'FAIL /etc/passwd: not a place this stage writes'
            'FAIL /home/liam/../root/x: not a place this stage writes'
            'FAIL /home/kai/x: not a place this stage writes'
            'FAIL /home/liam/x.yml: the content arrived changed'
            'FAIL /home/liam/kokoro/compose.yml: a symbolic link on the way')
        Test-Path (Join-Path $b.Root 'home/liam/real/compose.yml') | Should -BeFalse
        Test-Path (Join-Path $b.Root 'home/liam/x.yml') | Should -BeFalse
    }
}

Describe '05-services.sh' -Skip:$IsWindows {
    It 'loads the guard before any image or container, pulls at digests, builds, starts both projects and the relay site' {
        $b = New-PlacedBox
        $r = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images
        $r.Output | Should -Not -Match '^FAIL'
        $r.ExitCode | Should -Be 0
        $calls = Get-Fake $b 'calls'
        $guardAt = [array]::IndexOf($calls, ($calls -match '^systemctl start owui-web-egress-guard.service')[0])
        $firstDocker = [array]::IndexOf($calls, ($calls -match '^docker (pull|build|compose)')[0])
        $guardAt | Should -BeGreaterThan -1
        $firstDocker | Should -BeGreaterThan $guardAt
        $lastImage = [array]::LastIndexOf($calls, ($calls -match '^docker (pull|build) ')[-1])
        $firstUp = [array]::IndexOf($calls, ($calls -match '^docker compose .* up ')[0])
        $firstUp | Should -BeGreaterThan $lastImage
        ($calls -match '^docker compose .* up ') | ForEach-Object { $_ | Should -Match '--pull never --wait' }
        $r.Steps | Should -Contain "STEP pulled qmcgaw/gluetun@sha256:$($script:Digest)"
        $r.Steps | Should -Contain 'STEP tagged it qmcgaw/gluetun:v3'
        $r.Steps | Should -Contain 'STEP built searxng-mcp:1.6.0 from /home/liam/owui-web-egress/searxng-mcp'
        $r.Steps | Should -Contain 'STEP /home/liam/owui-web-egress: 3/3 services running'
        $r.Steps | Should -Contain "STEP nginx's default site switched off"
        (& readlink (Join-Path $b.Root 'etc/nginx/sites-enabled/groq-relay')) | Should -Be '/etc/nginx/sites-available/groq-relay'
        Test-Path (Join-Path $b.Root 'etc/nginx/sites-enabled/default') | Should -BeFalse

        Remove-Item -LiteralPath (Join-Path $b.Fake 'calls')
        $again = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images
        $again.ExitCode | Should -Be 0
        Get-Fake $b 'calls' | Where-Object { $_ -match '^docker (pull|build|tag) |^systemctl (re)?start ' } | Should -BeNullOrEmpty

        # Restarting the guard restarts Docker too, so only for new guard
        # files or a guard running without its rules.
        $r = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp, 'guard-changed') $script:Images
        $r.Steps | Should -Contain 'STEP owui-web-egress-guard.service restarted to load its new files; Docker restarted with it'
        Remove-Item -LiteralPath (Join-Path $b.Fake 'guard-loaded')
        $r = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images
        $r.Steps | Should -Contain 'STEP owui-web-egress-guard.service restarted: it was running without its rules; Docker restarted with it'
        (Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp, 'restart-all')).Output | Should -Be @('FAIL unknown option: restart-all')
    }

    It 'starts nothing when the guard is not loaded, or Docker does not need it' {
        $b = New-PlacedBox
        Set-Fake $b 'guard-empty' ''
        $r = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images
        $r.ExitCode | Should -Be 1
        $r.Output[-1] | Should -Match 'routing rule 5260 or IPv6 block 5265 is missing; no container was started'
        Get-Fake $b 'calls' | Where-Object { $_ -match '^docker ' } | Should -BeNullOrEmpty

        # The IPv4 rules alone are not enough: the IPv6 block must be there too.
        $b = New-PlacedBox
        Set-Fake $b 'guard-v6-missing' ''
        $r = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images
        $r.ExitCode | Should -Be 1
        $r.Output[-1] | Should -Match 'IPv6 block 5265 is missing; no container was started'
        Get-Fake $b 'calls' | Where-Object { $_ -match '^docker ' } | Should -BeNullOrEmpty

        $b = New-PlacedBox
        Set-Fake $b 'dropin-inactive' ''
        $r = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images
        $r.Output[-1] | Should -Match '^FAIL Docker does not need owui-web-egress-guard.service'
        Get-Fake $b 'calls' | Where-Object { $_ -match '^docker ' } | Should -BeNullOrEmpty
    }

    It 'stops without the egress .env, and on an image reference without a digest' {
        $b = New-PlacedBox
        Remove-Item -LiteralPath (Join-Path $b.Root 'home/liam/owui-web-egress/.env') -Force
        (Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images).Output[-1] | Should -Match '\.env is missing; Stage 4 places it'

        $b = New-PlacedBox
        $r = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) @('pull alpine/socat:latest -')
        $r.Output[-1] | Should -Be 'FAIL not a pinned image reference: alpine/socat:latest'
    }

    It 'reports the checkpoint facts, and whether the tunnel''s exit address differs from the VPS''s' {
        $b = New-PlacedBox
        $null = Invoke-Box $b '05-services.sh' @('run', 'liam', $script:TsIp) $script:Images
        Set-Fake $b 'host-ip' '203.0.113.10'
        Set-Fake $b 'tunnel-ip' '198.51.100.20'
        foreach ($p in '8880', '18099', '13100') { Set-Fake $b "listen-$p" $script:TsIp }
        $r = Invoke-Box $b '05-services.sh' @('check', 'liam', $script:TsIp)
        $r.ExitCode | Should -Be 0
        $facts = @{}
        foreach ($l in $r.Output) { if ($l -match '^FACT (\S+) ?(.*)$') { $facts[$Matches[1]] = $Matches[2] } }
        $facts['guard-active'] | Should -Be 'yes'
        $facts['nft-table'] | Should -Be 'yes'
        $facts['ip-rule'] | Should -Be 'yes'
        $facts['docker-needs-guard'] | Should -Be 'yes'
        $facts['egress-running'] | Should -Be '3/3'
        $facts['kokoro-running'] | Should -Be '1/1'
        $facts['exit-ip'] | Should -Be 'differs'
        $facts['listen-18099'] | Should -Be 'tailnet-only'
        $facts['nginx-site'] | Should -Be 'yes'
        $r.Output -join "`n" | Should -Not -Match '203\.0\.113\.10|198\.51\.100\.20'

        Set-Fake $b 'tunnel-ip' '203.0.113.10'
        Set-Fake $b 'listen-8880' "0.0.0.0`n$($script:TsIp)"
        Set-Fake $b 'running-owui-web-egress' "gluetun`nsearxng"
        $r = Invoke-Box $b '05-services.sh' @('check', 'liam', $script:TsIp)
        $r.Output | Should -Contain 'FACT exit-ip same'
        $r.Output | Should -Contain 'FACT listen-8880 other'
        $r.Output | Should -Contain 'FACT egress-running 2/3'
    }
}

Describe '09-reach.sh' -Skip:$IsWindows {

    It 'asks each address once from the VPS and reports only a name and a status' {
        $b = New-Box
        Set-Fake $b 'reach-3001' '401'
        $pc = @('100', '64', '0', '7') -join '.'
        $r = Invoke-Box $b '09-reach.sh' @() @("bolt-from-vps http://${pc}:3001/mcp", "terminal-from-vps http://${pc}:18019/health")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Be @('FACT reach_bolt-from-vps 401', 'FACT reach_terminal-from-vps 000', 'STEP asked 2 address(es) on the PC from the VPS')
        $r.Output -join "`n" | Should -Not -Match ([regex]::Escape($pc))
    }

    It 'refuses a line that is not a name and a tailnet URL' {
        $b = New-Box
        $pc = @('100', '64', '0', '7') -join '.'
        foreach ($line in 'bolt http://192.168.1.5:3001/', "Bolt! http://${pc}:3001/", "bolt http://${pc}:3001/ extra", "bolt https://${pc}:3001/") {
            $r = Invoke-Box $b '09-reach.sh' @() @($line)
            $r.ExitCode | Should -Be 1 -Because $line
            $r.Output | Should -Be @("FAIL input line 1 is not '<name> <tailnet URL>'")
        }
    }
}

Describe '10-vps.sh' -Skip:$IsWindows {

    BeforeAll {
        function New-RunningBox {
            # The rebuilt VPS after Stage 5: guard and Docker up, both projects running.
            $b = New-PlacedBox
            Set-Fake $b 'active' "owui-web-egress-guard.service`ndocker.service"
            $null = New-Item -ItemType File -Path (Join-Path $b.Fake 'guard-loaded') -Force
            foreach ($p in 'owui-web-egress', 'kokoro') { $null = New-Item -ItemType File -Path (Join-Path $b.Fake "up-$p") -Force }
            Set-BoxFile $b '/proc/sys/kernel/random/boot_id' "0f6c1c3e-2b1a-4c55-9d1e-7a0d0a6b9e21`n"
            return $b
        }
        function Get-Fact($Run) { $o = @{}; foreach ($l in $Run.Output) { if ($l -match '^FACT (\S+) ?(.*)$') { $o[$Matches[1]] = $Matches[2] } }; $o }
        $script:Dropin = 'run/systemd/system/owui-web-egress-guard.service.d/zz-ollama-cria-break.conf'
    }

    It 'reports the boot and whether the guard came up before Docker' {
        $b = New-RunningBox
        Set-Fake $b 'guard-mono' '4100200'
        Set-Fake $b 'docker-mono' '5300400'
        $r = Invoke-Box $b '10-vps.sh' @('boot')
        $r.ExitCode | Should -Be 0
        $f = Get-Fact $r
        $f['boot_id'] | Should -Be '0f6c1c3e-2b1a-4c55-9d1e-7a0d0a6b9e21'
        $f['guard_first'] | Should -Be 'yes'
        $f['guard_active'] | Should -Be 'yes'
        $f['docker_active'] | Should -Be 'yes'
        Set-Fake $b 'guard-mono' '6300400'
        (Get-Fact (Invoke-Box $b '10-vps.sh' @('boot')))['guard_first'] | Should -Be 'no'
        Set-Fake $b 'guard-mono' '0'
        (Get-Fact (Invoke-Box $b '10-vps.sh' @('boot')))['guard_first'] | Should -Be 'unknown'
    }

    It 'schedules the restart so the SSH command returns first' {
        $b = New-RunningBox
        $r = Invoke-Box $b '10-vps.sh' @('reboot')
        $r.ExitCode | Should -Be 0
        $r.Steps | Should -Be @('STEP the VPS restarts in 5 seconds')
        Test-Path -LiteralPath (Join-Path $b.Fake 'reboot-scheduled') | Should -BeTrue
        Get-Fake $b 'calls' | Where-Object { $_ -like 'systemd-run *' } | Should -Match '--on-active=5 .*/bin/systemctl reboot'
    }

    It 'breaks the guard, finds that Docker refuses to start, and puts everything back' {
        $b = New-RunningBox
        $r = Invoke-Box $b '10-vps.sh' @('guard-break', 'liam')
        $r.ExitCode | Should -Be 0
        $f = Get-Fact $r
        $f['docker_refused'] | Should -Be 'yes'
        $f['guard_active'] | Should -Be 'yes'
        $f['guard_loaded'] | Should -Be 'yes'
        $f['docker_active'] | Should -Be 'yes'
        $f['egress_running'] | Should -Be '3/3'
        $f['kokoro_running'] | Should -Be '1/1'
        $f['gluetun_health'] | Should -Be 'healthy'
        Test-Path -LiteralPath (Join-Path $b.Root $script:Dropin) | Should -BeFalse
        $calls = @(Get-Fake $b 'calls' | Where-Object { $_ -like 'systemctl st*' })
        $calls[0] | Should -Be 'systemctl stop docker.socket docker.service'
        $calls | Should -Contain 'systemctl start docker.service'
        $calls[-1] | Should -Be 'systemctl start docker.socket docker.service'
    }

    It 'reports a Docker that starts without its guard' {
        $b = New-RunningBox
        $null = New-Item -ItemType File -Path (Join-Path $b.Fake 'docker-ignores-guard') -Force
        $r = Invoke-Box $b '10-vps.sh' @('guard-break', 'liam')
        (Get-Fact $r)['docker_refused'] | Should -Be 'no'
        Test-Path -LiteralPath (Join-Path $b.Root $script:Dropin) | Should -BeFalse
    }

    It 'changes nothing when the guard or Docker is not up to begin with' {
        $b = New-RunningBox
        Set-Fake $b 'active' 'docker.service'
        $r = Invoke-Box $b '10-vps.sh' @('guard-break', 'liam')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Contain 'FAIL the guard is not active; nothing was changed'
        Test-Path -LiteralPath (Join-Path $b.Root 'run/systemd') | Should -BeFalse
        Get-Fake $b 'calls' | Where-Object { $_ -like 'systemctl stop*' } | Should -BeNullOrEmpty
    }

    It 'runs the kill-switch test inside the gateway and always starts the tunnel again' {
        $b = New-RunningBox
        $py = @(Get-Content -LiteralPath (Join-Path $script:Stages '10-killswitch.py'))
        Set-Fake $b 'killswitch-out' "FACT ks_search network_error`nFACT ks_recovered yes"
        $r = Invoke-Box $b '10-vps.sh' @('kill-switch') $py
        $r.ExitCode | Should -Be 0
        (Get-Fact $r)['ks_search'] | Should -Be 'network_error'
        (Get-Fake $b 'killswitch-in') -join "`n" | Should -Match 'def main'
        Test-Path -LiteralPath (Join-Path $b.Fake 'tunnel-resumed') | Should -BeTrue

        $b = New-RunningBox
        Set-Fake $b 'killswitch-exit' '3'
        $r = Invoke-Box $b '10-vps.sh' @('kill-switch') $py
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Contain 'FAIL the test stopped (exit 3); the tunnel was started again'
        Test-Path -LiteralPath (Join-Path $b.Fake 'tunnel-resumed') | Should -BeTrue
    }

    It 'touches nothing without the test or a running gateway' {
        $b = New-RunningBox
        $r = Invoke-Box $b '10-vps.sh' @('kill-switch') @('print(1)')
        $r.Output | Should -Contain 'FAIL no test on standard input'
        Set-Fake $b 'gateway-running' 'false'
        $r = Invoke-Box $b '10-vps.sh' @('kill-switch') @('def main(): pass')
        $r.Output | Should -Contain 'FAIL the gateway container is not running; nothing was changed'
        Get-Fake $b 'calls' | Where-Object { $_ -like 'docker exec*' } | Should -BeNullOrEmpty
    }

    It 'gives its public addresses and listening ports, and nothing private' {
        $b = New-RunningBox
        Set-Fake $b 'host-ip' '203.0.113.10'
        Set-Fake $b 'host-ip6' '2001:db8::10'
        Set-Fake $b 'listen-8880' $script:TsIp
        Set-Fake $b 'listen-53' '127.0.0.53'
        $f = Get-Fact (Invoke-Box $b '10-vps.sh' @('public-ip'))
        $f['public_ipv4'] | Should -Be '203.0.113.10'
        $f['public_ipv6'] | Should -Be '2001:db8::10'
        $f['tcp_ports'] | Should -Be '22,53,8880'
        Set-Fake $b 'host-ip' '192.168.1.20'
        Remove-Item -LiteralPath (Join-Path $b.Fake 'host-ip6')
        $f = Get-Fact (Invoke-Box $b '10-vps.sh' @('public-ip'))
        $f['public_ipv4'] | Should -Be 'none'
        $f['public_ipv6'] | Should -Be 'none'
    }

    It 'probes public addresses from the VPS without printing them' {
        $b = New-RunningBox
        $null = New-Item -ItemType File -Path (Join-Path $b.Fake 'tcp-open-3000') -Force
        $r = Invoke-Box $b '10-vps.sh' @('probe') @('198.51.100.7 3000', '198.51.100.7 443', '2001:db8::7 3000')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Be @('FACT probe_4_3000 open', 'FACT probe_4_443 closed', 'FACT probe_6_3000 open', 'STEP probed 3 port(s) from the VPS')
        foreach ($line in "$($script:TsIp) 3000", '192.168.1.5 80', '10.0.0.1 22', 'fe80::1 22', '198.51.100.7 70000', '198.51.100.7 80 x') {
            $r = Invoke-Box $b '10-vps.sh' @('probe') @($line)
            $r.ExitCode | Should -Be 1 -Because $line
            $r.Output | Should -Be @("FAIL input line 1 is not '<public address> <port>'")
        }
    }
}
