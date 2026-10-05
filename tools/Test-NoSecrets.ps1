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
      - every line of every text file against known secret formats (private
        keys, provider API keys, OAuth tokens, JWTs, webhook URLs, passwords in
        URLs, secret-named settings with a literal value);
      - private addresses: tailnet IPs and MagicDNS names, which belong in
        templates as {{PC_TS_IP}} and {{VPS_TS_IP}}.

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
    @{ Rule = 'password in a URL'; Pattern = '[a-z][a-z0-9+.-]*://[^/\s:@''"]+:[^/\s@''"]+@' }
    @{ Rule = 'secret-named setting with a literal value'; Pattern = '(?i)\b[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY)[A-Z0-9_]*["'']?\s*[:=]\s*["'']?[A-Za-z0-9+/=_.-]{16,}' }
    @{ Rule = 'tailnet IP (use {{PC_TS_IP}} or {{VPS_TS_IP}})'; Pattern = '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b' }
    @{ Rule = 'MagicDNS name'; Pattern = '(?i)\b[a-z0-9-]+\.[a-z0-9-]+\.ts\.net\b' }
)

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
    if ($bytes.Length -gt 5MB) { continue }
    $probe = [Math]::Min($bytes.Length, 8000)
    if ($probe -gt 0 -and [Array]::IndexOf($bytes, [byte]0, 0, $probe) -ge 0) { continue }   # binary

    $lines = [Text.Encoding]::UTF8.GetString($bytes) -split "\r?\n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($r in $lineRules) {
            if ($lines[$i] -match $r.Pattern) {
                $findings.Add([pscustomobject]@{ File = $rel; Line = $i + 1; Rule = $r.Rule })
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
