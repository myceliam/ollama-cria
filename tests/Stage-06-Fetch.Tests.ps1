#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 6 (windows/stages/06-fetch.ps1) against a small fake repo. git, py,
# the venv's python, ollama, curl and the Ollama API answer from
# $global:CriaWorld; downloads come from its Payload table.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')

    function Get-Sha([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }

    function Write-Json([string]$Path, $Object) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 6))
    }

    function New-Stage6([string]$Mode = 'Run', [string[]]$Accepted = @()) {
        Reset-Fake
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $repo = Join-Path $base 'repo'
        $payloadA = [byte[]](1..200)
        $payloadB = [byte[]](50..120)
        Write-Json (Join-Path $repo 'manifests/comfyui-nodes.json') @{
            comfyui      = @{ repo = 'https://example.invalid/ComfyUI.git'; commit = ('c' * 40) }
            python       = '3.11.9'
            pipIndexUrls = @('https://example.invalid/whl', 'https://example.invalid/simple')
            nodes        = @(@{ name = 'NodeA'; repo = 'https://example.invalid/NodeA.git'; commit = ('d' * 40) })
            manual       = @('NodeM (from a ZIP)')
        }
        Write-Json (Join-Path $repo 'manifests/ollama-models.json') @{ models = @(
                @{ name = 'base:1b'; digest = ('e' * 64); bytes = 1000; source = 'registry' }
                @{ name = 'mxbai-embed-large:latest'; digest = ('f' * 64); bytes = 1000; source = 'registry' }
                @{ name = 'custom:1b'; digest = ('1' * 64); bytes = 1000; source = 'modelfile'; base = 'base:1b'; modelfile = 'stack/modelfiles/custom.Modelfile' }
            )
        }
        Write-Json (Join-Path $repo 'manifests/comfyui-weights.json') @{ weights = @(
                @{ dest = 'checkpoints/a.safetensors'; bytes = $payloadA.Length; sha256 = (Get-Sha $payloadA); required = $true; url = 'https://example.invalid/a'; auth = 'none' }
                @{ dest = 'loras/b.safetensors'; bytes = $payloadB.Length; sha256 = (Get-Sha $payloadB); required = $true; url = 'https://example.invalid/b'; auth = 'civitai' }
                @{ dest = 'vae/c.safetensors'; bytes = 10; sha256 = ('0' * 64); required = $false; url = $null; auth = 'none' }
            )
        }
        Set-Content -LiteralPath (Join-Path $repo 'manifests/comfyui-requirements.lock') -Value 'torch==2.5.1'
        $null = New-Item -ItemType Directory -Path (Join-Path $repo 'stack/modelfiles') -Force
        Set-Content -LiteralPath (Join-Path $repo 'stack/modelfiles/custom.Modelfile') -Value 'FROM base:1b'

        $global:CriaWorld = @{
            Heads         = @{}
            FailCheckout  = $false
            Models        = @{}
            OllamaUp      = $true
            Registry      = @{ 'base:1b' = ('e' * 64); 'mxbai-embed-large:latest' = ('f' * 64) }
            Built         = @{ 'custom:1b' = ('1' * 64) }
            Payload       = @{ 'https://example.invalid/a' = $payloadA; 'https://example.invalid/b' = $payloadB }
            Curl          = [Collections.Generic.List[object]]::new()
            Pip           = [Collections.Generic.List[string]]::new()
            Torch         = 'True'
        }
        $global:CriaFake.Exec = {
            param($Name, $Arguments)
            $w = $global:CriaWorld
            if ($Name -eq 'git') {
                if ($Arguments[0] -eq 'clone') {
                    $f = [IO.Path]::GetFullPath($Arguments[-1])
                    $null = New-Item -ItemType Directory -Path (Join-Path $f '.git') -Force
                    $w.Heads[$f] = $null
                    return New-ExecResult 0
                }
                $f = [IO.Path]::GetFullPath($Arguments[1])
                if ($Arguments -contains 'rev-parse') { if ($w.Heads[$f]) { return New-ExecResult 0 @($w.Heads[$f]) } else { return New-ExecResult 128 } }
                if ($Arguments -contains 'checkout') { if ($w.FailCheckout) { return New-ExecResult 1 } ; $w.Heads[$f] = $Arguments[-1]; return New-ExecResult 0 }
                return New-ExecResult 0
            }
            if ($Name -eq 'py') {
                if ($Arguments -contains '--version') { return New-ExecResult 0 @('Python 3.11.9') }
                $python = if ($IsWindows) { Join-Path $Arguments[-1] 'Scripts/python.exe' } else { Join-Path $Arguments[-1] 'bin/python' }
                $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($python)) -Force
                Set-Content -LiteralPath $python -Value ''
                return New-ExecResult 0
            }
            if ($Name -match 'python(\.exe)?$') {
                if ($Arguments[0] -eq '-c') { return New-ExecResult 0 @($w.Torch) }
                $w.Pip.Add($Arguments -join ' ')
                return New-ExecResult 0
            }
            if ($Name -eq 'ollama') {
                if ($Arguments[0] -eq 'pull') { $w.Models[$Arguments[1]] = $w.Registry[$Arguments[1]] }
                else { $w.Models[$Arguments[1]] = $w.Built[$Arguments[1]] }
                return New-ExecResult 0
            }
            if ($Name -eq 'curl') {
                $out = $Arguments[[array]::IndexOf($Arguments, '--output') + 1]
                $header = if ($Arguments -contains '--header') { $Arguments[[array]::IndexOf($Arguments, '--header') + 1].TrimStart('@') } else { $null }
                $w.Curl.Add(@{ Url = $Arguments[-1]; Header = $header; HeaderText = $(if ($header) { (Get-Content -LiteralPath $header -Raw).Trim() } else { $null }) })
                $have = (Get-Item -LiteralPath $out).Length
                $bytes = [byte[]]$w.Payload[$Arguments[-1]]
                $stream = [IO.File]::Open($out, [IO.FileMode]::Append)
                try { $stream.Write($bytes, [int]$have, $bytes.Length - [int]$have) } finally { $stream.Dispose() }
                return New-ExecResult 0
            }
            return New-ExecResult -1
        }
        $global:CriaFake.Http = {
            param($Uri)
            $w = $global:CriaWorld
            if (-not $w.OllamaUp) { return $null }
            if ($Uri -like '*/api/version') { return [pscustomobject]@{ version = '0.35.1' } }
            return [pscustomobject]@{ models = @($w.Models.Keys | ForEach-Object { [pscustomobject]@{ name = $_; digest = $w.Models[$_] } }) }
        }
        $c = New-TestContext -Stage 6 -Mode $Mode -RepoRoot $repo -Base $base -Accepted $Accepted
        $null = New-Item -ItemType Directory -Path $c.StagingRoot -Force
        Set-OwnerOnly $c.StagingRoot
        $c['OllamaApp'] = Join-Path $base 'ollama app.exe'
        $c['Comfy'] = [IO.Path]::GetFullPath($c.Topology.roots.comfyui.path)
        return $c
    }

    function Invoke-Run($Context) {
        $r = Invoke-Stage '06-fetch.ps1' $Context
        $Context.Data = $r.Data
        return $r
    }

    function Add-Token($Context) {
        $file = Join-Path $Context.StagingRoot 'download-tokens/civitai-token.txt'
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($file)) -Force
        $s = Open-NewOwnerOnlyFile -Path $file
        $token = 'tok' + ('A' * 20)
        try { $b = [Text.Encoding]::ASCII.GetBytes("$token`n"); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
        return $token
    }
}

AfterAll {
    Remove-Variable -Name CriaFake, CriaCalls, CriaWorld -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Stage 6: plan' {
    It 'says what it would fetch and changes nothing' {
        $c = New-Stage6 -Mode Plan
        $r = Invoke-Stage '06-fetch.ps1' $c
        $r.Status | Should -Be 'planned'
        $r.Problems | Should -BeNullOrEmpty
        ($r.Steps -join "`n") | Should -Match 'would clone ComfyUI to cccccccccccc'
        ($r.Steps -join "`n") | Should -Match 'would pull or build 3 of 3 Ollama models'
        ($r.Steps -join "`n") | Should -Match 'would download the weights once ComfyUI is cloned'
        Test-Path -LiteralPath $c.Comfy | Should -BeFalse
        @($global:CriaCalls | Where-Object { $_ -notlike 'git -C *' }) | Should -BeNullOrEmpty
    }
}

Describe 'Stage 6: run and check' {
    It 'clones, builds the venv, fetches models and weights, asks for a token, then finishes with it' {
        $c = New-Stage6
        $r = Invoke-Run $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'needs-user'
        $r.Asks[0].Text | Should -Match 'civitai token'
        $global:CriaWorld.Heads[$c.Comfy] | Should -Be ('c' * 40)
        $global:CriaWorld.Heads[[IO.Path]::GetFullPath((Join-Path $c.Comfy 'custom_nodes/NodeA'))] | Should -Be ('d' * 40)
        $global:CriaWorld.Pip[0] | Should -Match '--requirement .*comfyui-requirements.lock --index-url https://example.invalid/whl --extra-index-url https://example.invalid/simple'
        @($global:CriaCalls | Where-Object { $_ -like 'ollama *' }) | Should -Be @('ollama pull base:1b', 'ollama pull mxbai-embed-large:latest', "ollama create custom:1b -f $(Join-Path $c.RepoRoot 'stack/modelfiles/custom.Modelfile')")
        Test-Path -LiteralPath (Join-Path $c.Comfy 'models/checkpoints/a.safetensors') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $c.Comfy 'models/loras/b.safetensors') | Should -BeFalse
        ($r.Warnings -join ' ') | Should -Match 'vae/c.safetensors has no download link'
        ($r.Warnings -join ' ') | Should -Match 'install by hand \(not automated\): NodeM'
        (@(Get-OwnedItem -State $c.State -Path $c.Comfy)[0]).retry | Should -Be 'keep'
        $global:CriaWorld.Curl[0].Header | Should -BeNullOrEmpty

        $token = Add-Token $c
        $global:CriaCalls.Clear()
        $r = Invoke-Run $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        Test-Path -LiteralPath (Join-Path $c.Comfy 'models/loras/b.safetensors') | Should -BeTrue
        $call = $global:CriaWorld.Curl[-1]
        $call.Url | Should -Be 'https://example.invalid/b'
        $call.HeaderText | Should -Be "Authorization: Bearer $token"
        Test-Path -LiteralPath $call.Header | Should -BeFalse
        ($global:CriaCalls -join "`n") | Should -Not -Match $token
        @($global:CriaCalls | Where-Object { $_ -like 'curl *' })[0] | Should -Match '--proto =https --proto-redir =https'
        # Only the new download; the first weight is remembered as checked.
        $global:CriaWorld.Curl.Count | Should -Be 2
        $tokenFile = @(Get-OwnedItem -State $c.State -Path (Join-Path $c.StagingRoot 'download-tokens/civitai-token.txt'))[0]
        $tokenFile.plaintext | Should -BeTrue
        $tokenFile.adopted | Should -BeTrue

        $k = Invoke-Stage '06-fetch.ps1' (Copy-Context $c 'Check')
        @($k.Checks | Where-Object { -not $_.Ok } | ForEach-Object { "$($_.What): $($_.Actual)" }) | Should -BeNullOrEmpty
        $k.Status | Should -Be 'passed'
    }

    It 'stops for a model whose digest moved on, and keeps it once accepted' {
        $c = New-Stage6
        $global:CriaWorld.Registry['base:1b'] = '9' * 64
        $r = Invoke-Run $c
        $r.Status | Should -Be 'needs-user'
        @($r.Asks | ForEach-Object Id) | Should -Contain 'model:base:1b'
        $c = New-Stage6 -Accepted 'model:base:1b'
        $global:CriaWorld.Registry['base:1b'] = '9' * 64
        $null = Add-Token $c
        $r = Invoke-Run $c
        $r.Status | Should -Be 'done'
        $r.Data.AcceptedDigests['base:1b'] | Should -Be ('9' * 64)
        $check = Copy-Context $c 'Check'
        $check.Accepted = @()
        $k = Invoke-Stage '06-fetch.ps1' $check
        $k.Status | Should -Be 'passed'
    }

    It 'deletes a download that does not match, and fails for a required weight' {
        $c = New-Stage6
        $null = Add-Token $c
        $global:CriaWorld.Payload['https://example.invalid/a'] = [byte[]](201..255)
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'checkpoints/a.safetensors: the download does not match its size and SHA-256; it was deleted'
        @(Get-ChildItem -LiteralPath (Join-Path $c.Comfy 'models/checkpoints') -Force).Count | Should -Be 0
    }

    It 'never changes a ComfyUI folder it did not create' {
        $c = New-Stage6
        $null = New-Item -ItemType Directory -Path (Join-Path $c.Comfy '.git') -Force
        $global:CriaWorld.Heads[$c.Comfy] = 'b' * 40
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'ComfyUI: .* is at bbbbbbbbbbbb; the controller does not change a folder it did not create'
        @($global:CriaCalls | Where-Object { $_ -like 'git clone*' -or $_ -like '*checkout*' }) | Should -BeNullOrEmpty
    }

    It 'clones again over an unfinished clone of its own' {
        $c = New-Stage6
        $global:CriaWorld.FailCheckout = $true
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'git checkout of cccccccccccc failed'
        $global:CriaWorld.FailCheckout = $false
        $null = Add-Token $c
        $global:CriaCalls.Clear()
        $r = Invoke-Run $c
        $r.Problems | Should -BeNullOrEmpty
        @($global:CriaCalls | Where-Object { $_ -like "git clone*ComfyUI.git*" }).Count | Should -Be 1
        $global:CriaWorld.Heads[$c.Comfy] | Should -Be ('c' * 40)
    }

    It 'starts Ollama when it does not answer, and asks when it never does' {
        $c = New-Stage6
        $null = Add-Token $c
        Set-Content -LiteralPath $c['OllamaApp'] -Value ''
        $global:CriaWorld.OllamaUp = $false
        $global:CriaFake.OnStart = { param($Path) $global:CriaWorld.OllamaUp = $true }
        $r = Invoke-Run $c
        $r.Status | Should -Be 'done'
        $r.Steps | Should -Contain 'started Ollama'
        $c = New-Stage6
        Set-Content -LiteralPath $c['OllamaApp'] -Value ''
        $global:CriaWorld.OllamaUp = $false
        $r = Invoke-Run $c
        $r.Status | Should -Be 'needs-user'
        ($r.Asks.Text -join ' ') | Should -Match 'Ollama did not answer'
    }

    It 'refuses to start without room for the models' {
        $c = New-Stage6
        $global:CriaFake.Free = [long]1000
        $r = Invoke-Run $c
        $r.Status | Should -Be 'failed'
        ($r.Problems -join ' ') | Should -Match 'not enough free space for the models'
        @($global:CriaCalls | Where-Object { $_ -like 'ollama *' }) | Should -BeNullOrEmpty
    }
}
