@{
    # Rules we intentionally skip - keep this list small and justified.
    ExcludeRules = @(
        # CLI tool prints to stdout with colors; Write-Host is the right choice.
        'PSAvoidUsingWriteHost',

        # Renaming Check-PHPVMUpdate / Ext-* / etc. would break user shims and
        # docs. Public surface is stable; verb purity is not worth the churn.
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',

        # Internal helpers; not exported, no -WhatIf surface needed.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Severity = @('Warning', 'Error')
}
