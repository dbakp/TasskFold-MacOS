# Build and runtime verification

- Owned Core planner/progress suite: passed (see core-results.txt).
- Mac: independent current-source Debug arm64 app build passed with signing disabled.
- iOS: isolated current-source app, share/widget extensions and UI runner built;
  deep/strict Simulator signature verification passed.
- Normal authoring flags, hosted data and release configuration were unchanged.
- Native Mac calendar actions, installed desktop widgets, spoken/largest-text
  acceptance, real-device and cross-device acceptance were not run in this stage.
- iOS screenshots include a debug-only test overlay; it is not release UI.

The corrected isolated iPhone and iPad scenario passed once on each device,
with explicit selected-mode assertions and editor-dismissal waits. It opened the
exact child in Week/Month/Year, cancelled without changes, completed only that
child, verified persisted equality after cold relaunch, and reopened it. Six
screenshots were visually inspected; the two independent tasks and year total
of two are visible. Phone lower rows scroll beneath the calendar. This is iOS
runtime evidence, not native Mac runtime evidence. The iOS repository owns the
screenshots and final result summaries. The initial launch-pinned runs are
excluded from cross-mode acceptance (see harness-correction.md).
