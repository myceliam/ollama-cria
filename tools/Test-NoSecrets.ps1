<#
.SYNOPSIS
    Refuses secret-shaped strings, private addresses and forbidden files in the
    repo. CI runs it on every push and pull request.

.DESCRIPTION
    ollama-cria must never hold a secret value (docs/RESTORE.md, the seed rule
    and Appendix D; review finding C-33). This scan is the guard behind that
    rule. It checks:

      - every file name against a list that must never be committed (the
        secrets bundle and its map, .env files, keys, databases, archives,
        the retired kais_chat_tidy.ps1);
      - every line of every file against known secret formats (private
        keys, provider API keys, ntfy and OAuth tokens, JWTs, webhook URLs,
        passwords in URLs, secret-named settings with a literal value, quoted
        passphrases, opaque values under a key or keys field). A line holding
        JSON \uXXXX escapes is scanned again with them decoded, so
        'sk-...' is found too;
      - every file that parses as JSON once more as a whole, so a value on
        a different line from its field name is still judged by that field:
        an opaque value anywhere under a key, keys, auth, credential or
        bearer property, and a literal value under a secret-named property.
        A long public digest under a "key" field is reported too; give such
        fields a clearer name rather than weakening the rule;
      - private addresses: tailnet IPv4 and IPv6 addresses and MagicDNS names,
        which belong in templates as {{PC_TS_IP}} and {{VPS_TS_IP}}.
        Tailscale's own service address (100.100.100.100, fd7a:115c:a1e0::53)
        is the same in every tailnet and passes.

    Every file is scanned, whatever its size. Text is decoded from its byte
    order mark (UTF-8, UTF-16 or UTF-32), or as UTF-16 when the NUL bytes fall
    in the pattern UTF-16 text leaves, or else as UTF-8. Anything else is
    binary: its bytes are still scanned, read one byte per character, so an
    ASCII secret inside it is found (reported as line 0). Compressed files
    are not unpacked, so archives are refused by name instead.

    In a Git work tree the file list comes from 'git ls-files -z', read as
    UTF-8, so a name Git would quote (non-ASCII, a tab) is scanned under its
    real name. A listed file that cannot be read is a finding, not a skip;
    only a tracked file deleted from the work tree is skipped.

    A pattern scan is a guard, not proof that nothing secret is here. It does
    not recognise an opaque token with no telling name or prefix (a bare hex
    string, a UUID, a base64 key on its own), so review still matters.

    A finding names the file, the line and the rule. It never prints the
    matched text, so the scan cannot leak what it finds.

    Tests must build fake secrets at run time (for example 'sk-' + ('A' * 40))
    so no literal lands in a file and this scan stays clean.

.PARAMETER Path
    Folder to scan. Defaults to the repo root. In a Git work tree, the files
    Git tracks plus new files it does not ignore are scanned; elsewhere, every
    file under the folder.

.PARAMETER PassThru
    Return the findings as objects instead of printing them and setting the
    exit code.

.EXAMPLE
    ./tools/Test-NoSecrets.ps1
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$Path = (Split-Path $PSScriptRoot -Parent),
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$forbiddenNames = @(
    @{ Rule = 'secrets bundle'; Pattern = '^stack-secrets-.*\.zip$' }
    @{ Rule = 'restore map (belongs in the bundle)'; Pattern = '^00-RESTORE-MAP\.json$' }
    @{ Rule = '.env file'; Pattern = '(^|\.)env$|^\.env\.' }
    @{ Rule = 'key or certificate file'; Pattern = '\.(pem|key|pfx|p12)$|^id_(rsa|ed25519|ecdsa|dsa)(\.pub)?$' }
    @{ Rule = 'database file'; Pattern = '\.(db|sqlite|sqlite3)(-wal|-shm)?$' }
    @{ Rule = 'archive (not scanned inside)'; Pattern = '\.(zip|7z|rar|tar|tgz|gz|bz2|xz|zst)$' }
    @{ Rule = 'service state file'; Pattern = '^(server-keys|config\.runtime|token|credentials)\.json$|^client_secret.*\.json$' }
    @{ Rule = 'retired script with a hard-coded key (R-20)'; Pattern = '^kais_chat_tidy\.ps1$' }
)
$allowedNames = '\.example$|\.sample$'

# Setting names that say where a secret is, or whether it is set, rather
# than holding it; and the start of a placeholder value.
$locatorName = '(?<!_(?:PATH|FILE|DIR|ENV|VAR|VARIABLE|NAME|PRESENT|CONFIGURED|SET|ENABLED|HEADER))'
$placeholderWord = '(?:paste|your[-_]|change[-_]?me|replace|example|placeholder|dummy|insert|xxx)'

# Quantifiers are bounded so a long line cannot make a rule backtrack for minutes.
$lineRules = @(
    @{ Rule = 'private key block'; Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }
    @{ Rule = 'API key (sk-)'; Pattern = '\bsk-[A-Za-z0-9_-]{20,}' }
    @{ Rule = 'Groq key'; Pattern = '\bgsk_[A-Za-z0-9]{20,}' }
    @{ Rule = 'GitHub token'; Pattern = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}' }
    @{ Rule = 'Google API key'; Pattern = '\bAIza[0-9A-Za-z_-]{35}' }
    @{ Rule = 'Google OAuth token'; Pattern = '\bya29\.[0-9A-Za-z_-]{20,}|\b1//0[0-9A-Za-z_-]{20,}' }
    @{ Rule = 'Google OAuth client secret'; Pattern = '\bGOCSPX-[0-9A-Za-z_-]{20,}' }
    @{ Rule = 'Hugging Face token'; Pattern = '\bhf_[A-Za-z0-9]{30,}' }
    @{ Rule = 'ntfy access token'; Pattern = '\btk_[A-Za-z0-9]{24,}' }
    @{ Rule = 'Brave Search key'; Pattern = '\bBSA[0-9A-Za-z_-]{20,}' }
    @{ Rule = 'AWS access key'; Pattern = '\bAKIA[0-9A-Z]{16}\b' }
    @{ Rule = 'Slack token'; Pattern = '\bxox[abprs]-[0-9A-Za-z-]{10,}' }
    @{ Rule = 'Fernet ciphertext (encrypted OWUI Valves)'; Pattern = '\bgAAAAA[A-Za-z0-9_-]{40,}' }
    @{ Rule = 'JWT'; Pattern = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' }
    @{ Rule = 'Discord webhook URL'; Pattern = 'discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{20,}' }
    @{ Rule = 'password in a URL'; Pattern = '[a-z][a-z0-9+.-]{0,31}://[^/\s:@''"]+:[^/\s@''"]+@' }
    # Not a secret, so it passes: a setting whose name says it holds where a
    # secret is rather than the secret (TOKEN_PATH, ..._FILE, ..._ENV,
    # token_environment_variable, client_secret_present); an unquoted value
    # that is code (a call, or a dotted name such as settings.watch_token);
    # and a quoted placeholder ("paste-...", "your-...", "changeme").
    @{ Rule = 'secret-named setting with a literal value'; Pattern = '(?i)\b[A-Z0-9_]{0,64}(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY|PRESHARED_?KEY)[A-Z0-9_]{0,64}' + $locatorName + '["'']?\s*[:=]\s*(?:["''](?!' + $placeholderWord + ')|(?![A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\s*\()(?![A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+(?![A-Za-z0-9+/=_-])))[A-Za-z0-9+/=_.-]{16,}' }
    # Quoted values the rule above misses: 8 or more characters with a space or
    # punctuation other than : / \ in them (a passphrase, not a path or a
    # 'root:relative' location). Placeholders ({{X}}, ${X}, $x, <x>, %X%) pass.
    @{ Rule = 'secret-named setting with a quoted passphrase'; Pattern = '(?i)\b[A-Z0-9_]{0,64}(?:SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY|PRESHARED_?KEY)[A-Z0-9_]{0,64}["'']?\s*[:=]\s*(["''])(?![{$<%])(?=(?:(?!\1)[^\r\n])*?[^A-Za-z0-9+/=_.:\\\r\n"''-])(?:(?!\1)[^\r\n]){8,}\1' }
    # A long opaque value under a generic key, keys, auth or credential field
    # (Bolt's key arrays, exported settings), or under a Civitai setting.
    @{ Rule = 'opaque value under a key or credential field'; Pattern = '(?i)"(?:keys?|auth|credentials?|bearer)"\s*:\s*\[?\s*"[A-Za-z0-9+/=_-]{32,}"' }
    @{ Rule = 'Civitai key'; Pattern = '(?i)\bcivitai[A-Za-z0-9_]{0,32}["'']?\s*[:=]\s*["'']?[A-Za-z0-9]{32,}' }
    # 100.100.100.100 and fd7a:115c:a1e0::53 are Tailscale's own service
    # address (the MagicDNS resolver), the same in every tailnet, so they pass.
    # So does the whole range written as a network (100.64.0.0/10,
    # fd7a:115c:a1e0::/48), which firewall rules and routes name.
    @{ Rule = 'tailnet IP (use {{PC_TS_IP}} or {{VPS_TS_IP}})'; Pattern = '\b(?!100\.100\.100\.100\b)(?!100\.64\.0\.0/)100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b' }
    # Tailscale gives every node an IPv6 address in one fixed /48.
    @{ Rule = 'tailnet IPv6 address'; Pattern = '(?i)\b(?!fd7a:115c:a1e0::53\b)(?!fd7a:115c:a1e0::/)fd7a:115c:a1e0:[0-9a-f]{0,4}:' }
    @{ Rule = 'MagicDNS name'; Pattern = '(?i)\b[a-z0-9-]{1,63}\.[a-z0-9-]{1,63}\.ts\.net\b' }
)

function Get-ScanText([byte[]]$Bytes) {
    # Returns the text to scan and whether the file is binary.
    $n = $Bytes.Length
    $bom = @(
        @{ Mark = [byte[]](0xFF, 0xFE, 0x00, 0x00); Encoding = [Text.UTF32Encoding]::new($false, $false) }
        @{ Mark = [byte[]](0x00, 0x00, 0xFE, 0xFF); Encoding = [Text.UTF32Encoding]::new($true, $false) }
        @{ Mark = [byte[]](0xEF, 0xBB, 0xBF); Encoding = [Text.UTF8Encoding]::new($false) }
        @{ Mark = [byte[]](0xFF, 0xFE); Encoding = [Text.UnicodeEncoding]::new($false, $false) }
        @{ Mark = [byte[]](0xFE, 0xFF); Encoding = [Text.UnicodeEncoding]::new($true, $false) }
    )
    foreach ($b in $bom) {
        $m = $b.Mark
        if ($n -ge $m.Length -and [Linq.Enumerable]::SequenceEqual([byte[]]$Bytes[0..($m.Length - 1)], $m)) {
            return @{ Text = $b.Encoding.GetString($Bytes, $m.Length, $n - $m.Length); Binary = $false }
        }
    }

    $probe = [Math]::Min($n, 8000) -band -2    # an even count, so byte pairs line up
    $evenNul = 0; $oddNul = 0
    for ($i = 0; $i -lt $probe; $i++) {
        if ($Bytes[$i] -eq 0) { if ($i % 2) { $oddNul++ } else { $evenNul++ } }
    }
    if ($evenNul + $oddNul -eq 0) {
        return @{ Text = [Text.Encoding]::UTF8.GetString($Bytes); Binary = $false }
    }
    # UTF-16 with no mark: mostly-ASCII text puts a NUL in every other byte.
    $pairs = [Math]::Max($probe / 2, 1)
    if ($oddNul / $pairs -ge 0.5 -and $evenNul / $pairs -le 0.05) {
        return @{ Text = [Text.UnicodeEncoding]::new($false, $false).GetString($Bytes); Binary = $false }
    }
    if ($evenNul / $pairs -ge 0.5 -and $oddNul / $pairs -le 0.05) {
        return @{ Text = [Text.UnicodeEncoding]::new($true, $false).GetString($Bytes); Binary = $false }
    }
    # Binary: one byte per character, so ASCII runs inside it are still scanned.
    return @{ Text = [Text.Encoding]::Latin1.GetString($Bytes); Binary = $true }
}

function Get-GitFile([string]$Root, [string[]]$Arguments) {
    # NUL-separated and read as UTF-8 bytes, so no name is quoted, escaped or
    # re-encoded on the way (PowerShell would decode it with the console code page).
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in @('-C', $Root, '-c', 'core.quotepath=off', 'ls-files', '-z') + $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $proc = [Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    $null = $errTask.Result
    if ($proc.ExitCode -ne 0) { throw 'git ls-files failed.' }
    return , @($out.Split([char]0) | Where-Object { $_ -ne '' })
}

function Test-Leaf([string]$FullPath) {
    try { return [bool]((Get-Item -LiteralPath $FullPath -Force -ErrorAction Stop) -is [IO.FileInfo]) }
    catch [Management.Automation.ItemNotFoundException] { return $false }
}

$root = (Resolve-Path -LiteralPath $Path).ProviderPath

# ---------- Which files ----------
$relativeFiles = $null
$deleted = @{}
if (Test-Path -LiteralPath (Join-Path $root '.git')) {
    $relativeFiles = Get-GitFile $root @('--cached', '--others', '--exclude-standard')
    foreach ($d in (Get-GitFile $root @('--deleted'))) { $deleted[$d] = $true }
}
else {
    # -Name gives paths relative to the root as listed, so they stay right even
    # when the root was given in another form (a Windows 8.3 short path).
    $relativeFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -Name |
            Where-Object { $_ -notmatch '(^|[\\/])\.git([\\/]|$)' })
}

# Structured JSON: the line rules above see one line at a time, so a value on
# the line after its field name ('"keys": [' then the value) slips past them
# (R2-03). Each JSON file is also parsed and every string is judged by the
# field it sits under, however the file is laid out.
$jsonOpaqueName = '^(?i)(keys?|auth|credentials?|bearer)$'
$jsonTellingName = '(?i)(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY|PRESHARED_?KEY)'
$jsonLocatorName = '(?i)_(PATH|FILE|DIR|ENV|VAR|VARIABLE|NAME|PRESENT|CONFIGURED|SET|ENABLED|HEADER)$'
function Get-JsonCredential($Node, [string]$Field, [bool]$Under) {
    # $Field is the nearest property name; $Under is true below a key,
    # keys, auth, credential or bearer property at any depth.
    if ($Node -is [Collections.IDictionary]) {
        foreach ($k in $Node.Keys) { Get-JsonCredential $Node[$k] ([string]$k) ($Under -or ([string]$k -match $jsonOpaqueName)) }
    }
    elseif ($Node -is [Collections.IList]) {
        foreach ($item in $Node) { Get-JsonCredential $item $Field $Under }
    }
    elseif ($Node -is [string]) {
        if ($Under -and $Node -match '^[A-Za-z0-9+/=_-]{32,}$') {
            [pscustomobject]@{ Value = $Node; Rule = 'opaque value under a key or credential field' }
        }
        elseif ($Field -match $jsonTellingName -and $Field -notmatch $jsonLocatorName -and $Node -match '^[A-Za-z0-9+/=_.-]{16,}$' -and $Node -notmatch "^(?i)$placeholderWord") {
            [pscustomobject]@{ Value = $Node; Rule = 'secret-named setting with a literal value' }
        }
    }
}

$findings = [Collections.Generic.List[object]]::new()

$scanned = 0
foreach ($rel in $relativeFiles) {
    if ($deleted.ContainsKey($rel)) { continue }   # tracked, but deleted from the work tree
    $rel = $rel -replace '\\', '/'
    $full = Join-Path $root $rel
    $name = Split-Path $rel -Leaf
    $bytes = $null
    try {
        if (Test-Leaf $full) { $bytes = [IO.File]::ReadAllBytes($full) }
    }
    catch {
        $bytes = $null
    }
    if ($null -eq $bytes) {
        # Listed but not readable as a file: fail closed rather than skip it.
        $findings.Add([pscustomobject]@{ File = $rel; Line = 0; Rule = 'listed file could not be read' })
        continue
    }
    $scanned++

    if ($name -notmatch $allowedNames) {
        foreach ($f in $forbiddenNames) {
            if ($name -match $f.Pattern) {
                $findings.Add([pscustomobject]@{ File = $rel; Line = 0; Rule = "forbidden file: $($f.Rule)" })
            }
        }
    }

    if ($bytes.Length -eq 0) { continue }
    $scan = Get-ScanText $bytes

    $lines = $scan.Text -split "\r?\n|\r"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $variants = @($lines[$i])
        if ($lines[$i] -match '\\u[0-9A-Fa-f]{4}') {
            # JSON escapes: 'sk-...' is 'sk-...' once a program reads it.
            $variants += [regex]::Replace($lines[$i], '\\u([0-9A-Fa-f]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
        }
        foreach ($r in $lineRules) {
            if (@($variants | Where-Object { $_ -match $r.Pattern }).Count -gt 0) {
                if ($scan.Binary) { $findings.Add([pscustomobject]@{ File = $rel; Line = 0; Rule = "$($r.Rule) (in a binary file)" }) }
                else { $findings.Add([pscustomobject]@{ File = $rel; Line = $i + 1; Rule = $r.Rule }) }
            }
        }
    }

    $trimmed = $scan.Text.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
    if (-not $scan.Binary -and $scan.Text.Length -le 8MB -and ($trimmed.StartsWith('{') -or $trimmed.StartsWith('['))) {
        $doc = $null
        try { $doc = ConvertFrom-Json -InputObject $scan.Text -AsHashtable -Depth 200 -NoEnumerate -ErrorAction Stop } catch { $doc = $null }
        if ($null -ne $doc) {
            foreach ($hit in @(Get-JsonCredential $doc '' $false)) {
                # Report the first line that holds the value; never the value.
                $line = 0
                for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Contains($hit.Value)) { $line = $i + 1; break } }
                $seen = @($findings | Where-Object { $_.File -eq $rel -and $_.Line -eq $line -and $_.Rule -eq $hit.Rule })
                if (-not $seen) { $findings.Add([pscustomobject]@{ File = $rel; Line = $line; Rule = $hit.Rule }) }
            }
        }
    }
}

if ($PassThru) {
    return $findings.ToArray()
}

if ($findings.Count -gt 0) {
    foreach ($f in $findings) {
        $where = if ($f.Line) { "$($f.File):$($f.Line)" } else { $f.File }
        Write-Output "  FOUND  $where  $($f.Rule)"
    }
    Write-Output "Test-NoSecrets: $($findings.Count) finding(s) in $($relativeFiles.Count) file(s). The matched text is never printed."
    exit 1
}
Write-Output "Test-NoSecrets: clean ($scanned files scanned)."
