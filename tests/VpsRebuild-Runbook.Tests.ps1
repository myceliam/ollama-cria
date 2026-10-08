#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The rebuild guides in docs/ are runbooks an assistant pastes from, so their
# code is tested like any script: every PowerShell block parses, every bash
# body passes 'bash -n', and each human walkthrough keeps the steps of the
# guide it pairs with. On Linux, the runbook's steps V0 to V10 also run end to
# end against a fake PC and a fake VPS: ssh, sudo, ssh-keyscan and tailscale
# are stand-ins written at run time, the VPS scripts run with bash against
# tests/fakes/fake-linux-tools.sh, and every file lands in the test drive.
# Addresses and keys are made at run time, so none is ever in a file.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Docs = Join-Path $script:Repo 'docs'
    $script:Runbook = Join-Path $script:Docs 'VPS-REBUILD-AI.md'
    $script:Fence = [string]::new([char]96, 3)
    $script:Todo = [string][char]0x2B1C
    $script:Dot = [string][char]0xB7

    function Get-CodeBlock([string]$Path, [string]$Language) {
        # Every fenced block of one language, in order, with its first line
        # number and the fence's indentation taken off each line.
        $lines = [IO.File]::ReadAllLines($Path)
        $blocks = [Collections.Generic.List[object]]::new()
        $buffer = $null; $indent = 0; $start = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ($null -eq $buffer) {
                if ($l -match "^(\s*)$($script:Fence)$Language\s*$") { $buffer = [Collections.Generic.List[string]]::new(); $indent = $Matches[1].Length; $start = $i + 2 }
                continue
            }
            if ($l -match "^\s*$($script:Fence)\s*$") {
                $blocks.Add([pscustomobject]@{ Line = $start; Text = ($buffer -join "`n") })
                $buffer = $null
                continue
            }
            $buffer.Add($(if ($l.Length -ge $indent -and -not $l.Substring(0, $indent).Trim()) { $l.Substring($indent) } else { $l.TrimStart() }))
        }
        return $blocks.ToArray()
    }

    function Get-NamedBlock([string]$Label) {
        # The runbook's PowerShell block whose first line is '# <Label>'.
        $found = @(Get-CodeBlock $script:Runbook 'powershell' | Where-Object { ($_.Text -split "`n")[0].Trim() -eq "# $Label" })
        if ($found.Count -ne 1) { throw "expected one block '# $Label' in the runbook, found $($found.Count)" }
        return $found[0].Text
    }

    function Get-BashBody([string]$Text) {
        # The bash script inside a block's @' ... '@ here-string.
        if ($Text -notmatch "(?s)@'\n(.*?)\n'@") { throw 'no here-string in the block' }
        return $Matches[1]
    }

    function Get-Step([string]$Path, [string]$Pattern) {
        @([regex]::Matches([IO.File]::ReadAllText($Path), $Pattern, 'Multiline') | ForEach-Object { $_.Groups[1].Value })
    }
}

Describe 'The rebuild guides: their code' {
    It 'parses every PowerShell block in <_>' -ForEach @('START-HERE.md', 'VPS-REBUILD-AI.md', 'VPS-REBUILD-HUMAN.md', 'FULL-REBUILD-HUMAN.md', 'VM-TEST.md') {
        $path = Join-Path $script:Docs $_
        foreach ($b in @(Get-CodeBlock $path 'powershell')) {
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($b.Text, [ref]$tokens, [ref]$errors)
            @($errors | ForEach-Object { "line $($b.Line): $($_.Message)" }) | Should -BeNullOrEmpty
        }
    }

    It 'has every block the steps refer to' {
        foreach ($label in 'V0 helpers', 'V2 bootstrap', 'V4 check', 'V5 trust', 'V7 place', 'V8B template', 'V8 shape', 'V9 guard', 'V10 images',
            'V11 multihop', 'V11 outside', 'V11 inward', 'V12 relay', 'V14 tidy') {
            { Get-NamedBlock $label } | Should -Not -Throw
        }
    }

    It 'passes bash -n for the bash inside <_>' -Skip:(-not $IsLinux) -ForEach @('V8B template', 'V8 shape', 'V9 guard', 'V11 multihop', 'V11 inward') {
        $f = Join-Path $TestDrive 'snippet.sh'
        [IO.File]::WriteAllText($f, (Get-BashBody (Get-NamedBlock $_)))
        $out = @(& bash -n $f 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }

    It 'never puts an address in the text a VPS script runs: they arrive as arguments' {
        foreach ($label in 'V8B template', 'V8 shape', 'V9 guard', 'V11 multihop', 'V11 inward') {
            Get-BashBody (Get-NamedBlock $label) | Should -Not -Match '\$\{?(vpsIp|pcIp)'
        }
    }
}

Describe 'The paired guides keep the same steps' {
    It 'VPS rebuild: the runbook, the walkthrough''s progress table and its sections all run V0 to V14' {
        $want = @(0..14 | ForEach-Object { "V$_" })
        $human = Join-Path $script:Docs 'VPS-REBUILD-HUMAN.md'
        Get-Step $script:Runbook "^## (V\d+) $($script:Dot) " | Should -Be $want
        Get-Step $human "^\| (V\d+) \| $($script:Todo) \|" | Should -Be $want
        Get-Step $human "^### (V\d+) $($script:Dot) " | Should -Be $want
    }

    It 'full rebuild: the walkthrough has a row and a section for P, Step 0 and every stage of RESTORE.md' {
        $stages = Get-Step (Join-Path $script:Docs 'RESTORE.md') "^# STAGE (\d+) $($script:Dot) "
        $stages | Should -Be @(1..11 | ForEach-Object { "$_" })
        $want = @('P', '0') + $stages
        $human = Join-Path $script:Docs 'FULL-REBUILD-HUMAN.md'
        Get-Step $human "^\| (\w+) \| $($script:Todo) \|" | Should -Be $want
        Get-Step $human "^### Stage (\w+) $($script:Dot) " | Should -Be $want
    }

    It 'VM test: its progress table and its sections run T0 to T9' {
        $want = @(0..9 | ForEach-Object { "T$_" })
        $path = Join-Path $script:Docs 'VM-TEST.md'
        Get-Step $path "^\| (T\d+) \| $($script:Todo) \|" | Should -Be $want
        Get-Step $path "^### (T\d+) $($script:Dot) " | Should -Be $want
    }
}

Describe 'The VPS runbook, V0 to V10, against a fake PC and VPS' -Skip:(-not $IsLinux) {
    BeforeAll {
        $script:FakeTools = Join-Path $script:Repo 'tests/fakes/fake-linux-tools.sh'
        $script:Domain = 'example-tailnet' + '.ts' + '.net'
        # The fake tailnet's addresses, as tests/fakes/fake-tailscale.ps1 makes them.
        $script:VpsIp = @('100', '64', '0', '8') -join '.'
        $script:PcIp = @('100', '64', '0', '7') -join '.'

        function New-KeyBlob {
            # An ssh-ed25519 public key blob around 32 random bytes.
            $type = [Text.Encoding]::ASCII.GetBytes('ssh-ed25519')
            $key = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($key)
            $bytes = [byte[]](@(0, 0, 0, $type.Length) + $type + @(0, 0, 0, 32) + $key)
            return [Convert]::ToBase64String($bytes)
        }

        function Write-Tool([string]$Path, [string]$Text) {
            [IO.File]::WriteAllText($Path, $Text.Replace("`r", ''))
            & chmod 755 $Path
        }

        function New-Rig {
            # A fresh PC (SSH key, known_hosts, the stack's compose file) and a
            # fresh Ubuntu 24.04 VPS (the account and Tailscale up), with every
            # stand-in on PATH.
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
            $vps = Join-Path $root 'vps'
            $bin = Join-Path $root 'bin'
            $pc = Join-Path $root 'pc'
            $null = New-Item -ItemType Directory -Path (Join-Path $vps 'etc'), (Join-Path $vps 'fake'), (Join-Path $vps 'home/liam'), (Join-Path $vps 'dev/net'),
                (Join-Path $vps 'etc/nginx/sites-enabled'), $bin, (Join-Path $pc '.ssh'), (Join-Path $pc 'stack'), (Join-Path $pc 'state') -Force
            foreach ($t in 'id', 'dpkg-query', 'apt-get', 'curl', 'gpg', 'systemctl', 'sysctl', 'ufw', 'sshd', 'docker', 'ss', 'chown', 'nft', 'ip', 'nginx', 'systemd-run', 'timeout') {
                Write-Tool (Join-Path $bin $t) "#!/usr/bin/env bash`nexec bash '$($script:FakeTools)' $t `"`$@`"`n"
            }
            Write-Tool (Join-Path $bin 'tailscale') @"
#!/usr/bin/env bash
case "`$1" in
  status) exec pwsh -NoProfile -File '$(Join-Path $script:Repo 'tests/fakes/fake-tailscale.ps1')' "`$@" ;;
  ping) echo 'pong from vps in 20ms'; exit 0 ;;
  *) exec bash '$($script:FakeTools)' tailscale "`$@" ;;
esac
"@
            # ssh: -G prints the alias's settings; anything else runs the remote command here.
            Write-Tool (Join-Path $bin 'ssh') @"
#!/usr/bin/env bash
if [ "`$1" = -G ]; then
  printf 'hostname %s\nport 22\nidentityfile %s\nuserknownhostsfile %s\n' "vps.$($script:Domain)" '$(Join-Path $pc '.ssh/id_ed25519')' '$(Join-Path $pc '.ssh/known_hosts')'
  exit 0
fi
while [ `$# -gt 0 ]; do case "`$1" in -o) shift 2 ;; -t|-T) shift ;; *) break ;; esac; done
shift
exec bash -c "`$*"
"@
            Write-Tool (Join-Path $bin 'sudo') "#!/usr/bin/env bash`n[ `"`$1`" = -n ] && shift`nexec `"`$@`"`n"
            $hostKey = New-KeyBlob
            Write-Tool (Join-Path $bin 'ssh-keyscan') "#!/usr/bin/env bash`necho '# vps.$($script:Domain):22 SSH-2.0-OpenSSH_9.6p1'`necho 'vps.$($script:Domain) ssh-ed25519 $hostKey'`n"

            # The VPS as tests/Linux-Stages.Tests.ps1 makes it.
            Set-Content -LiteralPath (Join-Path $vps 'etc/os-release') -Value "ID=ubuntu`nVERSION_ID=24.04`nPRETTY_NAME=`"Ubuntu 24.04.5 LTS`""
            $fake = @{ users = 'liam'; 'tailscale-ip' = $script:VpsIp; download = 'GOOD-KEY'; installed = "ca-certificates ubuntu`niproute2 ubuntu"
                'docker-version' = '29.8.2'; 'ssh-listen' = $script:VpsIp; enabled = 'ssh.socket'
                'services-owui-web-egress' = "gluetun`nsearxng`njina-reader"; 'services-kokoro' = 'kokoro-tts'
            }
            foreach ($k in $fake.Keys) { Set-Content -LiteralPath (Join-Path $vps "fake/$k") -Value $fake[$k] }
            Set-Content -LiteralPath (Join-Path $vps 'dev/net/tun') -Value 'x'
            & ln -s /etc/nginx/sites-available/default (Join-Path $vps 'etc/nginx/sites-enabled/default')

            # The PC: its key, the old server's key in known_hosts, and the stack naming the VPS.
            $oldKey = New-KeyBlob
            Set-Content -LiteralPath (Join-Path $pc '.ssh/id_ed25519.pub') -Value "ssh-ed25519 $(New-KeyBlob) liam@pc"
            Set-Content -LiteralPath (Join-Path $pc '.ssh/known_hosts') -Value @("vps.$($script:Domain) ssh-ed25519 $oldKey", "github.com ssh-ed25519 $(New-KeyBlob)")
            Set-Content -LiteralPath (Join-Path $pc 'stack/docker-compose.yml') -Value "      VPS_HOST: `"$($script:VpsIp)`""

            [pscustomobject]@{ Root = $root; Vps = $vps; Bin = $bin; Pc = $pc; State = (Join-Path $pc 'state'); Work = (Join-Path $pc 'state/vps-rebuild'); HostKey = $hostKey; OldKey = $oldKey }
        }

        function Get-Runnable([string]$Label, $Rig) {
            # A runbook block with the PC's paths moved into the rig.
            $text = Get-NamedBlock $Label
            foreach ($pair in @(@('E:\recovery-state\vps-rebuild', $Rig.Work), @('E:\recovery-state', $Rig.State), @('E:\recovery', $script:Repo), @('E:\ai\ollama', (Join-Path $Rig.Pc 'stack')))) {
                $new = $pair[1]
                $text = [regex]::Replace($text, "'$([regex]::Escape($pair[0]))((?:\\[^']*)?)'", { param($m) "'$new$($m.Groups[1].Value.Replace('\', '/'))'" }.GetNewClosure())
            }
            return [scriptblock]::Create($text)
        }

        function Get-VpsFile($Rig, [string]$Path) { [IO.File]::ReadAllText((Join-Path $Rig.Vps $Path.TrimStart('/'))) }

        function Set-EnvValue($Rig, [string]$Name, [string]$Value) {
            # Liam typing one value into the egress .env with nano.
            $p = Join-Path $Rig.Vps 'home/liam/owui-web-egress/.env'
            $t = [IO.File]::ReadAllText($p) -replace "(?m)^$Name=.*$", "$Name=$Value"
            [IO.File]::WriteAllText($p, $t)
        }
    }

    BeforeEach {
        $script:SavedPath = $env:PATH
    }

    AfterEach {
        $env:PATH = $script:SavedPath
        $env:CRIA_ROOT = $null
    }

    It 'sets up, trusts the new server, builds its base, places its files and keys, checks them against the guard, and starts the services' {
        $rig = New-Rig
        $env:PATH = "$($rig.Bin):$($script:SavedPath)"
        $env:CRIA_ROOT = $rig.Vps
        Set-Item -Path function:notepad -Value { param($Path) $script:Opened = $Path }
        # Start-VpsLong's own window: run it here, to the end.
        Mock Start-Process { & $FilePath @ArgumentList | Out-Null }

        # V0
        . (Get-Runnable 'V0 helpers' $rig)
        Test-Path (Join-Path $rig.Work 'PROGRESS.md') | Should -BeTrue
        { Get-WorkFile '../../escape.sh' } | Should -Throw '*STOP*'
        Set-StepDone V0
        [IO.File]::ReadAllText((Join-Path $rig.Work 'PROGRESS.md')) | Should -Match "(?m)^\| V0 \| $([char]0x2705) "
        [IO.File]::ReadAllText((Join-Path $rig.Work 'PROGRESS.md')) | Should -Match "(?m)^\| V1 \| $($script:Todo) \|"

        # V2
        . (Get-Runnable 'V2 bootstrap' $rig)
        $script:Opened | Should -Be (Join-Path $rig.Work 'vps-bootstrap.sh')
        $boot = [IO.File]::ReadAllText($script:Opened)
        $boot | Should -Not -Match '\{\{'
        $boot | Should -Match ([regex]::Escape((Get-Content -LiteralPath (Join-Path $rig.Pc '.ssh/id_ed25519.pub') -TotalCount 1)))

        # V4
        . (Get-Runnable 'V4 check' $rig)
        $vpsIp | Should -Be $script:VpsIp
        $pcIp | Should -Be $script:PcIp
        $kept | Should -BeTrue

        # V5, with the fingerprint Liam read out in V3
        $fp = Get-SshKeyFingerprint -Blob $rig.HostKey
        $out = @(. (Get-Runnable 'V5 trust' $rig))
        $out[-1] | Should -Be 'ssh exit code: 0'
        $known = [IO.File]::ReadAllText((Join-Path $rig.Pc '.ssh/known_hosts'))
        $known | Should -Match ([regex]::Escape($rig.HostKey))
        $known | Should -Not -Match ([regex]::Escape($rig.OldKey))
        $known | Should -Match '(?m)^github\.com '
        @(Get-ChildItem -LiteralPath (Join-Path $rig.Pc '.ssh') -Filter 'known_hosts.cria-*').Count | Should -Be 1
        # A server whose key is not the one from the console is never trusted.
        $fp = Get-SshKeyFingerprint -Blob (New-KeyBlob)
        { . (Get-Runnable 'V5 trust' $rig) } | Should -Throw '*STOP*'

        # V6
        $null = Start-VpsLong v6 02-base.sh run, liam, $vpsIp
        $log = @(Get-Content -LiteralPath (Join-Path $rig.Work 'v6.log'))
        $log[-1] | Should -Be 'exit code: 0' -Because ($log -join "`n")
        $r = Invoke-Vps 02-base.sh check, liam, $vpsIp 6> $null
        $r.ExitCode | Should -Be 0
        $r.Facts['tailscale-ip'] | Should -Be 'match'
        $r.Facts['ssh-listen'] | Should -Be 'tailnet-only'
        $r.Facts['ufw-other-allow'] | Should -Be '0'

        # V7
        $out = @(. (Get-Runnable 'V7 place' $rig) 6> $null)
        $r.ExitCode | Should -Be 0
        $out[0] | Should -Match '^\d+ files to place$'
        $count = [int]($out[0] -split ' ')[0]
        @(Get-Content -LiteralPath (Join-Path $rig.Vps 'var/lib/ollama-cria/placed')).Count | Should -Be $count
        Get-VpsFile $rig '/home/liam/owui-web-egress/compose.yml' | Should -Match ([regex]::Escape($script:VpsIp))
        Get-VpsFile $rig '/home/liam/owui-web-egress/compose.yml' | Should -Not -Match '\{\{VPS_TS_IP\}\}'
        Test-Path (Join-Path $rig.Vps 'etc/systemd/system/owui-web-egress-guard.service') | Should -BeTrue
        Test-Path (Join-Path $rig.Vps 'home/liam/owui-web-egress/compose.override.yml') | Should -BeTrue
        Test-Path (Join-Path $rig.Vps 'home/liam/owui-web-egress/searxng-mcp/Dockerfile') | Should -BeTrue

        # V8B: the empty file, never over one that is there
        $r = . (Get-Runnable 'V8B template' $rig) 6> $null
        $r.ExitCode | Should -Be 0
        $envPath = Join-Path $rig.Vps 'home/liam/owui-web-egress/.env'
        (& stat -c '%a' $envPath) | Should -Be '600'
        $names = @([IO.File]::ReadAllLines($envPath) | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { ($_ -split '=')[0] })
        $names | Should -Be @('VPN_ENDPOINT_IP', 'VPN_ENDPOINT_PORT', 'WIREGUARD_PUBLIC_KEY', 'WIREGUARD_PRIVATE_KEY', 'WIREGUARD_ADDRESSES', 'BRAVE_API_KEY', 'SEARXNG_SECRET')
        [IO.File]::ReadAllText($envPath) | Should -Match '(?m)^SEARXNG_SECRET=[0-9a-f]{64}$'
        $r = . (Get-Runnable 'V8B template' $rig) 6> $null
        $r.ExitCode | Should -Be 1

        # Liam fills it in from the Mullvad file and the Brave dashboard.
        $guard = Get-VpsFile $rig '/home/liam/owui-web-egress/guard.nft'
        $m = [regex]::Match($guard, 'ip daddr (\S+) udp dport (\d+) counter accept')
        $m.Success | Should -BeTrue
        $entryIp = $m.Groups[1].Value; $entryPort = $m.Groups[2].Value
        $wgKey = { $b = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($b); [Convert]::ToBase64String($b) }
        Set-EnvValue $rig 'VPN_ENDPOINT_IP' $entryIp
        Set-EnvValue $rig 'VPN_ENDPOINT_PORT' $entryPort
        Set-EnvValue $rig 'WIREGUARD_PUBLIC_KEY' (& $wgKey)
        Set-EnvValue $rig 'WIREGUARD_PRIVATE_KEY' (& $wgKey)
        Set-EnvValue $rig 'WIREGUARD_ADDRESSES' ((@('10', '64', '12', '34') -join '.') + '/32')
        Set-EnvValue $rig 'BRAVE_API_KEY' ('BS' + ('k' * 29))

        # V8 shape: only ok, EMPTY or WRONG SHAPE, never a value
        $shape = @(. (Get-Runnable 'V8 shape' $rig) 6>&1 | ForEach-Object { "$_" })
        @($shape -like 'STEP *: ok').Count | Should -Be 7 -Because ($shape -join "`n")
        $shape | Should -Contain "STEP mode and owner: 600 $([Environment]::UserName)"
        Set-EnvValue $rig 'WIREGUARD_ADDRESSES' ('Address = ' + (@('10', '64', '12', '34') -join '.') + '/32')
        $shape = @(. (Get-Runnable 'V8 shape' $rig) 6>&1 | ForEach-Object { "$_" })
        $shape | Should -Contain 'STEP WIREGUARD_ADDRESSES: WRONG SHAPE (24 characters)'
        ($shape -join "`n") | Should -Not -Match '10\.64\.12\.34'
        Set-EnvValue $rig 'WIREGUARD_ADDRESSES' ((@('10', '64', '12', '34') -join '.') + '/32')

        # V9: the .env and the guard name the same entry server
        $r = . (Get-Runnable 'V9 guard' $rig) 6> $null
        $r.ExitCode | Should -Be 0
        Set-EnvValue $rig 'VPN_ENDPOINT_PORT' ([string]([int]$entryPort + 1))
        $out = @(. (Get-Runnable 'V9 guard' $rig) 6>&1 | ForEach-Object { "$_" })
        $out | Should -Contain 'FAIL MISMATCH: guard.nft allows another entry server or port than .env'
        $out | Should -Contain 'exit code: 1'
        Set-EnvValue $rig 'VPN_ENDPOINT_PORT' $entryPort

        # V10, with the earlier steps' calls cleared
        Remove-Item -LiteralPath (Join-Path $rig.Vps 'fake/calls')
        $null = . (Get-Runnable 'V10 images' $rig)
        $log = @(Get-Content -LiteralPath (Join-Path $rig.Work 'v10.log'))
        $log[-1] | Should -Be 'exit code: 0' -Because ($log -join "`n")
        $log | Should -Contain 'STEP built searxng-mcp:1.6.0 from /home/liam/owui-web-egress/searxng-mcp'
        @($log -like 'STEP pulled *').Count | Should -BeGreaterThan 0
        $calls = @(Get-Content -LiteralPath (Join-Path $rig.Vps 'fake/calls'))
        $guardAt = [array]::IndexOf($calls, @($calls -match '^systemctl start owui-web-egress-guard.service')[0])
        $firstDocker = [array]::IndexOf($calls, @($calls -match '^docker (pull|build|compose)')[0])
        $guardAt | Should -BeGreaterThan -1
        $firstDocker | Should -BeGreaterThan $guardAt

        # Nothing from the tailnet was written down on the PC.
        foreach ($f in Get-ChildItem -LiteralPath $rig.Work -File) {
            [IO.File]::ReadAllText($f.FullName) | Should -Not -Match ([regex]::Escape($script:VpsIp)) -Because $f.Name
        }
    }
}
