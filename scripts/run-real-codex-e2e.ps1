[CmdletBinding()]
param(
    [string]$RtkPath,

    [string]$WorkingDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CodexLoopbackCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$CodexArguments,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$ObserverOutput,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$ExpectedCommand,
        [Parameter(Mandatory)][string]$ExpectedStatus,
        [Parameter(Mandatory)][int]$ExpectedExitCode
    )

    if ([IO.File]::Exists($ObserverOutput)) {
        [IO.File]::Delete($ObserverOutput)
    }

    $stdoutPath = Join-Path $EvidenceRoot "$Name-codex-events.jsonl"
    $stderrPath = Join-Path $EvidenceRoot "$Name-codex-stderr.log"
    $arguments = @($CodexArguments) + @($Prompt)
    $stdout = @(& $CodexPath @arguments 2>$stderrPath)
    $codexExitCode = $LASTEXITCODE
    [IO.File]::WriteAllLines($stdoutPath, [string[]]$stdout, [Text.UTF8Encoding]::new($false))
    if ($codexExitCode -ne 0) {
        throw "$Name codex exec failed with exit code $codexExitCode. See $stderrPath"
    }

    if (-not [IO.File]::Exists($ObserverOutput)) {
        throw "$Name observer Hook did not capture a PreToolUse payload."
    }
    $observed = [IO.File]::ReadAllText($ObserverOutput) | ConvertFrom-Json
    if ($observed.tool_name -ne 'Bash' -or $observed.tool_input.command -ne 'git status --short') {
        throw "$Name received unexpected raw tool input: $($observed.tool_input.command)"
    }
    [IO.File]::Copy($ObserverOutput, (Join-Path $EvidenceRoot "$Name-observed-input.json"), $true)

    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in $stdout) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $events.Add(($line | ConvertFrom-Json))
        }
    }
    $commandEvents = @($events | Where-Object {
        $_.type -eq 'item.completed' -and $_.item.type -eq 'command_execution'
    })
    if ($commandEvents.Count -ne 1) {
        throw "$Name expected one completed command event, got $($commandEvents.Count)."
    }
    $commandEvent = $commandEvents[0].item
    if (-not [string]$commandEvent.command.Contains($ExpectedCommand)) {
        throw "$Name Codex event does not contain the rewritten command: $ExpectedCommand"
    }
    if ($commandEvent.status -ne $ExpectedStatus -or [int]$commandEvent.exit_code -ne $ExpectedExitCode) {
        throw "$Name command completed as status=$($commandEvent.status), exit=$($commandEvent.exit_code)."
    }
    $agentMessages = @($events | Where-Object {
        $_.type -eq 'item.completed' -and $_.item.type -eq 'agent_message'
    })
    if ($agentMessages.Count -ne 1 -or $agentMessages[0].item.text -ne 'E2E_DONE') {
        throw "$Name did not complete the expected loopback turn."
    }

    return [pscustomobject]@{
        Command = [string]$commandEvent.command
        Status = [string]$commandEvent.status
        ExitCode = [int]$commandEvent.exit_code
        AggregatedOutput = [string]$commandEvent.aggregated_output
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $WorkingDirectory = $projectRoot
}
$workingRoot = [IO.Path]::GetFullPath($WorkingDirectory)
if (-not [IO.Directory]::Exists($workingRoot)) {
    throw "Working directory does not exist: $workingRoot"
}

$codex = Get-Command codex -ErrorAction Stop | Select-Object -First 1
$node = Get-Command node.exe, node -ErrorAction Stop | Select-Object -First 1
$strictRtkBinding = -not [string]::IsNullOrWhiteSpace($RtkPath)
if ([string]::IsNullOrWhiteSpace($RtkPath)) {
    $rtk = Get-Command rtk.exe, rtk -ErrorAction Stop | Select-Object -First 1
    $RtkPath = $rtk.Source
}
$resolvedRtkPath = [IO.Path]::GetFullPath($RtkPath)

$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$temporaryParent = [IO.Path]::GetFullPath((Join-Path $projectRoot '.tmp'))
$temporaryRoot = Join-Path $temporaryParent "rtk-codex-loopback-e2e-$runId-$([Guid]::NewGuid().ToString('N'))"
$evidenceRoot = Join-Path $projectRoot "artifacts\e2e\$runId"
[IO.Directory]::CreateDirectory($temporaryParent) | Out-Null
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null

$readyPath = Join-Path $temporaryRoot 'server-ready.json'
$requestLog = Join-Path $evidenceRoot 'responses-requests.jsonl'
$serverStdout = Join-Path $evidenceRoot 'mock-server-stdout.log'
$serverStderr = Join-Path $evidenceRoot 'mock-server-stderr.log'
$serverScript = Join-Path $projectRoot 'tests\fixtures\mock-responses-server.mjs'
$serverProcess = $null
$previousCodexHome = $env:CODEX_HOME

try {
    $serverProcess = Start-Process -FilePath $node.Source -ArgumentList @(
        $serverScript,
        $readyPath,
        $requestLog
    ) -WindowStyle Hidden -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr -PassThru

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not [IO.File]::Exists($readyPath)) {
        if ($serverProcess.HasExited) {
            throw "Loopback mock server exited with code $($serverProcess.ExitCode). See $serverStderr"
        }
        if ([DateTime]::UtcNow -ge $readyDeadline) {
            throw 'Timed out waiting for the loopback mock server.'
        }
        Start-Sleep -Milliseconds 50
    }
    $serverInfo = [IO.File]::ReadAllText($readyPath) | ConvertFrom-Json
    if ($serverInfo.host -ne '127.0.0.1' -or $serverInfo.baseUrl -notmatch '^http://127\.0\.0\.1:\d+/v1$') {
        throw "Mock server did not bind exclusively to loopback: $($serverInfo.baseUrl)"
    }

    $configSource = @"
model = "gpt-5.2-codex"
model_provider = "loopback"

[model_providers.loopback]
name = "Loopback release-test provider"
base_url = "$($serverInfo.baseUrl)"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 10000

[features]
enable_request_compression = false
plugins = false
remote_plugin = false
apps = false
memories = false
"@
    [IO.File]::WriteAllText(
        (Join-Path $temporaryRoot 'config.toml'),
        $configSource,
        [Text.UTF8Encoding]::new($false)
    )

    $installParameters = @{
        CodexHome = $temporaryRoot
        Confirm = $false
    }
    if ($strictRtkBinding) {
        $installParameters['RtkPath'] = $resolvedRtkPath
    }
    & (Join-Path $projectRoot 'install.ps1') @installParameters

    $observerOutput = Join-Path $temporaryRoot 'observed-input.json'
    $observerScript = Join-Path $temporaryRoot 'observe-pre-tool-use.ps1'
    $escapedObserverOutput = $observerOutput.Replace("'", "''")
    $observerSource = @"
`$raw = [Console]::In.ReadToEnd()
[IO.File]::WriteAllText('$escapedObserverOutput', `$raw, [Text.UTF8Encoding]::new(`$false))
"@
    [IO.File]::WriteAllText($observerScript, $observerSource, [Text.UTF8Encoding]::new($false))

    $hooksPath = Join-Path $temporaryRoot 'hooks.json'
    $hooksConfig = [IO.File]::ReadAllText($hooksPath) | ConvertFrom-Json -AsHashtable
    $bashEntry = @($hooksConfig['hooks']['PreToolUse'] | Where-Object {
        $_ -is [Collections.IDictionary] -and $_.Contains('matcher') -and [string]$_['matcher'] -eq '^Bash$'
    }) | Select-Object -First 1
    if ($null -eq $bashEntry) {
        throw 'Installed Bash Hook entry was not found.'
    }
    $observerRegistration = [ordered]@{
        type = 'command'
        command = "& '$($observerScript.Replace("'", "''"))'"
        timeout = 5
        statusMessage = 'Capturing loopback release-test input'
    }
    $bashEntry['hooks'] = @($bashEntry['hooks']) + @($observerRegistration)
    [IO.File]::WriteAllText(
        $hooksPath,
        ($hooksConfig | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )

    $env:CODEX_HOME = $temporaryRoot
    $prompt = 'Local release integration test. Follow the deterministic tool call returned by the loopback provider.'
    $expectedCommand = if ($strictRtkBinding) {
        $escapedRtkPath = $resolvedRtkPath.Replace("'", "''")
        "& '$escapedRtkPath' git status --short"
    }
    else {
        'rtk git status --short'
    }
    $policyResult = Invoke-CodexLoopbackCase `
        -Name 'policy' `
        -CodexPath $codex.Source `
        -CodexArguments @(
            '--ask-for-approval', 'never', 'exec', '--ephemeral', '--json',
            '--dangerously-bypass-hook-trust', '--sandbox', 'workspace-write',
            '--cd', $workingRoot
        ) `
        -Prompt $prompt `
        -ObserverOutput $observerOutput `
        -EvidenceRoot $evidenceRoot `
        -ExpectedCommand $expectedCommand `
        -ExpectedStatus 'declined' `
        -ExpectedExitCode -1
    if (-not $policyResult.AggregatedOutput.Contains('blocked by policy')) {
        throw 'Policy phase did not prove that Codex evaluated the rewritten command.'
    }

    $executionResult = Invoke-CodexLoopbackCase `
        -Name 'execution' `
        -CodexPath $codex.Source `
        -CodexArguments @(
            'exec', '--ephemeral', '--json', '--dangerously-bypass-hook-trust',
            '--dangerously-bypass-approvals-and-sandbox', '--cd', $workingRoot
        ) `
        -Prompt $prompt `
        -ObserverOutput $observerOutput `
        -EvidenceRoot $evidenceRoot `
        -ExpectedCommand $expectedCommand `
        -ExpectedStatus 'completed' `
        -ExpectedExitCode 0

    $requestRecords = @([IO.File]::ReadAllLines($requestLog) | ForEach-Object { $_ | ConvertFrom-Json })
    $responsesRequests = @($requestRecords | Where-Object { $_.method -eq 'POST' -and $_.url -eq '/v1/responses' })
    if ($responsesRequests.Count -ne 4) {
        throw "Expected exactly four Responses requests, got $($responsesRequests.Count)."
    }
    foreach ($phase in @(
        [pscustomobject]@{ RequestIndex = 1; CallId = 'call-loopback-1'; Name = 'policy' },
        [pscustomobject]@{ RequestIndex = 3; CallId = 'call-loopback-2'; Name = 'execution' }
    )) {
        $functionOutput = @($responsesRequests[$phase.RequestIndex].body.input | Where-Object {
            $_.type -eq 'function_call_output' -and $_.call_id -eq $phase.CallId
        })
        $outputJson = if ($functionOutput.Count -eq 1) {
            $functionOutput[0].output | ConvertTo-Json -Depth 20 -Compress
        }
        else {
            $null
        }
        if ($functionOutput.Count -ne 1 -or [string]::IsNullOrWhiteSpace($outputJson) -or $outputJson -eq 'null') {
            throw "$($phase.Name) Responses request did not contain shell tool output."
        }
    }

    $versions = [ordered]@{
        Date = (Get-Date).ToString('o')
        Windows = [Environment]::OSVersion.VersionString
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Codex = (& $codex.Source --version) -join ' '
        Rtk = (& $resolvedRtkPath --version) -join ' '
        RtkInvocation = if ($strictRtkBinding) { 'Absolute' } else { 'Bare' }
        Provider = $serverInfo.baseUrl
        ProviderScope = 'loopback-only'
        RawCommand = 'git status --short'
        RewrittenCommand = $expectedCommand
        PolicyGate = [ordered]@{
            Sandbox = 'workspace-write'
            ApprovalPolicy = 'never'
            Status = $policyResult.Status
            BlockedAfterRewrite = $true
        }
        ExecutionGate = [ordered]@{
            FixedCommandOnly = $true
            Status = $executionResult.Status
            ExitCode = $executionResult.ExitCode
            FunctionOutputObserved = $true
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $evidenceRoot 'environment.json'),
        ($versions | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
}
finally {
    $env:CODEX_HOME = $previousCodexHome
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill($true)
        $serverProcess.WaitForExit(5000) | Out-Null
    }
    if (
        [IO.Directory]::Exists($temporaryRoot) -and
        [string]::Equals(
            [IO.Directory]::GetParent($temporaryRoot).FullName,
            $temporaryParent,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [IO.Path]::GetFileName($temporaryRoot).StartsWith('rtk-codex-loopback-e2e-', [StringComparison]::Ordinal)
    ) {
        [IO.Directory]::Delete($temporaryRoot, $true)
    }
}

Write-Host 'Real Codex loopback e2e passed.'
Write-Host "  Evidence: $evidenceRoot"
