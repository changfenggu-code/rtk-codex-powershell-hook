@{
    Severity = @('Error', 'Warning')

    # These scripts are applications with internal helpers, not exported
    # PowerShell modules. CLI status output is intentional, New-* helpers are
    # pure constructors, and the repository standard is UTF-8 without BOM.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseApprovedVerbs',
        'PSUseBOMForUnicodeEncodedFile',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns'
    )
}
