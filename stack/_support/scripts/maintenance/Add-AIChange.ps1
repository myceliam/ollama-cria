<#
.SYNOPSIS
    Read, search or append the AI change ledger, E:\ai\ollama\AI-CHANGELOG.csv.

.DESCRIPTION
    The ledger is the machine-readable handover record between assistants.
    Liam does not edit it by hand - every row is written by an assistant.
    Governing rules: E:\ai\ollama\AI-CHANGELOG-PROTOCOL.md. Read it before
    adding a row.

    This script only ever APPENDS. It never rewrites or reorders the file.

    Concurrency (hardened 2026-09-04 after ChatGPT's review): the id is derived
    and the row written inside an exclusive file lock, so two assistants
    appending at the same moment cannot claim the same id. Previously the id was
    read, then written, with a gap in between.

.EXAMPLE
    Add-AIChange.ps1 -Tail 10          # the ten most recent rows
.EXAMPLE
    Add-AIChange.ps1 -Find open-terminal   # every row mentioning a component
.EXAMPLE
    Add-AIChange.ps1 -Author Claude -LoggedBy Claude -Model claude-opus-5 `
        -Request '...' -Summary '...' -Files '...' -Steps '...' `
        -Completed Y -Verification 'live: ... | trust: ...' `
        -Provenance verified-live -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Add')]
param(
    [Parameter(ParameterSetName = 'Tail')]
    [int]$Tail = 0,

    # Search every column. Use it whenever the task touches a component - the
    # last ten rows stop being enough orientation as the ledger grows.
    [Parameter(ParameterSetName = 'Find', Mandatory)]
    [string]$Find,

    [Parameter(ParameterSetName = 'Add', Mandatory)]
    [ValidateSet('Claude','ChatGPT','Liam','Liam (Autofilled)',
                 'Observed by Claude','Observed by ChatGPT','Unattributed')]
    [string]$Author,

    [Parameter(ParameterSetName = 'Add', Mandatory)]
    [ValidateSet('Claude','ChatGPT')]
    [string]$LoggedBy,

    [Parameter(ParameterSetName = 'Add', Mandatory)][string]$Model,
    [Parameter(ParameterSetName = 'Add', Mandatory)][string]$Request,
    [Parameter(ParameterSetName = 'Add', Mandatory)][string]$Summary,
    [Parameter(ParameterSetName = 'Add', Mandatory)][string]$Files,
    [Parameter(ParameterSetName = 'Add', Mandatory)][string]$Steps,

    [Parameter(ParameterSetName = 'Add', Mandatory)]
    [ValidateSet('Y','N','PARTIAL')]
    [string]$Completed,

    [Parameter(ParameterSetName = 'Add', Mandatory)][string]$Verification,
    [Parameter(ParameterSetName = 'Add')][string]$Sections = 'none',
    [Parameter(ParameterSetName = 'Add')][string]$Rollback = 'n/a',
    [Parameter(ParameterSetName = 'Add')][string]$Risk     = 'none',
    [Parameter(ParameterSetName = 'Add')][string]$FollowUp = 'none',

    # Tier of the change - see AI-CHANGELOG-PROTOCOL.md section 5.2.
    # routine  = ledger row only (comments, tidying, digest re-records)
    # material = full master-document update as well (behaviour, security,
    #            exposure, versions, a new trap or lesson)
    [Parameter(ParameterSetName = 'Add')]
    [ValidateSet('routine','material')]
    [string]$Tier = 'routine',

    [Parameter(ParameterSetName = 'Add', Mandatory)]
    [ValidateSet('verified-live','carried-forward','backfilled','observed-unconfirmed')]
    [string]$Provenance,

    [string]$Path = 'E:\ai\ollama\AI-CHANGELOG.csv'
)

$ErrorActionPreference = 'Stop'

$Columns = @('id','timestamp_local','author','logged_by','model','request_from_liam',
             'change_summary','files_touched','steps_taken','completed','verification',
             'doc_sections_updated','rollback','risk_notes','follow_up_ref','provenance')

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Ledger not found at $Path. Do not recreate it silently - find out why it is missing."
}

# ---- read modes ------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Tail') {
    $n = if ($Tail -gt 0) { $Tail } else { 10 }
    Import-Csv -LiteralPath $Path | Select-Object -Last $n | Format-List
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Find') {
    $hits = Import-Csv -LiteralPath $Path | Where-Object {
        ($_.PSObject.Properties.Value -join ' ') -like "*$Find*"
    }
    if (-not $hits) { Write-Host "  no ledger rows mention '$Find'" -ForegroundColor DarkGray; return }
    Write-Host ("  {0} row(s) mention '{1}'" -f @($hits).Count, $Find) -ForegroundColor Cyan
    $hits | Format-List
    return
}

# ---- append, under an exclusive lock ---------------------------------------
$values  = $null
$line    = $null
$id      = $null

$fs = $null
for ($try = 0; $try -lt 30 -and -not $fs; $try++) {
    try   { $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None') }
    catch { Start-Sleep -Milliseconds (150 + (Get-Random -Maximum 250)) }
}
if (-not $fs) {
    throw "Could not take an exclusive lock on $Path after ~6s. Another assistant may be writing, or the file is open in Excel. Retry."
}

try {
    $sr   = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
    $text = $sr.ReadToEnd()

    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -lt 1) { throw "Ledger is empty - even the header is gone. Stop and investigate." }

    # Schema guard: a row written against a changed header is worse than none.
    $headerCols = ($lines[0] -replace "^\uFEFF", '') -split ',' | ForEach-Object { $_.Trim('"') }
    if (Compare-Object $headerCols $Columns -SyncWindow 0) {
        throw ("Column mismatch. File header does not match the 16 columns this script writes. " +
               "Reconcile AI-CHANGELOG-PROTOCOL.md section 3 before logging anything.")
    }

    # Next id, derived INSIDE the lock so a concurrent writer cannot duplicate it.
    $lastNum = 0
    if ($lines.Count -gt 1) {
        if ($lines[-1] -match '^"?(AICL-(\d{4}))"?') { $lastNum = [int]$Matches[2] }
        else { throw "Last row has a malformed id. Fix the protocol violation before appending." }
    }
    $id = 'AICL-{0:D4}' -f ($lastNum + 1)

    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mmzzz')

    $values = @($id, $ts, $Author, $LoggedBy, $Model, $Request, $Summary, $Files,
                $Steps, $Completed, $Verification, $Sections, $Rollback, $Risk,
                $FollowUp, $Provenance)

    # Every field quoted; embedded quotes doubled; newlines flattened.
    $line = ($values | ForEach-Object {
        $v = [string]$_
        $v = $v -replace "`r`n", ' ' -replace "`n", ' ' -replace "`r", ' '
        '"' + ($v -replace '"', '""') + '"'
    }) -join ','

    if ($PSCmdlet.ShouldProcess($Path, "append $id")) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`r`n")
        [void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        $written = $true
    }
}
finally { if ($fs) { $fs.Dispose() } }

if ($written) {
    Write-Host "  logged $id  ($Author, tier: $Tier)" -ForegroundColor Green
    if ($Tier -eq 'material') {
        Write-Host '  MATERIAL change - the master document must be updated too:' -ForegroundColor Yellow
        Write-Host '    the chapter, Ch. 21 (backlog), Ch. 22 (change log), and the map if structure moved.' -ForegroundColor DarkGray
    }
    Write-Host "  quote this id in your handoff: $id" -ForegroundColor DarkGray
} else {
    Write-Host '  [WhatIf] would append:' -ForegroundColor Yellow
    Write-Host "  $line" -ForegroundColor DarkGray
}
