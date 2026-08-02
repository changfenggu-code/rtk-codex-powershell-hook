[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$evaluator = Join-Path $projectRoot 'scripts\evaluate-read.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rtk-read-evaluation-tests-' + [Guid]::NewGuid().ToString('N'))
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

function Get-Case {
    param([Parameter(Mandatory)][object]$Report, [Parameter(Mandatory)][string]$Name)

    return @($Report.Cases | Where-Object Mode -eq $Name)[0]
}

try {
    $fixture = Join-Path $testRoot 'sample.rs'
    $source = @'
/// Public documentation remains useful.
// Ordinary implementation comment.
pub fn alpha() {
    println!("alpha");
}

fn beta() {
    println!("beta");
}
'@
    [IO.File]::WriteAllText($fixture, $source, [Text.UTF8Encoding]::new($false))
    $beforeHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash

    $report = & $evaluator `
        -File $fixture `
        -Iterations 1 `
        -WindowLines 2 `
        -OutputFormat Object
    Assert-True 'Evaluator returns schema version 1' ($report.SchemaVersion -eq 1)
    Assert-True 'Evaluator reports RTK version' ($report.RtkVersion -match '^rtk \d+\.\d+\.\d+')
    Assert-True 'Evaluator isolates RTK tracking' $report.TrackingIsolated
    Assert-True 'Evaluator records bytes-over-four token method' ($report.TokenEstimate -eq 'ceil(UTF-8 output bytes / 4)')
    Assert-True 'Evaluator records six modes' ($report.Cases.Count -eq 6)
    Assert-True 'Evaluator records positive Get-Content timing' ($report.NativeGetContentAverageMilliseconds -ge 0)

    $default = Get-Case $report 'default'
    $minimal = Get-Case $report 'minimal'
    $aggressive = Get-Case $report 'aggressive'
    $maxLines = Get-Case $report 'max-lines'
    $tailLines = Get-Case $report 'tail-lines'
    $lineNumbers = Get-Case $report 'line-numbers'
    Assert-True 'Default read is exact' $default.Exact
    Assert-True 'Default read records UTF-8 byte count' ($default.Bytes -eq [Text.Encoding]::UTF8.GetByteCount($source))
    Assert-True 'Default read saves zero estimated tokens' ($default.SavingsPercent -eq 0)
    Assert-True 'Minimal read removes ordinary comments' ($minimal.Characters -lt $default.Characters)
    Assert-True 'Aggressive read is smaller than minimal' ($aggressive.Characters -lt $minimal.Characters)
    Assert-True 'Max-lines is explicitly non-exact' (-not $maxLines.Exact)
    Assert-True 'Tail-lines is smaller than the full file' ($tailLines.Characters -lt $default.Characters)
    Assert-True 'Line numbers add output characters' ($lineNumbers.Characters -gt $default.Characters)
    Assert-True 'Each RTK case records positive cold timing' (@($report.Cases | Where-Object ColdMilliseconds -le 0).Count -eq 0)
    Assert-True 'Each RTK case records positive average timing' (@($report.Cases | Where-Object AverageMilliseconds -le 0).Count -eq 0)

    $afterHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
    Assert-True 'Evaluator never modifies the input file' ($afterHash -eq $beforeHash)

    $json = & $evaluator -File $fixture -Iterations 1 -WindowLines 2 -OutputFormat Json
    $jsonReport = $json | ConvertFrom-Json
    Assert-True 'JSON output preserves schema version' ($jsonReport.SchemaVersion -eq 1)

    $missingRejected = $false
    try {
        & $evaluator -File (Join-Path $testRoot 'missing.rs') -Iterations 1 -OutputFormat Object
    }
    catch {
        $missingRejected = $_.Exception.Message.Contains('does not exist')
    }
    Assert-True 'Evaluator rejects a missing input file' $missingRejected

    $sizeRejected = $false
    try {
        & $evaluator -File $fixture -Iterations 1 -MaxFileBytes 1 -OutputFormat Object
    }
    catch {
        $sizeRejected = $_.Exception.Message.Contains('increase MaxFileBytes')
    }
    Assert-True 'Evaluator requires explicit opt-in for large files' $sizeRejected
}
finally {
    if (
        [IO.Directory]::Exists($testRoot) -and
        [IO.Path]::GetFileName($testRoot).StartsWith('rtk-read-evaluation-tests-', [StringComparison]::Ordinal)
    ) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}

Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
