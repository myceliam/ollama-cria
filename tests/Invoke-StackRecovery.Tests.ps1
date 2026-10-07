#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The controller, run against fake stage scripts (tests/fakes/fake-stage.ps1)
# in a temporary git repo, state root and stage folder.

BeforeAll {
    $script:Controller = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Invoke-StackRecovery.ps1'))
    $script:Real = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $script:Real 'tools/RecoveryState.psm1') -Force

    function Invoke-Git([string]$Repo, [string[]]$Arguments) {
        $out = & git -C $Repo -c user.email=test@example.invalid -c user.name=test -c commit.gpgsign=false @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' '): $out" }
        return $out
    }

    function New-Rig([int[]]$Stages = @(1, 2)) {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $rig = [pscustomobject]@{
            Base   = $base
            Repo   = Join-Path $base 'repo'
            Stages = Join-Path $base 'stages'
            State  = Join-Path $base 'state'
            Live   = Join-Path $base 'live'
        }
        foreach ($d in $rig.Repo, $rig.Stages, $rig.Live, (Join-Path $rig.Repo 'manifests/schemas')) { $null = New-Item -ItemType Directory -Path $d -Force }
        Copy-Item -LiteralPath (Join-Path $script:Real 'manifests/topology.json') -Destination (Join-Path $rig.Repo 'manifests/topology.json')
        Copy-Item -LiteralPath (Join-Path $script:Real 'manifests/schemas/topology.schema.json') -Destination (Join-Path $rig.Repo 'manifests/schemas/topology.schema.json')
        $null = Invoke-Git $rig.Repo @('init', '--quiet')
        $null = Invoke-Git $rig.Repo @('add', '--all')
        $null = Invoke-Git $rig.Repo @('commit', '--quiet', '-m', 'release')
        foreach ($n in $Stages) { Copy-Item -LiteralPath (Join-Path $script:Real 'tests/fakes/fake-stage.ps1') -Destination (Join-Path $rig.Stages ('{0:D2}-fake.ps1' -f $n)) }
        $global:CriaLive = $rig.Live
        $global:CriaStage = @{}
        $global:CriaStageCalls = [Collections.Generic.List[string]]::new()
        $global:CriaStageSeen = @{}
        return $rig
    }

    function Invoke-Controller($Rig, [switch]$Execute, [int]$Stage, [string[]]$Accept = @()) {
        $global:CriaStageCalls.Clear()
        $extra = @{}
        if ($Stage) { $extra['Stage'] = $Stage }
        if ($Accept) { $extra['Accept'] = $Accept }
        & $script:Controller -Execute:$Execute -RepoRoot $Rig.Repo -TopologyPath (Join-Path $Rig.Repo 'manifests/topology.json') `
            -StateRoot $Rig.State -StageRoot $Rig.Stages -PassThru @extra 6>$null
    }

    function Get-State($Rig) { Read-RecoveryState -Path (Join-Path $Rig.State 'state.json') }
}

AfterAll {
    Remove-Variable -Name CriaLive, CriaStage, CriaStageCalls, CriaStageSeen -Scope Global -ErrorAction SilentlyContinue
}

Describe 'plan' {
    It 'lists every stage and creates nothing, not even the state folder' {
        $rig = New-Rig
        $r = Invoke-Controller $rig
        $r.Mode | Should -Be 'Plan'
        $r.Status | Should -Be 'planned'
        $r.Stage | Should -Be 1
        ($r.Lines -join "`n") | Should -Match 'would run stage 1'
        ($r.Lines -join "`n") | Should -Match 'Stage 2 .*waits for Stage 1'
        ($r.Lines -join "`n") | Should -Match 'Stage 3 .*not built yet'
        Test-Path -LiteralPath $rig.State | Should -BeFalse
        $global:CriaStageCalls | Should -Be @('1:Plan')
    }
}

Describe 'execute' {
    It 'runs one stage, checks it, records the release and stops' {
        $rig = New-Rig
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'done'
        $r.Stage | Should -Be 1
        $global:CriaStageCalls | Should -Be @('1:Run', '1:Check')
        $s = Get-State $rig
        $s.stages['1'].status | Should -Be 'done'
        $s.stages['1'].attempts | Should -Be 1
        $s.release.commit | Should -Be (Invoke-Git $rig.Repo @('rev-parse', 'HEAD'))
        $s.release.manifests.Keys | Should -Contain 'topology.json'
        Test-Path -LiteralPath (Join-Path $rig.State 'evidence/stage-01-attempt-1.json') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $rig.State 'evidence/stage-01-attempt-1.txt') -Raw | Should -Match 'Result: done'
        Test-Path -LiteralPath (Join-Path $rig.State 'state.lock') | Should -BeFalse

        $r2 = Invoke-Controller $rig -Execute
        $r2.Stage | Should -Be 2
        $r2.Status | Should -Be 'done'
        $global:CriaStageCalls | Should -Be @('1:Check', '2:Run', '2:Check')
    }

    It 'refuses a stage whose needs are not done' {
        $rig = New-Rig
        $r = Invoke-Controller $rig -Execute -Stage 2
        $r.Status | Should -Be 'failed'
        ($r.Lines -join ' ') | Should -Match 'needs Stage 1 first'
        $global:CriaStageCalls.Count | Should -Be 0
    }

    It 'stops when a stage it needs no longer passes its checkpoint' {
        $rig = New-Rig
        $null = Invoke-Controller $rig -Execute
        $global:CriaStage['1'] = @{ Check = 'failed' }
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'failed'
        ($r.Lines -join ' ') | Should -Match "Stage 1's checkpoint no longer passes"
        $global:CriaStageCalls | Should -Be @('1:Check')
    }

    It 'runs nothing after Stage 1 once the repo or a manifest changed' {
        $rig = New-Rig
        $null = Invoke-Controller $rig -Execute
        Set-Content -LiteralPath (Join-Path $rig.Repo 'manifests/extra.json') -Value '{}'
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'failed'
        ($r.Lines -join ' ') | Should -Match 'manifests/extra.json changed since Stage 1'
        $null = Invoke-Git $rig.Repo @('add', '--all')
        $null = Invoke-Git $rig.Repo @('commit', '--quiet', '-m', 'later')
        $r = Invoke-Controller $rig -Execute
        ($r.Lines -join ' ') | Should -Match 'not .* as Stage 1 checked'
        $global:CriaStageCalls | Should -Not -Contain '2:Run'
    }

    It 'turns a stage that throws into a failed result with the message' {
        $rig = New-Rig
        $global:CriaStage['1'] = @{ Throw = 'the disk fell over' }
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'failed'
        ($r.Lines -join ' ') | Should -Match 'stopped: the disk fell over'
        (Get-State $rig).stages['1'].status | Should -Be 'failed'
    }

    It "wipes an interrupted stage's 'wipe' items, and nothing else, before running it again" {
        $rig = New-Rig
        $null = Invoke-Controller $rig -Execute
        $global:CriaStage['2'] = @{ Create = @('wipe.txt'); Keep = @('keep.txt'); Throw = 'cut off' }
        $null = Invoke-Controller $rig -Execute
        Test-Path -LiteralPath (Join-Path $rig.Live 'wipe.txt') | Should -BeTrue
        # As if the process had died mid-stage.
        $s = Get-State $rig
        $s.stages['2'].status = 'running'
        Save-RecoveryState -State $s -Path (Join-Path $rig.State 'state.json')
        Set-Content -LiteralPath (Join-Path $rig.Live 'stranger.txt') -Value 'not ours'
        $global:CriaStage['2'] = @{}
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'done'
        Test-Path -LiteralPath (Join-Path $rig.Live 'wipe.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $rig.Live 'keep.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $rig.Live 'stranger.txt') | Should -BeTrue
        (Get-State $rig).stages['2'].attempts | Should -Be 2
        (Get-State $rig).stages['2'].interruptions | Should -Be 1
        (Get-State $rig).stages['1'].ContainsKey('interruptions') | Should -BeFalse
    }

    It "keeps a finished stage's items from being wiped by a later attempt" {
        $rig = New-Rig
        $global:CriaStage['1'] = @{ Create = @('made.txt') }
        $null = Invoke-Controller $rig -Execute
        $o = @(Get-OwnedItem -State (Get-State $rig) -Stage 1)
        $o.Count | Should -Be 1
        $o[0].retry | Should -Be 'keep'
    }

    It 'stops for a question, keeps the answer, and carries on' {
        $rig = New-Rig
        $global:CriaStage['1'] = @{ Ask = 'gpu' }
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'needs-user'
        ($r.Lines -join ' ') | Should -Match '\[gpu\]'
        $r = Invoke-Controller $rig -Execute -Accept 'gpu'
        $r.Status | Should -Be 'done'
        (Get-State $rig).stages['1'].accepted | Should -Be @('gpu')
        $null = Invoke-Controller $rig -Execute
        $global:CriaStageSeen['1:Check'].Accepted | Should -Contain 'gpu'
        $global:CriaStageSeen['1:Check'].StageRoot | Should -Be ([IO.Path]::GetFullPath($rig.Stages))
        $global:CriaStageSeen['1:Check'].Tools.CollectSecrets | Should -Match 'Collect-StackSecrets\.ps1$'
        $global:CriaStageSeen['1:Check'].StatePath | Should -Be (Join-Path $global:CriaStageSeen['1:Check'].StateRoot 'state.json')
    }

    It 'runs a stage that asked for a restart again without wiping it' {
        $rig = New-Rig
        $null = Invoke-Controller $rig -Execute
        $global:CriaStage['2'] = @{ Create = @('half.txt'); Run = 'reboot' }
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'reboot'
        $global:CriaStage['2'] = @{}
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'done'
        Test-Path -LiteralPath (Join-Path $rig.Live 'half.txt') | Should -BeTrue
    }

    It 'refuses to run while another run holds the lock' {
        $rig = New-Rig
        $null = New-Item -ItemType Directory -Path $rig.State
        $lockId = Enter-RecoveryLock -StateRoot $rig.State
        try {
            $r = Invoke-Controller $rig -Execute
            $r.Status | Should -Be 'failed'
            ($r.Lines -join ' ') | Should -Match 'holds the lock'
            $global:CriaStageCalls.Count | Should -Be 0
        }
        finally { Exit-RecoveryLock -StateRoot $rig.State -Token $lockId }
    }

    It 'deletes evidence that holds a value from the bundle, fails the stage and never shows the value' {
        $rig = New-Rig
        $value = 'sk-' + ('R' * 36)
        $bundle = Join-Path $rig.Base 'bundle'
        $null = New-Item -ItemType Directory -Path (Join-Path $bundle '01') -Force
        Set-Content -LiteralPath (Join-Path $bundle '01/.env') -Value "API_KEY=$value"
        $global:CriaStage['1'] = @{ Data = @{ BundleRoot = $bundle }; Step = "printed $value by mistake" }
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'failed'
        $r.Run | Should -BeNullOrEmpty
        ($r.Lines -join ' ') | Should -Not -Match ([regex]::Escape($value))
        ($r.Lines -join ' ') | Should -Match 'stage-01-attempt-1.json held a value from the secrets bundle and was deleted'
        Test-Path -LiteralPath (Join-Path $rig.State 'evidence/stage-01-attempt-1.json') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $rig.State 'evidence/stage-01-attempt-1.txt') -Raw | Should -Not -Match ([regex]::Escape($value))
        Get-Content -LiteralPath (Join-Path $rig.State 'state.json') -Raw | Should -Not -Match ([regex]::Escape($value))
        (Get-State $rig).stages['1'].status | Should -Be 'failed'
    }

    It 'says so when every stage is done' {
        $rig = New-Rig
        $null = New-Item -ItemType Directory -Path $rig.State
        $s = Read-RecoveryState -Path (Join-Path $rig.State 'state.json')
        foreach ($n in 1..11) { $s.stages["$n"] = @{ status = 'done'; attempts = 1; accepted = @(); data = @{} } }
        Save-RecoveryState -State $s -Path (Join-Path $rig.State 'state.json')
        $r = Invoke-Controller $rig -Execute
        $r.Status | Should -Be 'done'
        $r.Lines | Should -Be @('Every stage is done.')
    }

    It 'fails a stage that needs admin rights when it cannot elevate' -Skip:$IsWindows {
        $rig = New-Rig -Stages 1, 3
        $null = Invoke-Controller $rig -Execute
        $r = Invoke-Controller $rig -Execute -Stage 3
        $r.Status | Should -Be 'failed'
        ($r.Lines -join ' ') | Should -Match 'needs admin rights'
        $global:CriaStageCalls | Should -Not -Contain '3:Run'
    }
}

Describe 'exit codes' {
    It 'exits 0 for a plan and 1 for a failure' {
        $rig = New-Rig
        $pwsh = (Get-Process -Id $PID).Path
        $common = @('-NoProfile', '-File', $script:Controller, '-RepoRoot', $rig.Repo, '-TopologyPath', (Join-Path $rig.Repo 'manifests/topology.json'),
            '-StateRoot', $rig.State, '-StageRoot', $rig.Stages)
        $null = & $pwsh @common 6>$null
        $LASTEXITCODE | Should -Be 0
        $null = & $pwsh @common -Execute -Stage 2 6>$null
        $LASTEXITCODE | Should -Be 1
    }
}
