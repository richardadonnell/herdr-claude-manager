# Contributing

## Before you open a PR

Run the self-test against a live Herdr server:

```powershell
pwsh -File .\herdrm.ps1 -SelfTest
```

It builds a throwaway workspace, checks the pane count, exercises the herdr command paths, and closes the workspace afterward. Try a second count if your change touches the tiler:

```powershell
pwsh -File .\herdrm.ps1 -SelfTest -SelfTestCount 9
```

CI runs PSScriptAnalyzer on every push and pull request. Fix what it reports before asking for a review.

## Constraints

- The script targets **PowerShell 7.0+**. It declares `#Requires -Version 7.0`, and Windows PowerShell 5.1 cannot run it.
- Keep `herdrm.ps1` a single file with no external module dependencies. Users install it by copying one script, so anything that needs `Install-Module` breaks that.
