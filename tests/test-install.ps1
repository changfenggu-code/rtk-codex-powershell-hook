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

function Copy-RtkFixture {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination)) | Out-Null
    [IO.File]::Copy($Source, $Destination, $true)
    $sourceShim = [IO.Path]::ChangeExtension($Source, '.shim')
    if ([IO.File]::Exists($sourceShim)) {
        [IO.File]::Copy($sourceShim, [IO.Path]::ChangeExtension($Destination, '.shim'), $true)
    }
}

function Remove-RtkDirectoriesFromPath {
    param([Parameter(Mandatory)][string]$PathValue)

    $rtkDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($command in @(Get-Command rtk -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $null = $rtkDirectories.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($command.Source)))
    }

    $retained = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($PathValue -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        $candidate = $entry.Trim().Trim('"')
        try {
            $resolved = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        }
        catch {
            $retained.Add($entry)
            continue
        }
        if (-not $rtkDirectories.Contains($resolved)) {
            $retained.Add($entry)
        }
    }
    return $retained -join ';'
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
$pathCaseRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('path-' + [Guid]::NewGuid().ToString('N'))))
$cargoCaseRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('cargo-' + [Guid]::NewGuid().ToString('N'))))
$localBinCaseRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('local-bin-' + [Guid]::NewGuid().ToString('N'))))
$scoopCaseRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('scoop-' + [Guid]::NewGuid().ToString('N'))))
$collisionCaseRoot = [IO.Path]::GetFullPath((Join-Path $fixturesRoot ('collision-' + [Guid]::NewGuid().ToString('N'))))
foreach ($testPath in @(
    $caseRoot, $dryRunRoot, $invalidRoot, $pathCaseRoot,
    $cargoCaseRoot, $localBinCaseRoot, $scoopCaseRoot, $collisionCaseRoot
)) {
    if (-not $testPath.StartsWith($fixturesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer test path escaped the fixture root: $testPath"
    }
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
    $agentsPath = Join-Path $caseRoot 'AGENTS.md'
    $agentsSource = '@C:\Users\example\.codex\RTK.md' + [Environment]::NewLine
    [IO.File]::WriteAllText($agentsPath, $agentsSource, [Text.UTF8Encoding]::new($false))

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
    Assert-True 'Installer warns about RTK instruction overlap' (($installWarnings -join "`n").Contains('AGENTS.md references RTK.md'))
    Assert-Equal 'Installer does not modify AGENTS.md' ([IO.File]::ReadAllText($agentsPath)) $agentsSource

    & $installerPath -CodexHome $caseRoot -RtkPath $rtkPath -Confirm:$false
    $reinstalledConfig = [IO.File]::ReadAllText($targetConfigPath) | ConvertFrom-Json -AsHashtable
    Assert-Equal 'Reinstall remains idempotent' @(Get-RtkRegistrations $reinstalledConfig).Count 1
    $backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'backups\rtk-codex-hook') -Recurse -File)
    Assert-True 'Reinstall creates Hook and config backups' ($backupFiles.Count -ge 2)

    & $installerPath -CodexHome $pathCaseRoot -Confirm:$false
    $pathConfigPath = Join-Path $pathCaseRoot 'hooks.json'
    $pathConfig = [IO.File]::ReadAllText($pathConfigPath) | ConvertFrom-Json -AsHashtable
    $pathRegistration = @(Get-RtkRegistrations $pathConfig)[0]
    Assert-True 'PATH install omits explicit RTK binding' (-not ([string]$pathRegistration['command']).Contains('-RtkPath'))
    Assert-True 'PATH install still writes absolute Hook path' ([string]$pathRegistration['command'] -match [regex]::Escape((Join-Path $pathCaseRoot 'hooks\rtk-codex-hook.ps1')))

    & $installerPath -CodexHome $pathCaseRoot -RtkPath $rtkPath -Confirm:$false
    $strictConfig = [IO.File]::ReadAllText($pathConfigPath) | ConvertFrom-Json -AsHashtable
    $strictRegistration = @(Get-RtkRegistrations $strictConfig)[0]
    Assert-True 'Explicit reinstall enables absolute RTK binding' ([string]$strictRegistration['command'] -match '-RtkPath')
    Assert-True 'Explicit reinstall records selected RTK path' ([string]$strictRegistration['command'] -match [regex]::Escape($rtkPath))

    & $installerPath -CodexHome $pathCaseRoot -Confirm:$false
    $restoredPathConfig = [IO.File]::ReadAllText($pathConfigPath) | ConvertFrom-Json -AsHashtable
    $restoredPathRegistration = @(Get-RtkRegistrations $restoredPathConfig)[0]
    Assert-True 'PATH reinstall removes stale absolute RTK binding' (-not ([string]$restoredPathRegistration['command']).Contains('-RtkPath'))

    $savedPath = $env:PATH
    $savedCargoHome = $env:CARGO_HOME
    $savedScoop = $env:SCOOP
    $savedUserProfile = $env:USERPROFILE
    try {
        $pathWithoutRtk = Remove-RtkDirectoriesFromPath $savedPath
        $isolatedUser = Join-Path $fixturesRoot 'isolated-user'
        $cargoHome = Join-Path $fixturesRoot 'cargo-home'
        $scoopRoot = Join-Path $fixturesRoot 'scoop-root'
        $cargoRtk = Join-Path $cargoHome 'bin\rtk.exe'
        $localBinRtk = Join-Path $isolatedUser '.local\bin\rtk.exe'
        $scoopRtk = Join-Path $scoopRoot 'shims\rtk.exe'
        Copy-RtkFixture $rtkPath $cargoRtk
        Copy-RtkFixture $rtkPath $localBinRtk
        Copy-RtkFixture $rtkPath $scoopRtk

        $env:PATH = $pathWithoutRtk
        $env:CARGO_HOME = $cargoHome
        $env:SCOOP = $scoopRoot
        $env:USERPROFILE = $isolatedUser
        & $installerPath -CodexHome $cargoCaseRoot -Confirm:$false
        $cargoConfig = [IO.File]::ReadAllText((Join-Path $cargoCaseRoot 'hooks.json')) | ConvertFrom-Json -AsHashtable
        $cargoRegistration = @(Get-RtkRegistrations $cargoConfig)[0]
        Assert-True 'Cargo fallback binds absolute RTK path' ([string]$cargoRegistration['command'] -match [regex]::Escape($cargoRtk))
        Assert-True 'Cargo fallback takes priority over local bin' (-not ([string]$cargoRegistration['command'] -match [regex]::Escape($localBinRtk)))
        Assert-True 'Cargo fallback takes priority over Scoop' (-not ([string]$cargoRegistration['command'] -match [regex]::Escape($scoopRtk)))

        $emptyCargoHome = Join-Path $fixturesRoot 'empty-cargo-home'
        [IO.Directory]::CreateDirectory($emptyCargoHome) | Out-Null
        $env:CARGO_HOME = $emptyCargoHome
        & $installerPath -CodexHome $localBinCaseRoot -Confirm:$false
        $localBinConfig = [IO.File]::ReadAllText((Join-Path $localBinCaseRoot 'hooks.json')) | ConvertFrom-Json -AsHashtable
        $localBinRegistration = @(Get-RtkRegistrations $localBinConfig)[0]
        Assert-True 'Local-bin fallback binds absolute RTK path' ([string]$localBinRegistration['command'] -match [regex]::Escape($localBinRtk))
        Assert-True 'Local-bin fallback takes priority over Scoop' (-not ([string]$localBinRegistration['command'] -match [regex]::Escape($scoopRtk)))

        $env:USERPROFILE = Join-Path $fixturesRoot 'scoop-only-user'
        & $installerPath -CodexHome $scoopCaseRoot -Confirm:$false
        $scoopConfig = [IO.File]::ReadAllText((Join-Path $scoopCaseRoot 'hooks.json')) | ConvertFrom-Json -AsHashtable
        $scoopRegistration = @(Get-RtkRegistrations $scoopConfig)[0]
        Assert-True 'Scoop fallback binds absolute RTK path' ([string]$scoopRegistration['command'] -match [regex]::Escape($scoopRtk))

        $wrongDirectory = Join-Path $fixturesRoot 'wrong-path'
        $validDirectory = Join-Path $fixturesRoot 'valid-path'
        [IO.Directory]::CreateDirectory($wrongDirectory) | Out-Null
        [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\where.exe'), (Join-Path $wrongDirectory 'rtk.exe'), $true)
        $validRtk = Join-Path $validDirectory 'rtk.exe'
        Copy-RtkFixture $rtkPath $validRtk
        $env:PATH = "$wrongDirectory;$validDirectory;$pathWithoutRtk"
        $env:CARGO_HOME = $emptyCargoHome
        $env:SCOOP = Join-Path $fixturesRoot 'missing-scoop'
        $collisionWarnings = @()
        & $installerPath -CodexHome $collisionCaseRoot -Confirm:$false -WarningVariable collisionWarnings
        $collisionConfig = [IO.File]::ReadAllText((Join-Path $collisionCaseRoot 'hooks.json')) | ConvertFrom-Json -AsHashtable
        $collisionRegistration = @(Get-RtkRegistrations $collisionConfig)[0]
        Assert-True 'PATH collision binds the later valid RTK path' ([string]$collisionRegistration['command'] -match [regex]::Escape($validRtk))
        Assert-True 'PATH collision warns about the effective invalid command' (($collisionWarnings -join "`n").Contains('effective PATH command'))
    }
    finally {
        $env:PATH = $savedPath
        $env:CARGO_HOME = $savedCargoHome
        $env:SCOOP = $savedScoop
        $env:USERPROFILE = $savedUserProfile
    }

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
