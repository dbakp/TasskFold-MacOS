# Task-bound shared file custody — local candidate

Reviewed 1 November 2026. Each repository owns its migration, implementation, tests and independently captured database fixture.

## Implemented

An explicitly admitted private file can be bound to a task identity and generation. A reviewed same-team project move signs and locks that exact inventory, then moves its project access together with the task and discussions. Undo reverses the binding. Deleted tasks no longer grant database file access; certified deletion Undo renews the file generation with the restored task. Unknown, missing, foreign, busy or changed bindings refuse safely. Older project-only bindings are never guessed or silently upgraded.

The native move review decodes the optional versioned file count and explains that stored files follow project access. Older server replies make no file-custody claim; malformed or unknown contracts refuse. Commands do not add client-authored custody assertions. Previously shared URLs and downloaded copies are not revoked.

## Verified locally

Each repo passes 59 actual PostgreSQL custody assertions and 68 existing child-transfer regression assertions with its own candidate applied. Tests cover source/destination/outsider access, exact generation and file identity, legacy compatibility, uploader removal, metadata invalidation, busy locks, deletion and certified Undo, replacement refusal, retry and late-failure rollback. Both fixture containers are removed. Advisor output introduces no additional findings over the fixture baseline. Each repo also passes 90 focused Core tests, including four new contract/boundary tests consuming its own SQL reply. Reports and source hashes are in verification.json.

## Still unfinished

This is storage/access infrastructure, not complete shared-file publishing. Trusted upload/admission, provider API byte delivery, legacy-file migration, native end-to-end file review/upload/recovery, audio custody, cross-team moves, genuine shared accounts and hosted acceptance remain open. Existing public native creation still refuses new attachment payloads. No migration was deployed, no normal-use gate changed, and no signed-link revocation is claimed. Full Supabase-stack migration-history parity is not claimed by the isolated PostgreSQL fixtures.

## Official guidance reviewed

The candidate reads Storage metadata and never changes Storage schema, objects, buckets or provider bytes. Private custody tables and helpers have no client grants; privileged helpers retain explicit authorization and an empty search path. Existing provider metadata/version changes invalidate inventory proofs. This follows the reviewed [Storage schema guidance](https://supabase.com/docs/guides/storage/schema/design), [access-control guidance](https://supabase.com/docs/guides/storage/security/access-control) and [database function guidance](https://supabase.com/docs/guides/database/functions). The [Supabase changelog](https://supabase.com/changelog) and relevant Postgres/Data API grant changes were reviewed; no engine or SDK upgrade was performed.

## Reproduce in this repository

Use an owned disposable local database fixture; no hosted credentials are needed. Run the storage-floor check before each resource-heavy job and serialize fixtures/builds.

```sh
python3 Scripts/check_test_storage.py --path /tmp
node Scripts/Database/test-task-file-custody.mjs /tmp/taskfold-file-custody-report.json
TASKFOLD_TASK_FILE_CUSTODY_SQL="$PWD/supabase/migrations/20261101212844_task_bound_file_custody.sql" node Scripts/Database/test-child-record-transfers.mjs /tmp/taskfold-file-transfer-report.json
```

The focused Core filter is `TeamTaskMoveTests|PersonalTaskMoveTests|TeamTaskLifecycleTests|TeamTaskEditorTests|ChildTaskTransferTests`; use the repository’s own Swift package and an external build cache. App/runner compilation and signatures are recorded separately from native file-workflow acceptance.

Current isolated app and runner compilation and strict signatures pass. The compiled move-review sources match this repository after test-identity isolation. Binary/source/build hashes are recorded in verification.json. This does not count as native stored-file workflow acceptance.
