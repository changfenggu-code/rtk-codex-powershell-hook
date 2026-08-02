[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tests = @(
    'test-rtk-codex-hook.ps1',
    'test-read-evaluation.ps1',
    'test-command-evaluation.ps1',
    'test-install.ps1',
    'test-security.ps1',
    'test-package.ps1',
    'test-docs.ps1'
)

foreach ($test in $tests) {
    Write-Host "==> $test"
    & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) {
        throw "$test failed with exit code $LASTEXITCODE"
    }
}

Write-Host "All $($tests.Count) test suites passed."
