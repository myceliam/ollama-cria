#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Stage 9 (windows/stages/09-acceptance.ps1) against a small fake repo and a
# fake stack: every HTTP request answers from $global:CriaWeb, the VPS from
# $global:CriaFake.Vps. Keys are made up at run time. The last tests check
# the real manifests/acceptance.json.

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/StageContext.ps1')

    function Write-Text([string]$Path, [string]$Text) {
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
        [IO.File]::WriteAllText($Path, $Text)
    }

    function Write-Json([string]$Path, $Object) { Write-Text $Path (ConvertTo-Json -InputObject $Object -Depth 10) }

    function New-Row([string]$Id, [int]$Group, [hashtable]$Probe, [hashtable]$Extra = @{}) {
        $r = [ordered]@{ id = $Id; group = $Group; who = 'auto'; owner = 8; what = $Id; probe = $Probe }
        foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
        return $r
    }

    function New-Acceptance {
        [ordered]@{
            '$schema'     = './schemas/acceptance.schema.json'
            formatVersion = 1
            groups        = [ordered]@{ '1' = 'Local inference'; '2' = 'Presets'; '3' = 'Tool servers'; '4' = 'Tools and services'; '12' = 'From the VPS' }
            rows          = @(
                New-Row 'ollama-models' 1 @{ type = 'http'; url = 'http://127.0.0.1:11434/api/tags'; contains = '"models"' }
                [ordered]@{ id = 'local-chat'; group = 1; who = 'user'; owner = 3; what = 'a local model answers'; steps = 'Chat with a local model.' }
                New-Row 'server:time' 3 @{ type = 'mcpo'; server = 'time'; operation = 'get_current_time'; body = @{ timezone = 'Europe/London' }; contains = 'day_of_week' } @{ server = '/time/?$' }
                New-Row 'server:censys' 3 @{ type = 'mcpo'; server = 'censys' } @{ server = '/censys/?$' }
                New-Row 'server:github' 3 @{ type = 'mcpo'; server = 'github' } @{ server = '/github/?$' }
                New-Row 'server:open-terminal' 3 @{ type = 'http'; url = 'http://127.0.0.1:18019/files/cwd'; uses = 'terminal'; contains = 'cwd' } @{ server = ':18019(/|$)' }
                New-Row 'tool:brave_search' 4 @{ type = 'owui-load'; kind = 'tool'; id = 'brave_search' } @{ covers = @('tool:brave_search'); owner = 7 }
                New-Row 'function:comfyui_studio' 4 @{ type = 'owui-load'; kind = 'function'; id = 'comfyui_studio' } @{ covers = @('function:comfyui_studio'); owner = 7 }
                New-Row 'gateway-health' 4 @{ type = 'http'; url = 'http://127.0.0.1:13100/health'; fields = @{ status = 'ok'; brave_configured = $true } } @{ owner = 5 }
                New-Row 'gateway-research' 4 @{ type = 'http'; method = 'POST'; url = 'http://127.0.0.1:13100/research'; body = @{ query = 'q' }; fields = @{ status = @('ok', 'partial') } } @{ owner = 5 }
                New-Row 'kokoro-speech' 4 @{ type = 'http'; method = 'POST'; url = 'http://{{VPS_TS_IP}}:8880/v1/audio/speech'; body = @{ voice = 'af_heart' } } @{ owner = 5 }
                New-Row 'gcal-events' 4 @{ type = 'http'; url = 'http://127.0.0.1:18100/events/next?days=1'; uses = 'gcal'; fields = @{ source = 'google_calendar_live' } } @{ owner = 4 }
                [ordered]@{ id = 'media'; group = 4; who = 'user'; owner = 6; what = 'media'; steps = 'Make a picture.' }
                New-Row 'bolt-from-vps' 12 @{ type = 'vps'; url = 'http://{{PC_TS_IP}}:3001/mcp'; anyStatus = $true }
                New-Row 'terminal-from-vps' 12 @{ type = 'vps'; url = 'http://{{PC_TS_IP}}:18019/health'; status = 200 }
            )
            models        = [ordered]@{ group = 2; owner = 7; prompt = 'Reply with the single word OK.'; timeoutSec = 300 }
        }
    }

    function New-Stage9([string]$Mode = 'Run', [switch]$NoSeed, [switch]$NoKey) {
        Reset-Fake
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $repo = Join-Path $base 'repo'
        Write-Text (Join-Path $repo 'linux/stages/09-reach.sh') ([IO.File]::ReadAllText((Join-Path $script:RealRepo 'linux/stages/09-reach.sh')))
        Write-Json (Join-Path $repo 'manifests/acceptance.json') (New-Acceptance)
        $seed = Join-Path $repo 'manifests/owui-seed/seed'
        if (-not $NoSeed) {
            Write-Json (Join-Path $seed 'config.json') @{
                'tool_server.connections' = @(
                    @{ url = 'http://mcpo-core:8000/time'; config = @{ enable = $true }; info = @{ id = 'time'; name = 'time' } }
                    @{ url = 'http://mcpo-core:8000/censys'; config = @{ enable = $true }; info = @{ name = 'Censys' } }
                    @{ url = 'http://{{PC_TS_IP}}:18019'; config = @{ enable = $true }; info = @{ name = 'Open Terminal' } }
                    @{ url = 'http://mcpo-core:8000/github'; config = @{ enable = $false }; info = @{ name = 'github' } }
                )
            }
            Write-Json (Join-Path $seed 'tool.json') @(@{ id = 'brave_search'; name = 'Brave search' })
            Write-Json (Join-Path $seed 'function.json') @(@{ id = 'comfyui_studio'; type = 'pipe'; is_active = 1 })
            Write-Json (Join-Path $seed 'skill.json') @(@{ id = 'concise'; is_active = 1 })
            Write-Json (Join-Path $seed 'model.json') @(
                @{ id = 'helper'; base_model_id = 'qwen3:8b'; is_active = 1; meta = @{ toolIds = @('brave_search'); skillIds = @('concise') } }
                @{ id = 'resting'; base_model_id = 'qwen3:8b'; is_active = 0; meta = @{} }
                @{ id = 'studio-hd'; base_model_id = 'comfyui_studio.hd'; is_active = 1; meta = @{} }
            )
        }

        $c = New-TestContext -Stage 9 -Mode $Mode -RepoRoot $repo -Base $base
        Initialize-ProtectedFolder -Path $c.StagingRoot
        $keys = @{ owui = 'sk-' + ('A' * 40); mcpo = 'm' * 32; terminal = 't' * 32; gcal = 'g' * 32 }
        if (-not $NoKey) {
            $k = Open-NewOwnerOnlyFile -Path (Join-Path $c.StagingRoot 'owui-api-key.txt')
            try { $b = [Text.Encoding]::ASCII.GetBytes($keys.owui); $k.Write($b, 0, $b.Length) } finally { $k.Dispose() }
        }
        $live = $c.Topology['roots']['stack']['path']
        Write-Text (Join-Path $live '.env') "# stack`nMCPO_API_KEY=$($keys.mcpo)`nOPEN_TERMINAL_API_KEY=`"$($keys.terminal)`"`n"
        Write-Text (Join-Path $live 'gcal-owui-bridge/.env') "GCAL_BRIDGE_API_KEY=$($keys.gcal)`n"

        $global:CriaWeb = @{
            Keys       = $keys
            Override   = @{}
            Models     = @{ helper = @{ toolIds = @('brave_search'); skillIds = @('concise') } }
            Skills     = @{ concise = $true }
            Answer     = 'OK'
            Posted     = [Collections.Generic.List[string]]::new()
            PrivateBit = 'Dentist with ' + 'Dr Example'
            Pc         = @('100', '64', '0', '7') -join '.'
            Vps        = @('100', '64', '0', '8') -join '.'
        }
        $global:CriaFake.Call = {
            param($Method, $Uri, $Headers, $Body)
            $w = $global:CriaWeb
            if ($null -ne $Body) { $w.Posted.Add("$Uri $Body") }
            if ($w.Override.ContainsKey("$Method $Uri")) { return $w.Override["$Method $Uri"] }
            $bearer = { param($Name) $Headers['Authorization'] -eq "Bearer $($w.Keys[$Name])" }
            $ok = { param($Text) @{ Status = 200; Body = $Text } }
            $no = @{ Status = 401; Body = '{"detail":"no"}' }
            if ($Uri -like 'http://127.0.0.1:3000/*') {
                if (-not (& $bearer 'owui')) { return $no }
                if ($Uri -like '*/api/v1/tools/') { return (& $ok '[]') }
                if ($Uri -match '/api/v1/(tools|functions)/id/[^/]+/valves/spec$') { return (& $ok 'null') }
                if ($Uri -match '/api/v1/models/model\?id=(.+)$') {
                    $m = $w.Models[[uri]::UnescapeDataString($Matches[1])]
                    if (-not $m) { return @{ Status = 404; Body = '{}' } }
                    return (& $ok (@{ id = $Matches[1]; meta = $m } | ConvertTo-Json -Depth 5))
                }
                if ($Uri -match '/api/v1/skills/id/(.+)$') {
                    $s = [uri]::UnescapeDataString($Matches[1])
                    if (-not $w.Skills.ContainsKey($s)) { return @{ Status = 404; Body = '{}' } }
                    return (& $ok (@{ id = $s; is_active = $w.Skills[$s] } | ConvertTo-Json))
                }
                if ($Uri -like '*/api/chat/completions') { return (& $ok (@{ choices = @(@{ message = @{ role = 'assistant'; content = $w.Answer } }) } | ConvertTo-Json -Depth 5)) }
                return @{ Status = 404; Body = '' }
            }
            if ($Uri -like 'http://127.0.0.1:18000/*') {
                if (-not (& $bearer 'mcpo')) { return $no }
                if ($Uri -like '*/openapi.json') { return (& $ok '{"paths":{"/get_host":{},"/search":{}}}') }
                if ($Uri -like '*/time/get_current_time') { return (& $ok '{"timezone":"Europe/London","day_of_week":"Tuesday"}') }
                return @{ Status = 404; Body = '' }
            }
            switch -Wildcard ($Uri) {
                'http://127.0.0.1:11434/api/tags' { return (& $ok '{"models":[]}') }
                'http://127.0.0.1:18019/files/cwd' { if (& $bearer 'terminal') { return (& $ok '{"cwd":"/home/user"}') } else { return $no } }
                'http://127.0.0.1:13100/health' { return (& $ok '{"status":"ok","brave_configured":true}') }
                'http://127.0.0.1:13100/research' { return (& $ok '{"status":"partial"}') }
                "http://$($w.Vps):8880/v1/audio/speech" { return (& $ok 'ID3') }
                'http://127.0.0.1:18100/events/next*' {
                    if ($Headers['X-API-Key'] -ne $w.Keys.gcal) { return $no }
                    return (& $ok (@{ source = 'google_calendar_live'; events = @(@{ summary = $w.PrivateBit }) } | ConvertTo-Json -Depth 4))
                }
            }
            return @{ Status = 0; Body = '' }
        }
        $global:CriaFake.Vps = {
            param($Call, $InputLines)
            $global:CriaWeb['VpsLines'] = @($InputLines)
            $out = foreach ($l in $InputLines) {
                $name, $url = $l -split ' '
                $code = if ($url -like '*:3001/*') { '401' } elseif ($url -like '*:18019/*') { '200' } else { '000' }
                if ($global:CriaWeb.Override.ContainsKey("vps $name")) { $code = $global:CriaWeb.Override["vps $name"] }
                "FACT reach_$name $code"
            }
            New-ExecResult 0 (@($out) + 'STEP asked them')
        }
        $c['Live'] = $live
        return $c
    }

    function Invoke-Check($Run, [hashtable]$Context, [string[]]$Accepted = @()) {
        $cc = Copy-Context $Context 'Check'
        $cc.Data = $Run.Data
        $cc.Accepted = $Accepted
        return (Invoke-Stage '09-acceptance.ps1' $cc)
    }

    function Get-Call([string]$Like) { @($global:CriaCalls | Where-Object { $_ -like $Like }) }
}

Describe 'Stage 9: functional tests' {

    It 'runs every auto row once, skips a server the seed does not enable, and asks for the user rows' {
        $c = New-Stage9
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Problems | Should -BeNullOrEmpty
        $r.Status | Should -Be 'done'
        $res = $r.Data['Results']
        @($res.Keys) | Should -Be @('ollama-models', 'server:time', 'server:censys', 'server:open-terminal', 'tool:brave_search', 'function:comfyui_studio',
            'gateway-health', 'gateway-research', 'kokoro-speech', 'gcal-events', 'bolt-from-vps', 'terminal-from-vps', 'model:helper', 'model:resting', 'model:studio-hd')
        @($res.Values | Where-Object { -not $_['ok'] }) | Should -BeNullOrEmpty
        $res['server:censys'].actual | Should -Be '2 tools'
        $res['bolt-from-vps'].actual | Should -Be 'HTTP 401 from the VPS'
        $res['model:resting'].actual | Should -Be 'inactive in the seed; not asked'
        $res['model:studio-hd'].actual | Should -Be 'built on the comfyui_studio pipe; its user row tests it'
        $r.Steps | Should -Contain 'skip  server:github: not a tool server the seed enables'

        # One call each; the tailnet placeholder filled in; one SSH call.
        Get-Call 'call POST http://127.0.0.1:18000/time/get_current_time' | Should -HaveCount 1
        Get-Call 'call GET http://127.0.0.1:18000/censys/openapi.json' | Should -HaveCount 1
        Get-Call '*github*' | Should -BeNullOrEmpty
        Get-Call "call POST http://$($global:CriaWeb.Vps):8880/v1/audio/speech" | Should -HaveCount 1
        Get-Call 'call GET http://127.0.0.1:3000/api/v1/functions/id/comfyui_studio/valves/spec' | Should -HaveCount 1
        Get-Call 'vps vps 09-reach.sh' | Should -HaveCount 1
        $pc = $global:CriaWeb.Pc
        $global:CriaWeb['VpsLines'] | Should -Be @("bolt-from-vps http://${pc}:3001/mcp", "terminal-from-vps http://${pc}:18019/health")
        # Only the active preset that is not a pipe is asked.
        Get-Call 'call POST http://127.0.0.1:3000/api/chat/completions' | Should -HaveCount 1
        $chat = @($global:CriaWeb.Posted | Where-Object { $_ -like '*chat/completions*' })[0]
        $chat | Should -BeLike '*"model":"helper"*'
        $chat | Should -BeLike '*"stream":false*'

        $k = Invoke-Check $r $c
        $k.Status | Should -Be 'needs-user'
        @($k.Asks | ForEach-Object Id) | Should -Be @('local-chat', 'media')
        $k.Asks[0].Text | Should -Be 'Chat with a local model. Then run again with -Accept local-chat.'
        $k.Steps | Should -Contain 'to answer every question at once: -Accept local-chat,media'
        $calls = $global:CriaCalls.Count
        $done = Invoke-Check $r $c @('local-chat', 'media')
        $done.Status | Should -Be 'passed'
        $global:CriaCalls.Count | Should -Be $calls -Because 'Check reads the recorded results and calls nothing'
        @($done.Checks | ForEach-Object What) | Should -Be @('acceptance.json covers every tool, function and tool server in the seed (C-46)',
            '1 Local inference', '2 Presets', '3 Tool servers', '4 Tools and services', '12 From the VPS')
        ($done.Checks | Where-Object What -EQ '4 Tools and services').Actual | Should -Be '7 of 7'
    }

    It 'never writes a key or an answer into its result' {
        $c = New-Stage9
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $k = Invoke-Check $r $c
        $text = (ConvertTo-Json -InputObject @($r, $k) -Depth 10)
        foreach ($v in $global:CriaWeb.Keys.Values) { $text | Should -Not -Match ([regex]::Escape($v)) }
        $text | Should -Not -Match ([regex]::Escape($global:CriaWeb.PrivateBit))
        $text | Should -Not -Match ([regex]::Escape($global:CriaWeb.Pc))
        $text | Should -Not -Match ([regex]::Escape($global:CriaWeb.Vps))
    }

    It 'names the owning stage of each failure, without quoting the answer' {
        $c = New-Stage9
        $w = $global:CriaWeb
        $w.Override['POST http://127.0.0.1:18000/time/get_current_time'] = @{ Status = 500; Body = 'boom' }
        $w.Override['GET http://127.0.0.1:13100/health'] = @{ Status = 200; Body = '{"status":"ok","brave_configured":false}' }
        $w.Override['POST http://127.0.0.1:13100/research'] = @{ Status = 200; Body = '{"status":"configuration_error"}' }
        $w.Override['GET http://127.0.0.1:11434/api/tags'] = @{ Status = 200; Body = '{"error":"x"}' }
        $w.Override['GET http://127.0.0.1:3000/api/v1/tools/id/brave_search/valves/spec'] = @{ Status = 500; Body = 'ModuleNotFoundError: secret detail' }
        $w.Override['vps terminal-from-vps'] = '000'
        Write-Text (Join-Path $c.Live 'gcal-owui-bridge/.env') "OTHER=1`n"
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain 'server:time failed (HTTP 500); Stage 8 owns it'
        $r.Problems | Should -Contain 'gateway-health failed (HTTP 200, but brave_configured is false); Stage 5 owns it'
        $r.Problems | Should -Contain "gateway-research failed (HTTP 200, but status is 'configuration_error'); Stage 5 owns it"
        $r.Problems | Should -Contain "ollama-models failed (HTTP 200, but the answer lacks '`"models`"'); Stage 8 owns it"
        $r.Problems | Should -Contain 'tool:brave_search failed (HTTP 500); Stage 7 owns it'
        $r.Problems | Should -Contain 'terminal-from-vps failed (nothing answered the VPS); Stage 8 owns it'
        $r.Problems | Should -Contain "gcal-events failed (GCAL_BRIDGE_API_KEY is not set in $(Join-Path $c.Live 'gcal-owui-bridge/.env') (Stage 4 renders it)); Stage 4 owns it"
        ($r.Problems -join "`n") | Should -Not -Match 'boom|secret detail'
        $r.Data['Results']['server:censys'].ok | Should -BeTrue -Because 'one failure does not stop the others'
    }

    It 'checks a preset''s attachments and answer' {
        $c = New-Stage9
        $global:CriaWeb.Models['helper'] = @{ toolIds = @('brave_search', 'extra'); skillIds = @('concise') }
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Problems | Should -Contain "model:helper failed (its toolIds are not the seed's); Stage 7 owns it"
        Get-Call 'call POST http://127.0.0.1:3000/api/chat/completions' | Should -BeNullOrEmpty

        $c = New-Stage9
        $global:CriaWeb.Skills['concise'] = $false
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Problems | Should -Contain "model:helper failed (its skill concise is not as the seed has it (switched the other way from the seed)); Stage 7 owns it"

        $c = New-Stage9
        $global:CriaWeb.Answer = '  '
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Problems | Should -Contain 'model:helper failed (HTTP 200, but no answer text); Stage 7 owns it'
    }

    It 'fails on a gap in coverage either way (C-46)' {
        $c = New-Stage9
        $seed = Join-Path $c.RepoRoot 'manifests/owui-seed/seed'
        Write-Json (Join-Path $seed 'tool.json') @(@{ id = 'nvd_recent_cves' })
        $cfg = Get-Content (Join-Path $seed 'config.json') -Raw | ConvertFrom-Json -AsHashtable
        $cfg['tool_server.connections'] += @{ url = 'http://mcpo-core:8000/shodan'; config = @{ enable = $true }; info = @{ name = 'Shodan' } }
        $cfg['tool_server.connections'] += @{ url = 'http://mcpo-core:8000/time/'; config = @{ enable = $true }; info = @{ name = 'time again' } }
        Write-Json (Join-Path $seed 'config.json') $cfg
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Contain "the seed's tool nvd_recent_cves has no row in acceptance.json (C-46)"
        $r.Problems | Should -Contain 'acceptance.json covers tool brave_search, which the seed does not hold (C-46)'
        $r.Problems | Should -Contain "the seed's tool server 'Shodan' has no row in acceptance.json (C-46)"
        $r.Data['Gaps'] | Should -HaveCount 3
        # Two connections to one server match one row: both are tested by it.
        $r.Problems | Should -Not -Match 'more than one row'

        $p = Invoke-Stage '09-acceptance.ps1' (Copy-Context $c 'Plan')
        $p.Status | Should -Be 'planned'
        $p.Warnings | Should -Contain "would fail: the seed's tool nvd_recent_cves has no row in acceptance.json"
    }

    It 'stops before calling anything without the seed or the OWUI key' {
        $c = New-Stage9 -NoSeed
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems | Should -Be @('manifests/owui-seed/seed is not in the repo yet: commit the seed from the first capture (docs/RESTORE.md 7d)')
        Get-Call 'call *' | Should -BeNullOrEmpty

        $c = New-Stage9 -NoKey
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Status | Should -Be 'failed'
        $r.Problems[0] | Should -BeLike "Stage 9 needs the OWUI API key: $(Join-Path $c.StagingRoot 'owui-api-key.txt') is missing. Create a key*"
        Get-Call 'call *' | Should -BeNullOrEmpty

        $c = New-Stage9
        $global:CriaWeb.Keys.owui = 'sk-' + ('B' * 40)
        $r = Invoke-Stage '09-acceptance.ps1' $c
        $r.Problems | Should -Be @("OWUI did not accept the API key in $(Join-Path $c.StagingRoot 'owui-api-key.txt') (HTTP 401). Create a new key in OWUI (Settings > Account > API keys), replace the file's contents with it, and run again.")
        Get-Call 'call *' | Should -HaveCount 1
    }

    It 'checks nothing it has not run' {
        $c = New-Stage9 'Check'
        $k = Invoke-Stage '09-acceptance.ps1' $c
        $k.Status | Should -Be 'failed'
        $k.Checks[0].What | Should -Be 'Stage 9 has run its probes'
    }

    It 'plans without touching anything' {
        $c = New-Stage9 'Plan'
        $p = Invoke-Stage '09-acceptance.ps1' $c
        $p.Status | Should -Be 'planned'
        $p.Warnings | Should -BeNullOrEmpty
        $p.Steps | Should -Contain "would check that acceptance.json covers the seed's 1 tools, 1 functions and 3 enabled tool servers"
        $p.Steps | Should -Contain 'would run 12 auto rows and one row for each of the 3 model presets (2 active)'
        $p.Steps | Should -Contain 'would then ask for 2 user rows: local-chat, media'
        $global:CriaCalls | Should -BeNullOrEmpty
    }
}

Describe 'manifests/acceptance.json' {

    BeforeAll {
        $script:Manifest = Join-Path $script:RealRepo 'manifests/acceptance.json'
        $script:Schema = Join-Path $script:RealRepo 'manifests/schemas/acceptance.schema.json'
        $script:Acc = Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json -AsHashtable
        $script:SeedSchema = Get-Content -LiteralPath (Join-Path $script:RealRepo 'manifests/owui-seed/schema.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    It 'matches its schema, and the schema refuses a row with the wrong half' {
        Test-Json -Path $script:Manifest -SchemaFile $script:Schema | Should -BeTrue
        $bad = Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json -AsHashtable
        $bad['rows'][0]['steps'] = 'do it'
        Test-Json -Json (ConvertTo-Json $bad -Depth 20) -SchemaFile $script:Schema -ErrorAction SilentlyContinue | Should -BeFalse
        $bad = Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json -AsHashtable
        $bad['rows'][0]['probe'] = @{ type = 'http'; url = 'http://192.168.1.2:80/' }
        Test-Json -Json (ConvertTo-Json $bad -Depth 20) -SchemaFile $script:Schema -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'has unique ids and a name for every group' {
        $ids = @($script:Acc['rows'] | ForEach-Object { $_['id'] })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        foreach ($r in $script:Acc['rows']) { $script:Acc['groups'].ContainsKey("$($r['group'])") | Should -BeTrue -Because $r['id'] }
        $script:Acc['groups'].ContainsKey("$($script:Acc['models']['group'])") | Should -BeTrue
    }

    It 'covers exactly the tools and functions the seed schema expects' {
        $covers = @($script:Acc['rows'] | ForEach-Object { @($_['covers'] | Where-Object { $_ }) })
        $want = @($script:SeedSchema['expected_ids']['tool'] | ForEach-Object { "tool:$_" }) + @($script:SeedSchema['expected_ids']['function'] | ForEach-Object { "function:$_" })
        @($covers | Sort-Object -Unique) | Should -Be @($want | Sort-Object -Unique)
    }

    It 'gives every server row a regex that matches its own mcpo route' {
        foreach ($r in @($script:Acc['rows'] | Where-Object { $_['server'] -and $_['probe']['type'] -eq 'mcpo' })) {
            "http://mcpo-core:8000/$($r['probe']['server'])" | Should -Match $r['server'] -Because $r['id']
            "http://mcpo-core:8000/$($r['probe']['server'])x" | Should -Not -Match $r['server'] -Because $r['id']
        }
    }

    It 'leaves no gap against a seed holding the expected tools and functions' {
        $c = New-Stage9 'Plan'
        Copy-Item -LiteralPath $script:Manifest -Destination (Join-Path $c.RepoRoot 'manifests/acceptance.json') -Force
        $seed = Join-Path $c.RepoRoot 'manifests/owui-seed/seed'
        Write-Json (Join-Path $seed 'tool.json') @($script:SeedSchema['expected_ids']['tool'] | ForEach-Object { @{ id = $_ } })
        Write-Json (Join-Path $seed 'function.json') @($script:SeedSchema['expected_ids']['function'] | ForEach-Object { @{ id = $_; type = $(if ($_ -eq 'comfyui_studio') { 'pipe' } else { 'filter' }) } })
        $p = Invoke-Stage '09-acceptance.ps1' $c
        $p.Warnings | Should -BeNullOrEmpty
    }
}
