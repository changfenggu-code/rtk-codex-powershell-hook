[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$File,

    [string]$RtkPath,

    [ValidateRange(1, 100)]
    [int]$Iterations = 5,

    [ValidateRange(1, 1000000)]
    [int]$WindowLines = 100,

    [ValidateRange(1, [long]::MaxValue)]
    [long]$MaxFileBytes = 16MB,

    [ValidateSet('Table', 'Json', 'Object')]
    [string]$OutputFormat = 'Table'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-EvaluationRtkPath {
    param([string]$RequestedPath)

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        $command = Get-Command rtk.exe, rtk -ErrorAction Stop | Select-Object -First 1
        return [IO.Path]::GetFullPath($command.Source)
    }
    if (-not [IO.Path]::IsPathFullyQualified($RequestedPath)) {
        throw 'RtkPath must be an absolute path.'
    }

    $resolved = [IO.Path]::GetFullPath($RequestedPath)
    if (-not [IO.File]::Exists($resolved)) {
        throw "RTK executable does not exist: $resolved"
    }
    return $resolved
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$TrackingDatabase
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['RTK_DB_PATH'] = $TrackingDatabase
    $startInfo.Environment['RTK_TELEMETRY_DISABLED'] = '1'
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "RTK process timed out after 60000 ms: $Executable"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $stopwatch.Stop()
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = $stdout
        StandardError = $stderr
        ElapsedMilliseconds = $stopwatch.Elapsed.TotalMilliseconds
    }
}

function Get-LineCount {
    param([AllowEmptyString()][string]$Text)

    if ($Text.Length -eq 0) {
        return 0
    }
    $newlines = [regex]::Matches($Text, "`n").Count
    return $newlines + $(if ($Text.EndsWith("`n", [StringComparison]::Ordinal)) { 0 } else { 1 })
}

function Get-EstimatedTokens {
    param([AllowEmptyString()][string]$Text)

    return [long][math]::Ceiling($Text.Length / 4.0)
}

function Measure-RtkReadCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$RawContent,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TrackingDatabase,
        [Parameter(Mandatory)][int]$SampleCount
    )

    $cold = Invoke-CapturedProcess $Executable (@('read') + $Arguments) $TrackingDatabase
    if ($cold.ExitCode -ne 0) {
        throw "rtk read case '$Name' failed with exit code $($cold.ExitCode): $($cold.StandardError)"
    }

    $totalMilliseconds = 0.0
    for ($index = 0; $index -lt $SampleCount; $index++) {
        $sample = Invoke-CapturedProcess $Executable (@('read') + $Arguments) $TrackingDatabase
        if ($sample.ExitCode -ne 0) {
            throw "rtk read case '$Name' failed during sampling: $($sample.StandardError)"
        }
        $totalMilliseconds += $sample.ElapsedMilliseconds
    }

    $output = $cold.StandardOutput
    $rawTokens = Get-EstimatedTokens $RawContent
    $outputTokens = Get-EstimatedTokens $output
    $savings = if ($rawTokens -eq 0) {
        0.0
    }
    else {
        [math]::Round((1.0 - ($outputTokens / [double]$rawTokens)) * 100.0, 1)
    }

    [pscustomobject]@{
        Mode = $Name
        Characters = $output.Length
        EstimatedTokens = $outputTokens
        Lines = Get-LineCount $output
        SavingsPercent = $savings
        Exact = $output -ceq $RawContent
        ColdMilliseconds = [math]::Round($cold.ElapsedMilliseconds, 3)
        AverageMilliseconds = [math]::Round($totalMilliseconds / $SampleCount, 3)
    }
}

$resolvedFile = [IO.Path]::GetFullPath($File)
if (-not [IO.File]::Exists($resolvedFile)) {
    throw "Input file does not exist: $resolvedFile"
}
$fileInfo = [IO.FileInfo]::new($resolvedFile)
if ($fileInfo.Length -gt $MaxFileBytes) {
    throw "Input file is $($fileInfo.Length) bytes; increase MaxFileBytes explicitly to evaluate it."
}

$resolvedRtkPath = Resolve-EvaluationRtkPath $RtkPath
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('rtk-read-evaluation-' + [Guid]::NewGuid().ToString('N'))
$trackingDatabase = Join-Path $temporaryRoot 'tracking.db'
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

try {
    $versionResult = Invoke-CapturedProcess $resolvedRtkPath @('--version') $trackingDatabase
    if ($versionResult.ExitCode -ne 0 -or $versionResult.StandardOutput -notmatch '^rtk \d+\.\d+\.\d+') {
        throw "RTK version check failed: $($versionResult.StandardError)"
    }
    $helpResult = Invoke-CapturedProcess $resolvedRtkPath @('read', '--help') $trackingDatabase
    if ($helpResult.ExitCode -ne 0) {
        throw "RTK read compatibility check failed: $($helpResult.StandardError)"
    }

    $rawContent = [IO.File]::ReadAllText($resolvedFile)
    $nativeStopwatch = [Diagnostics.Stopwatch]::StartNew()
    for ($index = 0; $index -lt $Iterations; $index++) {
        $null = Get-Content -LiteralPath $resolvedFile -Raw
    }
    $nativeStopwatch.Stop()

    $cases = @(
        Measure-RtkReadCase 'default' @($resolvedFile) $rawContent $resolvedRtkPath $trackingDatabase $Iterations
        Measure-RtkReadCase 'minimal' @($resolvedFile, '-l', 'minimal') $rawContent $resolvedRtkPath $trackingDatabase $Iterations
        Measure-RtkReadCase 'aggressive' @($resolvedFile, '-l', 'aggressive') $rawContent $resolvedRtkPath $trackingDatabase $Iterations
        Measure-RtkReadCase 'max-lines' @($resolvedFile, '--max-lines', [string]$WindowLines) $rawContent $resolvedRtkPath $trackingDatabase $Iterations
        Measure-RtkReadCase 'tail-lines' @($resolvedFile, '--tail-lines', [string]$WindowLines) $rawContent $resolvedRtkPath $trackingDatabase $Iterations
        Measure-RtkReadCase 'line-numbers' @($resolvedFile, '--line-numbers') $rawContent $resolvedRtkPath $trackingDatabase $Iterations
    )

    $report = [pscustomobject]@{
        SchemaVersion = 1
        Date = (Get-Date).ToString('o')
        File = $resolvedFile
        FileSha256 = (Get-FileHash -LiteralPath $resolvedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        FileBytes = $fileInfo.Length
        FileCharacters = $rawContent.Length
        FileLines = Get-LineCount $rawContent
        EstimatedRawTokens = Get-EstimatedTokens $rawContent
        RtkPath = $resolvedRtkPath
        RtkVersion = $versionResult.StandardOutput.Trim()
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Iterations = $Iterations
        WindowLines = $WindowLines
        NativeGetContentAverageMilliseconds = [math]::Round(
            $nativeStopwatch.Elapsed.TotalMilliseconds / $Iterations,
            3
        )
        TrackingIsolated = $true
        Cases = $cases
    }

    switch ($OutputFormat) {
        'Json' {
            $report | ConvertTo-Json -Depth 8
        }
        'Object' {
            $report
        }
        default {
            Write-Host "File:       $($report.File)"
            Write-Host "RTK:        $($report.RtkVersion)"
            Write-Host "Raw:        $($report.FileCharacters) characters / ~$($report.EstimatedRawTokens) tokens"
            Write-Host "Get-Content average: $($report.NativeGetContentAverageMilliseconds) ms"
            $report.Cases |
                Select-Object Mode, Characters, EstimatedTokens, Lines, SavingsPercent, Exact,
                    ColdMilliseconds, AverageMilliseconds |
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
        [IO.Path]::GetFileName($temporaryRoot).StartsWith('rtk-read-evaluation-', [StringComparison]::Ordinal)
    ) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}
