[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [switch]$AllowProviderRequest,

    [string]$CodexHome = $(
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $env:CODEX_HOME
        }
        else {
            Join-Path $HOME '.codex'
        }
    ),

    [string]$RtkPath,

    [string]$WorkingDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsonStringValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [string]) {
        $Value
        return
    }
    if ($Value -is [ValueType]) {
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Get-JsonStringValue $item
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        Get-JsonStringValue $property.Value
    }
}

if (-not $AllowProviderRequest) {
    throw 'Real Codex e2e sends the prompt and normal Codex context to the configured provider. Re-run with -AllowProviderRequest only after reviewing that provider.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $WorkingDirectory = $projectRoot
}
$workingRoot = [IO.Path]::GetFullPath($WorkingDirectory)
if (-not [IO.Directory]::Exists($workingRoot)) {
    throw "Working directory does not exist: $workingRoot"
}

$codex = Get-Command codex.exe, codex -ErrorAction Stop | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($RtkPath)) {
    $rtk = Get-Command rtk.exe, rtk -ErrorAction Stop | Select-Object -First 1
    $RtkPath = $rtk.Source
}
$resolvedRtkPath = [IO.Path]::GetFullPath($RtkPath)

$codexRoot = [IO.Path]::GetFullPath($CodexHome).TrimEnd([IO.Path]::DirectorySeparatorChar)
$targetConfig = Join-Path $codexRoot 'hooks.json'
$targetHook = Join-Path $codexRoot 'hooks\rtk-codex-hook.ps1'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "rtk-codex-real-e2e-$runId-$([Guid]::NewGuid().ToString('N'))"
$evidenceRoot = Join-Path $projectRoot "artifacts\e2e\$runId"
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null

$configExisted = [IO.File]::Exists($targetConfig)
$hookExisted = [IO.File]::Exists($targetHook)
$configHash = $null
$hookHash = $null
if ($configExisted) {
    [IO.File]::Copy($targetConfig, (Join-Path $temporaryRoot 'hooks.json.original'), $false)
    $configHash = (Get-FileHash -LiteralPath $targetConfig -Algorithm SHA256).Hash
}
if ($hookExisted) {
    [IO.File]::Copy($targetHook, (Join-Path $temporaryRoot 'rtk-codex-hook.ps1.original'), $false)
    $hookHash = (Get-FileHash -LiteralPath $targetHook -Algorithm SHA256).Hash
}

$observerOutput = Join-Path $temporaryRoot 'observed-input.json'
$observerScript = Join-Path $temporaryRoot 'observe-pre-tool-use.ps1'
$escapedObserverOutput = $observerOutput.Replace("'", "''")
$observerSource = @"
`$raw = [Console]::In.ReadToEnd()
[IO.File]::WriteAllText('$escapedObserverOutput', `$raw, [Text.UTF8Encoding]::new(`$false))
"@
[IO.File]::WriteAllText($observerScript, $observerSource, [Text.UTF8Encoding]::new($false))

$previousCodexHome = $env:CODEX_HOME
$restored = $false
try {
    & (Join-Path $projectRoot 'install.ps1') -CodexHome $codexRoot -RtkPath $resolvedRtkPath -Confirm:$false

    $installed = [IO.File]::ReadAllText($targetConfig) | ConvertFrom-Json -AsHashtable
    $rtkRegistration = $null
    foreach ($entry in @($installed['hooks']['PreToolUse'])) {
        foreach ($registration in @($entry['hooks'])) {
            if (
                $registration -is [Collections.IDictionary] -and
                $registration.Contains('command') -and
                [string]$registration['command'] -match '(?i)rtk-codex-hook\.ps1'
            ) {
                $rtkRegistration = $registration
                break
            }
        }
        if ($null -ne $rtkRegistration) {
            break
        }
    }
    if ($null -eq $rtkRegistration) {
        throw 'Installed RTK Hook registration was not found.'
    }

    $escapedObserverScript = $observerScript.Replace("'", "''")
    $isolatedHooks = [ordered]@{
        hooks = [ordered]@{
            PreToolUse = @(
                [ordered]@{
                    matcher = '^Bash$'
                    hooks = @(
                        $rtkRegistration,
                        [ordered]@{
                            type = 'command'
                            command = "& '$escapedObserverScript'"
                            timeout = 5
                            statusMessage = 'Capturing release-test input'
                        }
                    )
                }
            )
        }
    }
    [IO.File]::WriteAllText(
        $targetConfig,
        ($isolatedHooks | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )

    $env:CODEX_HOME = $codexRoot
    $stdoutPath = Join-Path $evidenceRoot 'codex-events.jsonl'
    $stderrPath = Join-Path $evidenceRoot 'codex-stderr.log'
    $prompt = 'Release integration test. Use the shell tool exactly once. Its command field must be exactly: git status --short. Do not add rtk yourself and do not run any other tool. After the tool completes, reply exactly E2E_DONE.'
    $stdout = @(& $codex.Source exec --ephemeral --json --dangerously-bypass-hook-trust --ask-for-approval never --sandbox workspace-write --cd $workingRoot $prompt 2>$stderrPath)
    $codexExitCode = $LASTEXITCODE
    [IO.File]::WriteAllLines($stdoutPath, [string[]]$stdout, [Text.UTF8Encoding]::new($false))
    if ($codexExitCode -ne 0) {
        throw "codex exec failed with exit code $codexExitCode. See $stderrPath"
    }

    if (-not [IO.File]::Exists($observerOutput)) {
        throw 'The observer Hook did not capture a PreToolUse payload.'
    }
    $observed = [IO.File]::ReadAllText($observerOutput) | ConvertFrom-Json
    if ($observed.tool_name -ne 'Bash' -or $observed.tool_input.command -ne 'git status --short') {
        throw "Unexpected raw tool input: $($observed.tool_input.command)"
    }

    $eventStrings = [Collections.Generic.List[string]]::new()
    foreach ($line in $stdout) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $eventObject = $line | ConvertFrom-Json
        foreach ($value in @(Get-JsonStringValue $eventObject)) {
            $eventStrings.Add($value)
        }
    }
    $combinedEvents = $eventStrings -join "`n"
    $escapedRtkPath = $resolvedRtkPath.Replace("'", "''")
    $expectedCommand = "& '$escapedRtkPath' git status --short"
    if (-not $combinedEvents.Contains($expectedCommand)) {
        throw "Codex events do not contain the rewritten command: $expectedCommand"
    }
    if (-not $combinedEvents.Contains('E2E_DONE')) {
        throw 'Codex did not complete the expected release-test turn.'
    }

    [IO.File]::Copy($observerOutput, (Join-Path $evidenceRoot 'observed-input.json'), $true)
    $versions = [ordered]@{
        Date = (Get-Date).ToString('o')
        Windows = [Environment]::OSVersion.VersionString
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Codex = (& $codex.Source --version) -join ' '
        Rtk = (& $resolvedRtkPath --version) -join ' '
        RawCommand = 'git status --short'
        RewrittenCommand = $expectedCommand
        Sandbox = 'workspace-write'
        ApprovalPolicy = 'never'
    }
    [IO.File]::WriteAllText(
        (Join-Path $evidenceRoot 'environment.json'),
        ($versions | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
}
finally {
    $env:CODEX_HOME = $previousCodexHome

    if ($configExisted) {
        [IO.File]::Copy((Join-Path $temporaryRoot 'hooks.json.original'), $targetConfig, $true)
    }
    elseif ([IO.File]::Exists($targetConfig)) {
        [IO.File]::Delete($targetConfig)
    }
    if ($hookExisted) {
        [IO.File]::Copy((Join-Path $temporaryRoot 'rtk-codex-hook.ps1.original'), $targetHook, $true)
    }
    elseif ([IO.File]::Exists($targetHook)) {
        [IO.File]::Delete($targetHook)
    }

    $configRestored = (-not $configExisted -and -not [IO.File]::Exists($targetConfig)) -or
        ($configExisted -and (Get-FileHash -LiteralPath $targetConfig -Algorithm SHA256).Hash -eq $configHash)
    $hookRestored = (-not $hookExisted -and -not [IO.File]::Exists($targetHook)) -or
        ($hookExisted -and (Get-FileHash -LiteralPath $targetHook -Algorithm SHA256).Hash -eq $hookHash)
    $restored = $configRestored -and $hookRestored

    if (
        [IO.Directory]::Exists($temporaryRoot) -and
        $temporaryRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($temporaryRoot).StartsWith('rtk-codex-real-e2e-', [StringComparison]::Ordinal)
    ) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}

if (-not $restored) {
    throw 'Real Codex e2e completed, but the original Hook files were not restored exactly.'
}

Write-Host 'Real Codex e2e passed and original Hook files were restored.'
Write-Host "  Evidence: $evidenceRoot"
