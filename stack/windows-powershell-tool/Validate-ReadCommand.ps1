[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$commandText = [Console]::In.ReadToEnd()
$reasons = [System.Collections.Generic.List[string]]::new()

if ([string]::IsNullOrWhiteSpace($commandText)) {
    @{ allowed = $false; reasons = @('The command is empty.') } | ConvertTo-Json -Compress
    exit 0
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $commandText,
    [ref]$tokens,
    [ref]$parseErrors
)

foreach ($parseError in @($parseErrors)) {
    $reasons.Add("Parse error: $($parseError.Message)")
}

$blockedNodeTypes = @(
    [System.Management.Automation.Language.AssignmentStatementAst],
    [System.Management.Automation.Language.RedirectionAst],
    [System.Management.Automation.Language.FunctionDefinitionAst],
    [System.Management.Automation.Language.TypeDefinitionAst],
    [System.Management.Automation.Language.UsingStatementAst],
    [System.Management.Automation.Language.InvokeMemberExpressionAst],
    [System.Management.Automation.Language.TrapStatementAst],
    [System.Management.Automation.Language.ConfigurationDefinitionAst]
)

foreach ($nodeType in $blockedNodeTypes) {
    $nodes = $ast.FindAll({ param($node) $node -is $nodeType }, $true)
    if ($nodes.Count -gt 0) {
        $reasons.Add("Read mode blocks syntax node $($nodeType.Name).")
    }
}

$incrementNodes = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.UnaryExpressionAst] -and
        $node.TokenKind -in @(
            [System.Management.Automation.Language.TokenKind]::PlusPlus,
            [System.Management.Automation.Language.TokenKind]::MinusMinus,
            [System.Management.Automation.Language.TokenKind]::PostfixPlusPlus,
            [System.Management.Automation.Language.TokenKind]::PostfixMinusMinus
        )
}, $true)
if ($incrementNodes.Count -gt 0) {
    $reasons.Add('Read mode blocks increment and decrement expressions.')
}

$allowedExact = @(
    'Compare-Object', 'ConvertFrom-Csv', 'ConvertFrom-Json', 'ConvertFrom-StringData',
    'ConvertTo-Csv', 'ConvertTo-Html', 'ConvertTo-Json', 'ConvertTo-Xml',
    'ForEach-Object', 'Format-Custom', 'Format-Hex', 'Format-List', 'Format-Table', 'Format-Wide',
    'Group-Object', 'Join-Path', 'Measure-Command', 'Measure-Object', 'Out-String',
    'Select-Object', 'Sort-Object', 'Split-Path', 'Tee-Object-DENIED',
    'Where-Object', 'Write-Information', 'Write-Output', 'Write-Verbose', 'Write-Warning'
)
$allowedVerbs = @('Compare', 'Find', 'Format', 'Get', 'Group', 'Measure', 'Resolve', 'Search', 'Select', 'Sort', 'Split', 'Test')
$blockedExact = @(
    'Get-Credential', 'Get-PSCallStack', 'Get-Runspace',
    'Invoke-Command', 'Invoke-Expression', 'Invoke-Item', 'Invoke-RestMethod', 'Invoke-WebRequest',
    'New-Object', 'Out-File', 'Start-Job', 'Tee-Object'
)

foreach ($commandAst in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    if ($commandAst.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown) {
        $reasons.Add('Read mode blocks the call and dot-source operators.')
        continue
    }

    $name = $commandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name)) {
        $reasons.Add('Read mode requires every command name to be a literal cmdlet or alias.')
        continue
    }

    try {
        $resolved = Get-Command -Name $name -ErrorAction Stop | Select-Object -First 1
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        while ($resolved.CommandType -eq [System.Management.Automation.CommandTypes]::Alias) {
            if (-not $seen.Add($resolved.Name)) { throw "Alias loop for $name" }
            $resolved = Get-Command -Name $resolved.Definition -ErrorAction Stop | Select-Object -First 1
        }
    }
    catch {
        $reasons.Add("Read mode could not resolve command '$name'. External programs and dynamic commands are not allowed.")
        continue
    }

    if ($resolved.CommandType -notin @(
        [System.Management.Automation.CommandTypes]::Cmdlet,
        [System.Management.Automation.CommandTypes]::Function,
        [System.Management.Automation.CommandTypes]::Filter
    )) {
        $reasons.Add("Read mode blocks external command or script '$name' ($($resolved.CommandType)).")
        continue
    }

    $canonical = $resolved.Name
    $verb = ($canonical -split '-', 2)[0]
    if ($canonical -in $blockedExact) {
        $reasons.Add("Read mode explicitly blocks '$canonical'.")
    }
    elseif ($canonical -in $allowedExact) {
        continue
    }
    elseif ($verb -notin $allowedVerbs) {
        $reasons.Add("Read mode blocks '$canonical' because verb '$verb' is not read-only.")
    }
}

$uniqueReasons = @($reasons | Select-Object -Unique)
@{
    allowed = ($uniqueReasons.Count -eq 0)
    reasons = $uniqueReasons
} | ConvertTo-Json -Compress -Depth 4
