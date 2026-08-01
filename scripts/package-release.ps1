[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [string]$OutputDirectory,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$normalizedVersion = $Version.TrimStart('v')
if ($normalizedVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Version must be SemVer without build metadata: $Version"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'artifacts'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null

$packageName = "rtk-codex-powershell-hook-$normalizedVersion"
$archivePath = Join-Path $outputRoot "$packageName.zip"
$checksumPath = "$archivePath.sha256"
foreach ($path in @($archivePath, $checksumPath)) {
    if ([IO.File]::Exists($path)) {
        if (-not $Force) {
            throw "Release artifact already exists: $path"
        }
        [IO.File]::Delete($path)
    }
}

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ($packageName + '-' + [Guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingRoot $packageName
$requiredFiles = @(
    'rtk-codex-hook.ps1',
    'hooks.json',
    'install.ps1',
    'install.cmd',
    'uninstall.ps1',
    'uninstall.cmd',
    'README.md',
    'README.zh-CN.md',
    'CHANGELOG.md',
    'SECURITY.md',
    'LICENSE',
    'DISCLAIMER.md'
)

try {
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    foreach ($relativePath in $requiredFiles) {
        $source = Join-Path $projectRoot $relativePath
        if (-not [IO.File]::Exists($source)) {
            throw "Required release file is missing: $relativePath"
        }
        [IO.File]::Copy($source, (Join-Path $packageRoot $relativePath), $false)
    }

    $sourceDocs = Join-Path $projectRoot 'docs'
    if (-not [IO.Directory]::Exists($sourceDocs)) {
        throw 'Required release directory is missing: docs'
    }
    Copy-Item -LiteralPath $sourceDocs -Destination (Join-Path $packageRoot 'docs') -Recurse

    Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksum = "$hash  $([IO.Path]::GetFileName($archivePath))" + [Environment]::NewLine
    [IO.File]::WriteAllText($checksumPath, $checksum, [Text.UTF8Encoding]::new($false))
}
finally {
    if (
        [IO.Directory]::Exists($stagingRoot) -and
        $stagingRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($stagingRoot).StartsWith($packageName + '-', [StringComparison]::Ordinal)
    ) {
        [IO.Directory]::Delete($stagingRoot, $true)
    }
}

Write-Host "Release package: $archivePath"
Write-Host "SHA-256 file:   $checksumPath"
