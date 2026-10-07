#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '../tools/Remove-RecoveryPlaintext.ps1'
    Import-Module (Join-Path $PSScriptRoot '../tools/RecoveryState.psm1') -Force

    function New-Plaintext {
        # A state root and a staging folder as Stages 1 and 6 leave them.
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $stateRoot = Join-Path $base 'state'
        $staging = Join-Path $base 'staging'
        $null = New-Item -ItemType Directory -Path $stateRoot, $staging -Force
        $statePath = Join-Path $stateRoot 'state.json'
        $s = Read-RecoveryState -Path $statePath
        Add-OwnedItem -State $s -StatePath $statePath -Stage 1 -Kind folder -Path $staging -Root $staging -Retry keep -Plaintext
        $zip = Join-Path $staging 'stack-secrets-2026-10-07.zip'
        Set-Content -LiteralPath $zip -Value 'zip'
        Add-OwnedItem -State $s -StatePath $statePath -Stage 1 -Kind file -Path $zip -Root $staging -Retry keep -Plaintext -Adopted
        $unpacked = Join-Path $staging 'stack-secrets-2026-10-07'
        $null = New-Item -ItemType Directory -Path (Join-Path $unpacked '01') -Force
        Set-Content -LiteralPath (Join-Path $unpacked '01/.env') -Value 'X=1'
        Add-OwnedItem -State $s -StatePath $statePath -Stage 1 -Kind folder -Path $unpacked -Root $staging -Retry keep -Plaintext -Adopted
        $tokens = Join-Path $staging 'download-tokens'
        $null = New-Item -ItemType Directory -Path $tokens
        Add-OwnedItem -State $s -StatePath $statePath -Stage 6 -Kind folder -Path $tokens -Root $staging -Retry keep -Plaintext
        $token = Join-Path $tokens 'civitai-token.txt'
        Set-Content -LiteralPath $token -Value 'tok'
        Add-OwnedItem -State $s -StatePath $statePath -Stage 6 -Kind file -Path $token -Root $staging -Retry keep -Plaintext -Adopted
        # Not plaintext: never touched by this tool.
        $rendered = Join-Path $stateRoot 'rendered.txt'
        Set-Content -LiteralPath $rendered -Value 'r'
        Add-OwnedItem -State $s -StatePath $statePath -Stage 4 -Kind file -Path $rendered -Root $stateRoot
        [pscustomobject]@{ StateRoot = $stateRoot; Staging = $staging; Zip = $zip; Unpacked = $unpacked; Tokens = $tokens; Rendered = $rendered }
    }

    function Get-Row($Result, [string]$Path) { @($Result.Rows | Where-Object Path -EQ ([IO.Path]::GetFullPath($Path)))[0].Status }
}

Describe 'Remove-RecoveryPlaintext' {
    It 'plans without removing, and counts what it would remove as gone from the staging folder' {
        $p = New-Plaintext
        $r = & $script:Tool -StateRoot $p.StateRoot -PassThru
        $r.Mode | Should -Be 'Plan'
        Get-Row $r $p.Zip | Should -Be 'would remove'
        Get-Row $r $p.Unpacked | Should -Be 'would remove'
        Get-Row $r $p.Staging | Should -Be 'would remove once empty'
        $r.IsClean | Should -BeTrue
        Test-Path -LiteralPath $p.Zip | Should -BeTrue
        Test-Path -LiteralPath $p.Unpacked | Should -BeTrue
    }

    It 'removes every plaintext item, then the staging folder, and nothing else' {
        $p = New-Plaintext
        $r = & $script:Tool -StateRoot $p.StateRoot -Execute -PassThru
        $r.Problems | Should -BeNullOrEmpty
        $r.IsClean | Should -BeTrue
        Test-Path -LiteralPath $p.Staging | Should -BeFalse
        Test-Path -LiteralPath $p.Rendered | Should -BeTrue
        $left = @((Read-RecoveryState -Path (Join-Path $p.StateRoot 'state.json')).owned)
        $left.Count | Should -Be 1
        $left[0].path | Should -Be ([IO.Path]::GetFullPath($p.Rendered))
        Test-Path -LiteralPath (Join-Path $p.StateRoot 'state.lock') | Should -BeFalse
    }

    It 'leaves the staging folder, naming what is in it, when something else is there' {
        $p = New-Plaintext
        Set-Content -LiteralPath (Join-Path $p.Staging 'mine.txt') -Value 'not the controller''s'
        $r = & $script:Tool -StateRoot $p.StateRoot -Execute -PassThru
        $r.IsClean | Should -BeFalse
        Get-Row $r $p.Staging | Should -Match 'left: not empty \(1 items the controller did not create: mine.txt\)'
        Test-Path -LiteralPath (Join-Path $p.Staging 'mine.txt') | Should -BeTrue
        Test-Path -LiteralPath $p.Zip | Should -BeFalse
        Remove-Item -LiteralPath (Join-Path $p.Staging 'mine.txt')
        $r = & $script:Tool -StateRoot $p.StateRoot -Execute -PassThru
        $r.IsClean | Should -BeTrue
        Test-Path -LiteralPath $p.Staging | Should -BeFalse
    }

    It 'leaves an item that is no longer the one recorded' {
        $p = New-Plaintext
        $other = Join-Path $p.Staging 'other.zip'
        Set-Content -LiteralPath $other -Value 'other'
        Remove-Item -LiteralPath $p.Zip
        Move-Item -LiteralPath $other -Destination $p.Zip
        $r = & $script:Tool -StateRoot $p.StateRoot -Execute -PassThru
        Get-Row $r $p.Zip | Should -Be 'left: another item is there now'
        Test-Path -LiteralPath $p.Zip | Should -BeTrue
        $r.IsClean | Should -BeFalse
    }

    It 'reports a missing state file and a held lock as problems' {
        $r = & $script:Tool -StateRoot (Join-Path $TestDrive 'nowhere') -PassThru
        $r.IsClean | Should -BeFalse
        $r.Problems[0] | Should -Match 'no controller state'
        $p = New-Plaintext
        $lockId = Enter-RecoveryLock -StateRoot $p.StateRoot
        try {
            $r = & $script:Tool -StateRoot $p.StateRoot -Execute -PassThru
            $r.IsClean | Should -BeFalse
            $r.Problems[0] | Should -Match 'holds the lock'
            Test-Path -LiteralPath $p.Zip | Should -BeTrue
        }
        finally { Exit-RecoveryLock -StateRoot $p.StateRoot -Token $lockId }
    }
}
