# Shared nested-array reads · 5 November 2026

The exact authored-data comparator now recognizes immutable arrays sharing the same backing buffer after checking their lengths. It borrows both buffers only for that comparison, retains no pointer/cache across calls, and skips the redundant child walk only when their addresses match. Swift value mutation detaches a shared array; a different buffer follows the existing exact comparison. Object keys, Unicode byte spelling, floating-point bit patterns and opaque-value rules are unchanged.

This applies to TaskCache refreshes and the existing editor/source/history checks using the same comparator. No stored task representation, authorization, service request or normal feature flag changes. Each repo owns its implementation and tests independently.

## Evidence

The own Core target passes 116 selected cases, including eight new cases: copied nested edits, independent equal arrays/lengths, composed/decomposed Unicode values and keys, signed zero/NaN payloads, opaque future values, sibling-field edits, real TaskCache reuse/invalidation, and the diagnostic. Existing preserving-JSON, projection, pinned-note/catalog, structural/opaque/selection reads and tab-cache cases remain green. The current own app build succeeds and development signatures verify; the iPhone app/test products also build/sign.

The actual production `sameRows` function is measured in SwiftPM Debug on this Mac. A fresh record wrapper retains a 4,096-entry nested array; five samples each repeat three comparisons. The own median changes from **20.810 ms to 0.005486 ms per comparison**. Setup, source generation and report writing are outside the measured interval. There is no timing assertion; before/after medians describe this shared-data case only. This is not Release, Simulator rendering, physical iPhone performance or a general FPS claim. Independently decoded or edited buffers still require comparison.

Both own apps build/sign with the change included. The existing normal/largest-text note-navigation screen rechecks remain pending while the Mac is locked, and update packaging stays held. Normal apps and the verified frozen Mac22/phone34 archives are preserved. No Simulator was booted, no real app was restarted, and no real task data or Keychain item was removed in this run.

## Reproduce

Use the owning repository's `swift test` and stable `core-ios` or `core-mac` cache. Select `AuthoredValueComparisonTests` for the focused cases; the full accepted selection is recorded in the test log hash. Set `TASKFOLD_COMPARE_DIAGNOSTIC` to a fresh `/tmp/taskfold-nested-read-*.json` path to retain the diagnostic. A first test-only reporter attempt rejected Foundation's `/tmp` path normalization; the corrected reporter accepts `/tmp` and `/private/tmp` and refuses existing or unrelated output paths. Production comparison semantics were not changed by that reporter fix.
