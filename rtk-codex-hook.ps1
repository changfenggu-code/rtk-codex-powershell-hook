[CmdletBinding()]
param(
    [switch]$LibraryMode,

    [string]$RtkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaxInputBytes = 1MB
$script:LibraryMode = $LibraryMode.IsPresent
$script:ConfiguredRtkPath = $RtkPath

function New-StaticValueResult {
    param(
        [bool]$Success,
        [object[]]$Values = @()
    )

    [pscustomobject]@{
        Success = $Success
        Values = @($Values)
    }
}

function Get-StaticAstValues {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return New-StaticValueResult $true @($Ast.Value)
    }

    if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        if ($Ast.NestedExpressions.Count -ne 0) {
            return New-StaticValueResult $false
        }
        return New-StaticValueResult $true @($Ast.Value)
    }

    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        if ($null -eq $Ast.Value) {
            return New-StaticValueResult $false
        }
        return New-StaticValueResult $true @($Ast.Value)
    }

    if ($Ast -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $values = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Ast.Elements) {
            $item = Get-StaticAstValues $element
            if (-not $item.Success) {
                return New-StaticValueResult $false
            }
            foreach ($value in $item.Values) {
                $values.Add($value)
            }
        }
        return New-StaticValueResult $true $values.ToArray()
    }

    return New-StaticValueResult $false
}

function Read-CommandShape {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command,

        [string[]]$SwitchParameters = @(),
        [string[]]$ValueParameters = @()
    )

    $switchNames = @{}
    foreach ($name in $SwitchParameters) {
        $switchNames[$name.ToLowerInvariant()] = $true
    }

    $valueNames = @{}
    foreach ($name in $ValueParameters) {
        $valueNames[$name.ToLowerInvariant()] = $true
    }

    $parameters = @{}
    $positionals = [System.Collections.Generic.List[object]]::new()
    $elements = @($Command.CommandElements)

    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]

        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $name = $element.ParameterName.ToLowerInvariant()
            if ($parameters.ContainsKey($name)) {
                return [pscustomobject]@{ Success = $false }
            }

            if ($switchNames.ContainsKey($name)) {
                if ($null -ne $element.Argument) {
                    return [pscustomobject]@{ Success = $false }
                }
                $parameters[$name] = @($true)
                continue
            }

            if (-not $valueNames.ContainsKey($name)) {
                return [pscustomobject]@{ Success = $false }
            }

            $argument = $element.Argument
            if ($null -eq $argument) {
                $index++
                if ($index -ge $elements.Count) {
                    return [pscustomobject]@{ Success = $false }
                }
                $argument = $elements[$index]
                if ($argument -is [System.Management.Automation.Language.CommandParameterAst]) {
                    return [pscustomobject]@{ Success = $false }
                }
            }

            $static = Get-StaticAstValues $argument
            if (-not $static.Success -or $static.Values.Count -eq 0) {
                return [pscustomobject]@{ Success = $false }
            }
            $parameters[$name] = @($static.Values)
            continue
        }

        $static = Get-StaticAstValues $element
        if (-not $static.Success -or $static.Values.Count -eq 0) {
            return [pscustomobject]@{ Success = $false }
        }
        $positionals.Add($static)
    }

    [pscustomobject]@{
        Success = $true
        Parameters = $parameters
        Positionals = $positionals.ToArray()
    }
}

function Get-CommandLeafName {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $name = $Command.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    $normalized = $name.ToLowerInvariant()
    if ($normalized.Contains('\')) {
        $parts = $normalized.Split('\')
        $module = $parts[0]
        $leaf = $parts[-1]
        $knownModule =
            ($module -eq 'microsoft.powershell.management' -and $leaf -in @('get-content', 'get-childitem')) -or
            ($module -eq 'microsoft.powershell.utility' -and $leaf -in @('select-string', 'select-object'))
        if (-not $knownModule) {
            return $null
        }
        return $leaf
    }

    return $normalized
}

function ConvertTo-NonNegativeInteger {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or $number -lt 0) {
        return $null
    }
    return $number
}

function Quote-PowerShellArgument {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-BoundRtkCommands {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($script:ConfiguredRtkPath)) {
        return $Source
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        return $null
    }

    $replacement = '& ' + (Quote-PowerShellArgument $script:ConfiguredRtkPath)
    $commands = $ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
            return $false
        }
        $name = $node.GetCommandName()
        return $null -ne $name -and $name.ToLowerInvariant() -in @('rtk', 'rtk.exe')
    }, $true)

    $result = $Source
    foreach ($command in @($commands | Sort-Object { $_.CommandElements[0].Extent.StartOffset } -Descending)) {
        $commandName = $command.CommandElements[0].Extent
        $length = $commandName.EndOffset - $commandName.StartOffset
        $result = $result.Remove($commandName.StartOffset, $length).Insert($commandName.StartOffset, $replacement)
    }
    return $result
}

function Test-SafeFilesystemPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [bool]$AllowWildcard = $false
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains("`0") -or $Path.Contains("`n") -or $Path.Contains("`r")) {
        return $false
    }

    if ($Path.Contains('::')) {
        return $false
    }

    if ($Path -match '^[A-Za-z][A-Za-z0-9+.-]*:' -and $Path -notmatch '^[A-Za-z]:') {
        return $false
    }

    if (-not $AllowWildcard -and [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Path)) {
        return $false
    }

    return $true
}

function Get-FlattenedPositionalValues {
    param(
        [AllowEmptyCollection()]
        [object[]]$Positionals
    )

    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $Positionals) {
        foreach ($value in $group.Values) {
            $values.Add($value)
        }
    }
    return $values.ToArray()
}

function Get-GetContentDescriptor {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $shape = Read-CommandShape $Command @('Raw', 'Force') @('Path', 'LiteralPath', 'TotalCount', 'Tail')
    if (-not $shape.Success) {
        return $null
    }

    $parameters = $shape.Parameters
    if ($parameters.ContainsKey('path') -and $parameters.ContainsKey('literalpath')) {
        return $null
    }
    if (($parameters.ContainsKey('path') -or $parameters.ContainsKey('literalpath')) -and $shape.Positionals.Count -ne 0) {
        return $null
    }
    if ($parameters.ContainsKey('totalcount') -and $parameters.ContainsKey('tail')) {
        return $null
    }
    if ($parameters.ContainsKey('raw') -and ($parameters.ContainsKey('totalcount') -or $parameters.ContainsKey('tail'))) {
        return $null
    }

    $isLiteralPath = $parameters.ContainsKey('literalpath')
    if ($parameters.ContainsKey('path')) {
        $files = @($parameters['path'])
    }
    elseif ($isLiteralPath) {
        $files = @($parameters['literalpath'])
    }
    else {
        $files = @(Get-FlattenedPositionalValues $shape.Positionals)
    }

    if ($files.Count -eq 0) {
        return $null
    }

    $normalizedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $path = [string]$file
        if (-not (Test-SafeFilesystemPath $path $isLiteralPath)) {
            return $null
        }
        $normalizedFiles.Add($path)
    }

    $maxLines = $null
    if ($parameters.ContainsKey('totalcount')) {
        if ($parameters['totalcount'].Count -ne 1) {
            return $null
        }
        $maxLines = ConvertTo-NonNegativeInteger $parameters['totalcount'][0]
        if ($null -eq $maxLines -or $maxLines -eq 0 -or $normalizedFiles.Count -ne 1) {
            return $null
        }
    }

    $tailLines = $null
    if ($parameters.ContainsKey('tail')) {
        if ($parameters['tail'].Count -ne 1) {
            return $null
        }
        $tailLines = ConvertTo-NonNegativeInteger $parameters['tail'][0]
        if ($null -eq $tailLines -or $tailLines -eq 0 -or $normalizedFiles.Count -ne 1) {
            return $null
        }
    }

    [pscustomobject]@{
        Files = $normalizedFiles.ToArray()
        Raw = $parameters.ContainsKey('raw')
        MaxLines = $maxLines
        TailLines = $tailLines
    }
}

function Test-UnsupportedDotNetRegex {
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    if ($Pattern.Contains("`0") -or $Pattern.Contains("`n") -or $Pattern.Contains("`r")) {
        return $true
    }

    # .NET balancing groups have no direct PCRE2 equivalent.
    return $Pattern -match '\(\?<[^>]+-[^>]+>' -or $Pattern -match "\(\?'[^']+-[^']+'"
}

function Test-RequiresPcre2 {
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    return (
        $Pattern -match '\(\?(?:[=!]|<[=!])' -or
        $Pattern -match '\(\?>' -or
        $Pattern -match '\(\?\(' -or
        $Pattern -match '\(\?#' -or
        $Pattern -match '\(\?<[^=!][^>]*>' -or
        $Pattern -match "\\(?:[1-9]|k[<'{])"
    )
}

function Get-SelectStringDescriptor {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command,

        [switch]$AllowPipelineInput
    )

    $shape = Read-CommandShape $Command @(
        'CaseSensitive',
        'SimpleMatch',
        'NotMatch',
        'List',
        'Quiet',
        'AllMatches'
    ) @('Path', 'LiteralPath', 'Pattern', 'Context')
    if (-not $shape.Success) {
        return $null
    }

    $parameters = $shape.Parameters
    if ($parameters.ContainsKey('path') -and $parameters.ContainsKey('literalpath')) {
        return $null
    }
    if ($parameters.ContainsKey('list') -and $parameters.ContainsKey('quiet')) {
        return $null
    }

    $positionals = @($shape.Positionals)
    if ($parameters.ContainsKey('pattern')) {
        $patterns = @($parameters['pattern'])
    }
    else {
        if ($positionals.Count -eq 0) {
            return $null
        }
        $patterns = @($positionals[0].Values)
        if ($positionals.Count -gt 1) {
            $positionals = @($positionals[1..($positionals.Count - 1)])
        }
        else {
            $positionals = @()
        }
    }

    if ($patterns.Count -eq 0) {
        return $null
    }

    $normalizedPatterns = [System.Collections.Generic.List[string]]::new()
    $requiresPcre2 = $false
    foreach ($patternValue in $patterns) {
        $pattern = [string]$patternValue
        if ([string]::IsNullOrEmpty($pattern) -or (Test-UnsupportedDotNetRegex $pattern)) {
            return $null
        }
        if (-not $parameters.ContainsKey('simplematch') -and (Test-RequiresPcre2 $pattern)) {
            $requiresPcre2 = $true
        }
        $normalizedPatterns.Add($pattern)
    }

    $isLiteralPath = $parameters.ContainsKey('literalpath')
    if ($parameters.ContainsKey('path')) {
        if ($positionals.Count -ne 0) {
            return $null
        }
        $paths = @($parameters['path'])
    }
    elseif ($isLiteralPath) {
        if ($positionals.Count -ne 0) {
            return $null
        }
        $paths = @($parameters['literalpath'])
    }
    else {
        $paths = @(Get-FlattenedPositionalValues $positionals)
    }

    if (-not $AllowPipelineInput -and $paths.Count -eq 0) {
        return $null
    }
    if ($AllowPipelineInput -and $paths.Count -ne 0) {
        return $null
    }

    $normalizedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        if (-not (Test-SafeFilesystemPath $path $isLiteralPath)) {
            return $null
        }
        try {
            if (Test-Path -LiteralPath $path -PathType Container) {
                return $null
            }
        }
        catch {
            return $null
        }
        $normalizedPaths.Add($path)
    }

    $beforeContext = $null
    $afterContext = $null
    if ($parameters.ContainsKey('context')) {
        $context = @($parameters['context'])
        if ($context.Count -lt 1 -or $context.Count -gt 2) {
            return $null
        }
        $first = ConvertTo-NonNegativeInteger $context[0]
        if ($null -eq $first) {
            return $null
        }
        if ($context.Count -eq 1) {
            $beforeContext = $first
            $afterContext = $first
        }
        else {
            $second = ConvertTo-NonNegativeInteger $context[1]
            if ($null -eq $second) {
                return $null
            }
            $beforeContext = $first
            $afterContext = $second
        }
    }

    [pscustomobject]@{
        Patterns = $normalizedPatterns.ToArray()
        Paths = $normalizedPaths.ToArray()
        CaseSensitive = $parameters.ContainsKey('casesensitive')
        SimpleMatch = $parameters.ContainsKey('simplematch')
        NotMatch = $parameters.ContainsKey('notmatch')
        List = $parameters.ContainsKey('list')
        Quiet = $parameters.ContainsKey('quiet')
        RequiresPcre2 = $requiresPcre2
        BeforeContext = $beforeContext
        AfterContext = $afterContext
    }
}

function Convert-SelectStringDescriptor {
    param(
        [Parameter(Mandatory)]
        [object]$Descriptor,

        [string[]]$OverridePaths
    )

    if ($null -ne $OverridePaths) {
        $paths = @($OverridePaths)
    }
    else {
        $paths = @($Descriptor.Paths)
    }
    $paths = @($paths)
    if ($paths.Count -eq 0) {
        return $null
    }

    $tokens = [System.Collections.Generic.List[string]]::new()
    $tokens.Add('rtk')
    $tokens.Add('rg')
    $tokens.Add('-n')
    if (-not $Descriptor.CaseSensitive) {
        $tokens.Add('-i')
    }
    if ($Descriptor.SimpleMatch) {
        $tokens.Add('-F')
    }
    elseif ($Descriptor.RequiresPcre2) {
        $tokens.Add('--pcre2')
    }
    if ($Descriptor.NotMatch) {
        $tokens.Add('-v')
    }
    if ($Descriptor.List) {
        $tokens.Add('-l')
    }
    if ($Descriptor.Quiet) {
        $tokens.Add('-q')
    }
    if ($null -ne $Descriptor.BeforeContext) {
        if ($Descriptor.BeforeContext -eq $Descriptor.AfterContext) {
            $tokens.Add('-C')
            $tokens.Add([string]$Descriptor.BeforeContext)
        }
        else {
            $tokens.Add('-B')
            $tokens.Add([string]$Descriptor.BeforeContext)
            $tokens.Add('-A')
            $tokens.Add([string]$Descriptor.AfterContext)
        }
    }
    foreach ($pattern in $Descriptor.Patterns) {
        $tokens.Add('-e')
        $tokens.Add((Quote-PowerShellArgument $pattern))
    }
    $tokens.Add('--')
    foreach ($path in $paths) {
        $tokens.Add((Quote-PowerShellArgument $path))
    }
    return $tokens -join ' '
}

function Convert-SelectStringCommand {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $descriptor = Get-SelectStringDescriptor $Command
    if ($null -eq $descriptor) {
        return $null
    }
    return Convert-SelectStringDescriptor $descriptor
}

function Convert-GetChildItemCommand {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $shape = Read-CommandShape $Command @('Force', 'Recurse', 'File', 'Directory') @(
        'Path',
        'LiteralPath',
        'Filter',
        'Depth'
    )
    if (-not $shape.Success) {
        return $null
    }

    $parameters = $shape.Parameters
    if ($parameters.ContainsKey('path') -and $parameters.ContainsKey('literalpath')) {
        return $null
    }
    if (($parameters.ContainsKey('path') -or $parameters.ContainsKey('literalpath')) -and $shape.Positionals.Count -ne 0) {
        return $null
    }
    if ($parameters.ContainsKey('file') -and $parameters.ContainsKey('directory')) {
        return $null
    }

    $isLiteralPath = $parameters.ContainsKey('literalpath')
    if ($parameters.ContainsKey('path')) {
        $paths = @($parameters['path'])
    }
    elseif ($isLiteralPath) {
        $paths = @($parameters['literalpath'])
    }
    else {
        $paths = @(Get-FlattenedPositionalValues $shape.Positionals)
    }
    if ($paths.Count -eq 0) {
        $paths = @('.')
    }

    $normalizedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($pathValue in $paths) {
        $path = [string]$pathValue
        if (-not (Test-SafeFilesystemPath $path $isLiteralPath) -or $path.StartsWith('-')) {
            return $null
        }
        $normalizedPaths.Add($path)
    }

    $filter = '*'
    if ($parameters.ContainsKey('filter')) {
        if ($parameters['filter'].Count -ne 1) {
            return $null
        }
        $filter = [string]$parameters['filter'][0]
        if ([string]::IsNullOrWhiteSpace($filter) -or $filter.Contains('/') -or $filter.Contains('\') -or $filter.Contains('[')) {
            return $null
        }
    }

    $depth = $null
    if ($parameters.ContainsKey('depth')) {
        if ($parameters['depth'].Count -ne 1) {
            return $null
        }
        $depth = ConvertTo-NonNegativeInteger $parameters['depth'][0]
        if ($null -eq $depth) {
            return $null
        }
    }

    $findMode =
        $parameters.ContainsKey('recurse') -or
        $null -ne $depth -or
        $parameters.ContainsKey('filter') -or
        $parameters.ContainsKey('file') -or
        $parameters.ContainsKey('directory')

    if (-not $findMode) {
        $tokens = [System.Collections.Generic.List[string]]::new()
        $tokens.Add('rtk')
        $tokens.Add('ls')
        if ($parameters.ContainsKey('force')) {
            $tokens.Add('-a')
        }
        foreach ($path in $normalizedPaths) {
            $tokens.Add((Quote-PowerShellArgument $path))
        }
        return $tokens -join ' '
    }

    if ($normalizedPaths.Count -ne 1 -or $parameters.ContainsKey('force')) {
        return $null
    }
    if (-not $parameters.ContainsKey('file') -and -not $parameters.ContainsKey('directory')) {
        return $null
    }

    $tokens = [System.Collections.Generic.List[string]]::new()
    $tokens.Add('rtk')
    $tokens.Add('find')
    $tokens.Add((Quote-PowerShellArgument $normalizedPaths[0]))
    $tokens.Add('-name')
    $tokens.Add((Quote-PowerShellArgument $filter))
    $tokens.Add('-type')
    $tokens.Add($(if ($parameters.ContainsKey('directory')) { 'd' } else { 'f' }))

    if ($null -ne $depth) {
        $tokens.Add('-maxdepth')
        $tokens.Add([string]($depth + 1))
    }
    elseif (-not $parameters.ContainsKey('recurse')) {
        $tokens.Add('-maxdepth')
        $tokens.Add('1')
    }

    return $tokens -join ' '
}

function Test-CommandHasRedirection {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    return $Command.Redirections.Count -ne 0
}

function Test-IsTopLevelPipeline {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.PipelineAst]$Pipeline
    )

    if ($Pipeline.PSObject.Properties.Name -contains 'Background' -and $Pipeline.Background) {
        return $false
    }

    $parent = $Pipeline.Parent
    while ($parent -is [System.Management.Automation.Language.PipelineChainAst]) {
        $parent = $parent.Parent
    }
    return $parent -is [System.Management.Automation.Language.NamedBlockAst]
}

function Convert-SupportedPipeline {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.PipelineAst]$Pipeline
    )

    if ($Pipeline.PipelineElements.Count -ne 2) {
        return $null
    }

    $first = $Pipeline.PipelineElements[0]
    $second = $Pipeline.PipelineElements[1]
    if ($first -isnot [System.Management.Automation.Language.CommandAst] -or $second -isnot [System.Management.Automation.Language.CommandAst]) {
        return $null
    }
    if ((Test-CommandHasRedirection $first) -or (Test-CommandHasRedirection $second)) {
        return $null
    }

    $firstName = Get-CommandLeafName $first
    $secondName = Get-CommandLeafName $second
    if ($firstName -notin @('get-content', 'gc', 'cat', 'type')) {
        return $null
    }

    $content = Get-GetContentDescriptor $first
    if ($null -eq $content -or $content.Files.Count -ne 1 -or $content.Raw -or $null -ne $content.MaxLines -or $null -ne $content.TailLines) {
        return $null
    }

    if ($secondName -in @('select-string', 'sls')) {
        $selection = Get-SelectStringDescriptor $second -AllowPipelineInput
        if ($null -eq $selection) {
            return $null
        }
        return Convert-SelectStringDescriptor $selection @($content.Files[0])
    }

    return $null
}

function Test-PipelineUsesPowerShellObjectSemantics {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.PipelineAst]$Pipeline
    )

    foreach ($element in $Pipeline.PipelineElements) {
        if ($element -isnot [System.Management.Automation.Language.CommandAst]) {
            return $true
        }

        $name = Get-CommandLeafName $element
        if (Test-IsPowerShellObjectCommandName $name) {
            return $true
        }
    }

    return $false
}

function Test-IsPowerShellObjectCommandName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    $objectCommands = @(
        'get-childitem', 'gci', 'dir', 'ls',
        'get-command', 'gcm', 'get-filehash', 'get-item', 'gi',
        'get-member', 'gm', 'get-process', 'ps', 'get-service',
        'get-variable', 'gv',
        'select-object', 'select', 'where-object', 'where', '?',
        'foreach-object', 'foreach', '%', 'sort-object', 'sort',
        'group-object', 'group', 'measure-object', 'measure',
        'tee-object', 'tee', 'out-gridview', 'ogv', 'out-string', 'oss',
        'format-table', 'ft', 'format-list', 'fl',
        'format-wide', 'fw', 'format-custom', 'fc',
        'export-csv', 'export-clixml',
        'convertto-csv', 'convertto-json', 'convertto-html', 'convertto-xml',
        'echo', 'pwd', 'cd', 'pushd', 'popd'
    )

    if ($Name -in $objectCommands) {
        return $true
    }

    # Unknown Verb-Noun commands are conservatively treated as PowerShell
    # cmdlets because their object-stream semantics cannot be reconstructed.
    return $Name -match '^[a-z]+-[a-z][a-z0-9-]*$'
}

function New-RewriteDecision {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Preserve', 'HookRewrite', 'DelegateToRtk')]
        [string]$Disposition,

        [AllowNull()]
        [string]$Replacement = $null
    )

    [pscustomobject]@{
        Disposition = $Disposition
        Replacement = $Replacement
    }
}

function Get-StandaloneRewriteDecision {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $name = Get-CommandLeafName $Command
    switch ($name) {
        { $_ -in @('rtk', 'rtk.exe') } {
            return New-RewriteDecision 'Preserve'
        }
        { $_ -in @('get-content', 'gc', 'cat', 'type', 'head', 'tail') } {
            return New-RewriteDecision 'Preserve'
        }
        { $_ -in @('select-string', 'sls') } {
            $replacement = Convert-SelectStringCommand $Command
            if ($null -eq $replacement) {
                return New-RewriteDecision 'Preserve'
            }
            return New-RewriteDecision 'HookRewrite' $replacement
        }
        { $_ -in @('get-childitem', 'gci', 'dir', 'ls') } {
            $replacement = Convert-GetChildItemCommand $Command
            if ($null -eq $replacement) {
                return New-RewriteDecision 'Preserve'
            }
            return New-RewriteDecision 'HookRewrite' $replacement
        }
        default {
            if (Test-IsPowerShellObjectCommandName $name) {
                return New-RewriteDecision 'Preserve'
            }
            return New-RewriteDecision 'DelegateToRtk'
        }
    }
}

function Convert-PowerShellNativeCommands {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    if (
        -not [string]::IsNullOrWhiteSpace($script:ConfiguredRtkPath) -and
        -not (Test-Path -LiteralPath $script:ConfiguredRtkPath -PathType Leaf)
    ) {
        return $Source
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        return $Source
    }

    $changesCommandResolution = $ast.FindAll({
        param($node)
        if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $true
        }
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
            return $false
        }
        $name = $node.GetCommandName()
        return $null -ne $name -and $name.ToLowerInvariant() -in @(
            'import-module',
            'ipmo',
            'new-alias',
            'nal',
            'set-alias',
            'sal'
        )
    }, $true)
    if ($changesCommandResolution.Count -ne 0) {
        return $Source
    }

    $replacements = [System.Collections.Generic.List[object]]::new()
    $delegates = [System.Collections.Generic.List[object]]::new()
    $coveredExtents = [System.Collections.Generic.List[object]]::new()

    $pipelines = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.PipelineAst]
    }, $true)

    $topLevelPipelines = [System.Collections.Generic.List[object]]::new()

    foreach ($pipeline in $pipelines) {
        if (-not (Test-IsTopLevelPipeline $pipeline)) {
            continue
        }
        $topLevelPipelines.Add($pipeline)
        $replacement = Convert-SupportedPipeline $pipeline
        if ($null -eq $replacement -and $pipeline.PipelineElements.Count -le 1) {
            continue
        }
        $extent = [pscustomobject]@{
            Start = $pipeline.Extent.StartOffset
            End = $pipeline.Extent.EndOffset
        }
        $coveredExtents.Add($extent)
        if ($null -ne $replacement) {
            $replacements.Add([pscustomobject]@{
                Start = $extent.Start
                End = $extent.End
                Text = $replacement
            })
        }
        elseif (Test-PipelineUsesPowerShellObjectSemantics $pipeline) {
            continue
        }
        else {
            $delegates.Add([pscustomobject]@{
                Start = $extent.Start
                End = $extent.End
                Original = $pipeline.Extent.Text
            })
        }
    }

    $commands = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($command in $commands) {
        $insideCoveredExtent = $false
        foreach ($extent in $coveredExtents) {
            if ($command.Extent.StartOffset -ge $extent.Start -and $command.Extent.EndOffset -le $extent.End) {
                $insideCoveredExtent = $true
                break
            }
        }
        if ($insideCoveredExtent -or (Test-CommandHasRedirection $command)) {
            continue
        }

        $pipeline = $command.Parent
        if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst]) {
            continue
        }
        if ($pipeline.PipelineElements.Count -ne 1 -or -not (Test-IsTopLevelPipeline $pipeline)) {
            continue
        }

        $decision = Get-StandaloneRewriteDecision $command
        if ($decision.Disposition -eq 'HookRewrite') {
            if ($decision.Replacement -ne $command.Extent.Text) {
                $replacements.Add([pscustomobject]@{
                    Start = $command.Extent.StartOffset
                    End = $command.Extent.EndOffset
                    Text = $decision.Replacement
                })
            }
        }
        elseif ($decision.Disposition -eq 'DelegateToRtk') {
            $delegates.Add([pscustomobject]@{
                Start = $command.Extent.StartOffset
                End = $command.Extent.EndOffset
                Original = $command.Extent.Text
            })
        }
    }

    $wholeSourceIsDelegated = $delegates.Count -gt 1 -and $topLevelPipelines.Count -eq $delegates.Count
    if ($wholeSourceIsDelegated) {
        foreach ($delegate in $delegates) {
            if (Test-ContainsRtkReadCommand $delegate.Original) {
                $wholeSourceIsDelegated = $false
                break
            }
        }
    }
    if ($wholeSourceIsDelegated) {
        foreach ($pipeline in $topLevelPipelines) {
            $matchingDelegate = @($delegates | Where-Object {
                $_.Start -eq $pipeline.Extent.StartOffset -and $_.End -eq $pipeline.Extent.EndOffset
            })
            if ($matchingDelegate.Count -ne 1) {
                $wholeSourceIsDelegated = $false
                break
            }
        }
    }

    foreach ($replacement in @(Invoke-RtkDelegateRewrites $Source $delegates.ToArray() $wholeSourceIsDelegated)) {
        if ($null -ne $replacement) {
            $replacements.Add($replacement)
        }
    }

    $result = $Source
    foreach ($replacement in ($replacements | Sort-Object Start -Descending)) {
        $length = $replacement.End - $replacement.Start
        $result = $result.Remove($replacement.Start, $length).Insert($replacement.Start, $replacement.Text)
    }
    $boundResult = ConvertTo-BoundRtkCommands $result
    if ($null -eq $boundResult) {
        return $Source
    }
    return $boundResult
}

function Resolve-RtkExecutable {
    if ($script:LibraryMode -and -not [string]::IsNullOrWhiteSpace($env:RTK_CODEX_RTK_EXE)) {
        return $env:RTK_CODEX_RTK_EXE
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ConfiguredRtkPath)) {
        if (Test-Path -LiteralPath $script:ConfiguredRtkPath -PathType Leaf) {
            return $script:ConfiguredRtkPath
        }
        return $null
    }
    $command = Get-Command rtk.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command rtk -ErrorAction SilentlyContinue
    }
    if ($null -eq $command) {
        return $null
    }
    return $command.Source
}

function Invoke-RtkRewriteProcess {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    $rtk = Resolve-RtkExecutable
    if ([string]::IsNullOrWhiteSpace($rtk)) {
        return $null
    }

    try {
        $lines = @(& $rtk rewrite $Command 2>$null)
        $status = $LASTEXITCODE
        if ($status -notin @(0, 3) -or $lines.Count -eq 0) {
            return $null
        }
        $rewritten = ($lines -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($rewritten)) {
            return $null
        }
        return [pscustomobject]@{
            Status = $status
            Text = $rewritten
        }
    }
    catch {
        return $null
    }
}

function Invoke-RtkRewrite {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    $result = Invoke-RtkRewriteProcess $Command
    if (
        $null -eq $result -or
        $result.Text -eq $Command -or
        (Test-ContainsRtkReadCommand $result.Text)
    ) {
        return $null
    }
    return $result.Text
}

function Test-ContainsRtkReadCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        return $true
    }

    $commands = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($command in $commands) {
        $name = Get-CommandLeafName $command
        if ($name -notin @('rtk', 'rtk.exe') -or $command.CommandElements.Count -lt 2) {
            continue
        }
        $subcommand = Get-StaticAstValues $command.CommandElements[1]
        if (
            $subcommand.Success -and
            $subcommand.Values.Count -eq 1 -and
            [string]$subcommand.Values[0] -ieq 'read'
        ) {
            return $true
        }
    }

    return $false
}

function New-RtkBatchId {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $batchId = 'codexrtkbatch_' + [Guid]::NewGuid().ToString('N')
        if ($Source.IndexOf($batchId, [StringComparison]::Ordinal) -lt 0) {
            return $batchId
        }
    }
    return $null
}

function New-RtkBatchMarkers {
    param(
        [Parameter(Mandatory)]
        [string]$BatchId,

        [Parameter(Mandatory)]
        [int]$SlotCount
    )

    $markers = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -le $SlotCount; $index++) {
        $markers.Add("${BatchId}_slot_$('{0:D6}' -f $index)")
    }
    return $markers.ToArray()
}

function New-RtkBatchCommand {
    param(
        [Parameter(Mandatory)]
        [object[]]$Delegates,

        [Parameter(Mandatory)]
        [string[]]$Markers
    )

    if ($Markers.Count -ne $Delegates.Count + 1) {
        return $null
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Delegates.Count; $index++) {
        $parts.Add($Markers[$index])
        $parts.Add([string]$Delegates[$index].Original)
    }
    $parts.Add($Markers[-1])
    return $parts -join '; '
}

function ConvertFrom-RtkBatchRewrite {
    param(
        [Parameter(Mandatory)]
        [string]$Output,

        [Parameter(Mandatory)]
        [string[]]$Markers,

        [Parameter(Mandatory)]
        [object[]]$Delegates
    )

    if ($Markers.Count -ne $Delegates.Count + 1) {
        return
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Output,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        return
    }

    $markerSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($marker in $Markers) {
        if (-not $markerSet.Add($marker)) {
            return
        }
    }

    $markerNodes = @($ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
            return $false
        }
        $name = $node.GetCommandName()
        return $null -ne $name -and $markerSet.Contains($name)
    }, $true) | Sort-Object { $_.Extent.StartOffset })

    if ($markerNodes.Count -ne $Markers.Count) {
        return
    }

    for ($index = 0; $index -lt $markerNodes.Count; $index++) {
        $markerNode = $markerNodes[$index]
        $pipeline = $markerNode.Parent
        if (
            $markerNode.GetCommandName() -cne $Markers[$index] -or
            $markerNode.CommandElements.Count -ne 1 -or
            $markerNode.Redirections.Count -ne 0 -or
            $pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or
            $pipeline.PipelineElements.Count -ne 1 -or
            -not (Test-IsTopLevelPipeline $pipeline)
        ) {
            return
        }
    }

    for ($index = 0; $index -lt $Delegates.Count; $index++) {
        $start = $markerNodes[$index].Extent.EndOffset
        $end = $markerNodes[$index + 1].Extent.StartOffset
        if ($end -le $start) {
            return
        }

        $between = $Output.Substring($start, $end - $start).Trim()
        if (
            $between.Length -lt 2 -or
            $between[0] -ne ';' -or
            $between[$between.Length - 1] -ne ';'
        ) {
            return
        }

        $candidate = $between.Substring(1, $between.Length - 2).Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            return
        }

        $delegate = $Delegates[$index]
        if (
            $candidate -ne $delegate.Original -and
            -not (Test-ContainsRtkReadCommand $candidate)
        ) {
            [pscustomobject]@{
                Start = $delegate.Start
                End = $delegate.End
                Text = $candidate
            }
        }
    }
}

function Invoke-RtkBatchRewrite {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [object[]]$Delegates
    )

    $batchId = New-RtkBatchId $Source
    if ([string]::IsNullOrWhiteSpace($batchId)) {
        return
    }

    $markers = @(New-RtkBatchMarkers $batchId $Delegates.Count)
    $batchCommand = New-RtkBatchCommand $Delegates $markers
    if (
        [string]::IsNullOrWhiteSpace($batchCommand) -or
        [System.Text.Encoding]::UTF8.GetByteCount($batchCommand) -gt $script:MaxInputBytes
    ) {
        return
    }

    $result = Invoke-RtkRewriteProcess $batchCommand
    if ($null -eq $result) {
        return
    }

    ConvertFrom-RtkBatchRewrite $result.Text $markers $Delegates
}

function Invoke-RtkDelegateRewrites {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [AllowEmptyCollection()]
        [object[]]$Delegates,

        [bool]$WholeSourceIsDelegated = $false
    )

    $ordered = @($Delegates | Sort-Object Start)
    if ($ordered.Count -eq 0) {
        return
    }

    if ($ordered.Count -eq 1) {
        $rewritten = Invoke-RtkRewrite $ordered[0].Original
        if ($null -ne $rewritten) {
            [pscustomobject]@{
                Start = $ordered[0].Start
                End = $ordered[0].End
                Text = $rewritten
            }
        }
        return
    }

    if ($WholeSourceIsDelegated) {
        $rewritten = Invoke-RtkRewrite $Source
        if ($null -ne $rewritten) {
            [pscustomobject]@{
                Start = 0
                End = $Source.Length
                Text = $rewritten
            }
        }
        return
    }

    Invoke-RtkBatchRewrite $Source $ordered
}

function New-CodexRewriteJson {
    param(
        [Parameter(Mandatory)]
        [object]$Payload,

        [Parameter(Mandatory)]
        [string]$RewrittenCommand
    )

    $updatedInput = [ordered]@{}
    foreach ($property in $Payload.tool_input.PSObject.Properties) {
        $updatedInput[$property.Name] = $property.Value
    }
    $updatedInput['command'] = $RewrittenCommand

    $response = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'allow'
            permissionDecisionReason = 'Accept RTK input rewrite; Codex still applies its own approval and sandbox policy'
            updatedInput = $updatedInput
        }
    }
    return $response | ConvertTo-Json -Depth 20 -Compress
}

function Invoke-CodexRtkHook {
    param(
        [Parameter(Mandatory)]
        [string]$RawInput
    )

    try {
        if ([string]::IsNullOrWhiteSpace($RawInput)) {
            return $null
        }
        if ([System.Text.Encoding]::UTF8.GetByteCount($RawInput) -gt $script:MaxInputBytes) {
            return $null
        }

        $payload = $RawInput | ConvertFrom-Json
        if (
            $payload.hook_event_name -ne 'PreToolUse' -or
            $payload.tool_name -ne 'Bash' -or
            $null -eq $payload.tool_input -or
            $payload.tool_input.command -isnot [string] -or
            [string]::IsNullOrWhiteSpace($payload.tool_input.command)
        ) {
            return $null
        }

        $original = [string]$payload.tool_input.command
        try {
            $rewritten = Convert-PowerShellNativeCommands $original
        }
        catch {
            $rewritten = $original
        }

        if ([string]::IsNullOrWhiteSpace($rewritten) -or $rewritten -eq $original) {
            return $null
        }
        return New-CodexRewriteJson $payload $rewritten
    }
    catch {
        return $null
    }
}

if (-not $LibraryMode) {
    try {
        $rawInput = [Console]::In.ReadToEnd()
        $output = Invoke-CodexRtkHook $rawInput
        if (-not [string]::IsNullOrEmpty($output)) {
            [Console]::Out.Write($output)
        }
        exit 0
    }
    catch {
        exit 0
    }
}
