[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$packager = Join-Path $projectRoot 'scripts\package-release.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rtk-codex-package-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition)

    if ($Condition) {
        $script:Passed++
        return
    }
    $script:Failed++
    Write-Host "FAIL: $Name" -ForegroundColor Red
}

function Assert-Equal {
    param([string]$Name, [object]$Actual, [object]$Expected)

    if ([object]::Equals($Actual, $Expected)) {
        $script:Passed++
        return
    }
    $script:Failed++
    Write-Host "FAIL: $Name" -ForegroundColor Red
    Write-Host "  expected: [$Expected]"
    Write-Host "  actual:   [$Actual]"
}

try {
    & $packager -Version '0.1.0' -OutputDirectory $testRoot
    $archive = Join-Path $testRoot 'rtk-codex-powershell-hook-0.1.0.zip'
    $checksum = "$archive.sha256"
    Assert-True 'Packager creates ZIP' ([IO.File]::Exists($archive))
    Assert-True 'Packager creates checksum' ([IO.File]::Exists($checksum))

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entryNames = @($zip.Entries | ForEach-Object FullName)
        foreach ($required in @(
            'rtk-codex-powershell-hook-0.1.0/rtk-codex-hook.ps1',
            'rtk-codex-powershell-hook-0.1.0/install.cmd',
            'rtk-codex-powershell-hook-0.1.0/uninstall.cmd',
            'rtk-codex-powershell-hook-0.1.0/README.md',
            'rtk-codex-powershell-hook-0.1.0/README.zh-CN.md',
            'rtk-codex-powershell-hook-0.1.0/LICENSE',
            'rtk-codex-powershell-hook-0.1.0/docs/SPEC.md',
            'rtk-codex-powershell-hook-0.1.0/docs/SPEC.zh-CN.md'
        )) {
            Assert-True "ZIP contains $required" ($required -in $entryNames)
        }
    }
    finally {
        $zip.Dispose()
    }

    $expectedHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumText = [IO.File]::ReadAllText($checksum).Trim()
    Assert-Equal 'Checksum matches release ZIP' ($checksumText.Split(' ')[0]) $expectedHash

    & $packager -Version 'v0.1.0' -OutputDirectory $testRoot -Force
    Assert-True 'Force packaging replaces exact artifact' ([IO.File]::Exists($archive))

    $invalidVersionRejected = $false
    try {
        & $packager -Version '..\escape' -OutputDirectory $testRoot
    }
    catch {
        $invalidVersionRejected = $true
    }
    Assert-True 'Packager rejects unsafe version' $invalidVersionRejected
}
finally {
    if (
        [IO.Directory]::Exists($testRoot) -and
        [IO.Path]::GetFileName($testRoot).StartsWith('rtk-codex-package-tests-', [StringComparison]::Ordinal)
    ) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}

Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
