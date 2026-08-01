[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$CodexHome = $(
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $env:CODEX_HOME
        }
        else {
            Join-Path $HOME '.codex'
        }
    )
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
        throw "Refusing to modify a path outside Codex home: $Path"
    }
}

function Test-IsRtkHookRegistration {
    param([object]$Registration)

    return (
        $Registration -is [Collections.IDictionary] -and
        $Registration.Contains('type') -and
        $Registration.Contains('command') -and
        [string]$Registration['type'] -eq 'command' -and
        [string]$Registration['command'] -match '(?i)rtk-codex-hook\.ps1'
    )
}

function Remove-RtkHookRegistrations {
    param([Parameter(Mandatory)][Collections.IDictionary]$Config)

    if (
        -not $Config.Contains('hooks') -or
        $Config['hooks'] -isnot [Collections.IDictionary] -or
        -not $Config['hooks'].Contains('PreToolUse')
    ) {
        return 0
    }

    $removed = 0
    foreach ($entry in @($Config['hooks']['PreToolUse'])) {
        if ($entry -isnot [Collections.IDictionary] -or -not $entry.Contains('hooks')) {
            continue
        }

        $retained = [Collections.Generic.List[object]]::new()
        foreach ($hook in @($entry['hooks'])) {
            if (Test-IsRtkHookRegistration $hook) {
                $removed++
            }
            else {
                $retained.Add($hook)
            }
        }
        $entry['hooks'] = $retained.ToArray()
    }
    return $removed
}

$targetRoot = Get-NormalizedFullPath $CodexHome
$volumeRoot = [IO.Path]::GetPathRoot($targetRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($targetRoot -eq $volumeRoot) {
    throw "Refusing to use a volume root as Codex home: $targetRoot"
}

$targetHook = [IO.Path]::GetFullPath((Join-Path $targetRoot 'hooks\rtk-codex-hook.ps1'))
$targetHooksJson = [IO.Path]::GetFullPath((Join-Path $targetRoot 'hooks.json'))
Assert-ContainedPath $targetRoot $targetHook
Assert-ContainedPath $targetRoot $targetHooksJson

$hookExisted = [IO.File]::Exists($targetHook)
$configExisted = [IO.File]::Exists($targetHooksJson)
$removedRegistrations = 0
$updatedJson = $null
if ($configExisted) {
    $config = [IO.File]::ReadAllText($targetHooksJson) | ConvertFrom-Json -AsHashtable
    $removedRegistrations = Remove-RtkHookRegistrations $config
    $updatedJson = $config | ConvertTo-Json -Depth 32
    $updatedJson | ConvertFrom-Json | Out-Null
}

if (-not $hookExisted -and $removedRegistrations -eq 0) {
    Write-Host 'RTK Codex Hook is not installed.'
    return
}

if (-not $PSCmdlet.ShouldProcess($targetRoot, 'Remove RTK Codex Hook registration and installed script')) {
    Write-Host "Would remove Hook: $targetHook"
    Write-Host "Would remove registrations: $removedRegistrations"
    return
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backupDir = Get-NormalizedFullPath (Join-Path $targetRoot "backups\rtk-codex-hook\$timestamp-uninstall")
Assert-ContainedPath $targetRoot $backupDir
[IO.Directory]::CreateDirectory($backupDir) | Out-Null
if ($hookExisted) {
    [IO.File]::Copy($targetHook, (Join-Path $backupDir 'rtk-codex-hook.ps1'), $false)
}
if ($configExisted) {
    [IO.File]::Copy($targetHooksJson, (Join-Path $backupDir 'hooks.json'), $false)
}

$temporaryConfig = Join-Path $targetRoot ('.hooks.' + [Guid]::NewGuid().ToString('N') + '.tmp')
Assert-ContainedPath $targetRoot ([IO.Path]::GetFullPath($temporaryConfig))
$configInstalled = $false
$hookRemoved = $false
try {
    if ($configExisted -and $removedRegistrations -gt 0) {
        [IO.File]::WriteAllText(
            $temporaryConfig,
            $updatedJson + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::ReadAllText($temporaryConfig) | ConvertFrom-Json | Out-Null
        [IO.File]::Move($temporaryConfig, $targetHooksJson, $true)
        $configInstalled = $true
    }
    if ($hookExisted) {
        [IO.File]::Delete($targetHook)
        $hookRemoved = $true
    }
}
catch {
    if ($configInstalled) {
        [IO.File]::Copy((Join-Path $backupDir 'hooks.json'), $targetHooksJson, $true)
    }
    if ($hookRemoved) {
        [IO.File]::Copy((Join-Path $backupDir 'rtk-codex-hook.ps1'), $targetHook, $true)
    }
    throw
}
finally {
    if ([IO.File]::Exists($temporaryConfig)) {
        [IO.File]::Delete($temporaryConfig)
    }
}

Write-Host 'RTK Codex Hook uninstalled.'
Write-Host "  Hook:          $targetHook"
Write-Host "  Registrations: $removedRegistrations"
Write-Host "  Backup:        $backupDir"
