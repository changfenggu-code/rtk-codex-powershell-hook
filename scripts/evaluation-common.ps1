Set-StrictMode -Version Latest

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

function Resolve-EvaluationApplication {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) {
            return [IO.Path]::GetFullPath($command.Source)
        }
    }
    return $null
}

function Invoke-EvaluationProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$TrackingDatabase,
        [string]$WorkingDirectory,
        [AllowNull()][string]$StandardInput,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInput
    $startInfo.Environment['RTK_DB_PATH'] = $TrackingDatabase
    $startInfo.Environment['RTK_TELEMETRY_DISABLED'] = '1'
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInput) {
            $process.StandardInput.Write($StandardInput)
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Process timed out after $TimeoutSeconds seconds: $Executable"
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

    $combined = $stdout
    if (-not [string]::IsNullOrEmpty($stderr)) {
        if (-not [string]::IsNullOrEmpty($combined) -and -not $combined.EndsWith("`n", [StringComparison]::Ordinal)) {
            $combined += [Environment]::NewLine
        }
        $combined += $stderr
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = $stdout
        StandardError = $stderr
        CombinedOutput = $combined
        ElapsedMilliseconds = $stopwatch.Elapsed.TotalMilliseconds
    }
}

function Get-EvaluationLineCount {
    param([AllowEmptyString()][string]$Text)

    if ($Text.Length -eq 0) {
        return 0
    }
    $newlines = [regex]::Matches($Text, "`n").Count
    return $newlines + $(if ($Text.EndsWith("`n", [StringComparison]::Ordinal)) { 0 } else { 1 })
}

function Get-EvaluationUtf8ByteCount {
    param([AllowEmptyString()][string]$Text)

    return [Text.Encoding]::UTF8.GetByteCount($Text)
}

function Get-EvaluationEstimatedTokens {
    param([AllowEmptyString()][string]$Text)

    return [long][math]::Ceiling((Get-EvaluationUtf8ByteCount $Text) / 4.0)
}
