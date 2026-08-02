[CmdletBinding()]
param(
    [string]$ProjectRoot = $(Split-Path -Parent $PSScriptRoot),

    [string]$RtkPath,

    [ValidateRange(1, 20)]
    [int]$Iterations = 2,

    [Alias('Profile')]
    [ValidateSet('Quick', 'Full')]
    [string]$EvaluationProfile = 'Full',

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 120,

    [ValidateRange(1, [long]::MaxValue)]
    [long]$MaxOutputBytes = 32MB,

    [ValidateSet('Table', 'Json', 'Object')]
    [string]$OutputFormat = 'Table'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'evaluation-common.ps1'
. $common

function Quote-EvaluationPowerShellLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-EvaluationTextHash {
    param([AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-EvaluationPreview {
    param([AllowEmptyString()][string]$Text)

    $normalized = ($Text -replace '\s+', ' ').Trim()
    if ($normalized.Length -le 160) {
        return $normalized
    }
    return $normalized.Substring(0, 160)
}

function New-CommandEvaluationCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RtkCommand,
        [Parameter(Mandatory)][string]$Category,
        [AllowNull()][string]$NativeExecutable,
        [AllowEmptyCollection()][string[]]$NativeArguments,
        [Parameter(Mandatory)][string]$RtkExecutable,
        [AllowEmptyCollection()][string[]]$RtkArguments,
        [int[]]$ExpectedNativeExitCodes = @(0),
        [int[]]$ExpectedRtkExitCodes = @(0),
        [ValidateSet('TaskEquivalent', 'ExplicitLossyView')]
        [string]$ComparisonClass = 'TaskEquivalent',
        [string]$RejectRtkOutputPattern,
        [ValidateSet('Quick', 'Full')]
        [string]$MinimumProfile = 'Quick'
    )

    [pscustomobject]@{
        Name = $Name
        RtkCommand = $RtkCommand
        Category = $Category
        NativeExecutable = $NativeExecutable
        NativeArguments = @($NativeArguments)
        RtkExecutable = $RtkExecutable
        RtkArguments = @($RtkArguments)
        ExpectedNativeExitCodes = @($ExpectedNativeExitCodes)
        ExpectedRtkExitCodes = @($ExpectedRtkExitCodes)
        ComparisonClass = $ComparisonClass
        RejectRtkOutputPattern = $RejectRtkOutputPattern
        MinimumProfile = $MinimumProfile
    }
}

function New-SkippedCommandResult {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][string]$Reason
    )

    [pscustomobject]@{
        Name = $Case.Name
        RtkCommand = $Case.RtkCommand
        Category = $Case.Category
        ComparisonClass = $Case.ComparisonClass
        Status = 'Skipped'
        Reason = $Reason
        NativeExitCode = $null
        RtkExitCode = $null
        NativeCharacters = $null
        RtkCharacters = $null
        NativeBytes = $null
        RtkBytes = $null
        EstimatedNativeTokens = $null
        EstimatedRtkTokens = $null
        SavingsPercent = $null
        ExactOutput = $null
        NativeColdMilliseconds = $null
        RtkColdMilliseconds = $null
        NativeAverageMilliseconds = $null
        RtkAverageMilliseconds = $null
        NativeOutputSha256 = $null
        RtkOutputSha256 = $null
        NativePreview = ''
        RtkPreview = ''
    }
}

function Measure-CommandEvaluationCase {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$TrackingDatabase,
        [Parameter(Mandatory)][int]$SampleCount,
        [Parameter(Mandatory)][int]$ProcessTimeoutSeconds,
        [Parameter(Mandatory)][long]$MaximumOutputBytes
    )

    if ([string]::IsNullOrWhiteSpace($Case.NativeExecutable)) {
        return New-SkippedCommandResult $Case 'Required native executable is not available.'
    }

    try {
        $nativeCold = Invoke-EvaluationProcess `
            $Case.NativeExecutable `
            $Case.NativeArguments `
            $TrackingDatabase `
            $WorkingDirectory `
            -TimeoutSeconds $ProcessTimeoutSeconds
        $rtkCold = Invoke-EvaluationProcess `
            $Case.RtkExecutable `
            $Case.RtkArguments `
            $TrackingDatabase `
            $WorkingDirectory `
            -TimeoutSeconds $ProcessTimeoutSeconds
    }
    catch {
        $skipped = New-SkippedCommandResult $Case "Execution failed: $($_.Exception.Message)"
        $skipped.Status = 'Failed'
        return $skipped
    }

    $nativeBytes = Get-EvaluationUtf8ByteCount $nativeCold.CombinedOutput
    $rtkBytes = Get-EvaluationUtf8ByteCount $rtkCold.CombinedOutput
    $failureReasons = [Collections.Generic.List[string]]::new()
    if ($nativeCold.ExitCode -notin $Case.ExpectedNativeExitCodes) {
        $failureReasons.Add("native exit code $($nativeCold.ExitCode)")
    }
    if ($rtkCold.ExitCode -notin $Case.ExpectedRtkExitCodes) {
        $failureReasons.Add("RTK exit code $($rtkCold.ExitCode)")
    }
    if ($nativeBytes -gt $MaximumOutputBytes -or $rtkBytes -gt $MaximumOutputBytes) {
        $failureReasons.Add("captured output exceeds $MaximumOutputBytes bytes")
    }
    if (
        -not [string]::IsNullOrWhiteSpace($Case.RejectRtkOutputPattern) -and
        $rtkCold.CombinedOutput -match $Case.RejectRtkOutputPattern
    ) {
        $failureReasons.Add('RTK output matched a known failure pattern')
    }

    $nativeTotalMilliseconds = 0.0
    $rtkTotalMilliseconds = 0.0
    if ($failureReasons.Count -eq 0) {
        for ($index = 0; $index -lt $SampleCount; $index++) {
            $nativeSample = Invoke-EvaluationProcess `
                $Case.NativeExecutable `
                $Case.NativeArguments `
                $TrackingDatabase `
                $WorkingDirectory `
                -TimeoutSeconds $ProcessTimeoutSeconds
            $rtkSample = Invoke-EvaluationProcess `
                $Case.RtkExecutable `
                $Case.RtkArguments `
                $TrackingDatabase `
                $WorkingDirectory `
                -TimeoutSeconds $ProcessTimeoutSeconds
            if (
                $nativeSample.ExitCode -notin $Case.ExpectedNativeExitCodes -or
                $rtkSample.ExitCode -notin $Case.ExpectedRtkExitCodes
            ) {
                $failureReasons.Add('a timed sample returned an unexpected exit code')
                break
            }
            $nativeTotalMilliseconds += $nativeSample.ElapsedMilliseconds
            $rtkTotalMilliseconds += $rtkSample.ElapsedMilliseconds
        }
    }

    $nativeTokens = Get-EvaluationEstimatedTokens $nativeCold.CombinedOutput
    $rtkTokens = Get-EvaluationEstimatedTokens $rtkCold.CombinedOutput
    $savings = if ($nativeBytes -eq 0) {
        $null
    }
    else {
        [math]::Round((1.0 - ($rtkBytes / [double]$nativeBytes)) * 100.0, 1)
    }

    [pscustomobject]@{
        Name = $Case.Name
        RtkCommand = $Case.RtkCommand
        Category = $Case.Category
        ComparisonClass = $Case.ComparisonClass
        Status = $(if ($failureReasons.Count -eq 0) { 'Succeeded' } else { 'Failed' })
        Reason = $failureReasons -join '; '
        NativeExitCode = $nativeCold.ExitCode
        RtkExitCode = $rtkCold.ExitCode
        NativeCharacters = $nativeCold.CombinedOutput.Length
        RtkCharacters = $rtkCold.CombinedOutput.Length
        NativeBytes = $nativeBytes
        RtkBytes = $rtkBytes
        EstimatedNativeTokens = $nativeTokens
        EstimatedRtkTokens = $rtkTokens
        SavingsPercent = $savings
        ExactOutput = $nativeCold.CombinedOutput -ceq $rtkCold.CombinedOutput
        NativeColdMilliseconds = [math]::Round($nativeCold.ElapsedMilliseconds, 3)
        RtkColdMilliseconds = [math]::Round($rtkCold.ElapsedMilliseconds, 3)
        NativeAverageMilliseconds = $(if ($failureReasons.Count -eq 0) { [math]::Round($nativeTotalMilliseconds / $SampleCount, 3) } else { $null })
        RtkAverageMilliseconds = $(if ($failureReasons.Count -eq 0) { [math]::Round($rtkTotalMilliseconds / $SampleCount, 3) } else { $null })
        NativeOutputSha256 = Get-EvaluationTextHash $nativeCold.CombinedOutput
        RtkOutputSha256 = Get-EvaluationTextHash $rtkCold.CombinedOutput
        NativePreview = Get-EvaluationPreview $nativeCold.CombinedOutput
        RtkPreview = Get-EvaluationPreview $rtkCold.CombinedOutput
    }
}

function Get-RtkCommandInventory {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TrackingDatabase,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][object[]]$MeasuredCases,
        [Parameter(Mandatory)][int]$ProcessTimeoutSeconds
    )

    $help = Invoke-EvaluationProcess `
        $Executable `
        @('--help') `
        $TrackingDatabase `
        $WorkingDirectory `
        -TimeoutSeconds $ProcessTimeoutSeconds
    if ($help.ExitCode -ne 0) {
        throw "RTK command inventory failed: $($help.StandardError)"
    }

    $measured = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('ls', 'smart', 'git', 'err', 'test', 'json', 'find', 'diff', 'log', 'summary', 'grep', 'rg', 'wc')) {
        $null = $measured.Add($name)
    }
    $projectNotApplicable = @(
        'gh', 'glab', 'aws', 'psql', 'pnpm', 'deps', 'dotnet', 'docker',
        'kubectl', 'oc', 'wget', 'jest', 'vitest', 'prisma', 'tsc', 'next',
        'lint', 'prettier', 'format', 'playwright', 'cargo', 'npm', 'npx',
        'curl', 'ruff', 'pytest', 'mypy', 'php', 'phpunit', 'phpstan', 'pest',
        'paratest', 'ecs', 'pint', 'rake', 'rubocop', 'rspec', 'pip', 'uv',
        'go', 'sbt', 'gt', 'golangci-lint', 'gradlew', 'mvn'
    )
    $management = @(
        'init', 'gain', 'cc-economics', 'config', 'discover', 'session',
        'telemetry', 'learn', 'trust', 'untrust', 'verify', 'hook-audit',
        'rewrite', 'hook', 'help'
    )

    $items = [Collections.Generic.List[object]]::new()
    $insideCommands = $false
    foreach ($line in $help.StandardOutput -split "`r?`n") {
        if ($line -ceq 'Commands:') {
            $insideCommands = $true
            continue
        }
        if ($line -ceq 'Options:') {
            $insideCommands = $false
        }
        if (-not $insideCommands -or $line -notmatch '^  (?<name>\S+)\s{2,}(?<description>.+)$') {
            continue
        }

        $name = $Matches.name
        $status = 'Unclassified'
        $reason = 'No evaluation classification exists for this RTK version.'
        if ($measured.Contains($name)) {
            $status = 'Measured'
            $reason = 'One or more reproducible project cases are included.'
        }
        elseif ($name -eq 'read') {
            $status = 'MeasuredSeparately'
            $reason = 'Covered by evaluate-read.ps1 across six read modes.'
        }
        elseif ($name -eq 'tree') {
            $status = 'UnsupportedOnBaseline'
            $reason = 'RTK 0.44.2 forwards Unix exclusion arguments to native Windows tree.exe, which reports an error with exit code 0.'
        }
        elseif ($name -in $projectNotApplicable) {
            $status = 'NotApplicableToProject'
            $reason = 'The required project ecosystem, manifest, service, or authenticated CLI is absent from this PowerShell repository.'
        }
        elseif ($name -in $management) {
            $status = 'ManagementCommand'
            $reason = 'This command manages RTK or integrations and has no native project-output comparison.'
        }
        elseif ($name -in @('run', 'proxy')) {
            $status = 'IntentionalPassthrough'
            $reason = 'The command explicitly promises raw or unfiltered execution.'
        }
        elseif ($name -eq 'pipe') {
            $status = 'FilterInterface'
            $reason = 'Requires a filter-specific stdin fixture; underlying project filters are covered through direct commands.'
        }
        elseif ($name -eq 'env') {
            $status = 'OutsideProjectFileScope'
            $reason = 'Environment output is not derived from project files.'
        }

        $items.Add([pscustomobject]@{
            Name = $name
            Description = $Matches.description.Trim()
            Status = $status
            Reason = $reason
            MeasuredCaseCount = @($MeasuredCases | Where-Object RtkCommand -eq $name).Count
        })
    }
    return $items.ToArray()
}

function Get-CommandEvaluationAggregate {
    param([Parameter(Mandatory)][object[]]$Results)

    $successful = @($Results | Where-Object { $_.Status -eq 'Succeeded' -and $null -ne $_.SavingsPercent })
    $nativeBytes = [long](($successful | Measure-Object NativeBytes -Sum).Sum)
    $rtkBytes = [long](($successful | Measure-Object RtkBytes -Sum).Sum)
    $orderedSavings = @($successful | ForEach-Object SavingsPercent | Sort-Object)
    $median = $null
    if ($orderedSavings.Count -gt 0) {
        $middle = [int][math]::Floor($orderedSavings.Count / 2)
        $median = if ($orderedSavings.Count % 2 -eq 1) {
            [double]$orderedSavings[$middle]
        }
        else {
            [math]::Round(([double]$orderedSavings[$middle - 1] + [double]$orderedSavings[$middle]) / 2.0, 1)
        }
    }

    [pscustomobject]@{
        CaseCount = $successful.Count
        NativeBytes = $nativeBytes
        RtkBytes = $rtkBytes
        EstimatedNativeTokens = [long][math]::Ceiling($nativeBytes / 4.0)
        EstimatedRtkTokens = [long][math]::Ceiling($rtkBytes / 4.0)
        WeightedSavingsPercent = $(if ($nativeBytes -eq 0) { $null } else { [math]::Round((1.0 - $rtkBytes / [double]$nativeBytes) * 100.0, 1) })
        MedianSavingsPercent = $median
        ImprovedCases = @($successful | Where-Object SavingsPercent -gt 0).Count
        NeutralCases = @($successful | Where-Object SavingsPercent -eq 0).Count
        RegressedCases = @($successful | Where-Object SavingsPercent -lt 0).Count
    }
}

$resolvedProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not [IO.Directory]::Exists($resolvedProjectRoot)) {
    throw "Project root does not exist: $resolvedProjectRoot"
}
$resolvedRtkPath = Resolve-EvaluationRtkPath $RtkPath
$pwshPath = Resolve-EvaluationApplication @('pwsh.exe', 'pwsh')
$gitPath = Resolve-EvaluationApplication @('git.exe', 'git')
$rgPath = Resolve-EvaluationApplication @('rg.exe', 'rg')
$grepPath = Resolve-EvaluationApplication @('grep.exe', 'grep')
$wcPath = Resolve-EvaluationApplication @('wc.exe', 'wc')

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('rtk-command-evaluation-' + [Guid]::NewGuid().ToString('N'))
$trackingDatabase = Join-Path $temporaryRoot 'tracking.db'
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

try {
    $versionResult = Invoke-EvaluationProcess `
        $resolvedRtkPath `
        @('--version') `
        $trackingDatabase `
        $resolvedProjectRoot `
        -TimeoutSeconds $TimeoutSeconds
    if ($versionResult.ExitCode -ne 0 -or $versionResult.StandardOutput -notmatch '^rtk \d+\.\d+\.\d+') {
        throw "RTK version check failed: $($versionResult.StandardError)"
    }

    $sampleFile = Join-Path $resolvedProjectRoot 'rtk-codex-hook.ps1'
    $jsonFile = Join-Path $resolvedProjectRoot 'hooks.json'
    $docsTest = Join-Path $resolvedProjectRoot 'tests\test-docs.ps1'
    $scriptsDirectory = Join-Path $resolvedProjectRoot 'scripts'
    $readme = Join-Path $resolvedProjectRoot 'README.md'
    $readmeChinese = Join-Path $resolvedProjectRoot 'README.zh-CN.md'
    $searchFixtures = @(
        'README.md',
        'README.zh-CN.md',
        'docs/SPEC.md',
        'docs/SPEC.zh-CN.md'
    )

    $gitDiffExecutable = $null
    if ($null -ne $gitPath) {
        $previousCommit = Invoke-EvaluationProcess `
            $gitPath `
            @('rev-parse', '--verify', 'HEAD~1') `
            $trackingDatabase `
            $resolvedProjectRoot `
            -TimeoutSeconds $TimeoutSeconds
        if ($previousCommit.ExitCode -eq 0) {
            $gitDiffExecutable = $gitPath
        }
    }

    $logFixture = Join-Path $temporaryRoot 'project-git.log'
    if ($null -ne $gitPath) {
        $gitLog = Invoke-EvaluationProcess $gitPath @('log', '-20', '--oneline', '--decorate') $trackingDatabase $resolvedProjectRoot -TimeoutSeconds $TimeoutSeconds
        $repeatedLog = $gitLog.StandardOutput + $gitLog.StandardOutput + $gitLog.StandardOutput
        [IO.File]::WriteAllText($logFixture, $repeatedLog, [Text.UTF8Encoding]::new($false))
    }

    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add((New-CommandEvaluationCase `
        'ls-root' 'ls' 'Files' $pwshPath `
        @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "Get-ChildItem -LiteralPath '.' -Force | Sort-Object Name | Format-Table Mode,Length,Name -AutoSize | Out-String -Width 4096") `
        $resolvedRtkPath @('ls', '-a', '.')))
    $cases.Add((New-CommandEvaluationCase `
        'find-scripts' 'find' 'Files' $pwshPath `
        @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "Get-ChildItem -LiteralPath $(Quote-EvaluationPowerShellLiteral $scriptsDirectory) -Recurse -File | Sort-Object FullName | ForEach-Object { [IO.Path]::GetRelativePath($(Quote-EvaluationPowerShellLiteral $resolvedProjectRoot), `$_.FullName) }") `
        $resolvedRtkPath @('find', 'scripts', '-type', 'f')))
    $cases.Add((New-CommandEvaluationCase `
        'rg-markdown' 'rg' 'Search' $rgPath `
        (@('-n', '-i', 'rtk') + $searchFixtures) `
        $resolvedRtkPath (@('rg', '-n', '-i', 'rtk') + $searchFixtures)))
    $cases.Add((New-CommandEvaluationCase `
        'grep-markdown' 'grep' 'Search' $grepPath `
        (@('-n', '-i', 'rtk') + $searchFixtures) `
        $resolvedRtkPath (@('grep', '-n', '-i', 'rtk') + $searchFixtures)))
    $cases.Add((New-CommandEvaluationCase `
        'wc-hook' 'wc' 'Files' $wcPath `
        @('-l', '-w', '-c', $sampleFile) `
        $resolvedRtkPath @('wc', '-l', '-w', '-c', $sampleFile)))
    $cases.Add((New-CommandEvaluationCase `
        'json-hooks' 'json' 'Files' $pwshPath `
        @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "Get-Content -LiteralPath $(Quote-EvaluationPowerShellLiteral $jsonFile) -Raw") `
        $resolvedRtkPath @('json', $jsonFile)))
    $cases.Add((New-CommandEvaluationCase `
        'git-status' 'git' 'Git' $gitPath `
        @('status', '--untracked-files=all') `
        $resolvedRtkPath @('git', 'status', '--untracked-files=all')))
    $cases.Add((New-CommandEvaluationCase `
        'git-log' 'git' 'Git' $gitPath `
        @('log', '-20', '--oneline', '--decorate') `
        $resolvedRtkPath @('git', 'log', '-20', '--oneline', '--decorate')))
    $cases.Add((New-CommandEvaluationCase `
        'git-show' 'git' 'Git' $gitPath `
        @('show', '--stat', '--oneline', 'HEAD') `
        $resolvedRtkPath @('git', 'show', '--stat', '--oneline', 'HEAD')))
    $cases.Add((New-CommandEvaluationCase `
        'git-diff-previous' 'git' 'Git' $gitDiffExecutable `
        @('diff', 'HEAD~1', 'HEAD') `
        $resolvedRtkPath @('git', 'diff', 'HEAD~1', 'HEAD')))

    if ($EvaluationProfile -eq 'Full') {
        $cases.Add((New-CommandEvaluationCase `
            'smart-hook' 'smart' 'Files' $pwshPath `
            @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "Get-Content -LiteralPath $(Quote-EvaluationPowerShellLiteral $sampleFile) -Raw") `
            $resolvedRtkPath @('smart', $sampleFile) `
            -ComparisonClass 'ExplicitLossyView' -MinimumProfile 'Full'))
        $cases.Add((New-CommandEvaluationCase `
            'diff-readmes' 'diff' 'Files' $gitPath `
            @('diff', '--no-index', '--', $readme, $readmeChinese) `
            $resolvedRtkPath @('diff', $readme, $readmeChinese) `
            -ExpectedNativeExitCodes @(1) -ExpectedRtkExitCodes @(1) -MinimumProfile 'Full'))
        $cases.Add((New-CommandEvaluationCase `
            'log-git-history' 'log' 'Files' $pwshPath `
            @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "Get-Content -LiteralPath $(Quote-EvaluationPowerShellLiteral $logFixture) -Raw") `
            $resolvedRtkPath @('log', $logFixture) `
            -ComparisonClass 'ExplicitLossyView' -MinimumProfile 'Full'))
        $testArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $docsTest)
        $cases.Add((New-CommandEvaluationCase `
            'test-docs' 'test' 'Tests' $pwshPath $testArguments `
            $resolvedRtkPath (@('test', 'pwsh') + $testArguments) -MinimumProfile 'Full'))
        $cases.Add((New-CommandEvaluationCase `
            'err-docs' 'err' 'Tests' $pwshPath $testArguments `
            $resolvedRtkPath (@('err', 'pwsh') + $testArguments) `
            -ComparisonClass 'ExplicitLossyView' -MinimumProfile 'Full'))
        $cases.Add((New-CommandEvaluationCase `
            'summary-docs' 'summary' 'Tests' $pwshPath $testArguments `
            $resolvedRtkPath (@('summary', 'pwsh') + $testArguments) `
            -ComparisonClass 'ExplicitLossyView' -MinimumProfile 'Full'))
    }

    $results = [Collections.Generic.List[object]]::new()
    foreach ($case in $cases) {
        $results.Add((Measure-CommandEvaluationCase `
            $case `
            $resolvedProjectRoot `
            $trackingDatabase `
            $Iterations `
            $TimeoutSeconds `
            $MaxOutputBytes))
    }

    $inventory = @(Get-RtkCommandInventory `
        $resolvedRtkPath `
        $trackingDatabase `
        $resolvedProjectRoot `
        $cases.ToArray() `
        $TimeoutSeconds)
    $gitHead = if ($null -eq $gitPath) {
        ''
    }
    else {
        (Invoke-EvaluationProcess $gitPath @('rev-parse', 'HEAD') $trackingDatabase $resolvedProjectRoot -TimeoutSeconds $TimeoutSeconds).StandardOutput.Trim()
    }
    $gitStatus = if ($null -eq $gitPath) {
        ''
    }
    else {
        (Invoke-EvaluationProcess $gitPath @('status', '--short') $trackingDatabase $resolvedProjectRoot -TimeoutSeconds $TimeoutSeconds).StandardOutput
    }

    $successfulTaskEquivalent = @($results | Where-Object { $_.Status -eq 'Succeeded' -and $_.ComparisonClass -eq 'TaskEquivalent' })
    $report = [pscustomobject]@{
        SchemaVersion = 1
        Date = (Get-Date).ToString('o')
        ProjectRoot = $resolvedProjectRoot
        ProjectGitHead = $gitHead
        ProjectDirty = -not [string]::IsNullOrWhiteSpace($gitStatus)
        RtkPath = $resolvedRtkPath
        RtkVersion = $versionResult.StandardOutput.Trim()
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Profile = $EvaluationProfile
        Iterations = $Iterations
        TokenEstimate = 'ceil(UTF-8 output bytes / 4)'
        TrackingIsolated = $true
        Aggregate = Get-CommandEvaluationAggregate $results.ToArray()
        TaskEquivalentAggregate = Get-CommandEvaluationAggregate $successfulTaskEquivalent
        Cases = $results.ToArray()
        CommandInventory = $inventory
        Coverage = [pscustomobject]@{
            TotalCommands = $inventory.Count
            MeasuredCommands = @($inventory | Where-Object Status -eq 'Measured').Count
            MeasuredSeparately = @($inventory | Where-Object Status -eq 'MeasuredSeparately').Count
            NotApplicableToProject = @($inventory | Where-Object Status -eq 'NotApplicableToProject').Count
            ManagementCommands = @($inventory | Where-Object Status -eq 'ManagementCommand').Count
            IntentionalPassthrough = @($inventory | Where-Object Status -eq 'IntentionalPassthrough').Count
            OtherClassified = @($inventory | Where-Object { $_.Status -in @('UnsupportedOnBaseline', 'FilterInterface', 'OutsideProjectFileScope') }).Count
            Unclassified = @($inventory | Where-Object Status -eq 'Unclassified').Count
        }
    }

    switch ($OutputFormat) {
        'Json' {
            $report | ConvertTo-Json -Depth 10
        }
        'Object' {
            $report
        }
        default {
            Write-Host "Project:    $($report.ProjectRoot)"
            Write-Host "RTK:        $($report.RtkVersion)"
            Write-Host "Profile:    $($report.Profile), $($report.Iterations) timed iteration(s)"
            Write-Host "Coverage:   $($report.Coverage.TotalCommands) commands, $($report.Coverage.Unclassified) unclassified"
            Write-Host "Weighted:   $($report.Aggregate.WeightedSavingsPercent)% all measured / $($report.TaskEquivalentAggregate.WeightedSavingsPercent)% task-equivalent"
            $report.Cases |
                Select-Object Name, RtkCommand, Status, ComparisonClass, NativeBytes, RtkBytes,
                    EstimatedNativeTokens, EstimatedRtkTokens, SavingsPercent,
                    NativeAverageMilliseconds, RtkAverageMilliseconds |
                Format-Table -AutoSize
            $report.CommandInventory |
                Group-Object Status |
                Sort-Object Name |
                Select-Object Name, Count |
                Format-Table -AutoSize
        }
    }
}
finally {
    if (
        [IO.Directory]::Exists($temporaryRoot) -and
        [string]::Equals(
            [IO.Directory]::GetParent($temporaryRoot).FullName.TrimEnd([IO.Path]::DirectorySeparatorChar),
            [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFileName($temporaryRoot).StartsWith('rtk-command-evaluation-', [StringComparison]::Ordinal)
    ) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}
