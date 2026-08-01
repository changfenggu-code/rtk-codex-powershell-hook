[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
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

$productionScripts = @(
    'rtk-codex-hook.ps1',
    'install.ps1',
    'uninstall.ps1',
    'scripts\package-release.ps1'
)
$forbiddenCommands = @(
    'invoke-expression', 'iex', 'start-process', 'add-type',
    'invoke-webrequest', 'iwr', 'invoke-restmethod', 'irm'
)

foreach ($relativePath in $productionScripts) {
    $path = Join-Path $projectRoot $relativePath
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    Assert-True "$relativePath parses" ($parseErrors.Count -eq 0)

    $dangerous = @($ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.CommandAst]) {
            return $false
        }
        $name = $node.GetCommandName()
        return $null -ne $name -and $name.ToLowerInvariant() -in $forbiddenCommands
    }, $true))
    Assert-True "$relativePath avoids dynamic, network, and process-launch commands" ($dangerous.Count -eq 0)

    $source = [IO.File]::ReadAllText($path)
    Assert-True "$relativePath contains no machine-specific drive path" ($source -notmatch '(?i)(?<![A-Za-z0-9])[''"]?[A-Z]:\\')
}

$hookSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'rtk-codex-hook.ps1'))
Assert-True 'Production Hook performs no filesystem writes' ($hookSource -notmatch '(?i)\[IO\.(?:File|Directory)\]')
Assert-True 'Production Hook has no recursive deletion primitive' ($hookSource -notmatch '(?i)(Remove-Item|Directory\]::Delete)')

$hooksConfig = [IO.File]::ReadAllText((Join-Path $projectRoot 'hooks.json')) | ConvertFrom-Json -AsHashtable
Assert-True 'hooks.json contains PreToolUse' (
    $hooksConfig.Contains('hooks') -and $hooksConfig['hooks'].Contains('PreToolUse')
)
$registrationCount = 0
foreach ($entry in @($hooksConfig['hooks']['PreToolUse'])) {
    foreach ($hook in @($entry['hooks'])) {
        if (
            $hook -is [Collections.IDictionary] -and
            $hook.Contains('command') -and
            [string]$hook['command'] -match '(?i)rtk-codex-hook\.ps1'
        ) {
            $registrationCount++
        }
    }
}
Assert-True 'hooks.json contains exactly one packaged registration' ($registrationCount -eq 1)

$realE2eGuarded = $false
try {
    & (Join-Path $projectRoot 'scripts\run-real-codex-e2e.ps1') -AllowProviderRequest:$false
}
catch {
    $realE2eGuarded = $_.Exception.Message.Contains('configured provider')
}
Assert-True 'Real Codex e2e requires explicit provider consent' $realE2eGuarded

Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
