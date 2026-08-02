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

function Test-RtkCompatibility {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) {
        return $false
    }

    try {
        & $Path --version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        & $Path rewrite --help 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Add-RtkCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Candidates,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$Seen,
        [string]$Path,
        [Parameter(Mandatory)][string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        $resolved = [IO.Path]::GetFullPath($Path.Trim())
    }
    catch {
        return
    }
    if ($Seen.Add($resolved)) {
        $Candidates.Add([pscustomobject]@{
            Path = $resolved
            Source = $Source
        })
    }
}

function New-RtkResolution {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Source,
        [ValidateSet('Bare', 'Absolute')]
        [string]$Invocation
    )

    [pscustomobject]@{
        Path = $Path
        Source = $Source
        Invocation = $Invocation
    }
}

function Resolve-ValidatedRtk {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not [IO.Path]::IsPathFullyQualified($RequestedPath)) {
            throw 'RtkPath must be an absolute path.'
        }
        $resolved = [IO.Path]::GetFullPath($RequestedPath)
        if (-not [IO.File]::Exists($resolved)) {
            throw "RTK executable does not exist: $resolved"
        }
        if (-not (Test-RtkCompatibility $resolved)) {
            throw "RTK compatibility check failed for explicit path: $resolved"
        }
        return New-RtkResolution $resolved 'Explicit' 'Absolute'
    }

    $pathCandidates = [Collections.Generic.List[object]]::new()
    $pathSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pathCommands = @(Get-Command rtk -All -CommandType Application -ErrorAction SilentlyContinue)
    if ($pathCommands.Count -eq 0) {
        $pathCommands = @(Get-Command rtk.exe -All -CommandType Application -ErrorAction SilentlyContinue)
    }
    foreach ($command in $pathCommands) {
        Add-RtkCandidate $pathCandidates $pathSeen $command.Source 'PATH'
    }

    if ($pathCandidates.Count -gt 0) {
        $effective = $pathCandidates[0]
        if (Test-RtkCompatibility $effective.Path) {
            return New-RtkResolution $effective.Path 'PATH' 'Bare'
        }

        for ($index = 1; $index -lt $pathCandidates.Count; $index++) {
            $candidate = $pathCandidates[$index]
            if (Test-RtkCompatibility $candidate.Path) {
                Write-Warning "The effective PATH command is not compatible RTK: $($effective.Path). Using a later validated candidate by absolute path: $($candidate.Path)"
                return New-RtkResolution $candidate.Path 'PATH collision' 'Absolute'
            }
        }
    }

    $cargoCandidates = [Collections.Generic.List[object]]::new()
    $cargoSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $cargoRoots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:CARGO_HOME)) {
        $cargoRoots.Add($env:CARGO_HOME)
    }
    $userHome = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $env:USERPROFILE
    }
    else {
        $HOME
    }
    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
        $cargoRoots.Add((Join-Path $userHome '.cargo'))
    }
    foreach ($cargoRoot in $cargoRoots) {
        Add-RtkCandidate $cargoCandidates $cargoSeen (Join-Path $cargoRoot 'bin\rtk.exe') 'Cargo'
    }
    foreach ($candidate in $cargoCandidates) {
        if (Test-RtkCompatibility $candidate.Path) {
            if ($pathCandidates.Count -gt 0) {
                Write-Warning "The effective PATH command is not compatible RTK: $($pathCandidates[0].Path). Using a validated Cargo candidate by absolute path: $($candidate.Path)"
            }
            return New-RtkResolution $candidate.Path 'Cargo' 'Absolute'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
        $localBinCandidate = Join-Path $userHome '.local\bin\rtk.exe'
        if (Test-RtkCompatibility $localBinCandidate) {
            if ($pathCandidates.Count -gt 0) {
                Write-Warning "The effective PATH command is not compatible RTK: $($pathCandidates[0].Path). Using a validated local-bin candidate by absolute path: $localBinCandidate"
            }
            return New-RtkResolution ([IO.Path]::GetFullPath($localBinCandidate)) 'Local bin' 'Absolute'
        }
    }

    $scoopCandidates = [Collections.Generic.List[object]]::new()
    $scoopSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $scoopRoots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:SCOOP)) {
        $scoopRoots.Add($env:SCOOP)
    }
    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
        $scoopRoots.Add((Join-Path $userHome 'scoop'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $scoopRoots.Add((Join-Path $env:ProgramData 'scoop'))
    }
    foreach ($scoopRoot in $scoopRoots) {
        Add-RtkCandidate $scoopCandidates $scoopSeen (Join-Path $scoopRoot 'shims\rtk.exe') 'Scoop'
        Add-RtkCandidate $scoopCandidates $scoopSeen (Join-Path $scoopRoot 'apps\rtk\current\rtk.exe') 'Scoop'
    }
    foreach ($candidate in $scoopCandidates) {
        if (Test-RtkCompatibility $candidate.Path) {
            if ($pathCandidates.Count -gt 0) {
                Write-Warning "The effective PATH command is not compatible RTK: $($pathCandidates[0].Path). Using a validated Scoop candidate by absolute path: $($candidate.Path)"
            }
            return New-RtkResolution $candidate.Path 'Scoop' 'Absolute'
        }
    }

    $scoop = Get-Command scoop -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $scoop) {
        try {
            foreach ($prefix in @(& $scoop.Source prefix rtk 2>$null)) {
                $prefixCandidates = [Collections.Generic.List[object]]::new()
                $prefixSeen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                Add-RtkCandidate $prefixCandidates $prefixSeen (Join-Path ([string]$prefix) 'rtk.exe') 'Scoop'
                foreach ($candidate in $prefixCandidates) {
                    if (Test-RtkCompatibility $candidate.Path) {
                        if ($pathCandidates.Count -gt 0) {
                            Write-Warning "The effective PATH command is not compatible RTK: $($pathCandidates[0].Path). Using a validated Scoop candidate by absolute path: $($candidate.Path)"
                        }
                        return New-RtkResolution $candidate.Path 'Scoop' 'Absolute'
                    }
                }
            }
        }
        catch {
            Write-Verbose "Scoop prefix lookup failed: $($_.Exception.Message)"
        }
    }

    throw 'Compatible RTK was not found on PATH or in bounded Cargo/local-bin/Scoop locations. Install RTK, add it to PATH, or pass -RtkPath with an absolute path.'
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

function Get-RtkInstructionReferences {
    param([Parameter(Mandatory)][string]$AgentsPath)

    if (-not [IO.File]::Exists($AgentsPath)) {
        return @()
    }

    $references = [Collections.Generic.List[string]]::new()
    try {
        foreach ($line in [IO.File]::ReadAllLines($AgentsPath)) {
            $trimmed = $line.Trim()
            if (-not $trimmed.StartsWith('@', [StringComparison]::Ordinal)) {
                continue
            }
            $reference = $trimmed.Substring(1).Trim().Trim('"').Trim("'")
            if ($reference -match '(?i)(?:^|[\\/])RTK\.md$') {
                $references.Add($trimmed)
            }
        }
    }
    catch {
        Write-Verbose "Could not inspect Codex AGENTS.md for RTK instructions: $($_.Exception.Message)"
    }
    return $references.ToArray()
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
$rtkResolution = Resolve-ValidatedRtk $RtkPath
$resolvedRtkPath = $rtkResolution.Path

$targetRoot = Get-NormalizedFullPath $CodexHome
$volumeRoot = [IO.Path]::GetPathRoot($targetRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($targetRoot -eq $volumeRoot) {
    throw "Refusing to use a volume root as Codex home: $targetRoot"
}

$targetHooksDir = Get-NormalizedFullPath (Join-Path $targetRoot 'hooks')
$targetHook = [IO.Path]::GetFullPath((Join-Path $targetHooksDir 'rtk-codex-hook.ps1'))
$targetHooksJson = [IO.Path]::GetFullPath((Join-Path $targetRoot 'hooks.json'))
$targetAgents = [IO.Path]::GetFullPath((Join-Path $targetRoot 'AGENTS.md'))
Assert-ContainedPath $targetRoot $targetHooksDir
Assert-ContainedPath $targetRoot $targetHook
Assert-ContainedPath $targetRoot $targetHooksJson
Assert-ContainedPath $targetRoot $targetAgents

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
foreach ($reference in @(Get-RtkInstructionReferences $targetAgents)) {
    Write-Warning "Codex AGENTS.md references RTK.md and may make the model prefix commands before this transparent Hook can classify them. Remove the reference when using this Hook; the installer will not modify it: $reference"
}

$escapedTargetHook = $targetHook.Replace("'", "''")
$escapedRtkPath = $resolvedRtkPath.Replace("'", "''")
$registrationCommand = "& '$escapedTargetHook'"
if ($rtkResolution.Invocation -eq 'Absolute') {
    $registrationCommand += " -RtkPath '$escapedRtkPath'"
}
$registration = [ordered]@{
    type = 'command'
    command = $registrationCommand
    timeout = $sourceRegistration['timeout']
    statusMessage = $sourceRegistration['statusMessage']
}
$mergedConfig = Merge-RtkHookRegistration $targetConfig $registration
$mergedJson = $mergedConfig | ConvertTo-Json -Depth 32
$mergedJson | ConvertFrom-Json | Out-Null

if (-not $PSCmdlet.ShouldProcess($targetRoot, 'Install RTK Codex Hook and merge hooks.json')) {
    Write-Host "Would install Hook: $targetHook"
    Write-Host "Would merge config: $targetHooksJson"
    Write-Host "Would use RTK: $resolvedRtkPath"
    Write-Host "Would discover RTK via: $($rtkResolution.Source)"
    Write-Host "Would emit RTK command as: $(if ($rtkResolution.Invocation -eq 'Bare') { 'rtk' } else { "& '$escapedRtkPath'" })"
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
Write-Host "  Source:  $($rtkResolution.Source)"
Write-Host "  Command: $(if ($rtkResolution.Invocation -eq 'Bare') { 'rtk' } else { "& '$escapedRtkPath'" })"
Write-Host "  SHA-256: $targetHash"
if ($hookExisted -or $configExisted) {
    Write-Host "  Backup:  $backupDir"
}
