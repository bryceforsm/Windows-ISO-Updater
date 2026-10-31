@{
    ExcludeRules = @(
        # Console output is the interface of these scripts, and the colors carry meaning.
        'PSAvoidUsingWriteHost',
        # Empty catches here are deliberate and most carry a comment saying why.
        'PSAvoidUsingEmptyCatchBlock',
        # Names such as Get-UpdateFileRecords describe a set, and renaming them would churn the tester.
        'PSUseSingularNouns',
        # None of these functions are exposed as cmdlets for -WhatIf callers.
        'PSUseShouldProcessForStateChangingFunctions',
        # Microsoft puts SHA-1 in catalog file names, so it is the only hash there is to compare against.
        'PSAvoidUsingBrokenHashAlgorithms',
        # False positives on parameters that are used through a script block.
        'PSReviewUnusedParameter'
    )
    Rules        = @{
        # Windows PowerShell 5.1 is the target, so PowerShell 7 syntax has to fail here.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
