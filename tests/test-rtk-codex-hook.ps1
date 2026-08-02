[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hookPath = Join-Path $projectRoot 'rtk-codex-hook.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rtk-codex-hook-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
. $hookPath -LibraryMode

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [AllowNull()] [object]$Actual,
        [AllowNull()] [object]$Expected
    )

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
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [bool]$Condition
    )

    if ($Condition) {
        $script:Passed++
        return
    }
    $script:Failed++
    Write-Host "FAIL: $Name" -ForegroundColor Red
}

function Assert-Rewrite {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Expected
    )

    Assert-Equal $Name (Convert-PowerShellNativeCommands $Source) $Expected
}

function Assert-Unchanged {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Source
    )

    Assert-Equal $Name (Convert-PowerShellNativeCommands $Source) $Source
}

Write-Host 'PowerShell AST rewrite tests'

Assert-Unchanged 'Get-Content positional' "Get-Content 'Cargo.toml'"
Assert-Unchanged 'Get-Content alias gc' "gc 'Cargo.toml'"
Assert-Unchanged 'Get-Content alias type' "type 'Cargo.toml'"
Assert-Unchanged 'Get-Content raw' "Get-Content -Raw 'Cargo.toml'"
Assert-Unchanged 'Get-Content force' "Get-Content -Force 'Cargo.toml'"
Assert-Unchanged 'Get-Content named path' "Get-Content -Path 'Cargo.toml'"
Assert-Unchanged 'Get-Content literal wildcard' "Get-Content -LiteralPath 'a*b.txt'"
Assert-Unchanged 'Get-Content multiple files' "Get-Content 'a.rs','b.rs'"
Assert-Unchanged 'Get-Content total count' "Get-Content -TotalCount 10 'Cargo.toml'"
Assert-Unchanged 'Get-Content tail' "Get-Content -Tail 5 'Cargo.toml'"
Assert-Unchanged 'Get-Content quoted apostrophe' "Get-Content `"team's file.txt`""
Assert-Unchanged 'Get-Content module-qualified' "Microsoft.PowerShell.Management\Get-Content 'Cargo.toml'"
Assert-Unchanged 'Get-Content Unicode path' "Get-Content '说明.txt'"
Assert-Unchanged 'Get-Content quoted metacharacters' "Get-Content 'a; `$x & b.txt'"
Assert-Unchanged 'Get-Content variable path' 'Get-Content $env:USERPROFILE\.codex\RTK.md'
Assert-Unchanged 'Get-Content expandable path' 'Get-Content "$env:USERPROFILE\RTK.md"'
Assert-Unchanged 'Get-Content wildcard path' "Get-Content -Path '*.rs'"
Assert-Unchanged 'Get-Content provider path' "Get-Content 'Env:PATH'"
Assert-Unchanged 'Get-Content unsupported encoding' "Get-Content -Encoding utf8 'Cargo.toml'"
Assert-Unchanged 'Get-Content raw window conflict' "Get-Content -Raw -Tail 2 'Cargo.toml'"
Assert-Unchanged 'Get-Content zero total count' "Get-Content -TotalCount 0 'Cargo.toml'"
Assert-Unchanged 'Get-Content redirect' "Get-Content 'Cargo.toml' > 'copy.txt'"
Assert-Unchanged 'Get-Content unknown module qualifier' "Example.Module\Get-Content 'Cargo.toml'"

Assert-Rewrite 'Select-String default case-insensitive' "Select-String -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String positional' "Select-String 'workspace' 'Cargo.toml'" "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String alias' "sls -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String case-sensitive' "Select-String -CaseSensitive -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String simple match' "Select-String -SimpleMatch -Path 'Cargo.toml' -Pattern 'a.b'" "rtk rg -n -i -F -e 'a.b' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String one context value' "Select-String -Context 2 -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -C 2 -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String asymmetric context' "Select-String -Context 1,2 -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -B 1 -A 2 -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String negative match' "Select-String -NotMatch -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -v -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String list' "Select-String -List -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -l -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String quiet' "Select-String -Quiet -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -q -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Select-String multiple patterns and files' "Select-String -Path 'a.rs','b.rs' -Pattern 'foo','bar'" "rtk rg -n -i -e 'foo' -e 'bar' -- 'a.rs' 'b.rs'"
Assert-Rewrite 'Select-String lookbehind uses PCRE2' "Select-String -Path 'Cargo.toml' -Pattern '(?<=work)space'" "rtk rg -n -i --pcre2 -e '(?<=work)space' -- 'Cargo.toml'"
Assert-Unchanged 'Select-String variable pattern' "Select-String -Path 'Cargo.toml' -Pattern `$pattern"
Assert-Unchanged 'Select-String wildcard path' "Select-String -Path '*.rs' -Pattern 'foo'"
Assert-Unchanged 'Select-String no path' "Select-String -Pattern 'foo'"
Assert-Unchanged 'Select-String balancing group' "Select-String -Path 'Cargo.toml' -Pattern '(?<open-open>x)'"
Assert-Unchanged 'Select-String raw unsupported' "Select-String -Raw -Path 'Cargo.toml' -Pattern 'foo'"
Assert-Unchanged 'Select-String redirect' "Select-String -Path 'Cargo.toml' -Pattern 'foo' > 'matches.txt'"

Assert-Rewrite 'Get-ChildItem default path' 'Get-ChildItem' "rtk ls '.'"
Assert-Rewrite 'Get-ChildItem positional path' "Get-ChildItem 'src'" "rtk ls 'src'"
Assert-Rewrite 'Get-ChildItem alias gci' "gci 'src'" "rtk ls 'src'"
Assert-Rewrite 'Get-ChildItem alias dir' "dir -Force 'src'" "rtk ls -a 'src'"
Assert-Rewrite 'Get-ChildItem multiple paths' "Get-ChildItem 'src','tests'" "rtk ls 'src' 'tests'"
Assert-Rewrite 'Get-ChildItem recursive files' "Get-ChildItem -Path 'src' -Recurse -Filter '*.rs' -File" "rtk find 'src' -name '*.rs' -type f"
Assert-Rewrite 'Get-ChildItem recursive directories' "Get-ChildItem -Path 'src' -Recurse -Directory" "rtk find 'src' -name '*' -type d"
Assert-Rewrite 'Get-ChildItem depth files' "Get-ChildItem -Path 'src' -Depth 2 -File" "rtk find 'src' -name '*' -type f -maxdepth 3"
Assert-Rewrite 'Get-ChildItem immediate files' "Get-ChildItem -Path 'src' -File" "rtk find 'src' -name '*' -type f -maxdepth 1"
Assert-Unchanged 'Get-ChildItem recursive mixed types' "Get-ChildItem -Path 'src' -Recurse"
Assert-Unchanged 'Get-ChildItem recursive force unsupported' "Get-ChildItem -Path 'src' -Recurse -File -Force"
Assert-Unchanged 'Get-ChildItem wildcard path' "Get-ChildItem -Path 'src*'"
Assert-Unchanged 'Get-ChildItem unsupported attribute' "Get-ChildItem -Path 'src' -Attributes Hidden"
Assert-Unchanged 'Get-ChildItem redirect' "Get-ChildItem 'src' > 'listing.txt'"

Assert-Unchanged 'Pipeline first' "Get-Content 'Cargo.toml' | Select-Object -First 10"
Assert-Unchanged 'Pipeline last alias' "gc 'Cargo.toml' | select -Last 5"
Assert-Rewrite 'Pipeline Select-String' "Get-Content 'Cargo.toml' | Select-String -Pattern 'workspace'" "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
Assert-Rewrite 'Pipeline Select-String alias' "gc 'Cargo.toml' | sls -CaseSensitive -Pattern 'workspace'" "rtk rg -n -e 'workspace' -- 'Cargo.toml'"
Assert-Unchanged 'Pipeline raw content' "Get-Content -Raw 'Cargo.toml' | Select-Object -First 1"
Assert-Unchanged 'Pipeline multiple files' "Get-Content 'a.rs','b.rs' | Select-Object -First 5"
Assert-Unchanged 'Pipeline unknown consumer' "Get-Content 'Cargo.toml' | ForEach-Object { `$_ }"
Assert-Unchanged 'Pipeline redirect' "Get-Content 'Cargo.toml' | Select-Object -First 2 > 'head.txt'"

Assert-Unchanged 'Compound Get-Content' "Get-Content 'a.rs'; Get-Content 'b.rs'"
Assert-Rewrite 'Compound pipeline chain' "Get-Content 'a.rs' && Get-ChildItem 'src'" "Get-Content 'a.rs' && rtk ls 'src'"
Assert-Unchanged 'Head remains native' "head -10 'Cargo.toml'"
Assert-Unchanged 'Tail remains native' "tail -10 'Cargo.toml'"
Assert-Rewrite 'Compound native rewrite excludes read' "git status; head -10 'Cargo.toml'" "rtk git status; head -10 'Cargo.toml'"
Assert-Rewrite 'Compound native rewrite preserves cat' "git status; cat 'Cargo.toml'" "rtk git status; cat 'Cargo.toml'"
Assert-Rewrite 'Batch two native commands' 'git status; cargo check -p btleplus' 'rtk git status; rtk cargo check -p btleplus'
Assert-Rewrite 'Batch delegates around preserved read' "git status; head -10 'Cargo.toml'; cargo check" "rtk git status; head -10 'Cargo.toml'; rtk cargo check"
Assert-Rewrite 'Batch delegates around local rewrite' "git status; Select-String -Path 'Cargo.toml' -Pattern 'workspace'; cargo check" "rtk git status; rtk rg -n -i -e 'workspace' -- 'Cargo.toml'; rtk cargo check"
Assert-Rewrite 'Batch keeps explicit rtk read slot' 'git status; rtk read Cargo.toml -l minimal; cargo check' 'rtk git status; rtk read Cargo.toml -l minimal; rtk cargo check'
Assert-Rewrite 'Batch preserves quoted separator' "rg 'alpha;beta' Cargo.toml; cargo check" "rtk rg 'alpha;beta' Cargo.toml; rtk cargo check"
Assert-Rewrite 'Batch delegates complete pipeline' 'cat Cargo.toml | rg workspace; cargo check' 'cat Cargo.toml | rtk rg workspace; rtk cargo check'
Assert-Rewrite 'Batch keeps unsupported delegate' "Write-Output 'hello'; cargo check" "Write-Output 'hello'; rtk cargo check"
Assert-Unchanged 'Batch with no supported delegates' "Write-Output 'hello'; Get-Date"
Assert-Unchanged 'Nested assignment remains unchanged' "`$content = Get-Content 'Cargo.toml'"
Assert-Unchanged 'Nested subexpression remains unchanged' 'Write-Output $(Get-Content ''Cargo.toml'')'
Assert-Unchanged 'Malformed PowerShell remains unchanged' "Get-Content 'unterminated"
Assert-Unchanged 'Function shadowing disables rewrite' "function Get-Content { 'shadowed' }; Get-Content 'Cargo.toml'"
Assert-Unchanged 'Alias mutation disables rewrite' "Set-Alias gc Write-Output; gc 'Cargo.toml'"
Assert-Unchanged 'Module import disables rewrite' "Import-Module Example; Get-Content 'Cargo.toml'"
Assert-Unchanged 'Background pipeline remains unchanged' "Get-Content 'Cargo.toml' &"

Write-Host 'RTK native rewrite tests'
$nativeGit = Invoke-RtkRewrite 'git status --short'
Assert-Equal 'RTK rewrites git status' $nativeGit 'rtk git status --short'
$nativeCat = Invoke-RtkRewrite 'cat Cargo.toml'
Assert-Equal 'RTK excludes cat' $nativeCat $null
Assert-Equal 'RTK excludes head' (Invoke-RtkRewrite 'head -10 Cargo.toml') $null
Assert-Equal 'RTK excludes tail' (Invoke-RtkRewrite 'tail -10 Cargo.toml') $null
$nativeCompound = Invoke-RtkRewrite 'git status; cat Cargo.toml'
Assert-True 'RTK compound result never imports generated read' (
    $null -eq $nativeCompound -or -not (Test-ContainsRtkReadCommand $nativeCompound)
)
Assert-Equal 'Explicit rtk read remains unchanged' (Invoke-RtkRewrite 'rtk read Cargo.toml -l minimal') $null
Assert-True 'Generated rtk read detector accepts read' (Test-ContainsRtkReadCommand 'rtk read Cargo.toml --max-lines 10')
Assert-True 'Generated rtk read detector rejects other commands' (-not (Test-ContainsRtkReadCommand 'rtk rg workspace Cargo.toml'))
Assert-Equal 'RTK leaves Write-Output alone' (Invoke-RtkRewrite "Write-Output 'hello'") $null

Write-Host 'RTK batch envelope tests'
$generatedBatchId = New-RtkBatchId 'git status; cargo check'
Assert-True 'Batch id uses safe random GUID shape' ($generatedBatchId -match '^codexrtkbatch_[0-9a-f]{32}$')
Assert-True 'Batch id does not collide with source' (-not 'git status; cargo check'.Contains($generatedBatchId))

$fixedBatchId = 'codexrtkbatch_00000000000000000000000000000000'
$fixedMarkers = @(New-RtkBatchMarkers $fixedBatchId 2)
Assert-Equal 'Batch uses N plus one markers' $fixedMarkers.Count 3
Assert-Equal 'Batch first marker is stable' $fixedMarkers[0] "${fixedBatchId}_slot_000000"
Assert-Equal 'Batch final marker closes last slot' $fixedMarkers[2] "${fixedBatchId}_slot_000002"

$fixedDelegates = @(
    [pscustomobject]@{ Start = 10; End = 20; Original = 'git status' }
    [pscustomobject]@{ Start = 40; End = 51; Original = 'cargo check' }
)
$fixedBatch = New-RtkBatchCommand $fixedDelegates $fixedMarkers
Assert-Equal 'Batch command packs delegate copies only' $fixedBatch "$($fixedMarkers[0]); git status; $($fixedMarkers[1]); cargo check; $($fixedMarkers[2])"

$validBatchOutput = "$($fixedMarkers[0]); rtk git status; $($fixedMarkers[1]); rtk cargo check; $($fixedMarkers[2])"
$validBatchReplacements = @(ConvertFrom-RtkBatchRewrite $validBatchOutput $fixedMarkers $fixedDelegates)
Assert-Equal 'Batch parser returns both rewrites' $validBatchReplacements.Count 2
Assert-Equal 'Batch parser maps first slot text' $validBatchReplacements[0].Text 'rtk git status'
Assert-Equal 'Batch parser maps first slot extent' $validBatchReplacements[0].Start 10
Assert-Equal 'Batch parser maps second slot text' $validBatchReplacements[1].Text 'rtk cargo check'
Assert-Equal 'Batch parser maps second slot extent' $validBatchReplacements[1].Start 40

$readBatchOutput = "$($fixedMarkers[0]); rtk read Cargo.toml --max-lines 10; $($fixedMarkers[1]); rtk cargo check; $($fixedMarkers[2])"
$readBatchReplacements = @(ConvertFrom-RtkBatchRewrite $readBatchOutput $fixedMarkers $fixedDelegates)
Assert-Equal 'Batch parser rejects only read slot' $readBatchReplacements.Count 1
Assert-Equal 'Batch parser preserves neighboring rewrite' $readBatchReplacements[0].Text 'rtk cargo check'
Assert-Equal 'Batch parser preserves neighboring extent' $readBatchReplacements[0].Start 40

$unchangedBatchOutput = "$($fixedMarkers[0]); git status; $($fixedMarkers[1]); cargo check; $($fixedMarkers[2])"
Assert-Equal 'Batch parser omits unchanged slots' @(ConvertFrom-RtkBatchRewrite $unchangedBatchOutput $fixedMarkers $fixedDelegates).Count 0
$missingFinalMarker = "$($fixedMarkers[0]); rtk git status; $($fixedMarkers[1]); rtk cargo check"
Assert-Equal 'Batch parser fails open on missing final marker' @(ConvertFrom-RtkBatchRewrite $missingFinalMarker $fixedMarkers $fixedDelegates).Count 0
$reorderedMarkers = "$($fixedMarkers[1]); rtk git status; $($fixedMarkers[0]); rtk cargo check; $($fixedMarkers[2])"
Assert-Equal 'Batch parser fails open on reordered markers' @(ConvertFrom-RtkBatchRewrite $reorderedMarkers $fixedMarkers $fixedDelegates).Count 0
$markerAsArgument = "Write-Output $($fixedMarkers[0]); rtk git status; $($fixedMarkers[1]); rtk cargo check; $($fixedMarkers[2])"
Assert-Equal 'Batch parser rejects marker used as argument' @(ConvertFrom-RtkBatchRewrite $markerAsArgument $fixedMarkers $fixedDelegates).Count 0

$quotedDelegate = @([pscustomobject]@{ Start = 70; End = 101; Original = "rg 'alpha;beta' Cargo.toml" })
$quotedMarkers = @(New-RtkBatchMarkers $fixedBatchId 1)
$quotedOutput = "$($quotedMarkers[0]); rtk rg 'alpha;beta' Cargo.toml; $($quotedMarkers[1])"
$quotedReplacement = @(ConvertFrom-RtkBatchRewrite $quotedOutput $quotedMarkers $quotedDelegate)
Assert-Equal 'Batch parser preserves quoted semicolon' $quotedReplacement[0].Text "rtk rg 'alpha;beta' Cargo.toml"

Write-Host 'Codex protocol tests'
function New-TestPayload {
    param([string]$Command, [string]$ToolName = 'Bash')
    return [ordered]@{
        session_id = 'test-session'
        hook_event_name = 'PreToolUse'
        tool_name = $ToolName
        tool_input = [ordered]@{
            command = $Command
            timeout_ms = 1234
        }
    } | ConvertTo-Json -Depth 10 -Compress
}

$protocolOutput = Invoke-CodexRtkHook (New-TestPayload "Select-String -Path 'Cargo.toml' -Pattern 'workspace'")
$protocolJson = $protocolOutput | ConvertFrom-Json
Assert-Equal 'Protocol event name' $protocolJson.hookSpecificOutput.hookEventName 'PreToolUse'
Assert-Equal 'Protocol decision' $protocolJson.hookSpecificOutput.permissionDecision 'allow'
Assert-Equal 'Protocol rewritten command' $protocolJson.hookSpecificOutput.updatedInput.command "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
Assert-Equal 'Protocol preserves other input' $protocolJson.hookSpecificOutput.updatedInput.timeout_ms ([long]1234)
Assert-Equal 'Protocol ignores other tool' (Invoke-CodexRtkHook (New-TestPayload 'git status' 'apply_patch')) $null
Assert-Equal 'Protocol ignores no-op command' (Invoke-CodexRtkHook (New-TestPayload "Write-Output 'hello'")) $null
Assert-Equal 'Protocol leaves Get-Content unchanged' (Invoke-CodexRtkHook (New-TestPayload "Get-Content -Raw 'Cargo.toml'")) $null
Assert-Equal 'Protocol leaves explicit rtk read unchanged' (Invoke-CodexRtkHook (New-TestPayload 'rtk read Cargo.toml -l minimal')) $null
Assert-Equal 'Protocol invalid JSON fails open' (Invoke-CodexRtkHook '{broken') $null
Assert-Equal 'Protocol blank input fails open' (Invoke-CodexRtkHook '   ') $null
$missingFields = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash' } | ConvertTo-Json -Compress
Assert-Equal 'Protocol missing tool input fails open' (Invoke-CodexRtkHook $missingFields) $null
$oversized = '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"' + ('x' * (1MB)) + '"}}'
Assert-Equal 'Protocol oversized input fails open' (Invoke-CodexRtkHook $oversized) $null

$mixedOutput = Invoke-CodexRtkHook (New-TestPayload "Get-Content 'Cargo.toml'; cargo check -p btleplus")
$mixedJson = $mixedOutput | ConvertFrom-Json
Assert-True 'Protocol combines RTK and PowerShell rewrites' (
    $mixedJson.hookSpecificOutput.updatedInput.command -eq "Get-Content 'Cargo.toml'; rtk cargo check -p btleplus"
)

Write-Host 'Subprocess protocol tests'
$subprocessOutput = New-TestPayload "Get-ChildItem 'src'" |
    & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath
Assert-Equal 'Subprocess exits with valid rewrite' $LASTEXITCODE 0
$subprocessJson = $subprocessOutput | ConvertFrom-Json
Assert-Equal 'Subprocess returns rewrite JSON' $subprocessJson.hookSpecificOutput.updatedInput.command "rtk ls 'src'"

$invalidSubprocessOutput = '{broken' | & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath
Assert-Equal 'Subprocess invalid JSON exits zero' $LASTEXITCODE 0
Assert-Equal 'Subprocess invalid JSON has no stdout' ($invalidSubprocessOutput -join '') ''

$handlerCommand = "& '$($hookPath.Replace("'", "''"))'"
$configuredOutput = New-TestPayload "Get-ChildItem 'src'" |
    & pwsh -NoLogo -NoProfile -NonInteractive -Command $handlerCommand
Assert-Equal 'Configured handler invocation exits zero' $LASTEXITCODE 0
$configuredJson = $configuredOutput | ConvertFrom-Json
Assert-Equal 'Configured handler invocation rewrites' $configuredJson.hookSpecificOutput.updatedInput.command "rtk ls 'src'"

$pathNativeOutput = New-TestPayload 'git status' |
    & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath
$pathNativeJson = $pathNativeOutput | ConvertFrom-Json
Assert-Equal 'Production PATH mode emits bare RTK command' $pathNativeJson.hookSpecificOutput.updatedInput.command 'rtk git status'

$pathPrefixedOutput = New-TestPayload 'rtk cat README.md' |
    & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath
Assert-Equal 'Production PATH mode leaves prefixed RTK command unchanged' ($pathPrefixedOutput -join '') ''

$missingBoundRtk = Join-Path $testRoot 'missing bound rtk.exe'
$missingBoundLocalOutput = New-TestPayload "Select-String -Path 'Cargo.toml' -Pattern 'workspace'" |
    & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath -RtkPath $missingBoundRtk
Assert-Equal 'Missing bound RTK leaves local rewrite unchanged' ($missingBoundLocalOutput -join '') ''
$missingBoundNativeOutput = New-TestPayload 'git status' |
    & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath -RtkPath $missingBoundRtk
Assert-Equal 'Missing bound RTK leaves native rewrite unchanged' ($missingBoundNativeOutput -join '') ''

$actualRtkPath = (Get-Command rtk.exe, rtk -ErrorAction Stop | Select-Object -First 1).Source
$savedRtkOverride = $env:RTK_CODEX_RTK_EXE
try {
    $env:RTK_CODEX_RTK_EXE = $missingBoundRtk
    $productionBoundOutput = New-TestPayload 'git status' |
        & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath -RtkPath $actualRtkPath
    $productionBoundJson = $productionBoundOutput | ConvertFrom-Json
    $escapedActualRtkPath = $actualRtkPath.Replace("'", "''")
    Assert-Equal 'Production Hook ignores test-only RTK override' $productionBoundJson.hookSpecificOutput.updatedInput.command "& '$escapedActualRtkPath' git status"
}
finally {
    $env:RTK_CODEX_RTK_EXE = $savedRtkOverride
}

$savedRtkOverride = $env:RTK_CODEX_RTK_EXE
try {
    $env:RTK_CODEX_RTK_EXE = Join-Path $testRoot 'missing-rtk.exe'
    $missingRtkPowerShell = Invoke-CodexRtkHook (New-TestPayload "Select-String -Path 'Cargo.toml' -Pattern 'workspace'")
    Assert-Equal 'Missing RTK still permits PowerShell rewrite' (($missingRtkPowerShell | ConvertFrom-Json).hookSpecificOutput.updatedInput.command) "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
    Assert-Equal 'Missing RTK leaves native command unchanged' (Invoke-CodexRtkHook (New-TestPayload 'git status')) $null
    $missingRtkMixed = Invoke-CodexRtkHook (New-TestPayload "Select-String -Path 'Cargo.toml' -Pattern 'workspace'; cargo check")
    Assert-Equal 'Missing RTK keeps local rewrite in mixed command' (($missingRtkMixed | ConvertFrom-Json).hookSpecificOutput.updatedInput.command) "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'; cargo check"
}
finally {
    $env:RTK_CODEX_RTK_EXE = $savedRtkOverride
}

Write-Host 'RTK invocation count tests'
$invocationFixture = Join-Path $testRoot "invocation path's"
[System.IO.Directory]::CreateDirectory($invocationFixture) | Out-Null
$fakeRtkPath = Join-Path $invocationFixture 'fake-rtk.ps1'
$fakeCountPath = Join-Path $invocationFixture 'count.txt'
$fakeInputPath = Join-Path $invocationFixture 'input.txt'
$fakeScript = @"
param([string]`$Subcommand, [string]`$Command)
[IO.File]::AppendAllText('$($fakeCountPath.Replace("'", "''"))', "call``n")
[IO.File]::WriteAllText('$($fakeInputPath.Replace("'", "''"))', `$Command)
`$rewritten = `$Command.Replace('git status', 'rtk git status').Replace('cargo check', 'rtk cargo check')
Write-Output `$rewritten
`$global:LASTEXITCODE = 0
"@
[System.IO.File]::WriteAllText($fakeRtkPath, $fakeScript)

function Reset-FakeRtkInvocation {
    [System.IO.File]::WriteAllText($fakeCountPath, '')
    [System.IO.File]::WriteAllText($fakeInputPath, '')
}

function Get-FakeRtkInvocationCount {
    return [System.IO.File]::ReadAllLines($fakeCountPath).Count
}

$savedRtkOverride = $env:RTK_CODEX_RTK_EXE
try {
    $env:RTK_CODEX_RTK_EXE = $fakeRtkPath

    Reset-FakeRtkInvocation
    Assert-Unchanged 'No delegate skips RTK invocation' "Get-Content 'Cargo.toml'"
    Assert-Equal 'No delegate RTK invocation count' (Get-FakeRtkInvocationCount) 0

    Reset-FakeRtkInvocation
    Assert-Rewrite 'Local rewrite skips RTK invocation' "Select-String -Path 'Cargo.toml' -Pattern 'workspace'" "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
    Assert-Equal 'Local rewrite RTK invocation count' (Get-FakeRtkInvocationCount) 0

    Reset-FakeRtkInvocation
    Assert-Unchanged 'PowerShell cmdlet skips RTK invocation' "Write-Output 'hello'"
    Assert-Equal 'PowerShell cmdlet RTK invocation count' (Get-FakeRtkInvocationCount) 0

    Reset-FakeRtkInvocation
    Assert-Unchanged 'Prefixed RTK cat skips registry rewrite' 'rtk cat README.md'
    Assert-Unchanged 'Prefixed RTK git skips registry rewrite' 'rtk git status'
    Assert-Unchanged 'Explicit RTK read skips registry rewrite' 'rtk read README.md'
    Assert-Equal 'Prefixed RTK commands use zero registry invocations' (Get-FakeRtkInvocationCount) 0

    Reset-FakeRtkInvocation
    Assert-Rewrite 'Single delegate uses direct RTK invocation' 'git status' 'rtk git status'
    Assert-Equal 'Single delegate RTK invocation count' (Get-FakeRtkInvocationCount) 1
    Assert-True 'Single delegate omits batch markers' (-not [System.IO.File]::ReadAllText($fakeInputPath).Contains('codexrtkbatch_'))

    Reset-FakeRtkInvocation
    Assert-Rewrite 'Multiple delegates use one RTK invocation' 'git status; cargo check' 'rtk git status; rtk cargo check'
    Assert-Equal 'Multiple delegates RTK invocation count' (Get-FakeRtkInvocationCount) 1
    $capturedWholeSource = [System.IO.File]::ReadAllText($fakeInputPath)
    Assert-Equal 'Pure delegate plan sends original source once' $capturedWholeSource 'git status; cargo check'
    Assert-True 'Pure delegate plan omits batch markers' (-not $capturedWholeSource.Contains('codexrtkbatch_'))

    Reset-FakeRtkInvocation
    $objectPipeline = "Get-ChildItem -LiteralPath 'src' -File | Select-Object Name,Length | Format-Table -AutoSize"
    Assert-Unchanged 'PowerShell object pipeline is preserved locally' $objectPipeline
    Assert-Equal 'PowerShell object pipeline skips RTK invocation' (Get-FakeRtkInvocationCount) 0

    Reset-FakeRtkInvocation
    $mixedPlanSource = "Get-Content 'Cargo.toml'; git status; head -10 'Cargo.toml'; Select-String -Path 'Cargo.toml' -Pattern 'workspace'; cargo check"
    $mixedPlanExpected = "Get-Content 'Cargo.toml'; rtk git status; head -10 'Cargo.toml'; rtk rg -n -i -e 'workspace' -- 'Cargo.toml'; rtk cargo check"
    Assert-Rewrite 'Batch includes delegate copies only' $mixedPlanSource $mixedPlanExpected
    Assert-Equal 'Mixed plan uses one RTK invocation' (Get-FakeRtkInvocationCount) 1
    $mixedPlanBatch = [System.IO.File]::ReadAllText($fakeInputPath)
    Assert-True 'Batch excludes preserved Get-Content' (-not $mixedPlanBatch.Contains('Get-Content'))
    Assert-True 'Batch excludes preserved head' (-not $mixedPlanBatch.Contains('head -10'))
    Assert-True 'Batch excludes local Select-String' (-not $mixedPlanBatch.Contains('Select-String'))
    $mixedMarkers = @([regex]::Matches($mixedPlanBatch, 'codexrtkbatch_[0-9a-f]{32}_slot_\d{6}') | ForEach-Object Value)
    Assert-Equal 'Mixed delegate plan uses N plus one markers' $mixedMarkers.Count 3

    Reset-FakeRtkInvocation
    $boundOutput = New-TestPayload 'git status' |
        & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath -RtkPath $fakeRtkPath
    Assert-Equal 'Bound RTK subprocess exits zero' $LASTEXITCODE 0
    $boundJson = $boundOutput | ConvertFrom-Json
    $escapedFakeRtkPath = $fakeRtkPath.Replace("'", "''")
    Assert-Equal 'Bound RTK path qualifies generated command' $boundJson.hookSpecificOutput.updatedInput.command "& '$escapedFakeRtkPath' git status"

    Reset-FakeRtkInvocation
    $prefixedBoundSource = 'rtk cat README.md; rtk git status; rtk read README.md'
    $prefixedBoundOutput = New-TestPayload $prefixedBoundSource |
        & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath -RtkPath $fakeRtkPath
    Assert-Equal 'Bound prefixed RTK subprocess exits zero' $LASTEXITCODE 0
    $prefixedBoundJson = $prefixedBoundOutput | ConvertFrom-Json
    $prefixedBoundExpected = "& '$escapedFakeRtkPath' cat README.md; & '$escapedFakeRtkPath' git status; & '$escapedFakeRtkPath' read README.md"
    Assert-Equal 'Absolute mode qualifies prefixed cat git and read' $prefixedBoundJson.hookSpecificOutput.updatedInput.command $prefixedBoundExpected
    Assert-Equal 'Absolute prefixed commands skip registry rewrite' (Get-FakeRtkInvocationCount) 0

    Reset-FakeRtkInvocation
    $mixedBoundSource = 'rtk cat README.md; git status; rtk read README.md'
    $mixedBoundOutput = New-TestPayload $mixedBoundSource |
        & pwsh -NoLogo -NoProfile -NonInteractive -File $hookPath -RtkPath $fakeRtkPath
    Assert-Equal 'Bound mixed RTK subprocess exits zero' $LASTEXITCODE 0
    $mixedBoundJson = $mixedBoundOutput | ConvertFrom-Json
    $mixedBoundExpected = "& '$escapedFakeRtkPath' cat README.md; & '$escapedFakeRtkPath' git status; & '$escapedFakeRtkPath' read README.md"
    Assert-Equal 'Absolute mode binds prefixed and generated RTK commands together' $mixedBoundJson.hookSpecificOutput.updatedInput.command $mixedBoundExpected
    Assert-Equal 'Bound mixed command delegates only raw git' (Get-FakeRtkInvocationCount) 1

    Reset-FakeRtkInvocation
    $largePayload = 'x' * (512KB)
    $oversizedDelegates = @(
        [pscustomobject]@{ Start = 0; End = $largePayload.Length; Original = "command-a-$largePayload" }
        [pscustomobject]@{ Start = $largePayload.Length + 1; End = (2 * $largePayload.Length) + 1; Original = "command-b-$largePayload" }
    )
    Invoke-RtkBatchRewrite 'oversized batch source' $oversizedDelegates | Out-Null
    Assert-Equal 'Oversized synthetic batch skips RTK invocation' (Get-FakeRtkInvocationCount) 0
}
finally {
    $env:RTK_CODEX_RTK_EXE = $savedRtkOverride
}

Write-Host 'Generated command smoke tests'
$fixture = Join-Path $testRoot 'fixtures'
[System.IO.Directory]::CreateDirectory($fixture) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $fixture 'nested')) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $fixture 'alpha file.txt'), "alpha`nneedle`nomega`n")
[System.IO.File]::WriteAllText((Join-Path $fixture 'nested\beta.rs'), "fn needle() {}`n")
[System.IO.File]::WriteAllText((Join-Path $fixture "team's 说明.txt"), "quoted path`n")
$fixtureQuoted = $fixture.Replace("'", "''")

$readSource = "Get-Content -Raw '$fixtureQuoted\alpha file.txt'"
$readCommand = Convert-PowerShellNativeCommands $readSource
$readOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command $readCommand
Assert-Equal 'Native Get-Content remains unchanged' $readCommand $readSource
Assert-Equal 'Native Get-Content executes' $LASTEXITCODE 0
Assert-True 'Native Get-Content returns content' (($readOutput -join "`n").Contains('needle'))

$explicitReadOutput = & rtk read (Join-Path $fixture 'alpha file.txt') -l minimal
Assert-Equal 'Explicit rtk read executes' $LASTEXITCODE 0
Assert-True 'Explicit rtk read returns content' (($explicitReadOutput -join "`n").Contains('needle'))

$quotedPathSource = "Get-Content -Raw '$fixtureQuoted\team''s 说明.txt'"
$quotedPathCommand = Convert-PowerShellNativeCommands $quotedPathSource
$quotedPathOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command $quotedPathCommand
Assert-Equal 'Native quoted Unicode path remains unchanged' $quotedPathCommand $quotedPathSource
Assert-Equal 'Native quoted Unicode path executes' $LASTEXITCODE 0
Assert-True 'Native quoted Unicode path returns content' (($quotedPathOutput -join "`n").Contains('quoted path'))

$searchSource = "Select-String -Path '$fixtureQuoted\alpha file.txt' -Pattern 'needle'"
$searchCommand = Convert-PowerShellNativeCommands $searchSource
$searchOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command $searchCommand
Assert-Equal 'Generated rtk rg executes' $LASTEXITCODE 0
Assert-True 'Generated rtk rg returns match' (($searchOutput -join "`n").Contains('needle'))

$pcreSource = "Select-String -Path '$fixtureQuoted\alpha file.txt' -Pattern '(?<=nee)dle'"
$pcreCommand = Convert-PowerShellNativeCommands $pcreSource
$pcreOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command $pcreCommand
Assert-Equal 'Generated PCRE2 search executes' $LASTEXITCODE 0
Assert-True 'Generated PCRE2 search returns match' (($pcreOutput -join "`n").Contains('needle'))

$findSource = "Get-ChildItem -Path '$fixtureQuoted' -Recurse -Filter '*.rs' -File"
$findCommand = Convert-PowerShellNativeCommands $findSource
$findOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command $findCommand
Assert-Equal 'Generated rtk find executes' $LASTEXITCODE 0
Assert-True 'Generated rtk find returns file' (($findOutput -join "`n").Contains('beta.rs'))

$listSource = "Get-ChildItem '$fixtureQuoted'"
$listCommand = Convert-PowerShellNativeCommands $listSource
$listOutput = & pwsh -NoLogo -NoProfile -NonInteractive -Command $listCommand
Assert-Equal 'Generated rtk ls executes' $LASTEXITCODE 0
Assert-True 'Generated rtk ls returns entry' (($listOutput -join "`n").Contains('alpha file.txt'))

Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
if ([IO.Directory]::Exists($testRoot)) {
    [IO.Directory]::Delete($testRoot, $true)
}
exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
