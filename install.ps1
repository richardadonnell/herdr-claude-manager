<#
.SYNOPSIS
  Installs or removes herdrm, the Herdr + Claude Code workspace manager.

.DESCRIPTION
  Copies herdrm.ps1 into an install root, writes a bin\herdrm.cmd shim beside
  it, appends that bin directory to your User PATH, and adds a herdrm function
  to your all-hosts PowerShell profile.

  Two modes, picked by testing for a sibling herdrm.ps1 next to this file:
    Local  - install.ps1 sits in a clone beside herdrm.ps1, so it copies that file.
    Remote - you piped this script from the web, so it downloads herdrm.ps1 from
             the repo's main branch.

  Every step is idempotent. A second run replaces the same files, leaves the
  PATH entry alone if it already exists, and rewrites the profile block in
  place instead of appending a second copy.

  Because 'irm ... | iex' cannot pass arguments, running with zero arguments
  performs the full default install.

.PARAMETER InstallRoot
  Directory that receives herdrm.ps1 and bin\herdrm.cmd.
  Defaults to $env:LOCALAPPDATA\Programs\herdrm.

.PARAMETER NoPath
  Skips the User PATH change. herdrm then runs through the profile function or
  by full path only.

.PARAMETER SkipProfile
  Skips the profile function.

  Name collision, resolved: pwsh owns -NoProfile. In 'pwsh -NoProfile -File
  install.ps1' the switch belongs to pwsh and never reaches this script, which
  would silently install the profile function you meant to skip. So the
  canonical switch here is -SkipProfile, with NoProfile kept as an alias for
  the arguments that do reach the script (anything after -File, and anything
  passed when you dot-source or call the script directly).

.PARAMETER Uninstall
  Reverses all three install steps: deletes the install root, strips the bin
  directory from the User PATH, and removes the profile block including its
  markers. Safe to run when nothing is installed, and safe to run twice.

  -NoPath and -SkipProfile govern installing only. Uninstall always reverses
  all three steps, and each one no-ops when there is nothing to undo.

.PARAMETER Force
  Proceeds past two safety stops. On install, repairs a profile that has an
  opening herdrm marker with no closing marker by replacing everything from
  that marker to the end of the file. On uninstall, deletes the install root
  even when it holds files this installer did not create.

.EXAMPLE
  irm https://raw.githubusercontent.com/richardadonnell/herdr-claude-manager/main/install.ps1 | iex

  Downloads herdrm.ps1 and performs the full default install.

.EXAMPLE
  ./install.ps1

  Installs from a clone, copying the herdrm.ps1 sitting next to this script.

.EXAMPLE
  ./install.ps1 -InstallRoot 'D:\tools\herdrm' -NoPath -SkipProfile

  Drops the files under D:\tools\herdrm and touches nothing else.

.EXAMPLE
  ./install.ps1 -Uninstall

  Removes the install root, the PATH entry, and the profile block.
#>
param(
    [string]$InstallRoot = "$env:LOCALAPPDATA\Programs\herdrm",
    [switch]$NoPath,
    [Alias('NoProfile')]
    [switch]$SkipProfile,
    [switch]$Uninstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- constants --------------------------------------------------------------

$ScriptName  = 'herdrm.ps1'
$ShimName    = 'herdrm.cmd'
$SourceUrl   = 'https://raw.githubusercontent.com/richardadonnell/herdr-claude-manager/main/herdrm.ps1'
$StartMarker = '# >>> herdrm >>>'
$EndMarker   = '# <<< herdrm <<<'
$DefaultRoot = Join-Path $env:LOCALAPPDATA 'Programs\herdrm'

# --- output helpers ---------------------------------------------------------

function Write-Status {
    # Installer progress belongs on the console, not in the success stream, so a
    # caller piping this script never swallows it. Write-Host is the pragmatic
    # tool for that and the rule is suppressed here only.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'User-facing installer status must reach the console regardless of stream redirection.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$Color = 'Gray'
    )
    Write-Host $Message -ForegroundColor $Color
}

function Resolve-FullPath {
    # Absolute path for a value that need not exist yet, honouring the caller's
    # PowerShell location rather than the process working directory.
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-SamePath {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    $Left.Trim().TrimEnd('\', '/') -ieq $Right.Trim().TrimEnd('\', '/')
}

# --- preflight --------------------------------------------------------------

function Test-Prerequisite {
    # Hard-fails on PowerShell 5.1 because herdrm.ps1 declares #Requires -Version 7.0.
    # herdr and claude are runtime dependencies, so a miss warns and continues.
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw ("herdrm needs PowerShell 7.0 or newer. This session is $($PSVersionTable.PSVersion). " +
            'Install PowerShell 7, open pwsh, and run this installer again.')
    }

    foreach ($dep in 'herdr', 'claude') {
        if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
            Write-Status "  warning: '$dep' is not on PATH. Install it before running herdrm." 'Yellow'
        }
    }
}

# --- User PATH --------------------------------------------------------------

function Add-UserPathEntry {
    # Appends to the User PATH with [Environment]::SetEnvironmentVariable.
    # setx is never used: it truncates at 2047 characters and would shred a
    # long PATH. Returns $true when it changed the stored value.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $parts = @()
    if (-not [string]::IsNullOrEmpty($current)) { $parts = $current -split ';' }
    foreach ($p in $parts) {
        if (Test-SamePath $p $Directory) { return $false }
    }

    if (-not $PSCmdlet.ShouldProcess("User PATH", "append '$Directory'")) { return $false }

    if ([string]::IsNullOrEmpty($current)) { $new = $Directory }
    elseif ($current.EndsWith(';')) { $new = $current + $Directory }
    else { $new = $current + ';' + $Directory }

    [Environment]::SetEnvironmentVariable('PATH', $new, 'User')
    return $true
}

function Remove-UserPathEntry {
    # Drops every entry matching $Directory and rejoins the rest verbatim, so
    # unrelated entries keep their order, casing, and any empty slots.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ([string]::IsNullOrEmpty($current)) { return $false }

    $parts = $current -split ';'
    $kept = @($parts | Where-Object { -not (Test-SamePath $_ $Directory) })
    if ($kept.Count -eq $parts.Count) { return $false }

    if (-not $PSCmdlet.ShouldProcess("User PATH", "remove '$Directory'")) { return $false }

    [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
    return $true
}

function Sync-SessionPath {
    # Mirrors the User PATH edit into this process so the command works now.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [switch]$Remove
    )

    $parts = @()
    if (-not [string]::IsNullOrEmpty($env:PATH)) { $parts = $env:PATH -split ';' }
    $present = $false
    foreach ($p in $parts) {
        if (Test-SamePath $p $Directory) { $present = $true; break }
    }

    if ($Remove) {
        if (-not $present) { return $false }
        $env:PATH = (@($parts | Where-Object { -not (Test-SamePath $_ $Directory) }) -join ';')
        return $true
    }

    if ($present) { return $false }
    if ([string]::IsNullOrEmpty($env:PATH)) { $env:PATH = $Directory } else { $env:PATH = "$env:PATH;$Directory" }
    return $true
}

# --- profile block ----------------------------------------------------------

function Get-ProfileLine {
    # The leading comma keeps an empty or single-line result an array. Without
    # it PowerShell unrolls @() to $null on the way out and the callers below
    # get nothing instead of an empty collection.
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    return , @(Get-Content -LiteralPath $Path)
}

function Find-MarkerRange {
    # Returns @{ Start = <int>; End = <int> }, either index -1 when absent.
    # $Line is deliberately not Mandatory: an empty profile is normal, and a
    # mandatory [string[]] rejects an empty array at bind time.
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line)

    $start = -1
    $end = -1
    if ($null -eq $Line) { return @{ Start = $start; End = $end } }
    for ($i = 0; $i -lt $Line.Count; $i++) {
        $trimmed = $Line[$i].Trim()
        if ($start -lt 0 -and $trimmed -eq $StartMarker) { $start = $i; continue }
        if ($start -ge 0 -and $trimmed -eq $EndMarker) { $end = $i; break }
    }
    return @{ Start = $start; End = $end }
}

function Write-ProfileBlock {
    # Replaces the marked region when both markers exist, otherwise appends the
    # block. Returns $true when the file changed.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Block,
        [switch]$RepairPartial
    )

    # Plain assignment. Get-ProfileLine already returns a wrapped array, so an
    # extra @(...) here would nest it one level deeper.
    $lines = Get-ProfileLine -Path $Path
    $range = Find-MarkerRange -Line $lines
    $start = [int]$range.Start
    $end = [int]$range.End

    if ($start -ge 0 -and $end -lt 0) {
        if (-not $RepairPartial) {
            throw ("$Path has an opening '$StartMarker' on line $($start + 1) with no closing " +
                "'$EndMarker'. Fix the profile by hand, or re-run with -Force to replace everything " +
                'from that marker to the end of the file.')
        }
        $end = $lines.Count - 1
        Write-Status "  repairing an unterminated herdrm block from line $($start + 1) to end of file" 'Yellow'
    }

    $out = [System.Collections.Generic.List[string]]::new()
    if ($start -ge 0) {
        for ($i = 0; $i -lt $start; $i++) { $out.Add($lines[$i]) }
        foreach ($b in $Block) { $out.Add($b) }
        for ($i = $end + 1; $i -lt $lines.Count; $i++) { $out.Add($lines[$i]) }
    }
    else {
        foreach ($l in $lines) { $out.Add($l) }
        if ($out.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { $out.Add('') }
        foreach ($b in $Block) { $out.Add($b) }
    }

    if (($out -join "`n") -eq ($lines -join "`n")) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, 'write herdrm profile block')) { return $false }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    Set-Content -LiteralPath $Path -Value $out -Encoding utf8
    return $true
}

function Remove-ProfileBlock {
    # Strips the marked region, markers included. A lone opening marker loses
    # just that line, so stray text below it survives.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $lines = Get-ProfileLine -Path $Path
    if ($lines.Count -eq 0) { return $false }

    $range = Find-MarkerRange -Line $lines
    $start = [int]$range.Start
    $end = [int]$range.End
    if ($start -lt 0) { return $false }

    if ($end -lt 0) {
        Write-Status "  found '$StartMarker' with no closing marker; removing that line only" 'Yellow'
        $end = $start
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'remove herdrm profile block')) { return $false }

    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $start; $i++) { $out.Add($lines[$i]) }
    for ($i = $end + 1; $i -lt $lines.Count; $i++) { $out.Add($lines[$i]) }
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { $out.RemoveAt($out.Count - 1) }

    Set-Content -LiteralPath $Path -Value $out -Encoding utf8
    return $true
}

# --- payload ----------------------------------------------------------------

function Get-ShimText {
    [OutputType([string])]
    param()
    # %~dp0 anchors the script relative to the shim. No cd, so the caller's
    # working directory survives, which herdrm.ps1 relies on for new panes.
    # pwsh, never powershell.exe: herdrm.ps1 declares #Requires -Version 7.0.
    return @'
@echo off
setlocal
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo herdrm requires PowerShell 7. Install pwsh, then try again.
  exit /b 9009
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\herdrm.ps1" %*
exit /b %ERRORLEVEL%
'@
}

function Confirm-PowerShellFile {
    # Guards against a truncated copy or a proxy serving something other than
    # the script. Parse errors mean the payload is not usable.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -eq 0) { throw "Downloaded or copied file is empty: $Path" }

    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "The herdrm.ps1 payload does not parse as PowerShell ($($parseErrors.Count) error(s)): $($parseErrors[0].Message)"
    }
}

# --- main -------------------------------------------------------------------

Test-Prerequisite

$InstallRoot = Resolve-FullPath $InstallRoot
$binDir      = Join-Path $InstallRoot 'bin'
$scriptDest  = Join-Path $InstallRoot $ScriptName
$shimDest    = Join-Path $binDir $ShimName
$profilePath = $PROFILE.CurrentUserAllHosts
$summary     = [System.Collections.Generic.List[string]]::new()

if ($Uninstall) {
    Write-Status ''
    Write-Status "Removing herdrm from $InstallRoot" 'Cyan'

    if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
        $known = @($scriptDest, $shimDest, $binDir, $InstallRoot)
        $extra = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force |
                Where-Object { $p = $_.FullName; -not ($known | Where-Object { Test-SamePath $p $_ }) })

        if ($extra.Count -gt 0 -and -not $Force) {
            Write-Status "  $InstallRoot holds $($extra.Count) file(s) this installer did not create." 'Yellow'
            foreach ($f in $scriptDest, $shimDest) {
                if (Test-Path -LiteralPath $f -PathType Leaf) {
                    Remove-Item -LiteralPath $f -Force
                    $summary.Add("removed $f")
                }
            }
            $summary.Add("kept $InstallRoot (re-run with -Force to delete it outright)")
        }
        else {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
            $summary.Add("removed $InstallRoot")
        }
    }
    else {
        $summary.Add("no install root at $InstallRoot")
    }

    if (Remove-UserPathEntry -Directory $binDir) { $summary.Add("removed $binDir from the User PATH") }
    else { $summary.Add("User PATH had no entry for $binDir") }
    $null = Sync-SessionPath -Directory $binDir -Remove

    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        if (Remove-ProfileBlock -Path $profilePath) { $summary.Add("removed the herdrm block from $profilePath") }
        else { $summary.Add("no herdrm block in $profilePath") }
    }
    else {
        $summary.Add("no profile at $profilePath")
    }

    Write-Status ''
    Write-Status 'Uninstalled.' 'Green'
    foreach ($s in $summary) { Write-Status "  $s" }
    Write-Status ''
    Write-Status 'Open a new terminal to pick up the PATH change.' 'Cyan'
    return
}

Write-Status ''
Write-Status "Installing herdrm to $InstallRoot" 'Cyan'

# Mode detection: a sibling herdrm.ps1 means a clone, anything else means the
# script arrived over the wire, where $PSScriptRoot is empty.
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir) -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
$localSource = ''
if (-not [string]::IsNullOrEmpty($scriptDir)) { $localSource = Join-Path $scriptDir $ScriptName }

$tempDownload = ''
try {
    if ($localSource -and (Test-Path -LiteralPath $localSource -PathType Leaf)) {
        $stagedSource = $localSource
        Write-Status "  source: local clone ($localSource)"
    }
    else {
        $tempDownload = Join-Path ([System.IO.Path]::GetTempPath()) ("herdrm-{0}.ps1" -f [guid]::NewGuid())
        Write-Status "  source: $SourceUrl"
        try {
            Invoke-WebRequest -Uri $SourceUrl -OutFile $tempDownload
        }
        catch {
            throw ("Could not download herdrm.ps1 from $SourceUrl - $($_.Exception.Message). " +
                'Check your network and proxy, or clone the repository and run install.ps1 from the clone.')
        }
        $stagedSource = $tempDownload
    }

    Confirm-PowerShellFile -Path $stagedSource

    $null = New-Item -ItemType Directory -Path $binDir -Force
    Copy-Item -LiteralPath $stagedSource -Destination $scriptDest -Force
    $summary.Add("wrote $scriptDest")
}
finally {
    if ($tempDownload -and (Test-Path -LiteralPath $tempDownload -PathType Leaf)) {
        Remove-Item -LiteralPath $tempDownload -Force -ErrorAction SilentlyContinue
    }
}

Set-Content -LiteralPath $shimDest -Value (Get-ShimText) -Encoding ascii
$summary.Add("wrote $shimDest")

if ($NoPath) {
    $summary.Add('skipped the PATH change (-NoPath)')
}
else {
    if (Add-UserPathEntry -Directory $binDir) { $summary.Add("appended $binDir to the User PATH") }
    else { $summary.Add("User PATH already contains $binDir") }
    $null = Sync-SessionPath -Directory $binDir
}

if ($SkipProfile) {
    $summary.Add('skipped the profile function (-SkipProfile)')
}
else {
    # The contract fixes the block text for the default root. A custom root
    # gets the same shape with its own literal path, so the function points at
    # the script that was actually installed.
    if (Test-SamePath $InstallRoot $DefaultRoot) {
        # Double quotes on purpose: $env:LOCALAPPDATA has to expand when the
        # profile loads, so the block stays valid across machines and accounts.
        $funcLine = 'function herdrm { & "$env:LOCALAPPDATA\Programs\herdrm\herdrm.ps1" @args }'
    }
    else {
        # Single quotes for a custom root. A path holding a $ would expand at
        # profile-load time and one holding a " would break the line outright,
        # so the path goes in verbatim with its own quotes doubled.
        $funcLine = "function herdrm { & '" + $scriptDest.Replace("'", "''") + "' @args }"
    }
    $block = @(
        $StartMarker,
        $funcLine,
        $EndMarker
    )
    if (Write-ProfileBlock -Path $profilePath -Block $block -RepairPartial:$Force) {
        $summary.Add("wrote the herdrm block to $profilePath")
    }
    else {
        $summary.Add("$profilePath already had the current herdrm block")
    }
}

Write-Status ''
Write-Status 'Installed.' 'Green'
foreach ($s in $summary) { Write-Status "  $s" }
Write-Status ''
Write-Status 'Open a new terminal, then run: herdrm' 'Cyan'
Write-Status 'herdrm needs Herdr on PATH with its server running, plus claude for Claude Code panes.'
