[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$CodexHome = $(
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $env:CODEX_HOME
        }
        else {
            Join-Path $HOME '.codex'
        }
    ),

    [string]$RtkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Assert-ContainedPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $rootPrefix = $Root + [IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside Codex home: $Path"
    }
}

function Resolve-ValidatedRtkPath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not [IO.Path]::IsPathFullyQualified($RequestedPath)) {
            throw 'RtkPath must be an absolute path.'
        }
        $resolved = [IO.Path]::GetFullPath($RequestedPath)
    }
    else {
        $command = Get-Command rtk.exe, rtk -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            throw 'RTK was not found on PATH. Install RTK or pass -RtkPath with an absolute path.'
        }
        $resolved = [IO.Path]::GetFullPath($command.Source)
    }

    if (-not [IO.File]::Exists($resolved)) {
        throw "RTK executable does not exist: $resolved"
    }

    try {
        & $resolved --version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "--version exited with $LASTEXITCODE"
        }
        & $resolved rewrite --help 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "rewrite --help exited with $LASTEXITCODE"
        }
    }
    catch {
        throw "RTK compatibility check failed for '$resolved': $($_.Exception.Message)"
    }

    return $resolved
}

function Get-PotentialBashHookConflicts {
    param([Parameter(Mandatory)][Collections.IDictionary]$Config)

    if (
        -not $Config.Contains('hooks') -or
        $Config['hooks'] -isnot [Collections.IDictionary] -or
        -not $Config['hooks'].Contains('PreToolUse')
    ) {
        return @()
    }

    $conflicts = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($Config['hooks']['PreToolUse'])) {
        if ($entry -isnot [Collections.IDictionary]) {
            continue
        }

        $matchesBash = $true
        if ($entry.Contains('matcher') -and -not [string]::IsNullOrWhiteSpace([string]$entry['matcher'])) {
            try {
                $matchesBash = [regex]::IsMatch('Bash', [string]$entry['matcher'])
            }
            catch {
                $matchesBash = $true
            }
        }
        if (-not $matchesBash -or -not $entry.Contains('hooks')) {
            continue
        }

        foreach ($hook in @($entry['hooks'])) {
            if (
                $hook -is [Collections.IDictionary] -and
                $hook.Contains('type') -and
                [string]$hook['type'] -eq 'command' -and
                $hook.Contains('command') -and
                -not (Test-IsRtkHookRegistration $hook)
            ) {
                $conflicts.Add([string]$hook['command'])
            }
        }
    }
    return $conflicts.ToArray()
}

function Test-IsRtkHookRegistration {
    param([object]$Registration)

    if ($Registration -isnot [Collections.IDictionary]) {
        return $false
    }
    if (-not $Registration.Contains('type') -or -not $Registration.Contains('command')) {
        return $false
    }
    return (
        [string]$Registration['type'] -eq 'command' -and
        [string]$Registration['command'] -match '(?i)rtk-codex-hook\.ps1'
    )
}

function Merge-RtkHookRegistration {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][Collections.IDictionary]$Registration
    )

    if (-not $Config.Contains('hooks')) {
        $Config['hooks'] = [ordered]@{}
    }
    $hooksSection = $Config['hooks']
    if ($hooksSection -isnot [Collections.IDictionary]) {
        throw 'hooks.json property "hooks" must be an object.'
    }
    if (-not $hooksSection.Contains('PreToolUse')) {
        $hooksSection['PreToolUse'] = @()
    }

    $entries = [Collections.Generic.List[object]]::new()
    $bashEntry = $null
    foreach ($entry in @($hooksSection['PreToolUse'])) {
        if ($entry -isnot [Collections.IDictionary]) {
            throw 'hooks.PreToolUse entries must be objects.'
        }

        if (
            $null -eq $bashEntry -and
            $entry.Contains('matcher') -and
            [string]$entry['matcher'] -eq '^Bash$'
        ) {
            $bashEntry = $entry
        }

        $retainedHooks = [Collections.Generic.List[object]]::new()
        if ($entry.Contains('hooks')) {
            foreach ($hook in @($entry['hooks'])) {
                if (-not (Test-IsRtkHookRegistration $hook)) {
                    $retainedHooks.Add($hook)
                }
            }
        }
        $entry['hooks'] = $retainedHooks.ToArray()
        $entries.Add($entry)
    }

    if ($null -eq $bashEntry) {
        $bashEntry = [ordered]@{
            matcher = '^Bash$'
            hooks = @()
        }
        $entries.Add($bashEntry)
    }

    $bashHooks = [Collections.Generic.List[object]]::new()
    foreach ($hook in @($bashEntry['hooks'])) {
        $bashHooks.Add($hook)
    }
    $bashHooks.Add($Registration)
    $bashEntry['hooks'] = $bashHooks.ToArray()
    $hooksSection['PreToolUse'] = $entries.ToArray()
    return $Config
}

$sourceHook = Join-Path $PSScriptRoot 'rtk-codex-hook.ps1'
$sourceHooksJson = Join-Path $PSScriptRoot 'hooks.json'
foreach ($source in @($sourceHook, $sourceHooksJson)) {
    if (-not [IO.File]::Exists($source)) {
        throw "Required installer source is missing: $source"
    }
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $sourceHook,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -ne 0) {
    throw "Source Hook does not parse: $($parseErrors[0].Message)"
}

$sourceConfig = [IO.File]::ReadAllText($sourceHooksJson) | ConvertFrom-Json -AsHashtable
if (
    -not $sourceConfig.Contains('hooks') -or
    -not $sourceConfig['hooks'].Contains('PreToolUse')
) {
    throw 'Source hooks.json does not contain hooks.PreToolUse.'
}

$sourceRegistration = $null
foreach ($entry in @($sourceConfig['hooks']['PreToolUse'])) {
    foreach ($registration in @($entry['hooks'])) {
        if (Test-IsRtkHookRegistration $registration) {
            $sourceRegistration = $registration
            break
        }
    }
    if ($null -ne $sourceRegistration) {
        break
    }
}
if ($null -eq $sourceRegistration) {
    throw 'Source hooks.json does not contain an RTK command registration.'
}

$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceHook).Hash
$resolvedRtkPath = Resolve-ValidatedRtkPath $RtkPath

$targetRoot = Get-NormalizedFullPath $CodexHome
$volumeRoot = [IO.Path]::GetPathRoot($targetRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($targetRoot -eq $volumeRoot) {
    throw "Refusing to use a volume root as Codex home: $targetRoot"
}

$targetHooksDir = Get-NormalizedFullPath (Join-Path $targetRoot 'hooks')
$targetHook = [IO.Path]::GetFullPath((Join-Path $targetHooksDir 'rtk-codex-hook.ps1'))
$targetHooksJson = [IO.Path]::GetFullPath((Join-Path $targetRoot 'hooks.json'))
Assert-ContainedPath $targetRoot $targetHooksDir
Assert-ContainedPath $targetRoot $targetHook
Assert-ContainedPath $targetRoot $targetHooksJson

if ([IO.File]::Exists($targetHooksJson)) {
    $targetConfig = [IO.File]::ReadAllText($targetHooksJson) | ConvertFrom-Json -AsHashtable
}
else {
    $targetConfig = [ordered]@{
        hooks = [ordered]@{
            PreToolUse = @()
        }
    }
}

$potentialConflicts = @(Get-PotentialBashHookConflicts $targetConfig)
foreach ($conflict in $potentialConflicts) {
    Write-Warning "Another PreToolUse command Hook may match Bash and compete for updatedInput: $conflict"
}

$escapedTargetHook = $targetHook.Replace("'", "''")
$escapedRtkPath = $resolvedRtkPath.Replace("'", "''")
$registration = [ordered]@{
    type = 'command'
    command = "& '$escapedTargetHook' -RtkPath '$escapedRtkPath'"
    timeout = $sourceRegistration['timeout']
    statusMessage = $sourceRegistration['statusMessage']
}
$mergedConfig = Merge-RtkHookRegistration $targetConfig $registration
$mergedJson = $mergedConfig | ConvertTo-Json -Depth 32
$mergedJson | ConvertFrom-Json | Out-Null

if (-not $PSCmdlet.ShouldProcess($targetRoot, 'Install RTK Codex Hook and merge hooks.json')) {
    Write-Host "Would install Hook: $targetHook"
    Write-Host "Would merge config: $targetHooksJson"
    Write-Host "Would bind RTK: $resolvedRtkPath"
    return
}

[IO.Directory]::CreateDirectory($targetRoot) | Out-Null
[IO.Directory]::CreateDirectory($targetHooksDir) | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backupDir = Get-NormalizedFullPath (Join-Path $targetRoot "backups\rtk-codex-hook\$timestamp")
Assert-ContainedPath $targetRoot $backupDir
$hookExisted = [IO.File]::Exists($targetHook)
$configExisted = [IO.File]::Exists($targetHooksJson)
if ($hookExisted -or $configExisted) {
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    if ($hookExisted) {
        [IO.File]::Copy($targetHook, (Join-Path $backupDir 'rtk-codex-hook.ps1'), $false)
    }
    if ($configExisted) {
        [IO.File]::Copy($targetHooksJson, (Join-Path $backupDir 'hooks.json'), $false)
    }
}

$nonce = [Guid]::NewGuid().ToString('N')
$temporaryHook = Join-Path $targetHooksDir ".rtk-codex-hook.$nonce.tmp"
$temporaryConfig = Join-Path $targetRoot ".hooks.$nonce.tmp"
Assert-ContainedPath $targetRoot ([IO.Path]::GetFullPath($temporaryHook))
Assert-ContainedPath $targetRoot ([IO.Path]::GetFullPath($temporaryConfig))

$hookInstalled = $false
$configInstalled = $false
try {
    [IO.File]::WriteAllBytes($temporaryHook, [IO.File]::ReadAllBytes($sourceHook))
    [IO.File]::WriteAllText($temporaryConfig, $mergedJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $temporaryHook).Hash -ne $sourceHash) {
        throw 'Staged Hook hash does not match the packaged Hook.'
    }

    [IO.File]::ReadAllText($temporaryConfig) | ConvertFrom-Json | Out-Null
    $temporaryTokens = $null
    $temporaryErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $temporaryHook,
        [ref]$temporaryTokens,
        [ref]$temporaryErrors
    ) | Out-Null
    if ($temporaryErrors.Count -ne 0) {
        throw "Staged Hook does not parse: $($temporaryErrors[0].Message)"
    }

    [IO.File]::Move($temporaryHook, $targetHook, $true)
    $hookInstalled = $true
    [IO.File]::Move($temporaryConfig, $targetHooksJson, $true)
    $configInstalled = $true
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $targetHook).Hash -ne $sourceHash) {
        throw 'Installed Hook hash does not match the packaged Hook.'
    }
}
catch {
    if ($hookInstalled) {
        if ($hookExisted) {
            [IO.File]::Copy((Join-Path $backupDir 'rtk-codex-hook.ps1'), $targetHook, $true)
        }
        elseif ([IO.File]::Exists($targetHook)) {
            [IO.File]::Delete($targetHook)
        }
    }
    if ($configInstalled) {
        if ($configExisted) {
            [IO.File]::Copy((Join-Path $backupDir 'hooks.json'), $targetHooksJson, $true)
        }
        elseif ([IO.File]::Exists($targetHooksJson)) {
            [IO.File]::Delete($targetHooksJson)
        }
    }
    throw
}
finally {
    if ([IO.File]::Exists($temporaryHook)) {
        [IO.File]::Delete($temporaryHook)
    }
    if ([IO.File]::Exists($temporaryConfig)) {
        [IO.File]::Delete($temporaryConfig)
    }
}

$targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetHook).Hash

Write-Host 'RTK Codex Hook installed.'
Write-Host "  Hook:    $targetHook"
Write-Host "  Config:  $targetHooksJson"
Write-Host "  RTK:     $resolvedRtkPath"
Write-Host "  SHA-256: $targetHash"
if ($hookExisted -or $configExisted) {
    Write-Host "  Backup:  $backupDir"
}
