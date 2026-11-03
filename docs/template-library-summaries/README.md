# Template-library summaries

Both apps now prepare fully validated library captions on a serial background actor. A presentation retains at most 24 source/caption pairs (the reusable model clamps capacity to 1…64), scoped to the workspace and session and invalidated by exact source changes. Cancellation prevents late captions from publishing. The row checks the current readable source before showing a result. Workspace changes and leaving the library clear retained entries.

The existing Use, Edit and Export validation paths remain independent; a cached caption never authorizes an operation. Version 1 captions keep their original root-task counts, while heading-format captions keep their original nested-task and heading counts. Unsupported content keeps the existing update message. Heading summaries no longer validate the same definition a second time.

The source picker displays Choose a source when its retained draft selection is no longer available, avoiding an invalid native picker selection. The template section explains when the workspace is unavailable.

## Evidence and limits

Each independent repo passes 185 selected Core tests, with four existing opt-in skips and no failures. The cache checks cover exact-caption parity, reuse and changed definitions, account/workspace/session separation, clear, bounded LRU retention, unsupported-source recovery and cancellation. The iPhone production library passes scrolling, unsupported captions, controlled live Store source replacement, unreadable/return and cold reopening, with tasks, unrelated templates and queued work unchanged. The isolated app was closed and its Simulator state restored. See `core-checks.json`, `core-diagnostic.json` and `iphone-after.json`. The first Core diagnostic attempt rejected its task-owned output path because the harness compared it with the per-user temporary folder; the corrected guard admits only a resolved /tmp/taskfold-*.json path. This was a harness failure. The first native run loaded the expected initial caption, then XCTest rejected the harness predicate for hittability. The corrected test filters queried elements through their actual `isHittable` property.

The timings compare bounded Debug summary work, not frame-rate, hardware responsiveness or whole-app performance. Native scope is synthetic local data; genuine shared accounts, wider platform/accessibility/cloud contexts and remaining Px work stay open. No hosted deployment or normal-use feature-gate change belongs to this package.

Both current Debug apps and test runners build and pass strict signature verification; `build-verification.json` binds each isolated host to its own changed source. This does not establish Mac/iPad interaction, genuine shared-account/provider, audible accessibility or all-workload performance acceptance.
