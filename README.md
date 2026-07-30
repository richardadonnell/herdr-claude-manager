# herdr-claude-manager

A PowerShell menu that opens a [Herdr](https://herdr.dev) workspace tiled with N Claude Code panes, then lists, resumes, or kills those workspaces later. It runs on Windows under PowerShell 7.

[![lint](https://img.shields.io/github/actions/workflow/status/richardadonnell/herdr-claude-manager/lint.yml?branch=main&label=lint)](https://github.com/richardadonnell/herdr-claude-manager/actions/workflows/lint.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Herdr's plugin ecosystem grew up on macOS and Linux, and this is the PowerShell path into it. Of the 133 projects on the awesome-herdr list (`yigitkonur/awesome-herdr`), one is PowerShell, a per-pane token badge, and every workspace or session tool there is Shell, Go, Rust, TypeScript, or Python.

## What it does

`herdrm` drives the Herdr CLI against your always-on default server. Pick option 2, give it a name and a pane count, and it creates the workspace, tiles that many panes into a rough grid, renames each pane `<name>-<n>`, and launches `claude -n <name>-<n>` inside every one of them.

Each workspace opens with its cwd set to the directory you ran `herdrm` from, so the panes land in the project you were already working in. The Herdr server keeps running after you detach, so the panes and the agents inside them survive until you kill the workspace.

The other three options cover the rest of the lifecycle: list what exists, focus and reattach to a workspace, close one and its panes.

## The menu

```
=== Herdr + Claude manager (default server) ===
 1) List workspaces
 2) New workspace (N Claude panes)
 3) Resume (focus + attach)
 4) Kill a workspace
 q) Quit
Choose:
```

## Requirements

- **Windows**, for the install path. The installer writes a `herdrm.cmd` shim and appends to your **User** PATH, and both of those are Windows-only mechanics. `herdrm.ps1` itself shells out to the `herdr` and `claude` CLIs and calls nothing Windows-specific, so running it by path elsewhere should work, though that route is untested.
- **PowerShell 7.0+** (`pwsh`). The script declares `#Requires -Version 7.0`, so Windows PowerShell 5.1 refuses to run it.
- **Herdr** installed, `herdr` on PATH, and the server running. `herdr status server` has to print `status: running`. Verified against Herdr 0.7.5-preview, protocol 17.
- **Claude Code CLI** (`claude`) on PATH. Only the pane launch needs it; `-SelfTest` skips claude entirely.

## Install

### One-liner

```powershell
irm https://raw.githubusercontent.com/richardadonnell/herdr-claude-manager/main/install.ps1 | iex
```

To pass flags, wrap the download in a scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/richardadonnell/herdr-claude-manager/main/install.ps1))) -NoPath
```

The installer:

- copies `herdrm.ps1` to `%LOCALAPPDATA%\Programs\herdrm\herdrm.ps1`
- writes a `herdrm.cmd` shim into `%LOCALAPPDATA%\Programs\herdrm\bin`
- appends that `bin` directory to your **User** PATH
- adds a `herdrm` function to `$PROFILE.CurrentUserAllHosts`

Open a new terminal afterward. The PATH change reaches only processes started after the edit.

### Clone and run

```powershell
git clone https://github.com/richardadonnell/herdr-claude-manager.git
cd herdr-claude-manager
pwsh -File .\herdrm.ps1
```

Running from the clone skips the shim and the profile function, so you invoke the script by path every time.

## Usage

Run `herdrm` with no arguments for the menu.

| Option | What it does |
|---|---|
| `1` | Prints a table of workspaces: number, label, id, tab count, pane count, agent status, and a `*` on the focused one. |
| `2` | Asks for a workspace name and a pane count. The name takes letters, digits, `.`, `_`, and `-`, with blank giving you `claude`; it becomes part of a command the pane's shell re-parses, so a space or a quote gets rejected rather than silently splitting every pane's name. The count has to be a positive integer. Creates the workspace, tiles the panes, renames them `<name>-1` through `<name>-N`, and starts `claude -n <name>-<n>` in each. Then it focuses the workspace. |
| `3` | Shows the same table, takes a workspace number, and focuses that workspace. |
| `4` | Shows the table, takes a number, and closes that workspace and its panes after you type `y` at the confirmation prompt. Anything else cancels. |
| `q` | Quits. |

Options 2 and 3 both end by focusing the workspace. What happens next depends on where you invoked `herdrm` from. Inside Herdr (`$env:HERDR_ENV` is `1`) the script prints a note telling you to switch to it and returns you to the menu. Outside Herdr it attaches the TUI by running `herdr`, which takes over the terminal and ends the script when you detach.

### Non-interactive flags

```powershell
herdrm -List
herdrm -New -Label api
herdrm -New -Label api -Count 4
```

`-List` prints the same workspace table option 1 produces, then exits 0.

`-New` requires `-Label` and accepts an optional `-Count`, which defaults to 1. It creates the workspace, tiles the panes, renames them, launches claude in each, prints the workspace id and the pane name range, then exits 0. It skips the TUI attach and never drops into the menu, which is what makes it safe to call from a script. `-Label` obeys the same rule the menu uses (`^[\w.-]+$`); a label with a space, a quote, or anything else outside that set gets a clear rejection message and a non-zero exit.

Killing a workspace stays interactive. Option 4 is the only way to do it, and the `y` confirmation guards a command that closes panes and the agents living in them.

### Self-test

```powershell
herdrm -SelfTest
herdrm -SelfTest -SelfTestCount 9
```

`-SelfTest` runs non-interactively and never touches claude. It builds a workspace labeled `__selftest__` with `-SelfTestCount` panes (default 5), asserts the resulting pane count matches what you asked for, then runs `Write-Output selftest` in the first pane to exercise the code path that handles herdr commands returning no JSON. It closes the workspace in a `finally` block, so a failed assertion still cleans up.

## How the tiling works

Herdr splits one pane at a time, so a grid comes from repeated splits rather than a layout call. To add pane number *k*, the script reads the current layout, sorts the panes by area, and splits the largest one down the middle at `--ratio 0.5`. Splitting the biggest pane every time keeps the panes close to the same size for any N, including counts that do not divide into a clean grid.

Direction comes from the aspect ratio of the pane being split. If its width is at least twice its height in cells, the split goes `right`; otherwise it goes `down`. Terminal cells run roughly twice as tall as they are wide, so a 2:1 cell rectangle is about square on screen, and that test keeps the results from turning into slivers.

Naming happens after all the splits land. The script pulls the final layout and sorts the panes by `rect.y` and then `rect.x`, which is reading order: left to right across the top row, then down. `<label>-1` is the top-left pane and `<label>-N` is the bottom-right one, both as the Herdr pane label and as the `claude --name`.

## Uninstall

Run the installer with `-Uninstall`:

```powershell
pwsh -File .\install.ps1 -Uninstall
```

Or remotely, using the same scriptblock form:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/richardadonnell/herdr-claude-manager/main/install.ps1))) -Uninstall
```

## Troubleshooting

**`herdr not found on PATH. Install/launch Herdr first.`**
The preflight check at the top of the script could not resolve `herdr`. Install Herdr, then confirm with `Get-Command herdr`. If it resolves in one terminal but not another, the PATH entry landed after that terminal started.

**`Herdr server not running. Launch 'herdr' once (starts the server), then re-run.`**
The script shells out to `herdr status server` and looks for `status: running` in the output. Run `herdr` once to start the server, then re-run `herdrm`. Run `herdr status server` yourself to see what the script saw.

**`herdrm` is not recognized after installing**
Open a new terminal. The installer appends to the User PATH and writes a profile function, and neither reaches a shell that was already open. If a fresh terminal still fails, the profile did not load: check that `$PROFILE.CurrentUserAllHosts` contains the `# >>> herdrm >>>` block, and reload it with `. $PROFILE.CurrentUserAllHosts`. As a fallback, call the installed copy by path with `pwsh -File "$env:LOCALAPPDATA\Programs\herdrm\herdrm.ps1"`.

## Related projects

Several projects cover nearby ground. Two things set `herdrm` apart: it runs on Windows through PowerShell, and it tiles any N you type without a config file. Each project below does something this one does not, so pick by what you need.

- [noor-latif/herd](https://github.com/noor-latif/herd) (Shell) sits closest to the core feature here. It gives you a project-scoped workspace with an N-agent grid, default 2x2, one Pi agent per pane, keyed to the current directory, and it relaunches dead agents.
- [cloudmanic/herdr-plus](https://github.com/cloudmanic/herdr-plus) (Go, 178 stars) reads declarative TOML project templates and spins up a whole workspace from a fuzzy picker, plus a quick-action launcher.
- [andrewchng/herdr-sessionizer](https://github.com/andrewchng/herdr-sessionizer) (TypeScript) runs fzf over project roots and git worktrees, with TOML defining tabs, splits, and per-pane startup commands.
- [razajamil/herdr-plugin-workspace-manager](https://github.com/razajamil/herdr-plugin-workspace-manager) (Rust) applies a YAML layout per repo to every new worktree.
- [ridho9/switchr](https://github.com/ridho9/switchr) (Go) gives you a full-screen session picker showing the workspace, tab, and pane tree.
- [j0urneyk/herdrctx](https://github.com/j0urneyk/herdrctx) (Go) is a keyboard-driven TUI for attaching, stopping, deleting, creating, and searching sessions.
- [carsonjones/herdr-plugin-tiles](https://github.com/carsonjones/herdr-plugin-tiles) adds six named split-ratio actions that override the default even split.

Want the same layout every time you open a given repo? Reach for herdr-plus, herdr-sessionizer, or herdr-plugin-workspace-manager. A checked-in TOML or YAML file describes that layout better than a pane-count prompt does. If most of your time goes on finding and attaching to sessions that already exist, switchr and herdrctx hand you a richer picker than a numbered menu. Come here when you are on Windows, or when you want to type `4` and get four even panes with no file to author first.

## License

MIT. See [LICENSE](LICENSE).
