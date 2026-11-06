# Independent child structure commands — 30 October 2026

This server candidate implements insertion, subtree moves/reordering, reviewed deletion and receipt-certified Undo **within one adopted root**. It is a source-only stage of the independent child-task migration, not completion of the whole feature or Px backlog. Each app repository owns its migration and tests. No hosted database, real tasks, ordinary application flags or release settings changed.

## Behavior

- **Versioned reads.** `taskfold_read_child_structure` returns protocol 2 with the independently advancing `structure_revision`. It delegates live account/session/root-generation/project/read admission and actual record/tree validation to the existing read contract while retaining the root SHARE lock. Protocol-1 reads remain exact and independent of the new gate.
- **Insertion.** Create a validated leaf or subtree at an explicit parent and sibling index. New supported fields pass existing field validation; forged history/files/opaque extensions are refused. The server creates fresh open completion identities for all new nodes, including non-completable headings. Duplicate normalized identities, cycles, unsupported layouts and excessive results are refused.
- **Moves/order.** Move the existing current subtree, preserving fields, comments, opaque data, raw identity strings and incarnations. The destination index applies after removing the source. The exact structure revision detects intervening moves even if visible order was later restored. Unrelated field edits remain compatible.
- **Reviewed deletion.** The request carries each affected node's incarnation/revision, not copied task content. An unseen own-field or descendant edit refuses deletion. The server archives the actual current subtree only after that review matches; sibling edits remain compatible.
- **Certified Undo.** Only the original actor's applied, unreversed receipt can be undone, once, in its original root/generation/project and exact resulting structure revision. Undo of a move preserves current fields and restores authored order/container shapes. Undo of insertion refuses to remove newly edited work. Undo of deletion restores server-held content with fresh incarnations **and fresh completion epochs**, retaining historical timestamps and other authored values. A supported older team completion request was admitted before deletion and refused after restoration. Undo cannot Undo another Undo.
- **Cold discovery.** A bounded account-scoped metadata list finds outstanding deletion archives without needing a saved local request ID, including while writes are paused. It exposes neither archived task text nor another actor’s records.
- **Explicit Undo disposal.** The original actor can permanently forget a deletion’s private Undo content without changing the task or its applied receipt. This frees archive capacity, is idempotent, works while write gates are paused and refuses another actor. A forgotten deletion still resolves/replays as applied; it cannot restore its removed archive. Native controls must confirm this irreversible disposal explicitly.
- **Sparse shapes.** Absent/null/array child containers survive; Undo restores the destination's prior empty shape. Empty null-root Undo stores SQL NULL. Nodes remain separately addressable through the existing projection bridge.
- **Retry/stop.** Exact request fingerprints replay their original metadata receipt without another write. Explicit close returns either the applied receipt or a permanent original-request fence. Resolution needs a live original actor but does not need current root access, edit gates or an existing task; it returns no task text or archived content. A closed UUID cannot become a field/completion/team request.

## Authorization, transactions and custody

Both structure gates default off. Writes additionally require existing reads, edits and completion gates, live actor/session, exact task generation/project, writable/non-archived personal or team scope and current editing role. Team/native task gates remain enforced, and creating/restoring shared headings also requires the existing task-type gate. Private writes use the existing team scope and record a dedicated `child_structure` ledger operation. The public invoker additionally enforces caller task SELECT policies; failure rolls the statement back.

Actor budget/nonces precede recipient, team/project and root locks. Final reciprocal nonce checks on older field/completion/team ledgers use a nonblocking lock, avoiding reversed root/decision lock waits. Tests hold actual competing transactions and pause a real older team command after its task mutation but before its final receipt. Both winners and rollback of the losing writer are checked.

Task changes, history, projection/counter, team scope/ledger, receipt, archive and Undo consumption share one transaction. Tampered post-write results, receipt failures and caller-policy refusal restore the original row/history/counter. No direct table access is granted; every new private table has RLS and internal helpers are explicitly closed.

Deleted content has an indexed root FK and an actor-owned receipt FK. Root deletion and actor removal cascade it; a generation/project transfer purges archived content. Undo consumes its archive; explicit disposal can remove an otherwise ineligible old archive without discarding nonce/receipt proof. Archived text is never included in public metadata receipts, closure responses or versioned reads of surviving records. This verifies SQL content custody, not hosted Storage API file retention/deletion or complete team/project-adoption acceptance.

Limits: request 384,000 bytes; read/result tree 2,000,000 bytes; 1,000 nodes; 24 levels; at most 2,000 new receipts and 2,000 new closures per actor/day; at most 64 outstanding deletion archives totaling 16 MiB per actor; archive-discovery responses at most 64 KiB. Capacity refusal preserves tasks and allows exact applied replay. Permanent metadata retention/maintenance still needs rollout work; these are not claims of an all-time metadata bound.

## Evidence

**Each repository independently passes 220 command/read/custody/race/boundary/capacity-recovery checks plus 317 existing regressions (61 structure, 95 edit, 98 completion and 63 recovery): 537 checks per repository.** `commands.json` and `verification.json` record exact canonical runs, source hashes, counts, advisors and cleanup. The checks use the actual repository history/custody/authorization/field/completion/resolution chain in owned PostgreSQL fixtures, not a mock authorizer. Fixtures remain synthetic, sequential, storage-preflighted and removed in `finally`. Exact existing-regression reports accompany the command report.

Earlier attempts are retained in `attempts.json`: an initial reserved parameter name failed SQL parsing; a missing-row test helper failed JSON parsing; an expiry test attempted an update blocked by the intentional session SHARE lock; the first old-team completion probe used an unsupported null-container layout; and a null-root test initially used the database's empty-array default. A later capacity review found that older ineligible archives could fill the quota without a public cleanup action; the explicit disposal operation and refusal/recovery tests close that dead end. The first iOS attempt also stopped before candidate execution because the harness named two Mac-specific dependency timestamps; its loader now uses the independently owned iOS migrations. None of those failed runs is counted as a pass. The corrected legacy probe is actually admitted inside a rolled-back transaction before testing its later stale-epoch refusal.

Official advisors add no findings to the minimal fixture's seven baseline findings. The fixture does not load every hosted migration/trigger. The Supabase CLI created each canonical filename after direct SQL/advisor checks. The complete local Supabase stack is unavailable, so local migration-history parity remains unverified. No hosted migration was applied. No app/Core code changed in this server stage; app builds, native/spoken UI and production performance are not inferred from SQL passes.

## Remaining implementation order

1. Strict protocol-2 client reads and structural request/receipt/Undo/disposal proofs in both independent repositories.
2. Encrypted offline journals, terminal-outcome recovery, scope/removal fences, current-value conflict review and confirmed private-Undo disposal for capacity recovery.
3. Premium insertion/move/reorder/delete/Undo controls, preserving drafts, keyboard/accessibility behavior and current-task navigation; actual Mac/iPhone/iPad runtime and lifecycle acceptance.
4. Fix the older team JSON field adapter’s null-container limitation (the independent structure engine preserves null), then cross-root/project adapters, legacy/adoption and authoritative-record migration, full-schema/Storage custody and genuine concurrency acceptance, maintenance and remaining Px work. The user's release, remote-reminder, older-client-upgrade, OAuth, email-provider, dictation and physical-geofence deferrals remain unchanged.

## Reproduction

Run `node Scripts/Database/test-child-task-structure-commands.mjs /tmp/child-structure-commands.json` from this repository. The default uses this repository's own CLI-generated migration. To exercise existing suites with it applied, set `TASKFOLD_STRUCTURE_SQL` to this repository's `20261030002245_child_structure_revision_and_assignment_bridge.sql` and `TASKFOLD_STRUCTURE_COMMAND_SQL` to its new structure-command migration, then run:

```sh
node Scripts/Database/test-child-task-structure-revision.mjs /tmp/structure-foundation.json
node Scripts/Database/test-child-task-field-edits.mjs /tmp/structure-fields.json --with-resolution --with-completion --with-completion-resolution
node Scripts/Database/test-child-task-completion.mjs /tmp/structure-completion.json --with-completion-resolution
node Scripts/Database/test-child-completion-resolution.mjs /tmp/structure-resolution.json
```

References: [Supabase database functions](https://supabase.com/docs/guides/database/functions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) and [PostgreSQL lock ordering](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-DEADLOCKS). Reviewed the Supabase/Postgres skills' least-privilege, lock-order and FK-index guidance. Recent changelog extension/operator notices introduce no dependency used by this candidate.

## Subsequent client and compatibility stage

The [30 October follow-up](../child-task-structure-client-read/README.md) implements strict protocol-2 client reads and fixes the older team field adapter’s null-container and large-root-envelope limitations. Its 630 database and 142 selected Core checks per repository include this stage’s 220 structural checks. The reports in this directory remain historical; structural command proofs, offline recovery and native controls remain open.
