#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 11 (windows/stages/11-cleanup.ps1) on a fake PC where Stages 1 to
# 10 are done: the staging folder holds what Stages 1, 2, 6, 7 and 10
# recorded as plaintext. The ledger command is run with the real
# Add-AIChange.ps1 against a ledger in the test drive.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')
    $script:LedgerHeader = 'id,timestamp_local,author,logged_by,model,request_from_liam,change_summary,files_touched,steps_taken,completed,verification,doc_sections_updated,rollback,risk_notes,follow_up_ref,provenance'

    function Write-Text([string]$Path, [string]$Text) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, $Text)
    }

    function New-Rebuilt {
        # A state where Stages 1 to 10 are done, with their plaintext on disk.
        Reset-Fake
        $c = New-TestContext -Stage 11
        $s = $c.State
        $sp = $c.StatePath
        $staging = $c.StagingRoot
        $own = {
            param([int]$Stage, [string]$Kind, [string]$Path, [switch]$Adopted)
            Add-OwnedItem -State $s -StatePath $sp -Stage $Stage -Kind $Kind -Path $Path -Root $staging -Retry keep -Plaintext -Adopted:$Adopted
        }
        $null = New-Item -ItemType Directory -Path $staging -Force
        & $own 1 folder $staging
        $zip = Join-Path $staging 'stack-secrets-20261007.zip'
        Write-Text $zip 'zip'
        & $own 1 file $zip -Adopted
        $unpacked = Join-Path $staging 'stack-secrets-20261007'
        Write-Text (Join-Path $unpacked '01/.env') 'X=1'
        & $own 1 folder $unpacked -Adopted
        $bootstrap = Join-Path $staging 'vps-bootstrap.sh'
        Write-Text $bootstrap 'bootstrap'
        & $own 2 file $bootstrap
        $tokens = Join-Path $staging 'download-tokens'
        $null = New-Item -ItemType Directory -Path $tokens
        & $own 6 folder $tokens
        Write-Text (Join-Path $tokens 'civitai-token.txt') 'tok'
        & $own 6 file (Join-Path $tokens 'civitai-token.txt') -Adopted
        $key = Join-Path $staging 'owui-api-key.txt'
        Write-Text $key 'key'
        & $own 7 file $key
        $run = Join-Path $staging 'stack-secrets-20261008T100000Z-a1b2c3'
        Write-Text (Join-Path $run 'stack-secrets-20261008T100000Z.zip') 'new zip'
        & $own 10 folder $run
        $round = Join-Path $staging 'roundtrip'
        $null = New-Item -ItemType Directory -Path $round
        & $own 10 folder $round
        # Liam's download from Bitwarden: inside a recorded folder, not recorded itself.
        Write-Text (Join-Path $round 'stack-secrets-20261008T100000Z.zip') 'new zip'
        # Not plaintext: left alone.
        $rendered = Join-Path $c.StateRoot 'rendered/web.env.example'
        Write-Text $rendered 'r'
        Add-OwnedItem -State $s -StatePath $sp -Stage 4 -Kind file -Path $rendered -Root $c.StateRoot -Retry keep

        foreach ($n in 1..10) { $s['stages']["$n"] = @{ status = 'done'; attempts = 1; accepted = @(); data = @{}; finished = '2026-10-07T10:00:00.0000000Z' } }
        $s['stages']['6']['attempts'] = 3
        $s['stages']['9']['attempts'] = 2
        $s['stages']['9']['interruptions'] = 1
        $s['stages']['1']['data'] = @{ BundlePath = $zip; BundleSha256 = ('c' * 64); BundleRoot = $unpacked }
        $s['stages']['10']['data'] = @{
            Backup    = @{ Ok = $true; Zip = 'stack-secrets-20261008T100000Z.zip'; Sha256 = ('d' * 64); SeedFiles = 2; RunFolder = $run }
            RoundTrip = @{ Ok = $true }
        }
        $s['release'] = @{ commit = ('a' * 40); manifests = @{ 'topology.json' = ('b' * 64); 'images.json' = ('e' * 64) } }
        Save-RecoveryState -State $s -Path $sp

        $stack = Join-Path $c.Base 'live/ollama'
        Write-Text (Join-Path $stack 'AI-CHANGELOG.csv') "$script:LedgerHeader`r`n"
        Write-Text (Join-Path $stack 'AI-CHANGELOG-PROTOCOL.md') 'protocol'
        $tool = Join-Path $stack '_support/scripts/maintenance/Add-AIChange.ps1'
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($tool)) -Force
        Copy-Item -LiteralPath (Join-Path $script:RealRepo 'stack/_support/scripts/maintenance/Add-AIChange.ps1') -Destination $tool
        $seed = Join-Path $c.StateRoot 'owui-seed-new'
        Write-Text (Join-Path $seed 'config.json') '{ "ui": { "default_locale": "en-GB" } }'
        Write-Text (Join-Path $seed 'provenance.json') '{ "owui_version": "0.11.4" }'

        [pscustomobject]@{
            Context = $c; Staging = $staging; Zip = $zip; Unpacked = $unpacked; Bootstrap = $bootstrap; Round = $round
            Rendered = $rendered; Stack = $stack; Seed = $seed; Record = (Join-Path $c.StateRoot 'rebuild-record.json')
        }
    }

    function Invoke-Run($Rig) { Invoke-Stage '11-cleanup.ps1' $Rig.Context }
    function Invoke-Check($Rig) { Invoke-Stage '11-cleanup.ps1' (Copy-Context $Rig.Context 'Check') }
    function Get-Record($Rig) { Get-Content -LiteralPath $Rig.Record -Raw | ConvertFrom-Json -AsHashtable }
    function Get-Command11($Result) { @($Result.Steps | Where-Object { $_.StartsWith('& ') })[0] }
}

Describe 'Stage 11: plan' {
    It 'lists what it would remove and changes nothing' {
        $rig = New-Rebuilt
        $r = Invoke-Stage '11-cleanup.ps1' (Copy-Context $rig.Context 'Plan')
        $r.Status | Should -Be 'planned'
        $r.Steps | Should -Contain "plaintext: would remove: $($rig.Zip)"
        $r.Steps | Should -Contain "plaintext: would remove once empty: $($rig.Staging)"
        Test-Path -LiteralPath $rig.Zip | Should -BeTrue
        Test-Path -LiteralPath $rig.Record | Should -BeFalse
        @(Get-OwnedItem -State $rig.Context.State -Plaintext).Count | Should -Be 9
    }
}

Describe 'Stage 11: clean-up and record' {
    It 'removes every plaintext item and the staging folder, writes the record, and checkpoint 11 passes' {
        $rig = New-Rebuilt
        $r = Invoke-Run $rig
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        Test-Path -LiteralPath $rig.Staging | Should -BeFalse
        Test-Path -LiteralPath $rig.Rendered | Should -BeTrue
        @(Get-OwnedItem -State $rig.Context.State -Plaintext).Count | Should -Be 0
        $saved = Read-RecoveryState -Path $rig.Context.StatePath
        @($saved['owned'] | Where-Object { $_['plaintext'] }).Count | Should -Be 0
        $c = Invoke-Check $rig
        $c.Status | Should -Be 'passed'
        @($c.Checks).Count | Should -Be 3
    }

    It 'records the release, both bundles by name and hash, each stage, and the stages that took more than one attempt' {
        $rig = New-Rebuilt
        $null = Invoke-Run $rig
        $rec = Get-Record $rig
        $rec.release.commit | Should -Be ('a' * 40)
        $rec.release.tag | Should -BeNullOrEmpty
        $rec.release.manifestCount | Should -Be 2
        $rec.release.manifests['images.json'] | Should -Be ('e' * 64)
        $rec.restoredFrom.bundle | Should -Be 'stack-secrets-20261007.zip'
        $rec.restoredFrom.sha256 | Should -Be ('c' * 64)
        $rec.newBundle.bundle | Should -Be 'stack-secrets-20261008T100000Z.zip'
        $rec.newBundle.sha256 | Should -Be ('d' * 64)
        $rec.newBundle.roundTrip | Should -Be 'match'
        @($rec.stages).Count | Should -Be 10
        @($rec.stages | ForEach-Object { $_.status } | Select-Object -Unique) | Should -Be @('done')
        $rec.retried | Should -Be @('Stage 6: 3 attempts', 'Stage 9: 2 attempts, 1 interrupted')
        $rec.plaintext.removed | Should -BeGreaterThan 0
        @($rec.plaintext.left).Count | Should -Be 0
    }

    It 'records the release tag when the checkout is at one' {
        $rig = New-Rebuilt
        $global:CriaFake.Exec = { param($Name, $Arguments) if ($Arguments -contains 'describe') { New-ExecResult 0 @('v1.0.0') } else { New-ExecResult 0 @() } }
        $null = Invoke-Run $rig
        (Get-Record $rig).release.tag | Should -Be 'v1.0.0'
    }

    It 'puts nothing from the bundle in the record or the steps' {
        $rig = New-Rebuilt
        $secret = 'sk-' + ('Q' * 40)
        Write-Text (Join-Path $rig.Unpacked '01/.env') "OPENAI_API_KEY=$secret"
        $r = Invoke-Run $rig
        [IO.File]::ReadAllText($rig.Record) | Should -Not -Match $secret
        ($r.Steps + $r.Warnings) -join "`n" | Should -Not -Match $secret
    }

    It 'names what it did not create in the staging folder, leaves it, and fails until it is gone' {
        $rig = New-Rebuilt
        $mine = Join-Path $rig.Staging 'notes.txt'
        Write-Text $mine 'mine'
        $r = Invoke-Run $rig
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'notes\.txt'
        Test-Path -LiteralPath $mine | Should -BeTrue
        Test-Path -LiteralPath $rig.Zip | Should -BeFalse
        Test-Path -LiteralPath $rig.Record | Should -BeTrue
        @((Get-Record $rig).plaintext.left) | Should -Be @([IO.Path]::GetFullPath($rig.Staging))

        Remove-Item -LiteralPath $mine
        $r = Invoke-Run $rig
        $r.Status | Should -Be 'done'
        Test-Path -LiteralPath $rig.Staging | Should -BeFalse
        (Invoke-Check $rig).Status | Should -Be 'passed'
    }

    It 'leaves a plaintext file another one replaced since it was recorded' {
        $rig = New-Rebuilt
        # Both exist at once, so the new one cannot reuse the old file ID or inode.
        $other = "$($rig.Bootstrap).new"
        Write-Text $other 'someone else'
        Remove-Item -LiteralPath $rig.Bootstrap
        Move-Item -LiteralPath $other -Destination $rig.Bootstrap
        $r = Invoke-Run $rig
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain "plaintext not removed: $($rig.Bootstrap) (another item is there now). Look at it; remove it yourself only if you put it there, then run again"
        [IO.File]::ReadAllText($rig.Bootstrap) | Should -Be 'someone else'
    }

    It 'can run again: what is gone stays gone and the record is written again' {
        $rig = New-Rebuilt
        $null = Invoke-Run $rig
        $first = (Get-Record $rig).written
        Start-Sleep -Milliseconds 20
        $r = Invoke-Run $rig
        $r.Status | Should -Be 'done'
        $r.Steps | Should -Contain 'plaintext: state.json records none'
        (Get-Record $rig).written | Should -Not -Be $first
        (Invoke-Check $rig).Status | Should -Be 'passed'
    }

    It 'never replaces a rebuild record it did not write' {
        $rig = New-Rebuilt
        Write-Text $rig.Record 'mine'
        $r = Invoke-Run $rig
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'the controller did not write it'
        [IO.File]::ReadAllText($rig.Record) | Should -Be 'mine'
        Test-Path -LiteralPath $rig.Staging | Should -BeFalse
        @(Get-ChildItem -LiteralPath $rig.Context.StateRoot -Filter 'rebuild-record.json.tmp-*').Count | Should -Be 0
    }
}

Describe 'Stage 11: what is left for a person' {
    It 'gives the ledger row as an Add-AIChange command that the real script accepts' {
        $rig = New-Rebuilt
        $r = Invoke-Run $rig
        $command = Get-Command11 $r
        $command | Should -Match "-Author 'Liam' -LoggedBy 'Claude' -Model '<your model>'"
        $command | Should -Match 'Stage 6: 3 attempts, Stage 9: 2 attempts, 1 interrupted'
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty

        $null = & ([scriptblock]::Create(($command -replace '<your model>', 'test-model'))) 6>$null
        $rows = @(Import-Csv -LiteralPath (Join-Path $rig.Stack 'AI-CHANGELOG.csv'))
        $rows.Count | Should -Be 1
        $rows[0].id | Should -Be 'AICL-0001'
        $rows[0].author | Should -Be 'Liam'
        $rows[0].change_summary | Should -Match 'stack-secrets-20261007\.zip'
        $rows[0].verification | Should -Match ([regex]::Escape($rig.Record))
    }

    It 'says the ledger and its protocol are missing when they are, and still gives the command' {
        $rig = New-Rebuilt
        Remove-Item -LiteralPath (Join-Path $rig.Stack 'AI-CHANGELOG.csv'), (Join-Path $rig.Stack 'AI-CHANGELOG-PROTOCOL.md')
        $r = Invoke-Run $rig
        $r.Status | Should -Be 'done'
        ($r.Warnings -join ' ') | Should -Match 'AI-CHANGELOG\.csv and AI-CHANGELOG-PROTOCOL\.md not in .*neither the bundle nor the repo carries them'
        Get-Command11 $r | Should -Not -BeNullOrEmpty
    }

    It 'offers a clean new seed for committing' {
        $rig = New-Rebuilt
        $r = Invoke-Run $rig
        ($r.Steps -join "`n") | Should -Match 'new OWUI seed: 2 files'
        ($r.Steps -join "`n") | Should -Match 'next: commit the new OWUI seed'
    }

    It 'does not offer a seed Test-NoSecrets finds something in, and never shows what it found' {
        $rig = New-Rebuilt
        $secret = 'sk-' + ('Z' * 40)
        Write-Text (Join-Path $rig.Seed 'prompt.json') "{ `"text`": `"$secret`" }"
        $r = Invoke-Run $rig
        $r.Status | Should -Be 'done'
        ($r.Warnings -join ' ') | Should -Match 'fails tools/Test-NoSecrets\.ps1 \(1 finding\(s\): prompt\.json line 1: API key \(sk-\)\)\. Do not commit it'
        ($r.Steps -join "`n") | Should -Not -Match 'commit the new OWUI seed'
        ($r.Steps + $r.Warnings) -join "`n" | Should -Not -Match $secret
    }

    It 'says when Stage 10 left no new seed' {
        $rig = New-Rebuilt
        Remove-Item -LiteralPath $rig.Seed -Recurse
        $r = Invoke-Run $rig
        ($r.Warnings -join ' ') | Should -Match 'no new OWUI seed'
        ($r.Steps -join "`n") | Should -Not -Match 'commit the new OWUI seed'
    }
}

Describe 'Stage 11: checkpoint' {
    It 'fails while plaintext is recorded, the staging folder holds anything, or there is no record' {
        $rig = New-Rebuilt
        $c = Invoke-Check $rig
        $c.Status | Should -Be 'failed'
        @($c.Checks | Where-Object { -not $_.Ok }).Count | Should -Be 3
        ($c.Checks | Where-Object What -EQ 'rebuild record').Actual | Should -Be 'missing'
    }

    It 'passes for an empty staging folder the controller did not create' {
        $rig = New-Rebuilt
        $null = Invoke-Run $rig
        $null = New-Item -ItemType Directory -Path $rig.Staging
        (Invoke-Check $rig).Status | Should -Be 'passed'
        Write-Text (Join-Path $rig.Staging 'stray.zip') 'z'
        $c = Invoke-Check $rig
        $c.Status | Should -Be 'failed'
        ($c.Checks | Where-Object { -not $_.Ok }).Actual | Should -Be '1 items: stray.zip'
    }
}
