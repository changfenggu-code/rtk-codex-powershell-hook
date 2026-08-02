[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$evaluator = Join-Path $projectRoot 'scripts\evaluate-command-savings.ps1'
$common = Join-Path $projectRoot 'scripts\evaluation-common.ps1'
. $common

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

function Get-InventoryItem {
    param([Parameter(Mandatory)][object]$Report, [Parameter(Mandatory)][string]$Name)

    return @($Report.CommandInventory | Where-Object Name -eq $Name)[0]
}

$git = Resolve-EvaluationApplication @('git.exe', 'git')
$statusBefore = if ($null -eq $git) {
    ''
}
else {
    (& $git -C $projectRoot status --porcelain=v1 --untracked-files=all) -join "`n"
}

$report = & $evaluator `
    -ProjectRoot $projectRoot `
    -EvaluationProfile Quick `
    -Iterations 1 `
    -OutputFormat Object

Assert-True 'Command evaluator returns schema version 1' ($report.SchemaVersion -eq 1)
Assert-True 'Command evaluator reports RTK 0.44-compatible version' ($report.RtkVersion -match '^rtk \d+\.\d+\.\d+')
Assert-True 'Command evaluator isolates RTK tracking' $report.TrackingIsolated
Assert-True 'Command evaluator records bytes-over-four token method' ($report.TokenEstimate -eq 'ceil(UTF-8 output bytes / 4)')
Assert-True 'Command inventory covers current RTK surface' ($report.Coverage.TotalCommands -ge 79)
Assert-True 'Command inventory has no unclassified entries' ($report.Coverage.Unclassified -eq 0)
Assert-True 'Quick profile measures successful project cases' (@($report.Cases | Where-Object Status -eq 'Succeeded').Count -ge 9)
Assert-True 'Every Quick case has a terminal status' (@($report.Cases | Where-Object Status -notin @('Succeeded', 'Skipped', 'Failed')).Count -eq 0)
Assert-True 'No Quick case fails validation' (@($report.Cases | Where-Object Status -eq 'Failed').Count -eq 0)
Assert-True 'Aggregate records at least one improved case' ($report.Aggregate.ImprovedCases -gt 0)
Assert-True 'Aggregate records nonzero native bytes' ($report.Aggregate.NativeBytes -gt 0)
Assert-True 'Aggregate records nonzero RTK bytes' ($report.Aggregate.RtkBytes -gt 0)
Assert-True 'Task-equivalent aggregate records successful cases' ($report.TaskEquivalentAggregate.CaseCount -ge 9)
Assert-True 'Successful cases record byte and token counts' (@($report.Cases | Where-Object {
    $_.Status -eq 'Succeeded' -and (
        $null -eq $_.NativeBytes -or $null -eq $_.RtkBytes -or
        $null -eq $_.EstimatedNativeTokens -or $null -eq $_.EstimatedRtkTokens
    )
}).Count -eq 0)
Assert-True 'Successful cases record nonnegative average timings' (@($report.Cases | Where-Object {
    $_.Status -eq 'Succeeded' -and (
        $_.NativeAverageMilliseconds -lt 0 -or $_.RtkAverageMilliseconds -lt 0
    )
}).Count -eq 0)
Assert-True 'Tree is explicitly unsupported on baseline' ((Get-InventoryItem $report 'tree').Status -eq 'UnsupportedOnBaseline')
Assert-True 'Read is linked to separate evaluator' ((Get-InventoryItem $report 'read').Status -eq 'MeasuredSeparately')
Assert-True 'Run is intentional passthrough' ((Get-InventoryItem $report 'run').Status -eq 'IntentionalPassthrough')
Assert-True 'Cargo is not applicable to this PowerShell project' ((Get-InventoryItem $report 'cargo').Status -eq 'NotApplicableToProject')
Assert-True 'UTF-8 byte count handles non-ASCII text' ((Get-EvaluationUtf8ByteCount '中文') -eq 6)
Assert-True 'Token estimate uses UTF-8 bytes' ((Get-EvaluationEstimatedTokens '中文') -eq 2)

$statusAfter = if ($null -eq $git) {
    ''
}
else {
    (& $git -C $projectRoot status --porcelain=v1 --untracked-files=all) -join "`n"
}
Assert-True 'Command evaluator does not modify project status' ($statusAfter -ceq $statusBefore)

$missingProjectRejected = $false
try {
    & $evaluator `
        -ProjectRoot (Join-Path $projectRoot 'missing-project') `
        -EvaluationProfile Quick `
        -Iterations 1 `
        -OutputFormat Object
}
catch {
    $missingProjectRejected = $_.Exception.Message.Contains('does not exist')
}
Assert-True 'Command evaluator rejects missing project root' $missingProjectRejected

$missingRtkRejected = $false
try {
    & $evaluator `
        -ProjectRoot $projectRoot `
        -RtkPath (Join-Path $projectRoot 'missing-rtk.exe') `
        -EvaluationProfile Quick `
        -Iterations 1 `
        -OutputFormat Object
}
catch {
    $missingRtkRejected = $_.Exception.Message.Contains('does not exist')
}
Assert-True 'Command evaluator rejects missing RTK path' $missingRtkRejected

Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
