#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../tools/RecoveryState.psm1') -Force

    function New-Case {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $root = Join-Path $base 'root'
        $null = New-Item -ItemType Directory -Path $root -Force
        [pscustomobject]@{ Base = $base; Root = $root; StatePath = (Join-Path $base 'state.json'); State = (Read-RecoveryState -Path (Join-Path $base 'state.json')) }
    }

    function New-File([string]$Path, [string]$Text = 'x') {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, $Text)
        return $Path
    }

    function Test-CanLink {
        $probe = Join-Path $TestDrive ("link-" + [guid]::NewGuid().ToString('n'))
        try { $null = New-Item -ItemType SymbolicLink -Path $probe -Target $TestDrive -ErrorAction Stop; Remove-Item -LiteralPath $probe -Force; return $true }
        catch { return $false }
    }
}

Describe 'state file' {
    It 'starts empty when there is no file, and keeps what was saved' {
        $c = New-Case
        $c.State.stages['1'] = @{ status = 'done'; attempts = 1 }
        $f = New-File (Join-Path $c.Root 'a.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 1 -Kind file -Path $f -Root $c.Root
        $again = Read-RecoveryState -Path $c.StatePath
        $again.stages['1'].status | Should -Be 'done'
        @($again.owned).Count | Should -Be 1
        $again.owned[0].path | Should -Be ([IO.Path]::GetFullPath($f))
        Test-Path -LiteralPath "$($c.StatePath).tmp" | Should -BeFalse
    }

    It 'refuses a file that is not a state file' {
        $c = New-Case
        $null = New-Item -ItemType Directory -Path $c.Base -Force
        Set-Content -LiteralPath $c.StatePath -Value 'not json'
        { Read-RecoveryState -Path $c.StatePath } | Should -Throw '*not JSON*'
        Set-Content -LiteralPath $c.StatePath -Value '{"formatVersion": 9}'
        { Read-RecoveryState -Path $c.StatePath } | Should -Throw '*not a format*'
    }
}

Describe 'lock' {
    It 'lets one run in, refuses a second, and takes over a lock whose process is gone' {
        $c = New-Case
        $lockId = Enter-RecoveryLock -StateRoot $c.Root
        $lockId | Should -Match '^[0-9a-f]{32}$'
        { Enter-RecoveryLock -StateRoot $c.Root } | Should -Throw '*holds the lock*'
        Enter-RecoveryLock -StateRoot $c.Root -Token $lockId | Should -Be $lockId
        { Enter-RecoveryLock -StateRoot $c.Root -Token ('0' * 32) } | Should -Throw '*not held*'
        Exit-RecoveryLock -StateRoot $c.Root -Token ('1' * 32)
        Test-Path (Join-Path $c.Root 'state.lock') | Should -BeTrue
        Exit-RecoveryLock -StateRoot $c.Root -Token $lockId
        Test-Path (Join-Path $c.Root 'state.lock') | Should -BeFalse

        # A process id that cannot be running.
        Set-Content -LiteralPath (Join-Path $c.Root 'state.lock') -Value '{"token":"x","pid":2147483000}'
        $new = Enter-RecoveryLock -StateRoot $c.Root -WarningAction SilentlyContinue
        $new | Should -Match '^[0-9a-f]{32}$'
        Exit-RecoveryLock -StateRoot $c.Root -Token $new
    }
}

Describe 'ownership' {
    It 'records an item with its identity, and refuses one outside its root' {
        $c = New-Case
        $f = New-File (Join-Path $c.Root 'sub/a.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 4 -Kind file -Path $f -Root $c.Root -Retry keep -Plaintext
        $o = @(Get-OwnedItem -State $c.State -Path $f)[0]
        $o.stage | Should -Be 4
        $o.retry | Should -Be 'keep'
        $o.plaintext | Should -BeTrue
        $o.identity | Should -Be (Get-ItemIdentity $f)
        Test-OwnedItem -State $c.State -Path $f | Should -BeTrue
        $outside = New-File (Join-Path $c.Base 'other/b.txt')
        { Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 4 -Kind file -Path $outside -Root $c.Root } | Should -Throw '*cannot record*'
        { Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 4 -Kind folder -Path $f -Root $c.Root } | Should -Throw '*not a folder*'
        { Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 4 -Kind file -Path (Join-Path $c.Root 'missing') -Root $c.Root } | Should -Throw '*missing*'
    }

    It 'removes only the object it recorded' {
        $c = New-Case
        $f = New-File (Join-Path $c.Root 'a.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 1 -Kind file -Path $f -Root $c.Root
        # Another file, made while the first still exists, moved into its place.
        $other = New-File (Join-Path $c.Root 'b.txt') 'other'
        Start-Sleep -Milliseconds 20
        Remove-Item -LiteralPath $f
        Move-Item -LiteralPath $other -Destination $f
        Test-OwnedItem -State $c.State -Path $f | Should -BeFalse
        $item = @(Get-OwnedItem -State $c.State -Path $f)[0]
        Remove-OwnedItem -State $c.State -StatePath $c.StatePath -Item $item | Should -Be 'changed'
        Get-Content -LiteralPath $f | Should -Be 'other'
        @(Get-OwnedItem -State $c.State -Path $f).Count | Should -Be 0
    }

    It 'removes a folder it created with everything in it, and the records inside it' {
        $c = New-Case
        $d = Join-Path $c.Root 'made'
        $null = New-Item -ItemType Directory -Path $d
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 2 -Kind folder -Path $d -Root $c.Root
        $f = New-File (Join-Path $d 'deep/x.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 2 -Kind file -Path $f -Root $c.Root
        (Get-ItemProperty -LiteralPath $f).IsReadOnly = $true
        $item = @(Get-OwnedItem -State $c.State -Path $d)[0]
        Remove-OwnedItem -State $c.State -StatePath $c.StatePath -Item $item | Should -Be 'removed'
        Test-Path -LiteralPath $d | Should -BeFalse
        @($c.State.owned).Count | Should -Be 0
        @((Read-RecoveryState -Path $c.StatePath).owned).Count | Should -Be 0
    }

    It 'never follows a link inside a folder it removes' {
        if (-not (Test-CanLink)) { Set-ItResult -Skipped -Because 'this account cannot create symbolic links'; return }
        $c = New-Case
        $d = Join-Path $c.Root 'made'
        $null = New-Item -ItemType Directory -Path $d
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 2 -Kind folder -Path $d -Root $c.Root
        $outside = Join-Path $c.Base 'precious'
        $keep = New-File (Join-Path $outside 'keep.txt')
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $d 'link') -Target $outside
        $item = @(Get-OwnedItem -State $c.State -Path $d)[0]
        Remove-OwnedItem -State $c.State -StatePath $c.StatePath -Item $item | Should -Be 'link'
        Test-Path -LiteralPath $keep | Should -BeTrue
    }

    It 'reports an item that is already gone and drops its record' {
        $c = New-Case
        $f = New-File (Join-Path $c.Root 'a.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 1 -Kind file -Path $f -Root $c.Root
        Remove-Item -LiteralPath $f
        Remove-OwnedItem -State $c.State -StatePath $c.StatePath -Item @(Get-OwnedItem -State $c.State)[0] | Should -Be 'gone'
        @($c.State.owned).Count | Should -Be 0
    }

    It "wipes only a stage's 'wipe' items, deepest first" {
        $c = New-Case
        $d = Join-Path $c.Root 'w'
        $null = New-Item -ItemType Directory -Path $d
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 3 -Kind folder -Path $d -Root $c.Root
        $inner = New-File (Join-Path $d 'inner.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 3 -Kind file -Path $inner -Root $c.Root
        $kept = New-File (Join-Path $c.Root 'kept.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 3 -Kind file -Path $kept -Root $c.Root -Retry keep
        $other = New-File (Join-Path $c.Root 'other.txt')
        Add-OwnedItem -State $c.State -StatePath $c.StatePath -Stage 4 -Kind file -Path $other -Root $c.Root
        $lines = @(Clear-StageOwned -State $c.State -StatePath $c.StatePath -Stage 3)
        $lines.Count | Should -Be 0
        Test-Path -LiteralPath $d | Should -BeFalse
        Test-Path -LiteralPath $kept | Should -BeTrue
        Test-Path -LiteralPath $other | Should -BeTrue
        @($c.State.owned | ForEach-Object { [IO.Path]::GetFileName($_.path) }) | Sort-Object | Should -Be @('kept.txt', 'other.txt')
    }

    It 'gives a stage callbacks that refuse to change anything in plan mode' {
        $c = New-Case
        $f = New-File (Join-Path $c.Root 'a.txt')
        $plan = Get-OwnershipCallback -State $c.State -StatePath $c.StatePath -Stage 1 -PlanOnly
        { & $plan.Own 'file' $f $c.Root } | Should -Throw '*plan mode*'
        $run = Get-OwnershipCallback -State $c.State -StatePath $c.StatePath -Stage 1
        & $run.Own 'file' $f $c.Root 'wipe' -Plaintext
        & $run.IsOwned $f | Should -BeTrue
        & $run.Keep $f
        @(Get-OwnedItem -State $c.State -Path $f)[0].retry | Should -Be 'keep'
        & $run.RemoveOwned (Join-Path $c.Root 'never') | Should -Be 'not-owned'
        & $run.RemoveOwned $f | Should -Be 'removed'
    }
}

Describe 'stage results' {
    It 'fails on a failed check and asks for a person without hiding a failure' {
        $r = New-StageResult -Status 'passed'
        Add-StageCheck $r 'one' 'a' 'a' $true
        $r.Status | Should -Be 'passed'
        Add-StageAsk $r 'do this' -Id 'x'
        $r.Status | Should -Be 'needs-user'
        Add-StageCheck $r 'two' 'a' 'b' $false
        $r.Status | Should -Be 'needs-user'
        $r2 = New-StageResult
        Add-StageCheck $r2 'two' 'a' 'b' $false
        Add-StageAsk $r2 'do this'
        $r2.Status | Should -Be 'failed'
        $r2.Asks[0].Text | Should -Be 'do this'
    }
}

Describe 'evidence check' {
    BeforeAll {
        # Values made at run time, so no secret-shaped literal is in a file.
        $script:EnvValue = 'sk-' + ('Q' * 30)
        $script:JsonValue = 'pa"ss\word' + ('Z' * 10)
        $script:KeyLine = 'b3BlbnNzaC1rZXktdjE' + ('A' * 40)
    }

    It 'names the evidence files that hold a bundle value, never the value' {
        $bundle = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path (Join-Path $bundle '01') -Force
        Set-Content -LiteralPath (Join-Path $bundle '01/.env') -Value "# comment`nOPENAI_API_KEY=`"$script:EnvValue`"`nPORT=3000"
        @{ client = @{ secret = $script:JsonValue } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bundle '01/oauth.json')
        Set-Content -LiteralPath (Join-Path $bundle '01/id_test') -Value "-----BEGIN KEY-----`n$script:KeyLine`n-----END KEY-----"
        $evidence = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $evidence
        $clean = Join-Path $evidence 'clean.json'
        @{ steps = @('placed 3 files', 'PORT=3000 is not a secret') } | ConvertTo-Json | Set-Content -LiteralPath $clean
        $env = Join-Path $evidence 'env.json'
        @{ steps = @("oops $script:EnvValue") } | ConvertTo-Json | Set-Content -LiteralPath $env
        $json = Join-Path $evidence 'json.json'
        @{ steps = @("oops $script:JsonValue") } | ConvertTo-Json | Set-Content -LiteralPath $json
        $key = Join-Path $evidence 'key.txt'
        Set-Content -LiteralPath $key -Value "line $script:KeyLine"
        $hits = @(Test-EvidenceSecretFree -EvidencePath $clean, $env, $json, $key -BundleRoot $bundle)
        $hits | Sort-Object | Should -Be (@($env, $json, $key) | Sort-Object)
    }
}
