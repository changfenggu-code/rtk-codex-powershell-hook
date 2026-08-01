[CmdletBinding()]
param(
    [switch]$Bootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$requiredVersion = [version]'1.25.0'
$module = Get-Module -ListAvailable PSScriptAnalyzer |
    Where-Object Version -eq $requiredVersion |
    Select-Object -First 1

if ($null -eq $module -and $Bootstrap) {
    $moduleRoot = Join-Path ([IO.Path]::GetTempPath()) "rtk-codex-pssa-$requiredVersion"
    [IO.Directory]::CreateDirectory($moduleRoot) | Out-Null
    $modulePath = Join-Path $moduleRoot "PSScriptAnalyzer\$requiredVersion\PSScriptAnalyzer.psd1"
    if (-not [IO.File]::Exists($modulePath)) {
        Save-Module PSScriptAnalyzer -RequiredVersion $requiredVersion -Repository PSGallery -Path $moduleRoot
    }
    Import-Module $modulePath -Force
}
elseif ($null -ne $module) {
    Import-Module $module.Path -Force
}
else {
    throw "PSScriptAnalyzer $requiredVersion is required. Re-run with -Bootstrap to save it under the temporary directory."
}

$settings = Join-Path $projectRoot 'PSScriptAnalyzerSettings.psd1'
$results = @(Invoke-ScriptAnalyzer -Path $projectRoot -Recurse -Settings $settings)
if ($results.Count -ne 0) {
    $results |
        Select-Object RuleName, Severity, ScriptName, Line, Message |
        Format-Table -Wrap
    throw "PSScriptAnalyzer reported $($results.Count) finding(s)."
}

Write-Host "PSScriptAnalyzer $requiredVersion passed."
