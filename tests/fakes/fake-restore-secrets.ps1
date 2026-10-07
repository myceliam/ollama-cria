# Test stand-in for tools/Restore-StackSecrets.ps1 -PassThru, used by the
# stage tests. $global:CriaRestore sets what it reports:
#   Rows      the rows it returns (Id, Folder, Destination, Status)
#   Problems  problems it reports (IsValid is false when there are any)
#   Files     full paths it creates, owner-only, as if it placed them
# Every call is added to $global:CriaRestore.Calls.
[CmdletBinding()]
param(
    [string]$ZipPath,
    [string]$Sha256,
    [string[]]$Folder,
    [switch]$Execute,
    [switch]$PassThru,
    [string]$SshHost,
    [string]$SshCommand,
    [string]$DockerCommand,
    [string]$HelperImage
)
$fake = $global:CriaRestore
$fake.Calls.Add([pscustomobject]@{ Zip = $ZipPath; Sha256 = $Sha256; Folder = ($Folder -join ','); Execute = [bool]$Execute; SshHost = $SshHost; SshCommand = $SshCommand; HelperImage = $HelperImage })
$root = Join-Path ([IO.Path]::GetDirectoryName($ZipPath)) ([IO.Path]::GetFileNameWithoutExtension($ZipPath))
if (-not (Test-Path -LiteralPath $root)) {
    if ($IsWindows) { Initialize-ProtectedFolder -Path $root }
    else { $null = [IO.Directory]::CreateDirectory($root, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
}
foreach ($f in @($fake.Files)) {
    if (Test-Path -LiteralPath $f) { continue }
    $null = New-FolderChain -Path ([IO.Path]::GetDirectoryName($f))
    $s = Open-NewOwnerOnlyFile -Path $f
    try { $b = [Text.Encoding]::UTF8.GetBytes('x'); $s.Write($b, 0, 1) } finally { $s.Dispose() }
}
[pscustomobject]@{
    Mode       = 'Execute'
    IsValid    = (@($fake.Problems).Count -eq 0)
    BundleRoot = $root
    Rows       = @($fake.Rows)
    Problems   = @($fake.Problems)
    Warnings   = @()
}
