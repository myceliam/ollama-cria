<#
.SYNOPSIS
    Refuses secret-shaped strings, private addresses and forbidden files in the
    repo. CI runs it on every push and pull request.

.DESCRIPTION
    ollama-cria must never hold a secret value (docs/RESTORE.md, the seed rule
    and Appendix D; review finding C-33). This scan is the guard behind that
    rule. It checks:

      - every file name against a list that must never be committed (the
        secrets bundle and its map, .env files, keys, databases, the retired
        kais_chat_tidy.ps1);
      - every line of every file against known secret formats (private
        keys, provider API keys, OAuth tokens, JWTs, webhook URLs, passwords in
        URLs, secret-named settings with a literal value, quoted passphrases);
      - private addresses: tailnet IPv4 and IPv6 addresses and MagicDNS names,
        which belong in templates as {{PC_TS_IP}} and {{VPS_TS_IP}}.

    Every file is scanned, whatever its size. Text is decoded from its byte
    order mark (UTF-8, UTF-16 or UTF-32), or as UTF-16 when the NUL bytes fall
    in the pattern UTF-16 text leaves, or else as UTF-8. Anything else is
    binary: its bytes are still scanned, read one byte per character, so an
    ASCII secret inside it is found (reported as line 0). Compressed files
    (ZIP, DOCX) are not unpacked; the bundle names are refused instead.

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
    @{ Rule = 'service state file'; Pattern = '^(server-keys|config\.runtime|token|credentials)\.json$|^client_secret.*\.json$' }
    @{ Rule = 'retired script with a hard-coded key (R-20)'; Pattern = '^kais_chat_tidy\.ps1$' }
)
$allowedNames = '\.example$|\.sample$'

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
    @{ Rule = 'Brave Search key'; Pattern = '\bBSA[0-9A-Za-z_-]{20,}' }
    @{ Rule = 'AWS access key'; Pattern = '\bAKIA[0-9A-Z]{16}\b' }
    @{ Rule = 'Slack token'; Pattern = '\bxox[abprs]-[0-9A-Za-z-]{10,}' }
    @{ Rule = 'JWT'; Pattern = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' }
    @{ Rule = 'Discord webhook URL'; Pattern = 'discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{20,}' }
    @{ Rule = 'password in a URL'; Pattern = '[a-z][a-z0-9+.-]{0,31}://[^/\s:@''"]+:[^/\s@''"]+@' }
    @{ Rule = 'secret-named setting with a literal value'; Pattern = '(?i)\b[A-Z0-9_]{0,64}(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY)[A-Z0-9_]{0,64}["'']?\s*[:=]\s*["'']?[A-Za-z0-9+/=_.-]{16,}' }
    # Quoted values the rule above misses: 8 or more characters with a space or
    # punctuation in them (a passphrase). Placeholders ({{X}}, ${X}, $x, <x>, %X%) pass.
    @{ Rule = 'secret-named setting with a quoted passphrase'; Pattern = '(?i)\b[A-Z0-9_]{0,64}(?:SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY)[A-Z0-9_]{0,64}["'']?\s*[:=]\s*(["''])(?![{$<%])(?=(?:(?!\1)[^\r\n])*?[^A-Za-z0-9+/=_.\r\n"''-])(?:(?!\1)[^\r\n]){8,}\1' }
    @{ Rule = 'tailnet IP (use {{PC_TS_IP}} or {{VPS_TS_IP}})'; Pattern = '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b' }
    # Tailscale gives every node an IPv6 address in one fixed /48.
    @{ Rule = 'tailnet IPv6 address'; Pattern = '(?i)\bfd7a:115c:a1e0:[0-9a-f]{0,4}:' }
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

$root = (Resolve-Path -LiteralPath $Path).ProviderPath

# ---------- Which files ----------
$relativeFiles = $null
if (Test-Path -LiteralPath (Join-Path $root '.git')) {
    $relativeFiles = @(git -C $root ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
}
else {
    $relativeFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            ForEach-Object { $_.FullName.Substring($root.TrimEnd([char[]]@('\', '/')).Length + 1) })
}

$findings = [Collections.Generic.List[object]]::new()

foreach ($rel in $relativeFiles) {
    $rel = $rel -replace '\\', '/'
    $full = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }   # deleted in the work tree
    $name = Split-Path $rel -Leaf

    if ($name -notmatch $allowedNames) {
        foreach ($f in $forbiddenNames) {
            if ($name -match $f.Pattern) {
                $findings.Add([pscustomobject]@{ File = $rel; Line = 0; Rule = "forbidden file: $($f.Rule)" })
            }
        }
    }

    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -eq 0) { continue }
    $scan = Get-ScanText $bytes

    $lines = $scan.Text -split "\r?\n|\r"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($r in $lineRules) {
            if ($lines[$i] -match $r.Pattern) {
                if ($scan.Binary) { $findings.Add([pscustomobject]@{ File = $rel; Line = 0; Rule = "$($r.Rule) (in a binary file)" }) }
                else { $findings.Add([pscustomobject]@{ File = $rel; Line = $i + 1; Rule = $r.Rule }) }
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
Write-Output "Test-NoSecrets: clean ($($relativeFiles.Count) files scanned)."
