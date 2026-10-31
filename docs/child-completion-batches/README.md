# Atomic subtask completion groups

This is the disabled server and client-contract foundation for bulk completion. It does not enable bulk controls or complete the subtask migration.

An immutable selection contains 1–32 independent child commands with one action: complete, reopen or certified Undo. The server applies every member in one transaction, including task/node projections, activity and receipts. A stale later member, permission failure, competing writer or capacity failure rolls back the entire selection. This avoids a partially completed list. Personal, Inbox and team child commands can share a group when the actor can edit every target. Mixed root-task/child selections are not implemented here.

The group identity is separate from its member request identities. A new group cannot adopt a member request already used or closed elsewhere. Exact replay returns its original ordered receipt without duplicating writes. Closing an unapplied group atomically reserves every member identity against later sends; closing an applied group returns its existing confirmation. These metadata-only decisions remain available after rollout is paused or task content disappears. They do not grant current task access.

Resource limits cover request bytes, item count, root and aggregate tree size, receipt size and daily group/component budgets. Resource prelocks are nonblocking before taking root locks; reversed competing selections cannot wait on each other's roots. The existing individual completion functions still enforce their own current permissions, incarnation, revision and completion-cohort safeguards. Opaque numeric and UTF-8 metadata is retained exactly.

Both repositories own the migration, fixture, tests and typed transport independently. The client rejects partial, reordered, duplicated, foreign or malformed receipts, fences account/session/backend changes, refuses cookies/cache/redirects and bounds streamed responses. The stored codec retains private Undo proofs while the wire body omits them. A generic durable vault is available for the next integration step; the bulk journal, recovery controls and list Undo manager are not connected yet.

## Verification and limits

See `verification.json` and the retained database/Core/build reports for exact tested source hashes and outcomes. All database fixtures use disposable local containers and synthetic accounts. No hosted migration or real task mutation is performed. Development build/signature checks establish compilation, not bulk UI runtime or release acceptance.

`completion_batches_enabled` defaults to false. Ordinary child flags remain disabled. The broader migration checkpoint stays **To build**. Next: durable group staging and uncertain-result recovery, bulk list controls and receipt-based group Undo, mixed root/child support, full Redo/shared history, then wider lifecycle/custody/workload acceptance. Before any real Keychain use, connect the new group recovery storage to confirmed account-removal cleanup as well as scope/removal fences; the current vault check uses synthetic in-memory storage only. User rollout/provider/distribution and device/audio deferrals remain unchanged.

The later saved-group journal, sender, recovery model and Store cleanup factories are recorded in `../child-completion-group-recovery/`. Bulk list/review controls remain unfinished.
