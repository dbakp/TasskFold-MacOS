# Structural child revisions and legacy assignment guard — 30 October 2026

This is a private server foundation for independent child insert/move/reorder/delete and certified restoration. Those commands and their UI are still unfinished. The migration is source-only in each repository; no hosted task, automatic adoption, ordinary app flag or release setting changed.

## Implemented

- [x] Add a separate monotonic `structure_revision` to each adopted projection. Existing projections start at 1; the current general revision and child revisions are preserved.
- [x] Compare validated topology, preserving root null/array, child absent/null/array, raw identity paths, normalized keys, parent and sibling position. Title, notes, completion and opaque-field changes do not advance this structural fence.
- [x] Advance for insert/delete/reparent/reorder/container-shape changes, even when later restored to identical visible values. Generation replacement and malformed/review transitions also advance it. Repeated adoption leaves it unchanged; ordinary projection updates cannot reset it.
- [x] Participate in the existing root/projection transaction. Concurrent root edits serialize, and manual rollback or injected derived-row failure restores source, projection and counter together. Moves preserve incarnations; deleted/restored nodes and generation/review replacement receive fresh incarnations through the existing bridge.
- [x] Preserve exact version-1 read envelopes/record keys and closed table/helper grants. No existing strict client decoder receives extra keys. A separately versioned structural read contract is still needed.
- [x] Repair the existing assignment trigger's two-level scan: traverse actual nested arrays safely, preserve null/absent/opaque containers, and apply the existing recipient predicate at every depth. Keep creator protection and project-move assignment clearing. This fixes the null-container error reproduced before the migration and prevents deeper children bypassing recipient checks.

## Evidence and limits

Each repository's `structure.json` records 61 actual PostgreSQL checks against its own canonical migration. This includes a failing-before null-container reproduction, topology ABA, disjoint fields, reparent identity/path, sparse shapes, removal/restoration, concurrent lock waiting, atomic failure rollback, generation/review fences, unchanged v1 reads, fourth-level allowed/refused assignments, creator refusal, private grants/RLS and advisors. The existing 95 edit, 98 completion and 63 terminal-recovery checks also pass with the new migration applied: **317 database checks per repository**. `verification.json` identifies the exact files and regression reports.

The first three draft attempts stopped after 12 checks at the null-container write. A diagnostic rerun identified the preexisting `taskfold_private.guard_task()` scalar-array extraction. Its repair then passed 52 draft checks, followed by the expanded 61-check canonical runs. These earlier failures are not counted as passes.

Official advisors retain seven baseline findings from the minimal dependency fixture and add none. The fixture loads the repository's inspected dependency chain and actual field/completion/resolution SQL, not the complete hosted schema. Containers are owned, synthetic, sequential and removed in `finally`; test credentials/user files are not mounted. Full-stack local migration listing could not connect because the local Supabase stack is not running. Neither full migration-history parity nor hosted rollout/performance is established. The CLI generated the canonical filename after direct SQL/advisor checks.

## Next implementation

1. Add a separately versioned bounded authenticated structural read, retaining the old read contract. Bind its counter to account/session/root generation/project and current access.
2. Add idempotent insert/reparent/reorder/delete commands with immutable structural baselines, retry receipts and current authorization; preserve concurrent own-field changes. Define server-owned deleted-subtree custody and certified one-use restore/Undo so restored identities cannot receive old queued field/completion requests.
3. Connect encrypted offline commands, conflict review and premium editor controls in both apps, then verify actual lifecycle/team/account/cold/native/accessibility behavior.
4. Finish legacy/adoption adapters, complete-schema custody acceptance and authoritative-record migration. All broader Px work and explicit release/remote-reminder/older-client/OAuth/email/dictation/physical-geofence deferrals remain unchanged.

## Reproduction

```sh
node Scripts/Database/test-child-task-structure-revision.mjs /tmp/child-structure.json
TASKFOLD_STRUCTURE_SQL="$PWD/supabase/migrations/20261030002245_child_structure_revision_and_assignment_bridge.sql" node Scripts/Database/test-child-task-field-edits.mjs /tmp/structure-fields.json --with-resolution --with-completion --with-completion-resolution
TASKFOLD_STRUCTURE_SQL="$PWD/supabase/migrations/20261030002245_child_structure_revision_and_assignment_bridge.sql" node Scripts/Database/test-child-task-completion.mjs /tmp/structure-completion.json --with-completion-resolution
TASKFOLD_STRUCTURE_SQL="$PWD/supabase/migrations/20261030002245_child_structure_revision_and_assignment_bridge.sql" node Scripts/Database/test-child-completion-resolution.mjs /tmp/structure-resolution.json
```

Documentation reviewed: [Supabase database functions](https://supabase.com/docs/guides/database/functions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), and the [PostgreSQL minor-release notice](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes). The notice's affected extensions and custom operators are not introduced here.
