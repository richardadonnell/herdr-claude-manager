@{
    # PSScriptAnalyzer config for herdrm: one interactive PowerShell 7 CLI script.
    # Everything ships by default; the exclusions below are conventions written for
    # modules and cmdlets, not for a menu-driven script you run in a terminal.

    ExcludeRules = @(
        # The menu, the colored status lines and the workspace table are the tool's
        # entire UI. Write-Output would pollute the pipeline and drop the colors.
        'PSAvoidUsingWriteHost',

        # Get-Workspaces / Show-Workspaces return collections and read that way.
        # These are script-local helpers, never exported, so the singular-noun
        # cmdlet convention buys nothing here.
        'PSUseSingularNouns',

        # New-ClaudeWorkspace is a script-local helper. -WhatIf / -Confirm plumbing
        # on a function only the menu calls adds surface without adding safety;
        # the destructive path (kill a workspace) already asks for a typed y.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules        = @{
        # The script declares #Requires -Version 7.0. Catch syntax that would not
        # parse there.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.0')
        }
    }
}
