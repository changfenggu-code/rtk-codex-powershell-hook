[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param([string]$Name, [object]$Actual, [object]$Expected)

    if ([object]::Equals($Actual, $Expected)) {
        $script:Passed++
        return
    }
    $script:Failed++
    Write-Host "FAIL: $Name" -ForegroundColor Red
    Write-Host "  expected: [$Expected]"
    Write-Host "  actual:   [$Actual]"
}

function Assert-True {
    param([string]$Name, [bool]$Condition)

    if ($Condition) {
        $script:Passed++
        return
    }
    $script:Failed++
    Write-Host "FAIL: $Name" -ForegroundColor Red
}

function Get-RtkRegistrations {
    param([Collections.IDictionary]$Config)

    $registrations = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Config['hooks']['PreToolUse'])) {
        foreach ($hook in @($entry['hooks'])) {
            if (
                $hook -is [Collections.IDictionary] -and
                $hook.Contains('command') -and
                [string]$hook['command'] -match '(?i)rtk-codex-hook\.ps1'
            ) {
                $registrations.Add($hook)
            }
        }
    }
    return $registrations.ToArray()
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $projectRoot 'install.ps1'
$uninstallerPath = Join-Path $projectRoot 'uninstall.ps1'
$rtkCommand = Get-Command rtk.exe, rtk -ErrorAction Stop | Select-Object -First 1
$rtkPath = [IO.Path]::GetFullPath($rtkCommand.Source)
$fixturesRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('rtk-codex-installer-tests-' + [Guid]::NewGuid().ToString('N'))))
[IO.Directory]::CreateDirectory($fixturesRoot) | Out-Null
$caseRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('case-' + [Guid]::NewGuid().ToString('N'))))
$dryRunRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('dry-' + [Guid]::NewGuid().ToString('N'))))
$invalidRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('invalid-' + [Guid]::NewGuid().ToString('N'))))
if (
    -not $caseRoot.StartsWith($fixturesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    -not $dryRunRoot.StartsWith($fixturesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    -not $invalidRoot.StartsWith($fixturesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
) {
    throw 'Installer test paths escaped the fixture root.'
}

try {
    [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
    $existingConfig = [ordered]@{
        hooks = [ordered]@{
            PreToolUse = @(
                [ordered]@{
                    matcher = '^Bash$'
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = "Write-Output 'existing-hook'"
                            timeout = 2
                        }
                    )
                },
                [ordered]@{
                    matcher = '^Other$'
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = "Write-Output 'other-hook'"
                            timeout = 2
                        }
                    )
                }
            )
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $caseRoot 'hooks.json'),
        ($existingConfig | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false)
    )

    & $installerPath -CodexHome $dryRunRoot -RtkPath $rtkPath -WhatIf
    Assert-True 'WhatIf does not create Codex home' (-not [IO.Directory]::Exists($dryRunRoot))

    $missingRtkRejected = $false
    try {
        & $installerPath -CodexHome $dryRunRoot -RtkPath (Join-Path $fixturesRoot 'missing-rtk.exe') -WhatIf
    }
    catch {
        $missingRtkRejected = $true
    }
    Assert-True 'Installer rejects missing explicit RTK path' $missingRtkRejected

    $relativeRtkRejected = $false
    try {
        & $installerPath -CodexHome $dryRunRoot -RtkPath '.\rtk.exe' -WhatIf
    }
    catch {
        $relativeRtkRejected = $true
    }
    Assert-True 'Installer rejects relative RTK path' $relativeRtkRejected

    $volumeRootRejected = $false
    try {
        & $installerPath -CodexHome ([IO.Path]::GetPathRoot($caseRoot)) -RtkPath $rtkPath -WhatIf
    }
    catch {
        $volumeRootRejected = $true
    }
    Assert-True 'Installer rejects volume root target' $volumeRootRejected

    [IO.Directory]::CreateDirectory($invalidRoot) | Out-Null
    $invalidConfigPath = Join-Path $invalidRoot 'hooks.json'
    [IO.File]::WriteAllText($invalidConfigPath, '{broken', [Text.UTF8Encoding]::new($false))
    $invalidConfigRejected = $false
    try {
        & $installerPath -CodexHome $invalidRoot -RtkPath $rtkPath -Confirm:$false
    }
    catch {
        $invalidConfigRejected = $true
    }
    Assert-True 'Installer rejects invalid existing hooks.json' $invalidConfigRejected
    Assert-Equal 'Invalid hooks.json remains unchanged' ([IO.File]::ReadAllText($invalidConfigPath)) '{broken'
    Assert-True 'Invalid config prevents Hook write' (-not [IO.File]::Exists((Join-Path $invalidRoot 'hooks\rtk-codex-hook.ps1')))

    $installWarnings = @()
    & $installerPath -CodexHome $caseRoot -RtkPath $rtkPath -Confirm:$false -WarningVariable installWarnings
    $targetHook = Join-Path $caseRoot 'hooks\rtk-codex-hook.ps1'
    $targetConfigPath = Join-Path $caseRoot 'hooks.json'
    Assert-True 'Installer writes Hook' ([IO.File]::Exists($targetHook))
    Assert-True 'Installer writes hooks.json' ([IO.File]::Exists($targetConfigPath))
    Assert-Equal 'Installed Hook hash matches source' (Get-FileHash $targetHook).Hash (Get-FileHash (Join-Path $projectRoot 'rtk-codex-hook.ps1')).Hash

    $installedConfig = [IO.File]::ReadAllText($targetConfigPath) | ConvertFrom-Json -AsHashtable
    Assert-Equal 'Installer creates one RTK registration' @(Get-RtkRegistrations $installedConfig).Count 1
    $installedJson = [IO.File]::ReadAllText($targetConfigPath)
    Assert-True 'Installer preserves existing Bash Hook' $installedJson.Contains('existing-hook')
    Assert-True 'Installer preserves other matcher' $installedJson.Contains('other-hook')
    Assert-True 'Installer writes absolute target path' $installedJson.Contains($targetHook.Replace('\', '\\'))
    Assert-True 'Installer binds absolute RTK path' $installedJson.Contains($rtkPath.Replace('\', '\\'))
    Assert-True 'Installer warns about competing Bash Hook' (($installWarnings -join "`n").Contains('existing-hook'))

    & $installerPath -CodexHome $caseRoot -RtkPath $rtkPath -Confirm:$false
    $reinstalledConfig = [IO.File]::ReadAllText($targetConfigPath) | ConvertFrom-Json -AsHashtable
    Assert-Equal 'Reinstall remains idempotent' @(Get-RtkRegistrations $reinstalledConfig).Count 1
    $backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'backups\rtk-codex-hook') -Recurse -File)
    Assert-True 'Reinstall creates Hook and config backups' ($backupFiles.Count -ge 2)

    & $uninstallerPath -CodexHome $caseRoot -WhatIf
    Assert-True 'Uninstall WhatIf keeps Hook' ([IO.File]::Exists($targetHook))

    & $uninstallerPath -CodexHome $caseRoot -Confirm:$false
    Assert-True 'Uninstaller removes Hook file' (-not [IO.File]::Exists($targetHook))
    $uninstalledConfig = [IO.File]::ReadAllText($targetConfigPath) | ConvertFrom-Json -AsHashtable
    Assert-Equal 'Uninstaller removes RTK registration' @(Get-RtkRegistrations $uninstalledConfig).Count 0
    $uninstalledJson = [IO.File]::ReadAllText($targetConfigPath)
    Assert-True 'Uninstaller preserves existing Bash Hook' $uninstalledJson.Contains('existing-hook')
    Assert-True 'Uninstaller preserves other matcher' $uninstalledJson.Contains('other-hook')
    Assert-True 'Uninstaller creates backups' (@(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'backups\rtk-codex-hook') -Recurse -File).Count -gt $backupFiles.Count)

    & $uninstallerPath -CodexHome $caseRoot -Confirm:$false
    Assert-True 'Uninstall remains idempotent' (-not [IO.File]::Exists($targetHook))

    & cmd.exe /d /c "`"$(Join-Path $projectRoot 'install.cmd')`" -CodexHome `"$dryRunRoot`" -RtkPath `"$rtkPath`" -WhatIf"
    Assert-Equal 'CMD launcher exits successfully' $LASTEXITCODE 0
    Assert-True 'CMD launcher WhatIf remains non-writing' (-not [IO.Directory]::Exists($dryRunRoot))

    & cmd.exe /d /c "`"$(Join-Path $projectRoot 'uninstall.cmd')`" -CodexHome `"$dryRunRoot`" -WhatIf"
    Assert-Equal 'Uninstall CMD launcher exits successfully' $LASTEXITCODE 0
}
finally {
    if (
        [IO.Directory]::Exists($fixturesRoot) -and
        [IO.Path]::GetFileName($fixturesRoot).StartsWith('rtk-codex-installer-tests-', [StringComparison]::OrdinalIgnoreCase)
    ) {
        [IO.Directory]::Delete($fixturesRoot, $true)
    }
}

Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
if ($script:Failed -ne 0) {
    exit 1
}
exit 0
