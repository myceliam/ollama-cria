# =============================================================================
#  owui-env-profiles.ps1
#  Environment-variable profile manager for the AI stack.
#
#  Dot-sourced by owui-toolkit.ps1. Provides:
#     owuihelp envprofile   - create / list / delete profiles (the gatekeeper)
#     owuihelp env          - edit the ACTIVE profile's variables
#     owuihelp profile      - activate a profile (with a full explained diff)
#     owuihelp drift        - intended vs registry vs what Ollama ACTUALLY used
#
#  Design notes (2026-08-25):
#   * Profiles are JSON. 'original' is a LOCKED baseline; every new profile
#     forks from it. It cannot be edited through the menus by design.
#   * Editing a profile is NOT the same as applying it. 'env' writes to the
#     profile file; 'profile' writes to the actual environment. This split is
#     deliberate - it means you can never half-break your live env mid-edit.
#   * Writes go to MACHINE scope only (changed 2026-08-29, option A). Since
#     the single-scope policy of 2026-08-29 every Ollama / llama.cpp / HF
#     variable lives at Machine scope and User scope holds none of them, so
#     there is one place to look and one place to edit. Applying therefore
#     REQUIRES an elevated shell; the check is enforced, not advisory.
#   * Any catalogued variable found at USER scope is now a POLICY VIOLATION,
#     not a shadow: User silently overrides Machine at process creation. It
#     is reported as a stray with the command to remove it.
#   * Values with a crash history on THIS machine are 'guarded': they require
#     typing the value out in full, and they print the incident log first.
# =============================================================================

# ---- store -----------------------------------------------------------------

$_owuienvRoot = if ($OWUI -and $OWUI.OllamaRoot) { $OWUI.OllamaRoot } else { 'E:\ai\ollama' }

$Global:OWUI_ENV = @{
    Root      = Join-Path $_owuienvRoot 'env-profiles'
    Rollback  = Join-Path $_owuienvRoot 'env-profiles\_rollback'
    StateFile = Join-Path $_owuienvRoot 'env-profiles\_state.json'
    Original  = 'original'
    Scope     = 'Machine'
    ServerLog = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
}

# ---- the catalogue ---------------------------------------------------------
# risk:  safe | caution | danger | inert
#   safe    - change freely, worst case is a preference
#   caution - real trade-offs, confirmed with y/N and an explanation
#   danger  - has caused a failure on THIS machine, guarded + typed confirm
#   inert   - the Ollama desktop app overrides this; setting it does nothing

$Global:OWUI_ENV_CATALOGUE = @(

    # ---------------- Stability & memory ----------------
    @{ name='OLLAMA_KV_CACHE_TYPE'; grp='Stability & memory'; type='enum'
       values=@('f16','q8_0','q4_0'); default='f16'; restart=$true; risk='danger'
       summary='Precision used to store the attention key/value cache.'
       why=@(
         'Every token generated appends a key and a value vector to a cache that'
         'lives in VRAM. f16 stores them at full half-precision. q8_0 and q4_0'
         'quantise them to save memory - roughly half and quarter the size.'
         ''
         'The saving is real, but on this machine quantised KV has twice caused'
         'numerical corruption that accumulates as the cache fills. It presents'
         'as a CUDA illegal memory access, or as the model emitting long runs of'
         'the token 0 late in a reasoning chain. It fails LATE, never at load,'
         'which is what makes it so easy to misdiagnose as a driver or VRAM fault.'
       )
       guard=@{ on=@('q8_0','q4_0')
                title='QUANTISED KV CACHE HAS CRASHED THIS MACHINE TWICE'
                incidents=@(
                  '2026-08-19  CUDA illegal memory access at ggml-cuda.cu:106, llama-server killed with 0xC0000409. Fixed by removing this variable.'
                  '2026-08-25  Recurred after a restore replayed an old env snapshot. Same fault, plus runs of 0 tokens mid-think-chain.'
                )
                also='Upstream llama.cpp #19036 confirms the triad: KV quantisation + flash attention + long prompt, and states it does not occur without the KV quantisation.' } }

    @{ name='OLLAMA_FLASH_ATTENTION'; grp='Stability & memory'; type='bool'
       values=@('1','0'); default='1'; restart=$true; risk='caution'
       summary='Use fused flash-attention kernels instead of the naive attention path.'
       why=@(
         'Flash attention computes attention in tiles that stay in fast on-chip'
         'memory, so it is markedly quicker at long context and uses less VRAM.'
         ''
         'On its own it is safe here and should stay on. It only becomes risky in'
         'combination with a quantised KV cache, which is the combination that'
         'caused both incidents. Turning it OFF is the correct escalation if a'
         'CUDA illegal memory access ever appears while KV cache is already f16.'
       ) }

    @{ name='OLLAMA_GPU_OVERHEAD'; grp='Stability & memory'; type='bytes'
       default='1073741824'; restart=$true; risk='caution'
       summary='VRAM held back from Ollama, in bytes, so other apps have headroom.'
       why=@(
         'Ollama sizes its model offload to fill the card. That starves ComfyUI,'
         'which then fails to allocate mid-generation.'
         ''
         'Reserving 1 GiB (1073741824) leaves ComfyUI room to breathe. Raise it if'
         'you run image and video work alongside the LLM; lower it to 0 if the LLM'
         'is the only thing on the card and you want maximum layers on GPU.'
         ''
         'This is a better lever than OLLAMA_KEEP_ALIVE=0 for GPU sharing, because'
         'it does not force a full model reload on every tool call.'
         ''
         'Handy values: 0 = none, 1073741824 = 1 GiB, 2147483648 = 2 GiB,'
         '3221225472 = 3 GiB, 4294967296 = 4 GiB.'
       )
       note='A reinstall of Ollama silently resets this to 0. Worth a drift check after any upgrade.' }

    @{ name='OLLAMA_CONTEXT_LENGTH'; grp='Stability & memory'; type='int'
       default=''; restart=$true; risk='inert'
       summary='Default context window in tokens - OVERRIDDEN by the desktop app.'
       why=@(
         'The Ollama desktop app has Settings > Context length, a slider offering'
         '4k / 8k / 16k / 32k / 64k / 128k / 256k. That slider WINS. This variable'
         'is a legacy path and is completely inert while the app is in charge.'
         ''
         'This was verified the hard way: the machine variable read 8192 while'
         'server.log reported n_ctx = 65536. Change the slider, not this.'
         ''
         'Remember the cost side too - at f16 the KV cache is about double the'
         'size it would be at q8_0, so raising the slider to 64k means noticeably'
         'more offload on a 16 GB card.'
       ) }

    # ---------------- Model lifecycle ----------------
    @{ name='OLLAMA_KEEP_ALIVE'; grp='Model lifecycle'; type='duration'
       default='0'; restart=$true; risk='caution'
       summary='How long a model stays resident in VRAM after a generation finishes. SELECTED POLICY: 0.'
       why=@(
         'This is a timer that starts when a generation ENDS. It is not a lease'
         'across a conversation, which is the usual misunderstanding.'
         ''
         '0 is the SELECTED OPERATING POLICY on this machine, confirmed by Liam on'
         '2026-08-29. The model unloads the moment a reply is emitted. This is a'
         'deliberate choice, not drift - do not reset it to 5m, and do not treat a'
         'live value of 0 as stale.'
         ''
         'The accepted cost, recorded honestly: at 0 the model also unloads after'
         'the reply that IS a tool call, then reloads when the result comes back -'
         'a three-tool turn costs four full loads. At 32k context that rebuild is'
         'not free. This cost is known and accepted.'
         ''
         'OLLAMA_GPU_OVERHEAD (1 GiB) is set alongside it for ComfyUI headroom.'
         'The two are complementary, not alternatives.'
         ''
         'Accepts Go durations: 30s, 5m, 1h, or -1 for never unload.'
       )
       note='2026-08-29: this entry previously argued for 5m and called older 0 guidance wrong. That was overruled - 0 is the intended value. Raise it only if Liam says so.' }

    @{ name='OLLAMA_MAX_LOADED_MODELS'; grp='Model lifecycle'; type='int'
       default='1'; restart=$true; risk='caution'
       summary='How many different models may sit in VRAM at once.'
       why=@(
         'On a 16 GB card with a 27B model that already offloads, anything above 1'
         'guarantees thrashing - two large models cannot coexist and Ollama will'
         'evict and reload constantly.'
         ''
         'Raise it only if you deliberately pair a large model with something tiny'
         'like an embedding model and have measured that both fit.'
       ) }

    @{ name='OLLAMA_NUM_PARALLEL'; grp='Model lifecycle'; type='int'
       default='1'; restart=$true; risk='caution'
       summary='Concurrent request slots per loaded model.'
       why=@(
         'Each parallel slot gets its own slice of the context window. With'
         'n_ctx 32768 and NUM_PARALLEL 2, each request effectively gets 16384.'
         ''
         'That is the trap: raising this silently HALVES your usable context'
         'rather than adding capacity. Keep it at 1 for single-user work.'
       ) }

    @{ name='OLLAMA_LOAD_TIMEOUT'; grp='Model lifecycle'; type='duration'
       default='5m'; restart=$true; risk='safe'
       summary='How long to wait for a model to finish loading before giving up.'
       why=@(
         'A 17 GB model loading from a SATA SSD with partial CPU offload can take'
         'a while. If you see load timeouts on big models, raise this to 10m.'
       ) }

    # ---------------- Serving & network ----------------
    @{ name='OLLAMA_HOST'; grp='Serving & network'; type='string'
       default='127.0.0.1:11434'; restart=$true; risk='inert'
       summary='Bind address and port - OVERRIDDEN by the app network setting.'
       why=@(
         'The desktop app has an "Expose Ollama to the network" toggle, and it'
         'wins. With it on, the server binds 0.0.0.0:11434 regardless of what'
         'this variable says.'
         ''
         'That toggle is what makes port 11434 reachable over Tailscale. Leave it'
         'on. It also means a remote Open WebUI is still using THIS GPU - so a'
         'fault seen "on the VPS" is not evidence that this machine is innocent.'
       ) }

    @{ name='OLLAMA_ORIGINS'; grp='Serving & network'; type='string'; nocompare=$true
       default=''; restart=$true; risk='caution'
       summary='Extra browser origins allowed to call the API (CORS).'
       why=@(
         'Comma-separated. Only needed when a web page on some other origin must'
         'talk to Ollama directly from the browser.'
         ''
         'Do not set this to * on a host that is exposed to the tailnet - it lets'
         'any page any browser visits drive your local models.'
       ) }

    @{ name='OLLAMA_MAX_QUEUE'; grp='Serving & network'; type='int'
       default='512'; restart=$true; risk='safe'
       summary='How many requests may queue before the server returns 503.'
       why=@(
         'Only matters under genuine concurrency. 512 is generous for a'
         'single-user stack and effectively never reached.'
       ) }

    @{ name='OLLAMA_MAX_TRANSFER_STREAMS'; grp='Serving & network'; type='int'
       default='4'; restart=$false; risk='safe'
       summary='Parallel connections used when pulling models from a registry.'
       why=@(
         'Raise for faster pulls on a fast link; lower if a pull is saturating'
         'the connection and disrupting everything else.'
       ) }

    # ---------------- Storage & models ----------------
    @{ name='OLLAMA_MODELS'; grp='Storage & models'; type='path'
       default='E:\ollama-models'; restart=$true; risk='danger'
       summary='Where model blobs and manifests are stored on disk.'
       why=@(
         'This is where roughly 200 GB of models live. Pointing it somewhere else'
         'does not move anything - Ollama simply finds an empty store and reports'
         'that you have no models installed.'
         ''
         'If you genuinely need to relocate, move the directory contents FIRST,'
         'then change this, then restart and confirm with "ollama list".'
       )
       guard=@{ on=@('*')
                title='CHANGING THIS CAN MAKE EVERY MODEL DISAPPEAR'
                incidents=@('No incident on this machine - guarded because the failure mode is silent and looks like data loss.')
                also='Move the files before changing the path, never after.' } }

    @{ name='OLLAMA_NOPRUNE'; grp='Storage & models'; type='bool'
       values=@('1','0'); default='0'; restart=$true; risk='caution'
       summary='Skip pruning of unused model blobs at startup.'
       why=@(
         'Normally Ollama tidies orphaned blobs when it starts. Setting this to 1'
         'keeps them, which is occasionally useful when recovering a store by'
         'hand - and otherwise just wastes disk.'
       ) }

    @{ name='OLLAMA_NO_CLOUD'; grp='Storage & models'; type='bool'
       values=@('1','0'); default='1'; restart=$true; risk='safe'
       summary='Hide cloud-hosted models from the model list.'
       why=@(
         'With this on, only models actually present on local disk are offered.'
         'Sensible for an air-gapped-ish local stack, and it keeps the list short.'
       ) }

    # ---------------- GPU selection ----------------
    @{ name='CUDA_VISIBLE_DEVICES'; grp='GPU selection'; type='string'
       default=''; restart=$true; risk='caution'
       summary='Restrict which NVIDIA GPUs Ollama can see, by index or UUID.'
       why=@(
         'Single-GPU machine, so leaving this unset is correct. Setting it to an'
         'index that does not exist makes Ollama fall back to CPU silently - the'
         'model still answers, just twenty times slower, which is a miserable'
         'thing to debug.'
       ) }

    @{ name='OLLAMA_SCHED_SPREAD'; grp='GPU selection'; type='bool'
       values=@('1','0'); default='0'; restart=$true; risk='safe'
       summary='Spread a model across all GPUs rather than filling one.'
       why=@('Multi-GPU only. No effect on a single-card machine.') }

    @{ name='OLLAMA_VULKAN'; grp='GPU selection'; type='bool'
       values=@('1','0'); default='1'; restart=$true; risk='safe'
       summary='Allow the Vulkan backend as an alternative to CUDA.'
       why=@(
         'CUDA is used on this card. Vulkan is the fallback path for hardware'
         'without a CUDA runtime, and is mostly irrelevant here.'
       ) }

    @{ name='OLLAMA_IGPU_ENABLE'; grp='GPU selection'; type='bool'
       values=@('1','0'); default='0'; restart=$true; risk='safe'
       summary='Allow an integrated GPU to be used for inference.'
       why=@(
         'An iGPU is far slower than the 4080 and shares system RAM. Only useful'
         'on machines with no discrete card.'
       ) }

    # ---------------- Diagnostics ----------------
    @{ name='OLLAMA_DEBUG'; grp='Diagnostics'; type='enum'
       values=@('INFO','DEBUG','WARN','ERROR'); default='INFO'; restart=$true; risk='safe'
       summary='Server log verbosity.'
       why=@(
         'DEBUG is genuinely useful when chasing a load or scheduling problem,'
         'but it makes server.log grow fast. Put it back to INFO afterwards.'
       ) }

    @{ name='OLLAMA_DEBUG_LOG_REQUESTS'; grp='Diagnostics'; type='bool'
       values=@('1','0'); default='0'; restart=$true; risk='caution'
       summary='Log the full body of every request.'
       why=@(
         'Excellent for debugging a misbehaving tool call, because you see exactly'
         'what Open WebUI sent.'
         ''
         'It also writes every prompt you type, verbatim, to a plain-text file on'
         'disk. Turn it off when you are done.'
       ) }

    @{ name='OLLAMA_NOHISTORY'; grp='Diagnostics'; type='bool'
       values=@('1','0'); default='0'; restart=$true; risk='safe'
       summary='Do not save readline history for the interactive "ollama run" CLI.'
       why=@('Only affects the terminal REPL. No impact on the API or Open WebUI.') }
)

# ---- small helpers ---------------------------------------------------------

function _owuienv_colour ([string]$Risk) {
    switch ($Risk) {
        'danger'  { 'Red' }
        'caution' { 'Yellow' }
        'inert'   { 'DarkGray' }
        default   { 'Green' }
    }
}

function _owuienv_tag ([string]$Risk) {
    switch ($Risk) {
        'danger'  { '(danger)' }
        'caution' { '(caution)' }
        'inert'   { '(inert - app overrides)' }
        default   { '' }
    }
}

function _owuienv_fmt ($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '<unset>' }
    return "$Value"
}

function _owuienv_var ([string]$Name) {
    return ($OWUI_ENV_CATALOGUE | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function _owuienv_ask ([string]$Prompt, [switch]$DefaultYes) {
    $suffix = if ($DefaultYes) { '(Y/n)' } else { '(y/N)' }
    $a = Read-Host "  $Prompt $suffix"
    if ($a -eq '') { return [bool]$DefaultYes }
    return ($a -in 'y','Y','yes','YES')
}

function _owuienv_pause { Write-Host ''; Read-Host '  press Enter to continue' | Out-Null }

function _owuienv_ensure_store {
    foreach ($d in @($OWUI_ENV.Root, $OWUI_ENV.Rollback)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function _owuienv_path ([string]$Name) { Join-Path $OWUI_ENV.Root "$Name.profile.json" }

function _owuienv_names {
    _owuienv_ensure_store
    @(Get-ChildItem (Join-Path $OWUI_ENV.Root '*.profile.json') -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name -replace '\.profile\.json$','' } | Sort-Object)
}

function _owuienv_user_names { @(_owuienv_names | Where-Object { $_ -ne $OWUI_ENV.Original }) }

function _owuienv_state {
    _owuienv_ensure_store
    if (Test-Path $OWUI_ENV.StateFile) {
        try { return (Get-Content $OWUI_ENV.StateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ active=$null; lastApplied=$null }
}

function _owuienv_set_state ([string]$Active, [string]$LastApplied) {
    _owuienv_ensure_store
    $s = _owuienv_state
    $obj = [ordered]@{
        active      = if ($Active)      { $Active }      else { $s.active }
        lastApplied = if ($LastApplied) { $LastApplied } else { $s.lastApplied }
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $OWUI_ENV.StateFile -Encoding UTF8
}

function _owuienv_load ([string]$Name) {
    $p = _owuienv_path $Name
    if (-not (Test-Path $p)) { return $null }
    $j = Get-Content $p -Raw | ConvertFrom-Json
    $h = @{}
    foreach ($k in $j.vars.PSObject.Properties.Name) { $h[$k] = $j.vars.$k }
    return @{ meta = $j.meta; vars = $h }
}

function _owuienv_save ([string]$Name, [hashtable]$Vars, $Meta) {
    _owuienv_ensure_store
    $ordered = [ordered]@{}
    foreach ($e in $OWUI_ENV_CATALOGUE) { if ($Vars.ContainsKey($e.name)) { $ordered[$e.name] = $Vars[$e.name] } }
    $doc = [ordered]@{ meta = $Meta; vars = $ordered }
    $doc | ConvertTo-Json -Depth 6 | Set-Content -Path (_owuienv_path $Name) -Encoding UTF8
}

# Read the live merged environment (Machine then User) for catalogued vars.
function _owuienv_capture_live {
    $h = @{}
    foreach ($scope in 'Machine','User') {
        $all = [Environment]::GetEnvironmentVariables($scope)
        foreach ($e in $OWUI_ENV_CATALOGUE) {
            $v = $all[$e.name]
            if ($null -ne $v -and "$v" -ne '') { $h[$e.name] = "$v" }
        }
    }
    foreach ($e in $OWUI_ENV_CATALOGUE) { if (-not $h.ContainsKey($e.name)) { $h[$e.name] = '' } }
    return $h
}

# Are we running elevated? Machine-scope writes require it.
function _owuienv_is_elevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Catalogued variables sitting at USER scope. Under the single-scope policy
# adopted 2026-08-29 these are policy violations, not shadows: User silently
# overrides Machine at process creation, so a stray here means the value you
# see in System Properties is NOT the value Ollama gets.
function _owuienv_user_strays {
    $out = @()
    $m = [Environment]::GetEnvironmentVariables('Machine')
    $u = [Environment]::GetEnvironmentVariables('User')
    foreach ($e in $OWUI_ENV_CATALOGUE) {
        $uv = $u[$e.name]
        if ($null -ne $uv -and "$uv" -ne '') {
            $mv = $m[$e.name]; if ($null -eq $mv -or "$mv" -eq '') { $mv = '<unset>' }
            $out += [pscustomobject]@{ Name=$e.name; Machine="$mv"; User=(_owuienv_fmt $uv) }
        }
    }
    return $out
}

# Shared reporting for strays.
function _owuienv_report_strays {
    $st = _owuienv_user_strays
    if (-not $st) { return }
    Write-Host ''
    Write-Host '  !! USER-SCOPE STRAYS - these OVERRIDE Machine scope:' -ForegroundColor Red
    foreach ($s in $st) {
        Write-Host ("      {0,-30} machine={1,-12} user={2}  <- WINS" -f $s.Name, $s.Machine, $s.User) -ForegroundColor Red
    }
    Write-Host '     Single-scope policy (2026-08-29): nothing belongs at User scope.' -ForegroundColor Red
    Write-Host '     Remove each one, then fully restart Ollama from the tray:' -ForegroundColor Red
    foreach ($s in $st) {
        Write-Host ("       [Environment]::SetEnvironmentVariable('{0}',`$null,'User')" -f $s.Name) -ForegroundColor DarkGray
    }
}

# What Ollama ACTUALLY resolved, straight from server.log. Ground truth.
function _owuienv_actual {
    $h = @{}
    if (-not (Test-Path $OWUI_ENV.ServerLog)) { return $h }
    $line = Get-Content $OWUI_ENV.ServerLog | Select-String -Pattern 'server config' | Select-Object -Last 1
    if (-not $line) { return $h }
    $t = $line.Line
    foreach ($e in $OWUI_ENV_CATALOGUE) {
        if ($t -match ($e.name + ':(\S*?)(?: [A-Z_]+:|\])')) { $h[$e.name] = $Matches[1] }
        elseif ($t -match ($e.name + ':(\S*)'))              { $h[$e.name] = $Matches[1] }
    }
    return $h
}

function _owuienv_restart {
    Write-Host '  restarting Ollama with a freshly merged environment...' -ForegroundColor DarkCyan
    $merged = @{}
    foreach ($scope in 'Machine','User') {
        $all = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in $all.Keys) { if ($k -like 'OLLAMA*' -and "$($all[$k])" -ne '') { $merged[$k] = $all[$k] } }
    }
    foreach ($k in $merged.Keys) { Set-Item -Path "Env:$k" -Value $merged[$k] }
    Get-Process -Name 'ollama app','ollama' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 4
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
    if (Test-Path $app) { Start-Process $app } else { Write-Host '  [x] ollama app.exe not found' -ForegroundColor Red; return }
    Write-Host '  waiting for the server...' -ForegroundColor DarkGray
    for ($i=0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 2
        try { $v = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 3
              Write-Host "  [ok] Ollama $($v.version) back up." -ForegroundColor Green; return } catch { }
    }
    Write-Host '  [!] server did not answer in time - check owuihelp status.' -ForegroundColor Yellow
}

# ---- explanation renderer --------------------------------------------------

function _owuienv_explain ($Entry, $Current) {
    _owui_head $Entry.name
    Write-Host "  $($Entry.summary)" -ForegroundColor Gray
    Write-Host ''
    foreach ($l in $Entry.why) { Write-Host "    $l" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host ("    type     : {0}" -f $Entry.type) -ForegroundColor DarkGray
    if ($Entry.ContainsKey('values')) { Write-Host ("    valid    : {0}" -f ($Entry['values'] -join ', ')) -ForegroundColor DarkGray }
    Write-Host ("    default  : {0}" -f (_owuienv_fmt $Entry.default)) -ForegroundColor DarkGray
    Write-Host ("    current  : {0}" -f (_owuienv_fmt $Current)) -ForegroundColor White
    Write-Host ("    risk     : {0}" -f $Entry.risk) -ForegroundColor (_owuienv_colour $Entry.risk)
    if ($Entry.restart) { Write-Host '    restart  : yes - Ollama must restart to pick this up' -ForegroundColor DarkYellow }
    if ($Entry.note)    { Write-Host ''; Write-Host "    ! $($Entry.note)" -ForegroundColor DarkYellow }
    if ($Entry.risk -eq 'inert') {
        Write-Host ''
        Write-Host '    ! This variable is overridden by the Ollama desktop app.' -ForegroundColor DarkYellow
        Write-Host '      You may set it, but it will have no effect.' -ForegroundColor DarkYellow
    }
}

# Guarded values need the value typed out, after the incident log is shown.
function _owuienv_guard_ok ($Entry, [string]$NewValue) {
    if (-not $Entry.guard) { return $true }
    $on = @($Entry.guard.on)
    if ($on -notcontains '*' -and $on -notcontains $NewValue) { return $true }

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host "   !!  $($Entry.guard.title)" -ForegroundColor Red
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host ''
    Write-Host "   You are setting $($Entry.name) = $NewValue" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   Incident history on this machine:' -ForegroundColor Yellow
    foreach ($i in @($Entry.guard.incidents)) { Write-Host "     - $i" -ForegroundColor DarkYellow }
    if ($Entry.guard.also) { Write-Host ''; Write-Host "   $($Entry.guard.also)" -ForegroundColor DarkYellow }
    Write-Host ''
    $typed = Read-Host "   To confirm you understand, type the value exactly ($NewValue)"
    if ($typed -ne $NewValue) {
        Write-Host '   did not match - change abandoned.' -ForegroundColor Green
        return $false
    }
    Write-Host '   confirmed.' -ForegroundColor DarkYellow
    return $true
}

# ---- value prompt ----------------------------------------------------------

function _owuienv_prompt_value ($Entry, $Current) {
    Write-Host ''
    if ($Entry.ContainsKey('values')) {
        $i = 0
        foreach ($v in $Entry['values']) {
            $i++
            $mark = ''
            if ($v -eq $Entry.default) { $mark += '  (default)' }
            if ($v -eq $Current)       { $mark += '  <- current' }
            $guarded = $Entry.guard -and (@($Entry.guard.on) -contains $v -or @($Entry.guard.on) -contains '*')
            if ($guarded) { $mark += '   !! GUARDED' }
            Write-Host ("    {0}  {1,-10}{2}" -f $i, $v, $mark) -ForegroundColor $(if ($guarded) { 'Red' } else { 'Yellow' })
        }
        Write-Host ("    {0}  <unset>   (fall back to Ollama's own default)" -f ($i+1)) -ForegroundColor DarkGray
        Write-Host '    0  leave unchanged' -ForegroundColor DarkGray
        Write-Host ''
        $sel = Read-Host '  choose'
        if ($sel -eq '0' -or $sel -eq '') { return @{ changed=$false } }
        if ($sel -eq "$($i+1)")           { return @{ changed=$true; value='' } }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Entry['values'].Count) {
            return @{ changed=$true; value=$Entry['values'][$n-1] }
        }
        Write-Host '  not a valid choice.' -ForegroundColor Red
        return @{ changed=$false }
    }

    Write-Host "    current: $(_owuienv_fmt $Current)" -ForegroundColor White
    Write-Host '    enter a new value, "unset" to clear it, or blank to leave unchanged' -ForegroundColor DarkGray
    Write-Host ''
    $raw = Read-Host '  value'
    if ($raw -eq '')      { return @{ changed=$false } }
    if ($raw -eq 'unset') { return @{ changed=$true; value='' } }

    switch ($Entry.type) {
        'int'   { $n=0; if (-not [int]::TryParse($raw,[ref]$n))    { Write-Host '  not a whole number.' -ForegroundColor Red; return @{changed=$false} } }
        'bytes' { $n=0; if (-not [long]::TryParse($raw,[ref]$n))   { Write-Host '  not a byte count.'   -ForegroundColor Red; return @{changed=$false} } }
        'duration' { if ($raw -notmatch '^(-1|\d+(\.\d+)?(ns|us|ms|s|m|h))$') { Write-Host '  not a Go duration (30s, 5m, 1h, -1).' -ForegroundColor Red; return @{changed=$false} } }
        'path'  { if (-not (Test-Path $raw)) {
                      Write-Host "  ! that path does not exist yet: $raw" -ForegroundColor DarkYellow
                      if (-not (_owuienv_ask 'use it anyway?')) { return @{changed=$false} } } }
    }
    return @{ changed=$true; value=$raw }
}

# =============================================================================
#  owuihelp envprofile   - the gatekeeper and profile lifecycle
# =============================================================================

function _owui_envprofile {
    _owuienv_ensure_store

    # Step 1: the locked baseline must exist before anything else can.
    if (-not (Test-Path (_owuienv_path $OWUI_ENV.Original))) {
        _owui_head 'No baseline profile yet'
        Write-Host '  Before any profile can exist, this toolkit needs a locked baseline' -ForegroundColor Gray
        Write-Host '  called "original". Every profile you create is a fork of it, and it' -ForegroundColor Gray
        Write-Host '  is the one thing you can always fall back to.' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  It will be seeded from your CURRENT environment:' -ForegroundColor Gray
        Write-Host ''
        $live = _owuienv_capture_live
        foreach ($e in $OWUI_ENV_CATALOGUE) {
            if ("$($live[$e.name])" -ne '') {
                Write-Host ("    {0,-30} {1}" -f $e.name, $live[$e.name]) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        Write-Host '  Once created it is LOCKED - the menus will refuse to edit it.' -ForegroundColor DarkYellow
        Write-Host '  To change it later, edit the JSON directly:' -ForegroundColor DarkYellow
        Write-Host ("    {0}" -f (_owuienv_path $OWUI_ENV.Original)) -ForegroundColor DarkYellow
        Write-Host ''
        if (-not (_owuienv_ask 'Create the "original" baseline from the values above?')) {
            Write-Host '  cancelled - nothing written.' -ForegroundColor DarkGray; return
        }
        _owuienv_save $OWUI_ENV.Original $live ([ordered]@{
            name        = $OWUI_ENV.Original
            locked      = $true
            created     = (Get-Date -Format o)
            forkedFrom  = $null
            description = 'Locked baseline. Verified-good configuration captured 2026-08-25 after the q8_0 KV cache incident: f16 KV cache, keep_alive 5m, flash attention on, 1 GiB GPU overhead. Proven clean at 28.8k context with a 3000-token reasoning chain.'
        })
        Write-Host '  [ok] baseline written.' -ForegroundColor Green
        Write-Host ''
    }

    # Step 2: lifecycle menu.
    while ($true) {
        $names  = _owuienv_names
        $users  = _owuienv_user_names
        $state  = _owuienv_state

        _owui_head 'ENV PROFILES'
        foreach ($n in $names) {
            $tags = ''
            if ($n -eq $OWUI_ENV.Original) { $tags += '  [locked baseline]' }
            if ($n -eq $state.active)      { $tags += '  [active]' }
            $p = _owuienv_load $n
            $when = if ($p.meta.created) { ([datetime]$p.meta.created).ToString('yyyy-MM-dd') } else { '' }
            Write-Host ("    {0,-22}" -f $n) -ForegroundColor Yellow -NoNewline
            Write-Host ("{0,-12}{1}" -f $when, $tags) -ForegroundColor DarkGray
        }
        if (-not $users) {
            Write-Host ''
            Write-Host '    (no editable profiles yet - "owuihelp env" stays locked until you make one)' -ForegroundColor DarkYellow
        }
        Write-Host ''
        Write-Host '    N  new profile (forked from original)' -ForegroundColor Gray
        Write-Host '    D  delete a profile' -ForegroundColor Gray
        Write-Host '    R  rename a profile' -ForegroundColor Gray
        Write-Host '    Q  quit' -ForegroundColor Gray
        Write-Host ''
        $c = (Read-Host '  choose').ToUpper()

        switch ($c) {
            'Q' { return }

            'N' {
                Write-Host ''
                Write-Host '  A new profile starts as an exact copy of "original", so you are' -ForegroundColor Gray
                Write-Host '  always building from the known-good baseline rather than from' -ForegroundColor Gray
                Write-Host '  whatever the environment happens to look like today.' -ForegroundColor Gray
                Write-Host ''
                $nm = Read-Host '  name it (letters, numbers, dash, underscore)'
                if ($nm -eq '') { Write-Host '  cancelled.' -ForegroundColor DarkGray; continue }
                if ($nm -notmatch '^[A-Za-z0-9_\-]+$') { Write-Host '  [x] invalid characters.' -ForegroundColor Red; continue }
                if ($nm -eq $OWUI_ENV.Original) { Write-Host '  [x] that name is reserved.' -ForegroundColor Red; continue }
                if ($names -contains $nm) { Write-Host '  [x] a profile with that name already exists.' -ForegroundColor Red; continue }
                $desc = Read-Host '  short description (optional)'
                $base = _owuienv_load $OWUI_ENV.Original
                _owuienv_save $nm $base.vars ([ordered]@{
                    name=$nm; locked=$false; created=(Get-Date -Format o)
                    forkedFrom=$OWUI_ENV.Original; description=$desc })
                Write-Host ''
                Write-Host "  [ok] created '$nm' as a fork of original." -ForegroundColor Green
                if (_owuienv_ask "make '$nm' the profile you are editing?" -DefaultYes) {
                    _owuienv_set_state -Active $nm
                    Write-Host "  [ok] '$nm' is now the active edit target." -ForegroundColor Green
                    Write-Host '  next: owuihelp env    to change its variables' -ForegroundColor DarkCyan
                }
                _owuienv_pause
            }

            'D' {
                $del = Read-Host '  name to delete'
                if ($del -eq $OWUI_ENV.Original) { Write-Host '  [x] the baseline cannot be deleted.' -ForegroundColor Red; continue }
                if ($names -notcontains $del)    { Write-Host '  [x] no such profile.' -ForegroundColor Red; continue }
                if (_owuienv_ask "permanently delete '$del'?") {
                    Remove-Item (_owuienv_path $del) -Force
                    if ($state.active -eq $del) { _owuienv_set_state -Active '' }
                    Write-Host "  [ok] deleted '$del'." -ForegroundColor Green
                }
            }

            'R' {
                $old = Read-Host '  current name'
                if ($old -eq $OWUI_ENV.Original) { Write-Host '  [x] the baseline cannot be renamed.' -ForegroundColor Red; continue }
                if ($names -notcontains $old)    { Write-Host '  [x] no such profile.' -ForegroundColor Red; continue }
                $new = Read-Host '  new name'
                if ($new -notmatch '^[A-Za-z0-9_\-]+$') { Write-Host '  [x] invalid characters.' -ForegroundColor Red; continue }
                if ($names -contains $new) { Write-Host '  [x] already taken.' -ForegroundColor Red; continue }
                $p = _owuienv_load $old
                $meta = $p.meta; $meta.name = $new
                _owuienv_save $new $p.vars $meta
                Remove-Item (_owuienv_path $old) -Force
                if ($state.active -eq $old) { _owuienv_set_state -Active $new }
                Write-Host "  [ok] renamed to '$new'." -ForegroundColor Green
            }

            default { }
        }
    }
}

# =============================================================================
#  owuihelp env   - edit the active profile
# =============================================================================

function _owui_env {
    _owuienv_ensure_store

    if (-not (Test-Path (_owuienv_path $OWUI_ENV.Original))) {
        _owui_head 'Environment editing is locked'
        Write-Host '  There is no baseline profile yet, so there is nothing safe to edit' -ForegroundColor Gray
        Write-Host '  against. Create one first:' -ForegroundColor Gray
        Write-Host ''
        Write-Host '     owuihelp envprofile' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    $users = _owuienv_user_names
    if (-not $users) {
        _owui_head 'Environment editing is locked'
        Write-Host '  A baseline exists, but you have no editable profile yet. The baseline' -ForegroundColor Gray
        Write-Host '  itself is deliberately read-only so there is always a clean fallback.' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Create a profile to edit:' -ForegroundColor Gray
        Write-Host ''
        Write-Host '     owuihelp envprofile      then choose N' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    $state = _owuienv_state
    $name  = $state.active
    if (-not $name -or $name -eq $OWUI_ENV.Original -or ($users -notcontains $name)) {
        Write-Host ''
        Write-Host '  No editable profile is selected. Pick one:' -ForegroundColor Gray
        Write-Host ''
        $i=0; foreach ($u in $users) { $i++; Write-Host ("    {0}  {1}" -f $i,$u) -ForegroundColor Yellow }
        Write-Host ''
        $sel = Read-Host '  choose'
        $n=0
        if (-not ([int]::TryParse($sel,[ref]$n)) -or $n -lt 1 -or $n -gt $users.Count) { Write-Host '  cancelled.' -ForegroundColor DarkGray; return }
        $name = $users[$n-1]
        _owuienv_set_state -Active $name
    }

    $prof    = _owuienv_load $name
    $working = @{}
    foreach ($k in $prof.vars.Keys) { $working[$k] = $prof.vars[$k] }
    foreach ($e in $OWUI_ENV_CATALOGUE) { if (-not $working.ContainsKey($e.name)) { $working[$e.name] = '' } }
    $saved = @{}
    foreach ($k in $working.Keys) { $saved[$k] = $working[$k] }

    while ($true) {
        $dirty = @($OWUI_ENV_CATALOGUE | Where-Object { "$($working[$_.name])" -ne "$($saved[$_.name])" })

        Write-Host ''
        Write-Host '  ENV EDITOR' -ForegroundColor White -BackgroundColor DarkBlue
        Write-Host ("  profile: {0}" -f $name) -ForegroundColor Cyan -NoNewline
        if ($dirty.Count) { Write-Host ("     [{0} unsaved change{1}]" -f $dirty.Count, $(if($dirty.Count -eq 1){''}else{'s'})) -ForegroundColor Yellow }
        else              { Write-Host '     [no unsaved changes]' -ForegroundColor DarkGray }

        $idx = @{}
        $n = 0
        foreach ($g in ($OWUI_ENV_CATALOGUE.grp | Select-Object -Unique)) {
            _owui_head $g
            foreach ($e in ($OWUI_ENV_CATALOGUE | Where-Object { $_.grp -eq $g })) {
                $n++; $idx[$n] = $e.name
                $val = _owuienv_fmt $working[$e.name]
                $mod = if ("$($working[$e.name])" -ne "$($saved[$e.name])") { '  [modified]' } else { '' }
                Write-Host ("    {0,3}  {1,-30}" -f $n, $e.name) -ForegroundColor Yellow -NoNewline
                Write-Host ("{0,-24}" -f $val) -ForegroundColor White -NoNewline
                Write-Host ("{0} {1}" -f (_owuienv_tag $e.risk), $mod) -ForegroundColor (_owuienv_colour $e.risk)
            }
        }

        Write-Host ''
        Write-Host '    [number] edit a variable     S  save to profile' -ForegroundColor Gray
        Write-Host '    R  revert all changes       X  explain a variable' -ForegroundColor Gray
        Write-Host '    Q  quit' -ForegroundColor Gray
        Write-Host ''
        $c = (Read-Host '  choose').Trim()

        if ($c.ToUpper() -eq 'Q') {
            if ($dirty.Count -and -not (_owuienv_ask "discard $($dirty.Count) unsaved change(s)?")) { continue }
            return
        }
        elseif ($c.ToUpper() -eq 'R') {
            if (-not $dirty.Count) { Write-Host '  nothing to revert.' -ForegroundColor DarkGray; continue }
            if (_owuienv_ask "revert all $($dirty.Count) change(s) back to the saved profile?") {
                foreach ($k in $saved.Keys) { $working[$k] = $saved[$k] }
                Write-Host '  [ok] reverted.' -ForegroundColor Green
            }
        }
        elseif ($c.ToUpper() -eq 'X') {
            $sel = Read-Host '  which number'
            $k=0; if ([int]::TryParse($sel,[ref]$k) -and $idx.ContainsKey($k)) {
                _owuienv_explain (_owuienv_var $idx[$k]) $working[$idx[$k]]
                _owuienv_pause
            }
        }
        elseif ($c.ToUpper() -eq 'S') {
            if (-not $dirty.Count) { Write-Host '  nothing to save.' -ForegroundColor DarkGray; continue }
            _owui_head "Save to '$name'"
            Write-Host ("  {0} change(s) will be written to the profile file:" -f $dirty.Count) -ForegroundColor Gray
            Write-Host ''
            foreach ($e in $dirty) {
                Write-Host ("    {0}" -f $e.name) -ForegroundColor Yellow
                Write-Host ("      {0}  ->  {1}" -f (_owuienv_fmt $saved[$e.name]), (_owuienv_fmt $working[$e.name])) -ForegroundColor White
                Write-Host ("      {0}" -f $e.summary) -ForegroundColor DarkGray
                if ($e.risk -ne 'safe') { Write-Host ("      {0}" -f (_owuienv_tag $e.risk)) -ForegroundColor (_owuienv_colour $e.risk) }
            }
            Write-Host ''
            Write-Host '  ! Saving updates the profile FILE only. Your live environment is' -ForegroundColor DarkYellow
            Write-Host '    untouched until you activate it with "owuihelp profile".' -ForegroundColor DarkYellow
            Write-Host ''
            if (_owuienv_ask 'save these changes?') {
                $meta = $prof.meta
                $meta | Add-Member -NotePropertyName modified -NotePropertyValue (Get-Date -Format o) -Force
                _owuienv_save $name $working $meta
                foreach ($k in $working.Keys) { $saved[$k] = $working[$k] }
                Write-Host "  [ok] saved to $((_owuienv_path $name))" -ForegroundColor Green
                Write-Host '  next: owuihelp profile    to make it live' -ForegroundColor DarkCyan
                _owuienv_pause
            } else { Write-Host '  not saved.' -ForegroundColor DarkGray }
        }
        else {
            $k=0
            if (-not ([int]::TryParse($c,[ref]$k)) -or -not $idx.ContainsKey($k)) { continue }
            $entry = _owuienv_var $idx[$k]
            _owuienv_explain $entry $working[$entry.name]
            $res = _owuienv_prompt_value $entry $working[$entry.name]
            if (-not $res.changed) { Write-Host '  unchanged.' -ForegroundColor DarkGray; continue }
            if ("$($res.value)" -ne '' -and -not (_owuienv_guard_ok $entry "$($res.value)")) { continue }
            $working[$entry.name] = "$($res.value)"
            Write-Host ("  [ok] staged: {0} = {1}" -f $entry.name, (_owuienv_fmt $res.value)) -ForegroundColor Green
        }
    }
}

# =============================================================================
#  owuihelp profile   - activate a profile against the real environment
# =============================================================================

function _owui_profile {
    _owuienv_ensure_store
    $names = _owuienv_names
    if (-not $names) {
        Write-Host ''
        Write-Host '  No profiles exist yet. Run "owuihelp envprofile" first.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    $state = _owuienv_state
    $live  = _owuienv_capture_live

    _owui_head 'ACTIVATE A PROFILE'
    $i = 0; $map = @{}
    foreach ($nm in $names) {
        $i++; $map[$i] = $nm
        $p = _owuienv_load $nm
        $diff = @($OWUI_ENV_CATALOGUE | Where-Object { "$($p.vars[$_.name])" -ne "$($live[$_.name])" })
        $tags = ''
        if ($nm -eq $OWUI_ENV.Original)   { $tags += '  [locked baseline]' }
        if ($nm -eq $state.lastApplied)   { $tags += '  [current]' }
        $d = if ($diff.Count -eq 0) { 'matches live env' } else { "$($diff.Count) difference(s)" }
        Write-Host ("    {0}  {1,-22}" -f $i, $nm) -ForegroundColor Yellow -NoNewline
        Write-Host ("{0,-22}{1}" -f $d, $tags) -ForegroundColor DarkGray
        if ($p.meta.description) { Write-Host ("        {0}" -f $p.meta.description) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host '    Q  quit' -ForegroundColor Gray
    Write-Host ''
    $sel = (Read-Host '  choose a profile to activate').Trim()
    if ($sel.ToUpper() -eq 'Q' -or $sel -eq '') { return }
    $k=0
    if (-not ([int]::TryParse($sel,[ref]$k)) -or -not $map.ContainsKey($k)) { Write-Host '  not a valid choice.' -ForegroundColor Red; return }

    $target = $map[$k]
    $prof   = _owuienv_load $target
    $diff   = @($OWUI_ENV_CATALOGUE | Where-Object { "$($prof.vars[$_.name])" -ne "$($live[$_.name])" })

    _owui_head "Activating '$target'"

    # A User-scope stray silently wins over Machine scope, so the EFFECTIVE
    # environment can match the profile while Machine scope does not. Reporting
    # strays only after a write would let the no-change path record a clean
    # state that is not true. Check first, on every path.
    $strays = _owuienv_user_strays

    if (-not $diff.Count) {
        if ($strays) {
            Write-Host '  The EFFECTIVE environment matches this profile - but only because' -ForegroundColor Yellow
            Write-Host '  User-scope strays are overriding Machine scope. Machine scope itself' -ForegroundColor Yellow
            Write-Host '  may NOT match. State has not been recorded as clean.' -ForegroundColor Yellow
            _owuienv_report_strays
            Write-Host ''
            Write-Host '  Remove the strays, then run this again.' -ForegroundColor Yellow
            Write-Host ''
            return
        }
        Write-Host '  Your live environment already matches this profile exactly.' -ForegroundColor Green
        Write-Host '  Nothing to do.' -ForegroundColor Gray
        _owuienv_set_state -Active $target -LastApplied $target
        Write-Host ''
        return
    }

    if ($strays) {
        Write-Host '  !! User-scope strays are present. Whatever this activation writes to' -ForegroundColor Red
        Write-Host '     Machine scope, these values will still win at process creation.' -ForegroundColor Red
        _owuienv_report_strays
        Write-Host ''
        if (-not (_owuienv_ask 'continue anyway? (the strays will still override)')) {
            Write-Host '  cancelled - nothing was changed.' -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        Write-Host ''
    }

    Write-Host ("  {0} variable(s) will change:" -f $diff.Count) -ForegroundColor Gray
    Write-Host ''
    $needsRestart = $false
    foreach ($e in $diff) {
        $from = _owuienv_fmt $live[$e.name]
        $to   = _owuienv_fmt $prof.vars[$e.name]
        Write-Host ("    {0}" -f $e.name) -ForegroundColor Yellow
        Write-Host ("      {0}  ->  {1}" -f $from, $to) -ForegroundColor White
        Write-Host ("      {0}" -f $e.summary) -ForegroundColor DarkGray
        if ($e.risk -ne 'safe') {
            Write-Host ("      {0}" -f (_owuienv_tag $e.risk)) -ForegroundColor (_owuienv_colour $e.risk)
        }
        if ($e.risk -eq 'inert') {
            Write-Host '      note: the desktop app overrides this - it will not take effect' -ForegroundColor DarkYellow
        }
        if ($e.restart) { $needsRestart = $true }
        Write-Host ''
    }

    $unchanged = $OWUI_ENV_CATALOGUE.Count - $diff.Count
    Write-Host ("  {0} other variable(s) are unchanged." -f $unchanged) -ForegroundColor DarkGray

    # Guarded values must still be confirmed on the way in, even via a profile.
    foreach ($e in $diff) {
        $to = "$($prof.vars[$e.name])"
        if ($to -ne '' -and -not (_owuienv_guard_ok $e $to)) {
            Write-Host ''
            Write-Host '  activation cancelled - a guarded value was not confirmed.' -ForegroundColor Green
            return
        }
    }

    Write-Host ''
    if ($needsRestart) { Write-Host '  ! Ollama must restart before these take effect.' -ForegroundColor DarkYellow }
    Write-Host ("  ! Writes go to MACHINE scope ({0} variables) - single-scope policy." -f $diff.Count) -ForegroundColor DarkYellow
    Write-Host '  ! A rollback snapshot of your current environment will be saved first.' -ForegroundColor DarkYellow

    if (-not (_owuienv_is_elevated)) {
        Write-Host ''
        Write-Host '  [x] NOT ELEVATED - Machine-scope writes need an administrator shell.' -ForegroundColor Red
        Write-Host '      Nothing has been changed. Reopen PowerShell as Administrator' -ForegroundColor Red
        Write-Host '      and run this again.' -ForegroundColor Red
        Write-Host ''
        Write-Host '      (Writing to User scope instead would appear to work and would' -ForegroundColor DarkGray
        Write-Host '       silently override Machine - that is exactly what the 2026-08-29' -ForegroundColor DarkGray
        Write-Host '       single-scope policy exists to prevent.)' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    Write-Host ''
    if (-not (_owuienv_ask "apply these $($diff.Count) change(s) now?")) {
        Write-Host '  cancelled - nothing was changed.' -ForegroundColor DarkGray
        return
    }

    # rollback snapshot
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $snap  = Join-Path $OWUI_ENV.Rollback "$stamp-before-$target.json"
    ([ordered]@{ taken=(Get-Date -Format o); replacedBy=$target; vars=$live }) |
        ConvertTo-Json -Depth 6 | Set-Content -Path $snap -Encoding UTF8
    Write-Host "  [ok] rollback snapshot: $snap" -ForegroundColor DarkGray

    foreach ($e in $diff) {
        $to = "$($prof.vars[$e.name])"
        if ($to -eq '') { [Environment]::SetEnvironmentVariable($e.name, $null, 'Machine') }
        else            { [Environment]::SetEnvironmentVariable($e.name, $to,   'Machine') }
        Write-Host ("  [ok] {0} = {1}" -f $e.name, (_owuienv_fmt $to)) -ForegroundColor Green
    }

    if (_owuienv_user_strays) {
        Write-Host ''
        Write-Host '  ! Machine scope was written, but User-scope strays still override it.' -ForegroundColor Red
        Write-Host '    Profile state NOT recorded as active - this activation is incomplete.' -ForegroundColor Red
        _owuienv_report_strays
    } else {
        _owuienv_set_state -Active $target -LastApplied $target
    }

    Write-Host ''
    if ($needsRestart -and (_owuienv_ask 'restart Ollama now so these take effect?' -DefaultYes)) {
        _owuienv_restart
        Write-Host ''
        if (_owuienv_ask 'run a drift check to confirm Ollama actually took them?' -DefaultYes) { _owui_env_drift }
    } else {
        Write-Host '  remember: nothing changes until Ollama restarts.' -ForegroundColor DarkYellow
    }
}

# =============================================================================
#  owuihelp drift   - intended vs registry vs what Ollama actually resolved
# =============================================================================

function _owui_env_drift {
    _owuienv_ensure_store
    $state  = _owuienv_state
    $live   = _owuienv_capture_live
    $actual = _owuienv_actual

    _owui_head 'ENVIRONMENT DRIFT CHECK'
    Write-Host '  Three sources compared. The rightmost column is ground truth - it is' -ForegroundColor Gray
    Write-Host '  what Ollama actually resolved, read from server.log.' -ForegroundColor Gray
    Write-Host ''

    $prof = $null
    if ($state.lastApplied) { $prof = _owuienv_load $state.lastApplied }
    $label = if ($state.lastApplied) { $state.lastApplied } else { '(none)' }

    Write-Host ("    {0,-30} {1,-16} {2,-16} {3}" -f 'VARIABLE', "PROFILE:$label", 'REGISTRY', 'OLLAMA ACTUAL') -ForegroundColor DarkCyan
    Write-Host ('    ' + ('-' * 88)) -ForegroundColor DarkCyan

    $problems = @()
    foreach ($e in $OWUI_ENV_CATALOGUE) {
        $pv = if ($prof) { _owuienv_fmt $prof.vars[$e.name] } else { '-' }
        $rv = _owuienv_fmt $live[$e.name]
        $av = if ($actual.ContainsKey($e.name)) { _owuienv_fmt $actual[$e.name] } else { '-' }

        $bad = $false
        if ($prof -and $pv -ne '-' -and $pv -ne $rv) { $bad = $true; $problems += "$($e.name): profile says $pv but the registry says $rv" }
        $norm = { param($x) $y=("$x" -replace '\\\\','\') -replace '^true$','1' -replace '^false$','0'; if($y -match '^(\d+)m0s$'){$y=$Matches[1]+'m'}; if($y -match '^(\d+)h0m0s$'){$y=$Matches[1]+'h'}; if($y -eq '0s'){$y='0'}; $y }
        if ($av -ne '-' -and $rv -ne '<unset>' -and (& $norm $av) -ne (& $norm $rv) -and $e.risk -ne 'inert' -and -not $e.nocompare) {
            $bad = $true; $problems += "$($e.name): registry says $rv but Ollama is running with $av (restart needed?)"
        }

        $col = if ($bad) { 'Red' } elseif ($e.risk -eq 'inert') { 'DarkGray' } else { 'Gray' }
        Write-Host ("    {0,-30} {1,-16} {2,-16} {3}" -f $e.name, $pv, $rv, $av) -ForegroundColor $col
    }

    Write-Host ''
    if ($problems) {
        Write-Host '  DRIFT DETECTED:' -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Yellow }
        Write-Host ''
        Write-Host '  Rows differing only because a value is app-controlled (inert) are' -ForegroundColor DarkGray
        Write-Host '  excluded - OLLAMA_HOST and OLLAMA_CONTEXT_LENGTH are expected to' -ForegroundColor DarkGray
        Write-Host '  disagree with the registry.' -ForegroundColor DarkGray
    } else {
        Write-Host '  [ok] no drift. Profile, registry and running server all agree.' -ForegroundColor Green
    }

    _owuienv_report_strays
    Write-Host ''
}

# ---- command registrations -------------------------------------------------
# Appended onto $OWUI_CMDS by owui-toolkit.ps1 so the registry in that file
# stays a single flat literal and this module owns its own help text.

$Global:OWUI_ENV_CMDS = @(

    @{ cmd='envprofile'; grp='Environment'; alias=@('envprofiles','newprofile')
       blurb='Create / list / delete env var profiles - the gatekeeper for "env"'
       details=@(
         'WHAT IT DOES:'
         'Manages named sets of Ollama environment variables. On first run it'
         'captures your current setup as a LOCKED baseline called "original",'
         'then offers to fork your first editable profile from it.'
         ''
         'WHY IT EXISTS:'
         'OLLAMA_KV_CACHE_TYPE=q8_0 has crashed this machine twice - on 19 Aug'
         'and again on 25 Aug - both times because an old snapshot was replayed'
         'and nobody noticed the value had come back. Profiles make the intended'
         'state explicit, diffable and confirmable instead of implicit.'
         ''
         'THE THREE-STEP FLOW:'
         '  1. owuihelp envprofile    create the baseline, then a profile'
         '  2. owuihelp env           edit that profile - saves to a file only'
         '  3. owuihelp profile       activate it against the real environment'
         ''
         'Editing and applying are deliberately separate. You can never half-break'
         'the live environment part-way through an editing session.'
         ''
         '! "original" is read-only by design - every profile forks from it.'
         '! To change the baseline, hand-edit env-profiles\original.profile.json.'
       )
       act={ _owui_envprofile } }

    @{ cmd='env'; grp='Environment'; alias=@('envvars','envedit')
       blurb='Menu of every Ollama env var with explanations - edit the active profile'
       details=@(
         'WHAT IT DOES:'
         'Shows every catalogued environment variable grouped by purpose, with'
         'its current value in the active profile. Pick a number to read a full'
         'explanation and change it. Changed entries are marked [modified] until'
         'you press S to save.'
         ''
         'RISK MARKERS:'
         '  (danger)   has caused a real failure on this machine. Setting the'
         '             known-bad value prints the incident log and makes you type'
         '             the value out in full before it is accepted.'
         '  (caution)  real trade-offs - explained, then a yes/no.'
         '  (inert)    the Ollama desktop app overrides this. You may set it, but'
         '             it will do nothing. OLLAMA_CONTEXT_LENGTH and OLLAMA_HOST'
         '             are both in this category.'
         ''
         'KEYS:'
         '  [number]  edit that variable        S  save to the profile file'
         '  X         explain without editing   R  revert all unsaved changes'
         '  Q         quit'
         ''
         '! Saving writes the PROFILE FILE only. Nothing reaches your real'
         '  environment until you run "owuihelp profile".'
         '! Locked until at least one profile exists - run "owuihelp envprofile".'
       )
       act={ _owui_env } }

    @{ cmd='profile'; grp='Environment'; alias=@('activate','useprofile')
       blurb='Activate a profile - shows an explained diff and confirms before writing'
       details=@(
         'WHAT IT DOES:'
         'Lists your profiles with [current] against the one last applied, then'
         'shows exactly what activating your choice would change: every variable,'
         'old value, new value, what it does and its risk level.'
         ''
         'BEFORE IT WRITES ANYTHING:'
         '  - a rollback snapshot of your current environment is saved to'
         '    env-profiles\_rollback\ with a timestamp'
         '  - guarded values must still be confirmed individually, even when they'
         '    arrive via a profile rather than a manual edit'
         '  - you get one final yes/no with the change count'
         ''
         'AFTER IT WRITES:'
         'It offers to restart Ollama properly - rebuilding the merged Machine'
         'plus User environment first, which is the step that is easy to get'
         'wrong by hand and silently drops variables. Then it offers a drift'
         'check to prove the running server actually took the new values.'
         ''
         '! Writes to MACHINE scope - needs an elevated shell. Any catalogued'
         '  variable found at User scope is reported as a STRAY: it silently'
         '  overrides Machine, which the single-scope policy forbids.'
       )
       act={ _owui_profile } }

    @{ cmd='drift'; grp='Environment'; alias=@('envdrift','envcheck')
       blurb='Compare intended profile vs registry vs what Ollama ACTUALLY loaded'
       details=@(
         'WHAT IT DOES:'
         'Prints three columns side by side for every catalogued variable:'
         '  PROFILE   what the last-applied profile says it should be'
         '  REGISTRY  what is actually stored (Machine scope; User strays flagged)'
         '  ACTUAL    what the running Ollama resolved, read from server.log'
         ''
         'WHY THE THIRD COLUMN MATTERS:'
         'The environment variable is NOT the truth. The desktop app overrides'
         'some of them, a restart may not have happened, and a process launched'
         'from a stale shell can inherit values that no longer exist. server.log'
         'is the only ground truth, and this is the command that reads it.'
         ''
         'Rows that disagree are printed in red and summarised underneath.'
         'Variables marked inert are excluded from the comparison, because they'
         'are EXPECTED to disagree with the registry.'
         ''
         'Run this after any Ollama upgrade - a reinstall silently resets'
         'OLLAMA_GPU_OVERHEAD to 0.'
       )
       act={ _owui_env_drift } }
)

