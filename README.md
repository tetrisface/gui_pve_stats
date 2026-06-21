# PvE Stats

In-game RmlUi widget for Beyond All Reason PvE lobby/game stats.

The widget posts the current game context to a `/stats` API and shows setting difficulty, match status, player wins, and ratings. It is distributed as a standalone BAR RmlWidget so it can be installed without waiting for a full game release.

## Files

- `gui_pve_stats.lua`
- `gui_pve_stats.rml`
- `gui_pve_stats.rcss`
- `include/pve_stats_rml_model.lua`

## Evidence

For manual API checks, set `PveStatsEvidenceLog=1` or call `WG.PveStatsRml.LogLastEvidence()` after a fetch. The log line includes compact request/response hashes and match status without dumping the full payload.
