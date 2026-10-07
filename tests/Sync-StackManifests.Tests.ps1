#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '../tools/Sync-StackManifests.ps1'
    $script:Fakes = Join-Path $PSScriptRoot 'fakes'
    $script:Schemas = Join-Path $PSScriptRoot '../manifests/schemas'

    # The same addresses and names tests/fakes/fake-tailscale.ps1 reports,
    # put together at run time so none is ever written to a file.
    $script:Domain = 'example-tailnet' + '.ts' + '.net'
    $script:VpsIp = @('100', '64', '0', '8') -join '.'

    # An empty repo with the real schemas, and an optional Modelfile folder.
    function New-Repo([hashtable]$Modelfiles = @{}) {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $repo 'manifests/schemas'), (Join-Path $repo 'stack/modelfiles') -Force | Out-Null
        Copy-Item -Path (Join-Path $script:Schemas '*.json') -Destination (Join-Path $repo 'manifests/schemas')
        foreach ($k in $Modelfiles.Keys) { Set-Content -LiteralPath (Join-Path $repo "stack/modelfiles/$k") -Value $Modelfiles[$k] }
        return $repo
    }

    function Invoke-Manifest {
        param([string]$Repo, [string[]]$Only, [switch]$Execute, [string]$ComfyRoot = (Join-Path $TestDrive 'no-comfy'), [switch]$Offline, [hashtable]$Env = @{})
        $saved = @{}
        foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
        try {
            & $script:Tool -Only $Only -RepoPath $Repo -Execute:$Execute -ComfyRoot $ComfyRoot -Offline:$Offline -PassThru `
                -TailscaleCommand (Join-Path $script:Fakes 'fake-tailscale.ps1') `
                -DockerCommand (Join-Path $script:Fakes 'fake-docker-images.ps1') `
                -SshCommand (Join-Path $script:Fakes 'fake-ssh-docker.ps1') `
                -PythonCommand (Join-Path $script:Fakes 'fake-python.ps1') `
                -WingetCommand (Join-Path $script:Fakes 'fake-winget.ps1') `
                -NvidiaSmiCommand (Join-Path $script:Fakes 'fake-nvidia-smi.ps1')
        }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    }

    function Get-Doc([string]$Repo, [string]$Name) { Get-Content -LiteralPath (Join-Path $Repo "manifests/$Name") -Raw | ConvertFrom-Json }

    function Test-Schema([string]$Repo, [string]$Name) {
        Test-Json -Path (Join-Path $Repo "manifests/$Name.json") -SchemaFile (Join-Path $script:Schemas "$Name.schema.json")
    }

    # A git checkout with one commit, and an origin.
    function New-GitFolder([string]$Path, [string]$Origin, [hashtable]$Files = @{ 'README.md' = 'x' }) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        foreach ($k in $Files.Keys) {
            $p = Join-Path $Path $k
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            Set-Content -LiteralPath $p -Value $Files[$k]
        }
        git -C $Path init -q
        git -C $Path add -A
        git -C $Path -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m init
        git -C $Path remote add origin $Origin
        return (git -C $Path rev-parse HEAD)
    }

    function New-Weight([string]$Path, [int]$Bytes, [byte]$Fill) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        $data = [byte[]]::new($Bytes)
        [Array]::Fill($data, $Fill)
        [IO.File]::WriteAllBytes($Path, $data)
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant()
    }

    function Get-FakeModel([string]$Name, [string]$Parent = '', [string]$Char = 'a') {
        [pscustomobject]@{
            name    = $Name
            digest  = $Char * 64
            size    = 1000
            details = [pscustomobject]@{ parent_model = $Parent; family = 'qwen3'; parameter_size = '9B'; quantization_level = 'Q4_K_M' }
        }
    }
}

# Mock bodies run in the tool's scope, so what they need is in globals.
AfterAll { Remove-Variable -Name CriaFakeModels, CriaFakeShaA, CriaFakeShaB -Scope Global -ErrorAction SilentlyContinue }

Describe 'Sync-StackManifests.ps1: Ollama' {
    BeforeEach {
        $global:CriaFakeModels = @(
            (Get-FakeModel 'qwen3.5-agent:9b' 'base/qwen:9b' 'b')
            (Get-FakeModel 'base/qwen:9b' '' 'c')
            (Get-FakeModel 'llama3:8b' '' 'd')
        )
        Mock Invoke-RestMethod { [pscustomobject]@{ models = $global:CriaFakeModels } } -ParameterFilter { "$Uri" -like '*/api/tags' }
        Mock Invoke-RestMethod { [pscustomobject]@{ version = '0.12.3' } } -ParameterFilter { "$Uri" -like '*/api/version' }
    }

    It 'lists every model, and points local builds at their Modelfile and base' {
        $repo = New-Repo @{ 'qwen3.5-agent_9b.Modelfile' = "FROM base/qwen:9b`nPARAMETER num_ctx 8192"; 'old_1b.Modelfile' = 'FROM gone:1b' }
        $r = Invoke-Manifest -Repo $repo -Only ollama -Execute
        $r.IsValid | Should -BeTrue
        Test-Schema $repo 'ollama-models' | Should -BeTrue
        $d = Get-Doc $repo 'ollama-models.json'
        $d.ollamaVersion | Should -Be '0.12.3'
        @($d.models.name) | Should -Be @('base/qwen:9b', 'llama3:8b', 'qwen3.5-agent:9b')
        $local = $d.models | Where-Object name -EQ 'qwen3.5-agent:9b'
        $local.source | Should -Be 'modelfile'
        $local.base | Should -Be 'base/qwen:9b'
        $local.modelfile | Should -Be 'stack/modelfiles/qwen3.5-agent_9b.Modelfile'
        ($d.models | Where-Object name -EQ 'llama3:8b').PSObject.Properties.Name | Should -Not -Contain 'modelfile'
        $r.Warnings | Should -Contain 'ollama: stack/modelfiles/old_1b.Modelfile builds no installed model'
    }

    It 'stops when a local build has no Modelfile' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only ollama -Execute
        $r.IsValid | Should -BeFalse
        $r.Problems | Should -Contain 'ollama: qwen3.5-agent:9b is built from base/qwen:9b here, but 0 Modelfiles in stack/modelfiles match it; it needs exactly one'
        Test-Path (Join-Path $repo 'manifests/ollama-models.json') | Should -BeFalse
    }

    It 'stops when Ollama does not answer' {
        Mock Invoke-RestMethod { throw 'connection refused' } -ParameterFilter { "$Uri" -like '*/api/tags' }
        $r = Invoke-Manifest -Repo (New-Repo) -Only ollama
        $r.Problems | Should -Contain 'ollama: the API at http://127.0.0.1:11434 did not answer; is Ollama running?'
    }
}

Describe 'Sync-StackManifests.ps1: ComfyUI' {
    BeforeAll {
        $script:Comfy = Join-Path $TestDrive 'ComfyUI'
        $script:ComfyCommit = New-GitFolder $script:Comfy 'https://github.com/comfyanonymous/ComfyUI.git' @{ 'main.py' = 'x'; 'custom_nodes/example_node.py.example' = 'x' }
        $script:NodeCommit = New-GitFolder (Join-Path $script:Comfy 'custom_nodes/ComfyUI-Manager') ('https://' + 'someone' + '@github.com/ltdrdata/ComfyUI-Manager.git')
        New-Item -ItemType Directory -Path (Join-Path $script:Comfy 'custom_nodes/hand-copied') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Comfy 'main.py') -Value 'changed'
    }

    It 'records ComfyUI, its nodes and its packages, and says what a rebuild would miss' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only comfyui -ComfyRoot $script:Comfy -Execute -Env @{ CRIA_FAKE_PIP = 'local' }
        $r.IsValid | Should -BeTrue
        Test-Schema $repo 'comfyui-nodes' | Should -BeTrue
        $d = Get-Doc $repo 'comfyui-nodes.json'
        $d.comfyui.commit | Should -Be $script:ComfyCommit
        $d.python | Should -Be '3.11.9'
        $d.pipIndexUrls | Should -Be @('https://download.pytorch.org/whl/cu124', 'https://pypi.org/simple')
        $d.nodes.Count | Should -Be 1
        $d.nodes[0].name | Should -Be 'ComfyUI-Manager'
        $d.nodes[0].repo | Should -Be 'https://github.com/ltdrdata/ComfyUI-Manager.git'
        $d.nodes[0].commit | Should -Be $script:NodeCommit
        $d.manual | Should -Be @('hand-copied')
        $lock = Get-Content -LiteralPath (Join-Path $repo 'manifests/comfyui-requirements.lock')
        @($lock | Where-Object { $_ -notmatch '^#' }) | Should -Be @('aiohttp==3.10.5', 'mypkg @ file:///C:/build/mypkg', 'Pillow==10.4.0', 'torch==2.5.1+cu124')
        ($lock -join "`n") | Should -Match 'index-url https://download\.pytorch\.org/whl/cu124 --extra-index-url https://pypi\.org/simple'
        $r.Warnings | Should -Contain "comfyui: ComfyUI's own file 'main.py' differs from its commit; a rebuild will not have that change"
        $r.Warnings | Should -Contain 'comfyui: custom node folder hand-copied is not a git checkout; it cannot be rebuilt from a commit'
        $r.Warnings | Should -Contain "comfyui: the venv package 'mypkg' was installed from a local folder or file; the lock cannot reinstall it"
    }

    It 'notes a torch build without CUDA' {
        $r = Invoke-Manifest -Repo (New-Repo) -Only comfyui -ComfyRoot $script:Comfy -Env @{ CRIA_FAKE_PIP = 'cpu' }
        $r.IsValid | Should -BeTrue
        $r.Warnings | Should -Contain 'comfyui: the venv has a torch build without CUDA'
    }

    It 'stops when pip fails, or the folder is not a checkout' {
        (Invoke-Manifest -Repo (New-Repo) -Only comfyui -ComfyRoot $script:Comfy -Env @{ CRIA_FAKE_PIP = 'fail' }).Problems |
            Should -Contain "comfyui: '$(Join-Path $script:Fakes 'fake-python.ps1')' failed (exit 1)"
        (Invoke-Manifest -Repo (New-Repo) -Only comfyui).Problems | Should -Contain 'comfyui: -ComfyRoot is not a git checkout'
    }

    It 'stops before writing when a package line holds a secret' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only comfyui -ComfyRoot $script:Comfy -Execute -Env @{ CRIA_FAKE_PIP = 'leak' }
        $r.IsValid | Should -BeFalse
        @($r.Problems | Where-Object { $_ -like 'manifests/comfyui-requirements.lock:*' }).Count | Should -BeGreaterThan 0
        ($r.Problems -join "`n") | Should -Not -Match 'ghp_'
        Test-Path (Join-Path $repo 'manifests/comfyui-requirements.lock') | Should -BeFalse
        Test-Path (Join-Path $repo 'manifests/comfyui-nodes.json') | Should -BeFalse
    }
}

Describe 'Sync-StackManifests.ps1: weights' {
    BeforeEach {
        $script:Comfy = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $script:ShaA = $global:CriaFakeShaA = New-Weight (Join-Path $script:Comfy 'models/checkpoints/a.safetensors') (1MB + 1) 1
        $script:ShaB = $global:CriaFakeShaB = New-Weight (Join-Path $script:Comfy 'models/b root.safetensors') 1MB 2
        $null = New-Weight (Join-Path $script:Comfy 'models/vae/small.txt') 100 3
    }

    It 'hashes every file of 1 MB or more, offline' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only weights -ComfyRoot $script:Comfy -Offline -Execute
        $r.IsValid | Should -BeTrue
        Test-Schema $repo 'comfyui-weights' | Should -BeTrue
        $w = (Get-Doc $repo 'comfyui-weights.json').weights
        @($w.dest) | Should -Be @('b root.safetensors', 'checkpoints/a.safetensors')
        $w[1].sha256 | Should -Be $script:ShaA
        $w[1].bytes | Should -Be (1MB + 1)
        $w[1].role | Should -Be 'checkpoints'
        $w[0].role | Should -Be 'root'
        $w[1].required | Should -BeTrue
        $w[1].url | Should -BeNullOrEmpty
        $r.Warnings | Should -Contain 'weights: checkpoints/a.safetensors has no known download URL; add one by hand, or keep a copy of the file'
    }

    It 'keeps a URL and required set by hand for the same bytes, and drops them when the file changed' {
        $repo = New-Repo
        $before = [ordered]@{ formatVersion = 1; weights = @(
                [ordered]@{ dest = 'checkpoints/a.safetensors'; bytes = 1MB + 1; sha256 = $script:ShaA; role = 'checkpoints'; required = $false; url = 'https://example.org/a'; auth = 'none'; checked = $false }
                [ordered]@{ dest = 'b root.safetensors'; bytes = 1MB; sha256 = ('0' * 64); role = 'root'; required = $false; url = 'https://example.org/b'; auth = 'none'; checked = $false }
            )
        }
        $before | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $repo 'manifests/comfyui-weights.json')
        $r = Invoke-Manifest -Repo $repo -Only weights -ComfyRoot $script:Comfy -Offline -Execute
        $r.IsValid | Should -BeTrue
        $r.Rows[0].Status | Should -Be 'changed'
        $w = (Get-Doc $repo 'comfyui-weights.json').weights
        ($w | Where-Object dest -EQ 'checkpoints/a.safetensors').url | Should -Be 'https://example.org/a'
        ($w | Where-Object dest -EQ 'checkpoints/a.safetensors').required | Should -BeFalse
        ($w | Where-Object dest -EQ 'b root.safetensors').url | Should -BeNullOrEmpty
        ($w | Where-Object dest -EQ 'b root.safetensors').required | Should -BeTrue
    }

    It 'finds a URL that serves the same SHA-256 on Hugging Face or Civitai' {
        $repo = New-Repo
        $list = Join-Path $script:Comfy 'custom_nodes/ComfyUI-Manager/model-list.json'
        New-Item -ItemType Directory -Path (Split-Path $list -Parent) -Force | Out-Null
        @{ models = @(
                @{ filename = 'a.safetensors'; url = 'https://huggingface.co/someone/wrong/resolve/main/a.safetensors' }
                @{ filename = 'a.safetensors'; url = 'https://huggingface.co/someone/right/resolve/main/a.safetensors' }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $list
        Mock Invoke-WebRequest {
            $etag = if ("$Uri" -like '*/right/*') { '"' + $global:CriaFakeShaA + '"' } else { '"' + ('9' * 64) + '"' }
            [pscustomobject]@{ StatusCode = 302; Headers = @{ 'X-Linked-Etag' = @($etag) } }
        }
        Mock Invoke-RestMethod {
            if ("$Uri" -notlike "*/by-hash/$($global:CriaFakeShaB)") { throw 'not found' }
            [pscustomobject]@{ files = @([pscustomobject]@{ downloadUrl = 'https://civitai.com/api/download/models/1'; hashes = [pscustomobject]@{ SHA256 = $global:CriaFakeShaB.ToUpperInvariant() } }) }
        }
        $r = Invoke-Manifest -Repo $repo -Only weights -ComfyRoot $script:Comfy -Execute
        $r.IsValid | Should -BeTrue
        $w = (Get-Doc $repo 'comfyui-weights.json').weights
        $a = $w | Where-Object dest -EQ 'checkpoints/a.safetensors'
        $a.url | Should -Be 'https://huggingface.co/someone/right/resolve/main/a.safetensors'
        $a.checked | Should -BeTrue
        $a.auth | Should -Be 'none'
        $b = $w | Where-Object dest -EQ 'b root.safetensors'
        $b.url | Should -Be 'https://civitai.com/api/download/models/1'
        $b.auth | Should -Be 'civitai'
    }
}

Describe 'Sync-StackManifests.ps1: Tailscale Serve' {
    It 'records the rules by port, with no host name' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only serve -Execute
        $r.IsValid | Should -BeTrue
        Test-Schema $repo 'serve' | Should -BeTrue
        $rules = (Get-Doc $repo 'serve.json').rules
        @($rules | ForEach-Object { "$($_.port) $($_.kind) $($_.PSObject.Properties['path'] ? $_.path : '-') $($_.target)" }) | Should -Be @(
            '443 https / http://127.0.0.1:3000'
            '8443 https / http://127.0.0.1:8090'
            '8443 https /api http://127.0.0.1:8091'
            '11434 tcp - 127.0.0.1:11434'
        )
        Get-Content -LiteralPath (Join-Path $repo 'manifests/serve.json') -Raw | Should -Not -Match ([regex]::Escape($script:Domain))
    }

    It 'templates a tailnet address in a rule, and lists the file as templated' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only serve -Execute -Env @{ CRIA_FAKE_SERVE = 'tailnet' }
        $r.IsValid | Should -BeTrue
        ((Get-Doc $repo 'serve.json').rules | Where-Object kind -EQ 'tcp').target | Should -Be '{{VPS_TS_IP}}:8090'
        (Get-Doc $repo 'endpoints.json').files[0].file | Should -Be 'manifests/serve.json'
    }

    It 'stops on Funnel, and on a rule it does not know' {
        (Invoke-Manifest -Repo (New-Repo) -Only serve -Env @{ CRIA_FAKE_SERVE = 'funnel' }).Problems |
            Should -Contain 'serve: Funnel is on for a port; the stack never uses Funnel (C-23)'
        (Invoke-Manifest -Repo (New-Repo) -Only serve -Env @{ CRIA_FAKE_SERVE = 'text' }).Problems |
            Should -Contain 'serve: port 443 / is not a proxy rule; this tool records proxies only'
    }
}

Describe 'Sync-StackManifests.ps1: container images' {
    It 'records the image behind every container on the PC and the VPS' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only images -Execute
        $r.IsValid | Should -BeTrue
        Test-Schema $repo 'images' | Should -BeTrue
        $d = Get-Doc $repo 'images.json'
        @($d.pc.container) | Should -Be @('ntfy', 'open-webui')
        ($d.pc | Where-Object container -EQ 'ntfy').project | Should -Be ''
        ($d.pc | Where-Object container -EQ 'open-webui').repoDigests | Should -Be @('ghcr.io/open-webui/open-webui@sha256:' + ('1' * 64))
        @($d.vps.container) | Should -Be @('kokoro-tts', 'vps-web-gateway')
        @(($d.vps | Where-Object container -EQ 'vps-web-gateway').repoDigests).Count | Should -Be 0
        $r.Warnings | Should -Contain 'images: VPS container vps-web-gateway runs a local image with no registry digest'
    }

    It 'stops when docker fails on either machine' {
        (Invoke-Manifest -Repo (New-Repo) -Only images -Env @{ CRIA_FAKE_IMAGES = 'fail-vps' }).Problems |
            Should -Contain "images: '$(Join-Path $script:Fakes 'fake-ssh-docker.ps1')' failed (exit 1)"
        (Invoke-Manifest -Repo (New-Repo) -Only images -Env @{ CRIA_FAKE_IMAGES = 'fail-pc' }).IsValid | Should -BeFalse
    }
}

Describe 'Sync-StackManifests.ps1: the run' {
    It 'plans without writing, then writes, then finds nothing to change' {
        $repo = New-Repo
        $plan = Invoke-Manifest -Repo $repo -Only serve, images
        $plan.Mode | Should -Be 'Plan'
        @($plan.Rows.Status) | Should -Be @('new', 'new')
        Test-Path (Join-Path $repo 'manifests/serve.json') | Should -BeFalse
        (Invoke-Manifest -Repo $repo -Only serve, images -Execute).IsValid | Should -BeTrue
        @((Invoke-Manifest -Repo $repo -Only serve, images).Rows.Status) | Should -Be @('unchanged', 'unchanged')
    }

    It 'stops when Tailscale is down, and when the repo is not ollama-cria' {
        (Invoke-Manifest -Repo (New-Repo) -Only serve -Env @{ CRIA_FAKE_TAILSCALE = 'down' }).Problems |
            Should -Contain "tailnet: 'tailscale status --json' failed; is Tailscale running and signed in?"
        (Invoke-Manifest -Repo $TestDrive -Only serve).Problems | Should -Contain '-RepoPath: not an ollama-cria checkout (no manifests folder)'
    }

    It 'says which sections run only on Windows' -Skip:$IsWindows {
        $r = Invoke-Manifest -Repo (New-Repo) -Only ollama-env, windows-apps, tasks
        $r.Problems | Should -Contain 'ollama-env: reads Machine-scope variables, so it runs on Windows only'
        $r.Problems | Should -Contain 'windows-apps: reads winget, so it runs on Windows only'
        $r.Problems | Should -Contain 'tasks: reads the Task Scheduler, so it runs on Windows only'
    }
}

Describe 'Sync-StackManifests.ps1 on Windows' -Skip:(-not $IsWindows) {
    It 'records the stack apps winget knows and the GPU driver' {
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only windows-apps -Execute
        $r.IsValid | Should -BeTrue
        Test-Schema $repo 'windows-apps' | Should -BeTrue
        $d = Get-Doc $repo 'windows-apps.json'
        @($d.packages.id) | Should -Be @('Ollama.Ollama', 'Git.Git')
        $d.gpu.driver | Should -Be '999.01'
        $r.Warnings | Should -Contain 'windows-apps: Docker.DockerDesktop is not installed through winget here'
    }

    It 'exports the stack tasks with the user templated, and says what it leaves out' {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $xml = "<?xml version=`"1.0`" encoding=`"UTF-16`"?>`n<Task><RegistrationInfo><Author>$env:USERDOMAIN\$env:USERNAME</Author></RegistrationInfo>" +
            "<Principals><Principal><UserId>$sid</UserId></Principal></Principals><Actions><Exec><Command>pwsh.exe</Command>" +
            "<Arguments>-File `"E:\ai\ollama\_support\scripts\ntfy\Watch-Fast.ps1`" -Log `"$env:USERPROFILE\x.log`"</Arguments></Exec></Actions></Task>"
        Mock Get-ScheduledTask {
            @(
                [pscustomobject]@{ TaskName = 'OWUI-ntfy-Fast'; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'pwsh.exe'; Arguments = '-File "E:\ai\ollama\_support\scripts\ntfy\Watch-Fast.ps1"' }) }
                [pscustomobject]@{ TaskName = 'OWUI-ntfy-MorningBrief'; State = 'Disabled'; Actions = @() }
                [pscustomobject]@{ TaskName = 'OWUI-Nightly-Backup'; State = 'Ready'; Actions = @() }
                [pscustomobject]@{ TaskName = 'Some vendor task'; State = 'Ready'; Actions = @() }
            )
        }
        Mock Export-ScheduledTask { $xml }
        $repo = New-Repo
        $r = Invoke-Manifest -Repo $repo -Only tasks -Execute
        $r.IsValid | Should -BeTrue
        Test-Schema $repo 'tasks' | Should -BeTrue
        $d = Get-Doc $repo 'tasks.json'
        @($d.tasks.name) | Should -Be @('OWUI-ntfy-Fast', 'OWUI-ntfy-MorningBrief')
        ($d.tasks | Where-Object name -EQ 'OWUI-ntfy-MorningBrief').enabled | Should -BeFalse
        ($d.tasks | Where-Object name -EQ 'OWUI-ntfy-Fast').runs | Should -Be @('stack/_support/scripts/ntfy/Watch-Fast.ps1')
        $d.notCovered | Should -Be @('Some vendor task')
        $r.Warnings | Should -Contain 'tasks: OWUI-ntfy-Fast runs stack/_support/scripts/ntfy/Watch-Fast.ps1, which is not in the repo'
        $r.Warnings | Should -Contain 'tasks: OWUI-Stack-Startup is not on this PC'
        $text = Get-Content -LiteralPath (Join-Path $repo 'windows/tasks/OWUI-ntfy-Fast.xml') -Raw
        $text | Should -Match '^<\?xml version="1\.0" encoding="UTF-8"\?>'
        $text | Should -Match '<Author>\{\{USER_ID\}\}</Author>'
        $text | Should -Match '<UserId>\{\{USER_SID\}\}</UserId>'
        $text | Should -Match '\{\{USER_PROFILE\}\}\\x\.log'
        $text | Should -Not -Match ([regex]::Escape($sid))
    }
}

Describe 'This repo: the manifests Sync-StackManifests.ps1 writes' {
    It 'match their schemas, where they exist yet' -ForEach @(
        @{ Name = 'ollama-models' }, @{ Name = 'ollama-env' }, @{ Name = 'windows-apps' }, @{ Name = 'comfyui-nodes' },
        @{ Name = 'comfyui-weights' }, @{ Name = 'serve' }, @{ Name = 'tasks' }, @{ Name = 'images' }
    ) {
        $file = Join-Path $PSScriptRoot "../manifests/$Name.json"
        if (-not (Test-Path -LiteralPath $file)) { Set-ItResult -Skipped -Because "$Name.json is not captured yet"; return }
        Test-Json -Path $file -SchemaFile (Join-Path $script:Schemas "$Name.schema.json") | Should -BeTrue
    }
}
