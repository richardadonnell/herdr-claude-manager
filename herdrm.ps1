#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  Interactive manager for Herdr workspaces + Claude Code panes (default server).

.DESCRIPTION
  Run bare -> a menu. Each "workspace" is a screenful of panes in your always-on
  default Herdr server; treat it like a named session. You can:
    - list workspaces
    - start a new workspace with N Claude Code panes (asks how many)
    - resume (focus + attach the TUI) a workspace
    - kill (close) a workspace and its panes

  New panes are tiled into a rough grid for any N, each named "<label>-<n>" as
  both the Herdr pane label and the claude --name. Persistence is free: the
  server keeps running when you detach, so panes/agents survive until killed.

.PARAMETER SelfTest
  Non-interactive: build a workspace of -SelfTestCount panes WITHOUT claude,
  assert the pane count, close it, exit. Sanity-checks the tiler.

.PARAMETER SelfTestCount
  How many panes -SelfTest builds. Default 5.

.EXAMPLE
  herdrm
  Opens the menu.

.EXAMPLE
  herdrm -SelfTest -SelfTestCount 3
  Tiles 3 claude-free panes, asserts the count, closes the workspace.
#>
param(
  [switch]$SelfTest,
  [int]$SelfTestCount = 5
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command herdr -ErrorAction SilentlyContinue)) {
  throw "herdr not found on PATH. Install/launch Herdr first."
}
$serverStatus = (& herdr status server 2>&1) -join "`n"   # join: -match on an array filters lines, not a bool
if ($serverStatus -notmatch 'status:\s*running') {
  throw "Herdr server not running. Launch 'herdr' once (starts the server), then re-run."
}

# --- herdr CLI plumbing -----------------------------------------------------

# Run a herdr command, fail loud on non-zero, return its single JSON line parsed.
function Invoke-Herdr {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$HerdrArgs)
  $raw = & herdr @HerdrArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "herdr $($HerdrArgs -join ' ') failed (exit $LASTEXITCODE): $raw"
  }
  $line = $raw | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
  if (-not $line) { throw "herdr $($HerdrArgs -join ' ') returned no JSON: $raw" }
  return $line | ConvertFrom-Json
}

# Run a herdr command that emits no JSON (pane run, rename, focus, close).
# Fail loud on non-zero exit; ignore output.
function Invoke-HerdrRaw {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$HerdrArgs)
  $raw = & herdr @HerdrArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "herdr $($HerdrArgs -join ' ') failed (exit $LASTEXITCODE): $raw"
  }
}

# Split a pane; --ratio = share the ORIGINAL keeps. Returns the NEW pane id.
function Split-Pane {
  param([string]$Pane, [ValidateSet('right', 'down')][string]$Direction, [double]$Ratio = 0.5)
  (Invoke-Herdr pane split --pane $Pane --direction $Direction --ratio $Ratio --no-focus).result.pane.pane_id
}

# Add one pane: split the largest current pane, direction by aspect (cells ~2:1).
function Add-Pane {
  param([string]$TabPane)   # any live pane in the target tab (root works)
  $panes = (Invoke-Herdr pane layout --pane $TabPane).result.layout.panes
  $big = $panes | Sort-Object { $_.rect.width * $_.rect.height } -Descending | Select-Object -First 1
  $dir = if ($big.rect.width -ge $big.rect.height * 2) { 'right' } else { 'down' }
  Split-Pane $big.pane_id $dir 0.5 | Out-Null
}

# --- workspace operations ---------------------------------------------------

function Get-Workspaces {
  (Invoke-Herdr workspace list).result.workspaces
}

# Create a workspace, tile $Count panes, name + launch claude in each.
function New-ClaudeWorkspace {
  param([string]$Label, [int]$Count, [switch]$NoClaude)
  if ($Count -lt 1) { $Count = 1 }
  # Panes open where you invoked from, not where this script lives.
  $ws = Invoke-Herdr workspace create --label $Label --cwd $PWD.Path --no-focus
  $wsId = $ws.result.workspace.workspace_id
  $root = $ws.result.root_pane.pane_id
  for ($i = 1; $i -lt $Count; $i++) { Add-Pane $root }

  # Name in reading order (top row, left-to-right).
  $ordered = (Invoke-Herdr pane layout --pane $root).result.layout.panes |
    Sort-Object { $_.rect.y }, { $_.rect.x }
  $n = 0
  foreach ($p in $ordered) {
    $n++
    $name = "$Label-$n"
    Invoke-HerdrRaw pane rename $p.pane_id $name
    if (-not $NoClaude) { Invoke-HerdrRaw pane run $p.pane_id "claude -n $name" }
  }
  [pscustomobject]@{ WorkspaceId = $wsId; PaneCount = $ordered.Count }
}

# Focus a workspace; attach the TUI if we're not already inside Herdr.
function Enter-Workspace {
  param([string]$WsId)
  Invoke-HerdrRaw workspace focus $WsId
  if ($env:HERDR_ENV -eq '1') {
    Write-Host "Focused $WsId. You're inside Herdr - switch to it." -ForegroundColor Green
  }
  else {
    Write-Host "Attaching Herdr TUI on $WsId..." -ForegroundColor Green
    & herdr
  }
}

function Show-Workspaces {
  $ws = Get-Workspaces
  if (-not $ws) { Write-Host "No workspaces."; return }
  $ws | Sort-Object number |
    Format-Table @{L = '#'; E = { $_.number } },
    @{L = 'Label'; E = { $_.label } },
    @{L = 'Id'; E = { $_.workspace_id } },
    @{L = 'Tabs'; E = { $_.tab_count } },
    @{L = 'Panes'; E = { $_.pane_count } },
    @{L = 'Agent'; E = { $_.agent_status } },
    @{L = 'Focused'; E = { if ($_.focused) { '*' } else { '' } } } -AutoSize | Out-String | Write-Host
}

# Prompt to pick a workspace by number; returns its object or $null.
function Select-Workspace {
  param([string]$Verb)
  $ws = Get-Workspaces
  if (-not $ws) { Write-Host "No workspaces."; return $null }
  Show-Workspaces
  $sel = Read-Host "$Verb which # (blank to cancel)"
  if (-not $sel) { return $null }
  $hit = $ws | Where-Object { "$($_.number)" -eq $sel.Trim() }
  if (-not $hit) { Write-Host "No workspace #$sel." -ForegroundColor Yellow; return $null }
  $hit
}

# --- self-test (checks the tiler without launching claude) ------------------

if ($SelfTest) {
  $r = New-ClaudeWorkspace -Label '__selftest__' -Count $SelfTestCount -NoClaude
  try {
    if ($r.PaneCount -ne $SelfTestCount) {
      throw "SelfTest FAIL: asked $SelfTestCount panes, got $($r.PaneCount)."
    }
    # Exercise the no-JSON path (pane run) that -NoClaude skips - benign command, no claude.
    $firstPane = (Invoke-Herdr pane list --workspace $r.WorkspaceId).result.panes[0].pane_id
    Invoke-HerdrRaw pane run $firstPane 'Write-Output selftest'
    Write-Host "SelfTest OK: $($r.PaneCount) panes in $($r.WorkspaceId); pane run path clean." -ForegroundColor Green
  }
  finally {
    Invoke-Herdr workspace close $r.WorkspaceId | Out-Null
  }
  return
}

# --- menu -------------------------------------------------------------------

$exit = $false
while (-not $exit) {
  Write-Host ""
  Write-Host "=== Herdr + Claude manager (default server) ===" -ForegroundColor Cyan
  Write-Host " 1) List workspaces"
  Write-Host " 2) New workspace (N Claude panes)"
  Write-Host " 3) Resume (focus + attach)"
  Write-Host " 4) Kill a workspace"
  Write-Host " q) Quit"
  switch ((Read-Host "Choose").Trim().ToLower()) {
    '1' { Show-Workspaces }
    '2' {
      $label = (Read-Host "Workspace name").Trim()
      if (-not $label) { $label = 'claude' }
      # The label lands in "claude -n <label>-<n>", which the pane's shell re-parses.
      # A space or a quote there word-splits every pane's name, so keep it shell-inert.
      if ($label -notmatch '^[\w.-]+$') {
        Write-Host "Name: letters, digits, . _ - only (no spaces)." -ForegroundColor Yellow
        break
      }
      $cntRaw = (Read-Host "How many Claude panes").Trim()
      $cnt = 0
      if (-not [int]::TryParse($cntRaw, [ref]$cnt) -or $cnt -lt 1) {
        Write-Host "Need a positive number." -ForegroundColor Yellow
        break
      }
      $r = New-ClaudeWorkspace -Label $label -Count $cnt
      Write-Host "Created $($r.WorkspaceId): $($r.PaneCount) panes '$label-1'..'$label-$($r.PaneCount)'." -ForegroundColor Green
      Enter-Workspace $r.WorkspaceId   # attaches -> ends script when run outside Herdr
      $exit = ($env:HERDR_ENV -ne '1')
    }
    '3' {
      $hit = Select-Workspace -Verb 'Resume'
      if ($hit) { Enter-Workspace $hit.workspace_id; $exit = ($env:HERDR_ENV -ne '1') }
    }
    '4' {
      $hit = Select-Workspace -Verb 'Kill'
      if ($hit) {
        $ok = (Read-Host "Close '$($hit.label)' ($($hit.workspace_id), $($hit.pane_count) panes)? Type y to confirm").Trim().ToLower()
        if ($ok -eq 'y') {
          Invoke-Herdr workspace close $hit.workspace_id | Out-Null
          Write-Host "Closed $($hit.workspace_id)." -ForegroundColor Green
        }
        else { Write-Host "Cancelled." }
      }
    }
    'q' { $exit = $true }
    '' { }
    default { Write-Host "?" -ForegroundColor Yellow }
  }
}
