# Reuse subtask progress while browsing — 6 November 2026

Task rows and planning cards now reuse checklist progress while the immutable checklist array is unchanged. Date/title/other root-field redraws no longer rebuild a descendant outline just for the completed/total badge. The shared cold count also walks the tree directly, avoiding the Item array and two filtered arrays. Existing heading, future-kind, malformed legacy-row and depth semantics are preserved; nothing rewrites task data or grants editing authority.

Each Store owns a read-only cache bound to workspace generation, account, session and access epoch. Account changes, access-mask changes, unreadable storage and workspace-read revision changes clear retained readings. A changed same-ID checklist computes fresh counts. Buffer identity is compared only while both immutable arrays remain retained; no pointer is stored or used as a durable identity. Copy-on-write edits cannot hit the old allocation. Each cache retains at most 128 readings and 32,768 visited nodes, evicts least-recently-read entries and skips oversized/depth-truncated trees. This is a retained-reading limit, not a byte limit on opaque metadata. Nothing is persisted to disk.

## Verification and limits

- [Owning Core evidence](core-verification.json): 167 selected progress/tree/heading checks pass, including eight new progress cases. These cover mixed/opaque legacy equivalence without rewriting bytes, same-count replacements, nested completion/reversal, workspace/session/access changes, explicit clearing, LRU/node bounds, disabled caching and the established depth boundary.
- The Debug diagnostic reads a 4,096-item checklist 100 times. It compares the former outline/filter path with retained progress including the first count, and verifies exactly one computation. Exact measured times are in the owning receipt. This is not an app frame-rate claim or a release-speed guarantee.
- [Current owning signed build](signed-build.json) checks the source integration. Store boundary-clearing hooks are compiled; this round does not claim native account-switch/privacy/rendering acceptance or repeat unchanged earlier journeys.
- Normal installed Mac14/phone34, frozen update archives, rollout gates, persistence and appearance are unchanged. Further phone installation stays deferred; assistance remains on-device only. The three agreed release/remote-reminder/older-client deferrals remain.

## Remaining

Actual rendering/scrolling, larger editor and note workloads, native Mac/iPad/accessibility/account/window cases and physical FPS remain open. Keep this within the existing responsiveness checkpoint; test totals do not add progress checkpoints. [Cleanup](cleanup.json) records the run's storage budget.
