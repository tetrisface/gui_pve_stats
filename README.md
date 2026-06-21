# PvE Stats

In-game RmlUi widget for Beyond All Reason PvE lobby/game stats.

The widget posts the current game context to a `/stats` API and shows setting difficulty, match result, player wins, and ratings. It is distributed as a standalone BAR RmlWidget so it can be installed without waiting for a full game release.

## Files

- `gui_pve_stats.lua`
- `gui_pve_stats.rml`
- `gui_pve_stats.rcss`
- `include/pve_stats_rml_model.lua`

## Live Development

For BAR hot reload on Windows, keep the live checkout under a Windows path such as:

```text
C:\Users\a\git\Widgets\rmlwidgets\gui_pve_stats
```

Expose that same checkout to WSL through `/mnt/c/Users/a/git/Widgets/rmlwidgets/gui_pve_stats` when editing or testing from Linux. This avoids making the game load files from `\\wsl$`, which is more fragile for file watching, permissions, and runtime access.

If another repo needs this widget as local context, bind-mount or clone the same Git repo there instead of maintaining a copied tree.

## Evidence

For manual API checks, leave `PveStatsEvidenceLog=1` enabled or call `WG.PveStatsRml.LogLastEvidence()` after a fetch. The `pve_stats_evidence` log line includes compact request/response hashes and match status without dumping the full payload.
