# Explicit history custody when separating duplicate references

An older tree can contain two items with the same reference. The repair review now lets the user give one item a fresh reference and explicitly choose the item that keeps the original reference and its recorded activity. The choice uses positions in the reviewed tree, never matching task names. Canonically equivalent Unicode references count as duplicates.

The preview shows how many existing events and completion events stay with the chosen item. These are ledger-event counts, not net productive-work totals. Existing history gaps remain gaps; this repair cannot manufacture credit or make an incomplete history complete. Every old event keeps its identity, sequence, actor, completion version, effective date and recorded date. No event is reassigned or copied to the fresh reference.

The final proposal must preserve the chosen keeper's entire JSON value. It may move intact; renaming it, changing its content later in the same proposal, selecting an unrelated item, reusing an earlier historical identity, or leaving duplicate references unresolved cannot become a saveable repair. Other duplicate references may be separated with the same explicit keeper. Opaque values continue through the existing preserving planner.

The retention proof binds the exact observed historical rows into the repair digest. An event arriving after preview forces a fresh review even when the root itself is unchanged. Both preview and first send verify those rows through current caller RLS in addition to the existing explicit custody checks. A later restrictive history policy therefore protects event counts and prevents an unsent repair. Confirming an already applied request retains the existing content-free replay behavior.

Saving reuses the existing archive-before-write transaction, promotion, permission checks, quotas, rollback, exact retry and recovery controls. The complete original tree and all original child-history rows are archived before any source write. Each repository owns its implementation, migration, client fixture and acceptance scripts independently.

## Verified scope

See `verification.json`, `postgres.json`, `core.json` and `build.json`. The owned database suite includes the entire prior repair/access acceptance corpus, then explicit keeper selection, unchanged historical rows, no copied completion, rollback after a late failure, exact retry, original export, stale source/history, historical-key collision, Unicode identity, keeper movement and future restrictive policies. Database advisors must add no findings and the owned fixture must be removed.

The client cases read each platform's actual database proof, preserve the choice in durable requests, reject missing or mismatched consent metadata, bound positional counters, separate identity from names, and preserve every parsed historical event. Existing repair/adoption and activity checks are retained.

## Still open

The reserved native peer now exercises this choice through the real review, durable draft, save and recovery controls. Current native acceptance is recorded in [the native evidence](../duplicate-history-repair-native/README.md); its persisted-state verifier is independent of the UI diagnostic panel. Mac runtime and human VoiceOver listening acceptance remain open. Native peer results do not substitute for the separate SQL custody checks.

This is a bounded duplicate-separation workflow. Arbitrary renames into a different historical identity, splitting historical lifecycles, reconciliation of conflicting indexed copies, general opaque editable-cache adoption, and shared attachment/discussion custody remain open. The broader older-data checkpoint stays unfinished. This migration is not deployed to a hosted service, normal-use migration gates stay off, and all user deferrals remain unchanged.
