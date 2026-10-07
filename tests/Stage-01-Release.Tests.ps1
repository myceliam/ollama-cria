#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 1 (windows/stages/01-release.ps1) on a fake machine, against the
# real manifests, with the bundle restorer replaced by
# tests/fakes/fake-restore-secrets.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')

    function New-Stage1([string]$Mode = 'Run') {
        Reset-Fake
        $global:CriaDirty = @()
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            if ($Name -ne 'git') { return New-ExecResult -1 }
            switch ($Arguments[2]) {
                'rev-parse' { New-ExecResult 0 @('ab' * 20) }
                'describe' { New-ExecResult 128 @('fatal: no tag exactly matches') }
                'status' { New-ExecResult 0 @($global:CriaDirty) }
                default { New-ExecResult 1 }
            }
        }
        $c = New-TestContext -Stage 1 -Mode $Mode
        # Where bundle folder 04 goes: a test 'ssh' root under the test drive.
        $roots = Join-Path $c.Base 'recovery-roots.json'
        @{ roots = @{ ssh = @{ kind = 'path'; host = 'pc'; path = (Join-Path $c.Base 'live/ssh') } } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $roots
        $c.RootsPath = $roots
        $global:CriaRestore = @{
            Calls    = [Collections.Generic.List[object]]::new()
            Rows     = @([pscustomobject]@{ Id = 'ssh-key'; Folder = '04'; Destination = 'ssh:id_test'; Status = 'placed' })
            Problems = @()
            Files    = @((Join-Path $c.Base 'live/ssh/id_test'))
        }
        return $c
    }

    function Add-Bundle($Context) {
        $zip = Join-Path $Context.StagingRoot 'stack-secrets-2026-10-07.zip'
        [IO.File]::WriteAllBytes($zip, [byte[]](1..64))
        return @{ Zip = $zip; Sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}

AfterAll {
    Remove-Variable -Name CriaFake, CriaCalls, CriaRestore, CriaDirty -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 1: plan' {
    It 'says what it would create and asks for the bundle, creating nothing' {
        $c = New-Stage1 -Mode Plan
        $r = Invoke-Stage '01-release.ps1' $c
        $r.Status | Should -Be 'planned'
        ($r.Steps -join "`n") | Should -Match 'would create the staging folder'
        ($r.Steps -join "`n") | Should -Match "root 'stack': would create"
        ($r.Steps -join "`n") | Should -Not -Match "root 'comfyui'"
        $r.Asks[0].Text | Should -Match 'save the bundle'
        Test-Path -LiteralPath $c.StagingRoot | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $c.Base 'live') | Should -BeFalse
        $global:CriaRestore.Calls.Count | Should -Be 0
    }
}

Describe 'Stage 1: run and check' {
    It 'creates the roots and an owner-only staging folder, then asks for the bundle' {
        $c = New-Stage1
        $r = Invoke-Stage '01-release.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Problems | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $c.Base 'live/ollama') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $c.Base 'live/comfyui') | Should -BeFalse
        Get-ProtectionProblem -Path $c.StagingRoot -OwnFolder | Should -BeNullOrEmpty
        $staging = @(Get-OwnedItem -State $c.State -Path $c.StagingRoot)[0]
        $staging.plaintext | Should -BeTrue
        $staging.retry | Should -Be 'keep'
        $r.Warnings | Should -Contain 'the repo is not at a release tag; the commit is recorded instead'
    }

    It 'checks and unpacks the bundle, places folder 04, and passes its checkpoint' {
        $c = New-Stage1
        $null = Invoke-Stage '01-release.ps1' $c
        $bundle = Add-Bundle $c
        $c.Bundle = @{ Path = $null; Sha256 = $bundle.Sha256.ToUpperInvariant() }
        $r = Invoke-Stage '01-release.ps1' $c
        $r.Status | Should -Be 'done'
        $global:CriaRestore.Calls.Count | Should -Be 1
        $global:CriaRestore.Calls[0].Folder | Should -Be '04'
        $global:CriaRestore.Calls[0].SshHost | Should -Be 'vps'
        $global:CriaRestore.Calls[0].Sha256 | Should -Be $bundle.Sha256
        $r.Data.BundlePath | Should -Be $bundle.Zip
        $r.Data.SshPlaced | Should -Be @('ssh:id_test')
        (@(Get-OwnedItem -State $c.State -Path $bundle.Zip)[0]).adopted | Should -BeTrue
        (@(Get-OwnedItem -State $c.State -Path $r.Data.BundleRoot)[0]).plaintext | Should -BeTrue

        $check = Copy-Context $c 'Check'
        $check.Data = $r.Data
        $k = Invoke-Stage '01-release.ps1' $check
        $failed = @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.What): $($_.Actual)" })
        $failed | Should -BeNullOrEmpty
        $k.Status | Should -Be 'passed'
        @($k.Checks | Where-Object What -EQ 'manifests match their schemas')[0].Ok | Should -BeTrue

        # A changed bundle no longer passes.
        [IO.File]::WriteAllBytes($bundle.Zip, [byte[]](2..65))
        $k = Invoke-Stage '01-release.ps1' $check
        $k.Status | Should -Be 'failed'
        @($k.Checks | Where-Object What -Like 'bundle SHA-256*')[0].Actual | Should -Be 'differs'
    }

    It 'refuses a repo with local changes' {
        $c = New-Stage1
        $global:CriaDirty = @(' M manifests/topology.json')
        $r = Invoke-Stage '01-release.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match '1 changed or new files'
        Test-Path -LiteralPath $c.StagingRoot | Should -BeTrue
        $global:CriaRestore.Calls.Count | Should -Be 0
    }

    It 'refuses a bundle outside the staging folder' {
        $c = New-Stage1
        $null = Invoke-Stage '01-release.ps1' $c
        $elsewhere = Join-Path $c.Base 'stack-secrets-2026-10-07.zip'
        [IO.File]::WriteAllBytes($elsewhere, [byte[]](1..8))
        $c.Bundle = @{ Path = $elsewhere; Sha256 = ('0' * 64) }
        $r = Invoke-Stage '01-release.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'must sit directly in'
        $global:CriaRestore.Calls.Count | Should -Be 0
    }

    It 'stops when BitLocker is off' {
        $c = New-Stage1
        $global:CriaFake.BitLocker = 'Off'
        $r = Invoke-Stage '01-release.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'BitLocker is not on'
    }

    It 'refuses a staging folder that others can reach' -Skip:$IsWindows {
        $c = New-Stage1
        $null = New-Item -ItemType Directory -Path $c.StagingRoot -Force
        & chmod 755 $c.StagingRoot
        $r = Invoke-Stage '01-release.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'staging folder'
    }
}
