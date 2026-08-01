[CmdletBinding()]
param(
    [switch]$Bootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$version = '1.7.12'
$expectedHash = '6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9'
$command = Get-Command actionlint.exe, actionlint -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -ne $command) {
    $actionlint = $command.Source
}
elseif ($Bootstrap) {
    $toolRoot = Join-Path ([IO.Path]::GetTempPath()) "rtk-codex-actionlint-$version"
    [IO.Directory]::CreateDirectory($toolRoot) | Out-Null
    $archive = Join-Path $toolRoot 'actionlint.zip'
    $actionlint = Join-Path $toolRoot 'actionlint.exe'
    if (-not [IO.File]::Exists($actionlint)) {
        $uri = "https://github.com/rhysd/actionlint/releases/download/v$version/actionlint_${version}_windows_amd64.zip"
        Invoke-WebRequest -Uri $uri -OutFile $archive
        $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "actionlint archive checksum mismatch: $actualHash"
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $toolRoot -Force
    }
}
else {
    throw "actionlint $version is required. Re-run with -Bootstrap to download it under the temporary directory."
}

$workflows = @(
    (Join-Path $projectRoot '.github\workflows\ci.yml'),
    (Join-Path $projectRoot '.github\workflows\release.yml')
)
& $actionlint @workflows
if ($LASTEXITCODE -ne 0) {
    throw "actionlint failed with exit code $LASTEXITCODE"
}

Write-Host "actionlint $version passed."
