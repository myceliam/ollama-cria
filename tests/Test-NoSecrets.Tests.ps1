#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '../tools/Test-NoSecrets.ps1'

    # Every fake secret is built at run time, so no literal lands in this file
    # and the repo scan stays clean.
    $script:FakeKey = 'sk-' + ('A' * 40)

    # A folder outside Git, so the scan walks every file in it.
    function New-ScanFolder {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        return $dir
    }

    function Save-Text([string]$Dir, [string]$Name, [string]$Text, [Text.Encoding]$Encoding = [Text.UTF8Encoding]::new($false)) {
        $path = Join-Path $Dir $Name
        [IO.File]::WriteAllText($path, $Text, $Encoding)
        return $path
    }

    function Get-Finding([string]$Dir) {
        @(& $script:Tool -Path $Dir -PassThru)
    }

    # A throwaway Git work tree, so the scan lists files the way CI does.
    function New-GitFolder {
        $dir = New-ScanFolder
        git -C $dir init -q
        git -C $dir config user.email 'test@example.invalid'
        git -C $dir config user.name 'test'
        git -C $dir config commit.gpgsign false
        return $dir
    }
}

Describe 'Test-NoSecrets' {

    Context 'what it reads' {
        It 'passes a clean folder' {
            $d = New-ScanFolder
            Save-Text $d 'notes.md' "# Notes`nNothing secret here.`n" | Out-Null
            Get-Finding $d | Should -BeNullOrEmpty
        }

        It 'scans a text file over 5 MB' {
            $d = New-ScanFolder
            Save-Text $d 'big.txt' (('x' * 6MB) + "`nkey = $($script:FakeKey)`n") | Out-Null
            $f = Get-Finding $d
            $f.Rule | Should -Contain 'API key (sk-)'
            ($f | Where-Object Rule -EQ 'API key (sk-)').Line | Should -Be 2
        }

        It 'decodes <Name> text' -ForEach @(
            @{ Name = 'UTF-16 LE with a mark'; Encoding = [Text.UnicodeEncoding]::new($false, $true) }
            @{ Name = 'UTF-16 BE with a mark'; Encoding = [Text.UnicodeEncoding]::new($true, $true) }
            @{ Name = 'UTF-16 LE with no mark'; Encoding = [Text.UnicodeEncoding]::new($false, $false) }
            @{ Name = 'UTF-16 BE with no mark'; Encoding = [Text.UnicodeEncoding]::new($true, $false) }
            @{ Name = 'UTF-32 LE with a mark'; Encoding = [Text.UTF32Encoding]::new($false, $true) }
            @{ Name = 'UTF-8 with a mark'; Encoding = [Text.UTF8Encoding]::new($true) }
        ) {
            $d = New-ScanFolder
            Save-Text $d 'wide.txt' "first line`r`nsecond line`r`nkey = $($script:FakeKey)`r`n" $Encoding | Out-Null
            $f = Get-Finding $d
            $f.Rule | Should -Be @('API key (sk-)')
            $f.Line | Should -Be 3
        }

        It 'scans the bytes of a binary file and reports line 0' {
            $d = New-ScanFolder
            $bytes = [Collections.Generic.List[byte]]::new()
            $bytes.AddRange([byte[]](0..255))
            $bytes.AddRange([byte[]](0, 0x22))
            $bytes.AddRange([Text.Encoding]::ASCII.GetBytes($script:FakeKey))
            $bytes.AddRange([byte[]](0x22, 0, 7, 0, 255))
            [IO.File]::WriteAllBytes((Join-Path $d 'blob.bin'), $bytes.ToArray())
            $f = Get-Finding $d
            $f.Rule | Should -Be @('API key (sk-) (in a binary file)')
            $f.Line | Should -Be 0
        }

        It 'passes a binary file with nothing secret in it' {
            $d = New-ScanFolder
            [IO.File]::WriteAllBytes((Join-Path $d 'blob.bin'), [byte[]]((0..255) * 40))
            Get-Finding $d | Should -BeNullOrEmpty
        }

        It 'never prints the matched text' {
            $d = New-ScanFolder
            Save-Text $d 'leak.txt' "key = $($script:FakeKey)`n" | Out-Null
            $out = & $script:Tool -Path $d
            $LASTEXITCODE | Should -Be 1
            ($out -join "`n") | Should -Not -Match ([regex]::Escape($script:FakeKey))
            ($out -join "`n") | Should -Match 'leak\.txt:1'
        }
    }

    Context 'folders that are not Git work trees' {
        It 'names and reads every file when the folder is given as a Windows short path' -Skip:(-not $IsWindows) {
            $d = New-ScanFolder
            Save-Text $d 'seed.json' ('{"k": "sk-' + ('A' * 40) + '"}' + "`n") | Out-Null
            $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($d).ShortPath
            $found = @(& $script:Tool -Path $short -PassThru)
            $found | Should -HaveCount 1
            $found[0].File | Should -Be 'seed.json'
            $found[0].Rule | Should -Be 'API key (sk-)'
        }

        It 'skips files inside a .git folder' {
            $d = New-ScanFolder
            New-Item -ItemType Directory -Path (Join-Path $d 'sub/.git') -Force | Out-Null
            Save-Text $d 'sub/.git/HEAD' ('sk-' + ('A' * 40) + "`n") | Out-Null
            Save-Text $d 'sub/ok.txt' "fine`n" | Out-Null
            Get-Finding $d | Should -BeNullOrEmpty
        }
    }

    Context 'Git work trees' {
        It 'scans a tracked file whose name Git would quote (<Label>)' -ForEach @(
            @{ Label = 'non-ASCII'; Name = 'caf' + [char]0xE9 + '.txt'; LinuxOnly = $false }
            @{ Label = 'a tab'; Name = "tab`there.txt"; LinuxOnly = $true }
        ) {
            if ($LinuxOnly -and $IsWindows) { Set-ItResult -Skipped -Because 'a Windows file name cannot hold a tab'; return }
            $d = New-GitFolder
            Save-Text $d $Name "key = $($script:FakeKey)`n" | Out-Null
            git -C $d add -- $Name
            $f = Get-Finding $d
            $f.File | Should -Be @($Name)
            $f.Rule | Should -Be @('API key (sk-)')
        }

        It 'scans a new file Git does not ignore, whatever its name' {
            $d = New-GitFolder
            $name = 'na' + [char]0xEF + 've.txt'
            Save-Text $d $name "key = $($script:FakeKey)`n" | Out-Null
            (Get-Finding $d).File | Should -Be @($name)
        }

        It 'skips a tracked file deleted from the work tree' {
            $d = New-GitFolder
            Save-Text $d 'gone.txt' "nothing here`n" | Out-Null
            git -C $d add -- 'gone.txt'
            git -C $d commit -q -m 'add' | Out-Null
            Remove-Item -LiteralPath (Join-Path $d 'gone.txt')
            Get-Finding $d | Should -BeNullOrEmpty
        }
    }

    Context 'more token formats' {
        It 'finds <Name>' -ForEach @(
            @{ Name = 'an ntfy access token'; Text = 'publish with tk_' + ('a' * 29); Rule = 'ntfy access token' }
            @{ Name = 'an API key written with a JSON escape'; Text = '{"value": "sk' + '\u002d' + ('A' * 40) + '"}'; Rule = 'API key (sk-)' }
            @{ Name = 'an opaque value in a keys array'; Text = '{"keys": ["' + ('A' * 48) + '"]}'; Rule = 'opaque value under a key or credential field' }
            @{ Name = 'a Civitai key'; Text = 'civitai: ' + ('a1' * 16); Rule = 'Civitai key' }
            @{ Name = 'Fernet ciphertext from an OWUI Valve'; Text = '"valves": "gAAAAA' + ('Bx9_' * 20) + '"'; Rule = 'Fernet ciphertext (encrypted OWUI Valves)' }
            @{ Name = 'a WireGuard preshared key'; Text = 'Preshared' + 'Key = ' + ('A' * 43) + '='; Rule = 'secret-named setting with a literal value' }
        ) {
            $d = New-ScanFolder
            Save-Text $d 'data.txt' "$Text`n" | Out-Null
            (Get-Finding $d).Rule | Should -Contain $Rule
        }

        It 'passes a short value in a keys array and an escape that decodes to nothing secret' {
            $d = New-ScanFolder
            Save-Text $d 'data.json' ('{"keys": ["id", "name"], "note": "a\u002db"}' + "`n") | Out-Null
            Get-Finding $d | Should -BeNullOrEmpty
        }
    }

    Context 'tailnet addresses' {
        It 'finds a tailnet IPv6 address written as <Name>' -ForEach @(
            @{ Name = 'compressed'; Text = 'fd7a:115c:' + 'a1e0::1' }
            @{ Name = 'full'; Text = 'FD7A:115C:' + 'A1E0:AB12:4843:CD96:6258:B240' }
            @{ Name = 'a URL host'; Text = 'http://[fd7a:115c:' + 'a1e0::53]:8080/' }
        ) {
            $d = New-ScanFolder
            Save-Text $d 'net.conf' "host = $Text`n" | Out-Null
            (Get-Finding $d).Rule | Should -Contain 'tailnet IPv6 address'
        }

        It 'passes other IPv6 addresses and the bare range name' {
            $d = New-ScanFolder
            Save-Text $d 'net.conf' "a = fd00::1`nb = 2001:db8::1`nc = fd7a:115c:a1e0 /48 is the tailnet range`n" | Out-Null
            Get-Finding $d | Should -BeNullOrEmpty
        }
    }

    Context 'secret-named settings' {
        It 'finds a quoted passphrase in <Name>' -ForEach @(
            @{ Name = 'a .env file'; Text = 'DB_PASS' + 'WORD="correct horse battery staple"' }
            @{ Name = 'JSON'; Text = '"ntfy_pass' + 'word": "it''s a long one, really"' }
            @{ Name = 'YAML'; Text = 'pass' + 'phrase: ''tr0ub4dor & 3 more!''' }
            @{ Name = 'PowerShell'; Text = '$Api' + 'Key = ''abc!def@ghi#''' }
        ) {
            $d = New-ScanFolder
            Save-Text $d 'settings.txt' "$Text`n" | Out-Null
            (Get-Finding $d).Rule | Should -Contain 'secret-named setting with a quoted passphrase'
        }

        It 'passes the placeholder <Text>' -ForEach @(
            @{ Text = 'PASS' + 'WORD="{{DB_PASSWORD}}"' }
            @{ Text = 'TOK' + 'EN: "${NTFY_TOKEN}"' }
            @{ Text = '$pass' + 'word = "$env:DB_PASSWORD from the vault"' }
            @{ Text = 'PASS' + 'WORD="<your passphrase here>"' }
            @{ Text = 'PASS' + 'WORD="%DB_PASSWORD% or empty"' }
            @{ Text = 'PASS' + 'WORD="short x"' }
            @{ Text = '"audit ''stack:secret' + 's'': ''stack:secrets/new-service.pw'' has no row"' }
            @{ Text = 'TOK' + 'EN_PATH = "E:\ai\ollama\secrets\ntfy-pc.token"' }
        ) {
            $d = New-ScanFolder
            Save-Text $d 'settings.txt' "$Text`n" | Out-Null
            Get-Finding $d | Should -BeNullOrEmpty
        }
    }

    Context 'file names' {
        It 'refuses <Name>' -ForEach @(
            @{ Name = '.env' }
            @{ Name = 'stack-secrets-20261005T120000Z.zip' }
            @{ Name = '00-RESTORE-MAP.json' }
            @{ Name = 'user.db' }
            @{ Name = 'backup.tar.gz' }
            @{ Name = 'export.7z' }
        ) {
            $d = New-ScanFolder
            Save-Text $d $Name 'fake' | Out-Null
            (Get-Finding $d).Rule | Should -Match '^forbidden file:'
        }

        It 'allows an .example file' {
            $d = New-ScanFolder
            Save-Text $d '.env.example' "NTFY_URL={{PC_TS_IP}}`n" | Out-Null
            Get-Finding $d | Should -BeNullOrEmpty
        }
    }
}
