#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 3 (windows/stages/03-runtime.ps1) on a fake machine whose wsl,
# nvidia-smi, winget and docker answer from $global:CriaWorld, against the
# real windows-apps.json and ollama-env.json.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')
    $script:Apps = Get-Content -LiteralPath (Join-Path $script:RealRepo 'manifests/windows-apps.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:OllamaEnv = Get-Content -LiteralPath (Join-Path $script:RealRepo 'manifests/ollama-env.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:SavedPath = $env:PATH

    function New-Stage3([string]$Mode = 'Run', [switch]$Fresh, [string[]]$Accepted = @()) {
        Reset-Fake
        $ids = @($script:Apps.packages | ForEach-Object { $_.id })
        $global:CriaWorld = @{
            Installed       = [Collections.Generic.HashSet[string]]::new()
            Pinned          = [Collections.Generic.HashSet[string]]::new()
            Wsl             = -not $Fresh
            AfterWslInstall = 'EnablePending'
            Gpu             = "$($script:Apps.gpu.name), $($script:Apps.gpu.driver)"
            Docker          = -not $Fresh
            InstallCode     = 0
        }
        if (-not $Fresh) {
            foreach ($id in $ids) { [void]$global:CriaWorld.Installed.Add($id) }
            foreach ($id in 'Docker.DockerDesktop', 'Ollama.Ollama') { [void]$global:CriaWorld.Pinned.Add($id) }
        }
        $global:CriaFake.Feature['VirtualMachinePlatform'] = $(if ($Fresh) { 'Disabled' } else { 'Enabled' })
        $global:CriaFake.Env['Machine/Path'] = $script:SavedPath
        if (-not $Fresh) { foreach ($v in $script:OllamaEnv.variables) { $global:CriaFake.Env["Machine/$($v.name)"] = $v.value } }
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            $w = $global:CriaWorld
            $id = if ($Arguments -contains '--id') { $Arguments[[array]::IndexOf($Arguments, '--id') + 1] } else { $null }
            if ($Name -eq 'wsl') {
                if ($Arguments[0] -eq '--version') { return New-ExecResult $(if ($w.Wsl) { 0 } else { 1 }) }
                $global:CriaFake.Feature['VirtualMachinePlatform'] = $w.AfterWslInstall
                return New-ExecResult 0
            }
            if ($Name -eq 'nvidia-smi') { if ($w.Gpu) { return New-ExecResult 0 @($w.Gpu) } else { return New-ExecResult -1 } }
            if ($Name -eq 'docker') { if ($w.Docker) { return New-ExecResult 0 @('28.0.1') } else { return New-ExecResult 1 @('error during connect') } }
            if ($Name -eq 'winget') {
                switch ($Arguments[0]) {
                    'list' { return New-ExecResult $(if ($w.Installed.Contains($id)) { 0 } else { -1978335212 }) }
                    'install' { if ($w.InstallCode -eq 0 -or $w.InstallCode -eq 3010) { [void]$w.Installed.Add($id) }; return New-ExecResult $w.InstallCode }
                    'pin' {
                        if ($Arguments[1] -eq 'add') { [void]$w.Pinned.Add($id); return New-ExecResult 0 }
                        return New-ExecResult 0 @('Name  Id  Version  Source  Pin type', $(if ($w.Pinned.Contains($id)) { "App  $id  1.0  winget  Pinning" } else { 'No pins found' }))
                    }
                }
            }
            return New-ExecResult -1
        }
        $c = New-TestContext -Stage 3 -Mode $Mode -Accepted $Accepted
        $c['DockerDesktop'] = Join-Path $c.Base 'Docker Desktop.exe'
        return $c
    }

    function Get-Call([string]$Pattern) { @($global:CriaCalls | Where-Object { $_ -like $Pattern }) }
}

AfterAll {
    Remove-Variable -Name CriaFake, CriaCalls, CriaWorld -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 3 on a machine that is already set up' {
    AfterEach { $env:PATH = $script:SavedPath }

    It 'changes nothing and passes its checkpoint' {
        $c = New-Stage3
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'done'
        $r.Problems | Should -BeNullOrEmpty
        Get-Call 'winget install*' | Should -BeNullOrEmpty
        Get-Call 'winget pin add*' | Should -BeNullOrEmpty
        Get-Call 'setenv*' | Should -BeNullOrEmpty
        Get-Call 'stop *' | Should -BeNullOrEmpty
        $r.Steps | Should -Contain 'the Ollama profile is already in place'

        $k = Invoke-Stage '03-runtime.ps1' (Copy-Context $c 'Check')
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object What) | Should -BeNullOrEmpty
        $k.Status | Should -Be 'passed'
    }
}

Describe 'Stage 3 on a new machine' {
    AfterEach { $env:PATH = $script:SavedPath }

    It 'installs WSL and every app at its version, pins two, sets the profile, and asks for a restart' {
        $c = New-Stage3 -Fresh
        $global:CriaFake.Env['User/OLLAMA_HOST'] = '0.0.0.0'
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'reboot'
        Get-Call 'wsl --install --no-distribution' | Should -HaveCount 1
        Get-Call 'winget install --id Ollama.Ollama *' | Should -Match '--version 0\.35\.1'
        Get-Call 'winget install --id Python.Python.3.13 *' | Should -Not -Match '--version'
        Get-Call 'winget install --id Python.Python.3.13 *' | Should -Match '--override /quiet InstallAllUsers=1 TargetDir=C:\\Python313 '
        Get-Call 'winget install --id Ollama.Ollama *' | Should -Not -Match '--override'
        Get-Call 'winget install --id Microsoft.PowerShell *' | Should -BeNullOrEmpty
        Get-Call 'winget install*' | Should -HaveCount ($script:Apps.packages.Count - 1)
        Get-Call 'winget pin add --id Docker.DockerDesktop*' | Should -HaveCount 1
        Get-Call 'winget pin add --id Ollama.Ollama*' | Should -HaveCount 1
        $global:CriaFake.Env['Machine/OLLAMA_KEEP_ALIVE'] | Should -Be '45s'
        $global:CriaFake.Env.ContainsKey('User/OLLAMA_HOST') | Should -BeFalse
        Get-Call 'stop ollama*' | Should -HaveCount 2
        # Docker waits for the restart.
        Get-Call 'start *' | Should -BeNullOrEmpty
    }

    It 'fails, naming the app, when winget cannot install it' {
        $c = New-Stage3 -Fresh
        $global:CriaFake.Feature['VirtualMachinePlatform'] = 'Enabled'
        $global:CriaWorld.Wsl = $true
        $global:CriaWorld.InstallCode = 1
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'winget could not install Docker\.DockerDesktop 4\.94\.0 \(exit 1\)'
    }

    It 'starts Docker Desktop as the user and waits for its engine' {
        $c = New-Stage3
        $global:CriaWorld.Docker = $false
        Set-Content -LiteralPath $c['DockerDesktop'] -Value ''
        $global:CriaFake.OnStart = { param($Path) $global:CriaWorld.Docker = $true }
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'done'
        Get-Call 'start *' | Should -Be @("start $($c['DockerDesktop'])")
        $r.Steps | Should -Contain 'Docker engine 28.0.1 answers'
    }

    It 'asks for a person when the Docker engine never answers' {
        $c = New-Stage3
        $global:CriaWorld.Docker = $false
        Set-Content -LiteralPath $c['DockerDesktop'] -Value ''
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match 'Engine running'
    }
}

Describe 'Stage 3 questions' {
    AfterEach { $env:PATH = $script:SavedPath }

    It 'asks about a different GPU and accepts it once answered' {
        $c = New-Stage3
        $global:CriaWorld.Gpu = 'NVIDIA GeForce RTX 3060, 600.01'
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Id | Should -Be 'gpu'
        $c = New-Stage3 -Accepted 'gpu'
        $global:CriaWorld.Gpu = $null
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'done'
        ($r.Warnings -join ' ') | Should -Match 'no NVIDIA card instead of'
    }

    It 'warns about a different driver without stopping' {
        $c = New-Stage3
        $global:CriaWorld.Gpu = "$($script:Apps.gpu.name), 1.0"
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'done'
        ($r.Warnings -join ' ') | Should -Match 'the GPU driver is 1\.0'
    }

    It 'stops before anything else when virtualisation is off' {
        $c = New-Stage3 -Fresh
        $global:CriaFake.Virtualization = @{ Firmware = $false; Hypervisor = $false }
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'needs-user'
        $global:CriaCalls | Should -BeNullOrEmpty
    }

    It 'plans without changing anything' {
        $c = New-Stage3 -Mode Plan -Fresh
        $r = Invoke-Stage '03-runtime.ps1' $c
        $r.Status | Should -Be 'planned'
        ($r.Steps -join "`n") | Should -Match 'would install WSL'
        ($r.Steps -join "`n") | Should -Match 'would install Ollama\.Ollama 0\.35\.1 with winget'
        ($r.Steps -join "`n") | Should -Match 'would pin Ollama\.Ollama'
        Get-Call 'winget install*' | Should -BeNullOrEmpty
        Get-Call 'wsl --install*' | Should -BeNullOrEmpty
        Get-Call 'setenv*' | Should -BeNullOrEmpty
    }
}
