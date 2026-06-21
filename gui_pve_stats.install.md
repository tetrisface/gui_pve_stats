# PvE Stats RmlUi Widget

Shows PvE setting difficulty, match result, wins, and ratings from a `/stats` API.

## Automatic Install

On Windows with BAR installed in the default location, open PowerShell and run:

```pwsh
$n="gui_pve_stats"
$d="$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\LuaUI\rmlwidgets\$n"
$u="https://raw.githubusercontent.com/tetrisface/gui_pve_stats/main"
New-Item -ItemType Directory -Force "$d\include" | Out-Null
"lua","rml","rcss" | %{ iwr "$u/$n.$_" -OutFile "$d\$n.$_" }
iwr "$u/include/pve_stats_rml_model.lua" -OutFile "$d\include\pve_stats_rml_model.lua"
```

## Manual Install

1. Download `https://github.com/tetrisface/gui_pve_stats/archive/refs/heads/main.zip`.
2. Extract it.
3. Rename the extracted folder to `gui_pve_stats`.
4. Move it to `%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\LuaUI\rmlwidgets\`.
5. Restart BAR or run `/luaui reload`, then enable **PvE Stats RmlUi** in F11.

Expected layout:

```text
LuaUI/
└─ rmlwidgets/
   └─ gui_pve_stats/
      ├─ gui_pve_stats.lua
      ├─ gui_pve_stats.rml
      ├─ gui_pve_stats.rcss
      └─ include/
         └─ pve_stats_rml_model.lua
```

## Live Development Install

For hot reload, clone this repo directly into the Windows BAR widget tree:

```pwsh
$d="$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data\LuaUI\rmlwidgets\gui_pve_stats"
git clone git@github-tetrisface:tetrisface/gui_pve_stats.git $d
```

If you keep all live widgets under `C:\Users\a\git\Widgets`, clone there and let your existing Windows symlinks point BAR at that directory. From WSL, edit the same checkout through:

```text
/mnt/c/Users/a/git/Widgets/rmlwidgets/gui_pve_stats
```

Prefer this direction over pointing BAR at files stored under `\\wsl$`.

## API Config

The widget defaults to `http://127.0.0.1:8080/stats`.

Useful Spring settings:

- `PveStatsUrl`
- `PveStatsHost`
- `PveStatsPort`
- `PveStatsPath`
- `PveStatsAutoFetch`
- `PveStatsEvidenceLog`
- `PveStatsTimeoutMs`
- `PveStatsRetryMaxAttempts` defaults to `5`
- `PveStatsRetryInitialSeconds` defaults to `2`
- `PveStatsRetryMaxSeconds` defaults to `30`
