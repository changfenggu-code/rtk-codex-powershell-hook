[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
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

$required = @(
    'README.md', 'README.zh-CN.md', 'CHANGELOG.md', 'CONTRIBUTING.md',
    'SECURITY.md', 'DISCLAIMER.md', 'LICENSE',
    'docs\SPEC.md', 'docs\SPEC.zh-CN.md',
    'docs\compatibility.md', 'docs\compatibility.zh-CN.md',
    'docs\upstream-roadmap.md', 'docs\upstream-roadmap.zh-CN.md',
    'docs\read-evaluation.md', 'docs\read-evaluation.zh-CN.md',
    'scripts\evaluate-read.ps1',
    'scripts\run-real-codex-e2e.ps1', 'tests\fixtures\mock-responses-server.mjs',
    '.github\workflows\ci.yml', '.github\workflows\release.yml'
)
foreach ($relativePath in $required) {
    Assert-True "Required file exists: $relativePath" ([IO.File]::Exists((Join-Path $projectRoot $relativePath)))
}

$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
$sourceFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Force | Where-Object {
    $relativePath = $_.FullName.Substring($projectRoot.Length + 1)
    $relativePath -notmatch '^(?:artifacts|\.tmp|\.git)[\\/]'
})
$textFiles = @($sourceFiles | Where-Object {
    $_.Extension -in @('.md', '.ps1', '.cmd', '.json', '.yml', '.yaml', '.psd1', '.mjs') -or $_.Name -eq 'LICENSE'
})
foreach ($file in $textFiles) {
    $validUtf8 = $true
    try {
        $null = $strictUtf8.GetString([IO.File]::ReadAllBytes($file.FullName))
    }
    catch {
        $validUtf8 = $false
    }
    Assert-True "UTF-8: $($file.FullName.Substring($projectRoot.Length + 1))" $validUtf8
}

$markdownFiles = @($sourceFiles | Where-Object { $_.Extension -eq '.md' })
foreach ($file in $markdownFiles) {
    $source = [IO.File]::ReadAllText($file.FullName)
    foreach ($match in [regex]::Matches($source, '\[[^\]]+\]\(([^)]+)\)')) {
        $destination = $match.Groups[1].Value.Trim()
        if (
            $destination.StartsWith('http://', [StringComparison]::OrdinalIgnoreCase) -or
            $destination.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase) -or
            $destination.StartsWith('#', [StringComparison]::Ordinal)
        ) {
            continue
        }
        $pathPart = $destination.Split('#')[0]
        $resolved = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $pathPart))
        Assert-True "Local link from $($file.Name): $destination" (
            [IO.File]::Exists($resolved) -or [IO.Directory]::Exists($resolved)
        )
    }
}

$combinedDocs = ($markdownFiles | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
Assert-True 'Documentation has no owner placeholder' ($combinedDocs -notmatch 'github\.com/OWNER/')
Assert-True 'Documentation has no TODO or TBD marker' ($combinedDocs -notmatch '(?im)\b(?:TODO|TBD)\b')
Assert-True 'Documentation no longer calls the package staging-only' ($combinedDocs -notmatch '(?i)this (?:directory|package) is staging only')

Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
