# Independent child records — first migration stage

29 October 2026. This is source-only, opt-in preparation for the existing
independent child-task backlog item. The full migration remains **unfinished**.
No hosted schema, real tasks, normal application flags or release gates changed.
Each repository owns its SQL and tests; neither builds against the other.

## Implemented and verified

- [x] Store individually addressable children in private rows with a root binding,
  normalized stable key, incarnation UUID, own revision, parent, sibling order,
  original identity path, complete non-child fields and child-container shape.
- [x] Adopt one explicitly reviewed root at a time. Lock the root first and compare
  both generation and exact JSON tree. Concurrent changes return `stale`; missing
  roots return `missing`. No bulk backfill or automatic enrollment occurs.
- [x] Reconstruct the complete tree from actual stored rows without using the
  source snapshot for content. Comments, attachments, assignments, completion
  metadata, unknown fields, exact date/time strings and ordering survive.
- [x] Preserve absent, null and empty child containers. Root SQL NULL and JSON null
  have the same null JSON representation. Genuine legacy null task generations
  remain representable; no generation is invented during adoption.
- [x] Update adopted rows within the same transaction as existing root edits.
  Unchanged rows keep their incarnation/revision; moves and own-field changes
  advance revision. Removed rows disappear; restoring a key creates a fresh
  incarnation. Root deletion cascades, and recreation requires explicit adoption.
- [x] Refuse text-only, missing/oversized IDs, duplicate identities (including
  canonically equivalent Unicode IDs), malformed child containers, more than
  1,000 nodes or more than 24 levels. Keep the original root unchanged and mark
  its projection `review`, removing stale addressable rows. Corrected trees can
  recover with fresh incarnations. IDs are never guessed, rekeyed or dropped.
- [x] Private-schema RLS and explicit revocation deny tables and helpers to anon,
  authenticated and service roles. Adoption/sync are invoker functions available
  only to trusted SQL operators. The sole definer is a trigger deriving all input
  from an already-authorized updated root; it cannot be called by clients or
  write tasks. Existing root RLS, checklist scopes and permission checks remain.

The canonical migration is
`supabase/migrations/20261028235056_independent_child_record_projection.sql`.
`Scripts/Database/child-task-records-schema.mjs` names that repo's file.

## Evidence and limits

`records.json` records 92 checks against this repo's canonical migration in an
owned PostgreSQL 17.6 container. They include real concurrent lock waiting, stale
adoption, source/record rollback on injected derived-storage failure, direct grant
checks, authenticated allowed/denied root edits, malformed review/recovery,
removal/recreation and exact row-based reconstruction. Official advisors are
recorded before and after, with no additional findings. Seven baseline findings
belong to the deliberately minimal dependency fixture, not this new schema.

`team-regression.json` records the actual team edit/lifecycle/conversation/batch/
planning/checklist regression suite with all initial roots explicitly adopted.
Before team deletion it verifies nonempty independent rows, exact source and child
field/path agreement. After deletion it verifies projection cleanup. This exercises
the existing actual SQL guards and RPCs, not a rewritten mock authorizer.

The fixture loads inspected minimal dependencies and unchanged repository
migrations through team checklists, not every hosted trigger or the full current
hosted database. These results do not establish hosted deployment, production
performance, client reads/writes, full team custody acceptance or native UI.
There is no new app UI, so no app build/runtime result is inferred from SQL tests.

Early harness failures are recorded in `attempts.json`: asynchronous default
parameters initially caused a JavaScript parse failure, a write of JSON null
hit the existing assignment guard, and a PostgreSQL boolean was queried without
JSON encoding. The harness now tests SQL-null roots, nested null children and the
JSON-null decoder separately; it does not weaken that guard. The first iOS
canonical attempt had the Mac migration filename in its loader and failed before
a database was created. The first team regression command omitted its required
batch flag and exited before running assertions. Corrected runs are recorded
separately; none of these failures are counted as passes.

The draft was iterated using direct SQL in the disposable fixture. Official
advisors ran before CLI-generated migration filenames were created, then each
canonical file was independently tested. Supabase CLI 2.109.0 created each file.
`supabase migration list --local` could not connect because the full local Supabase
stack is not running. No local migration-history or hosted-history parity is
claimed, and no hosted `apply_migration` call was made.

## Remaining implementation order

1. [ ] **Authorized reads.** Return a bounded record envelope only after current
   session, account, root generation, task/project access and team read role checks.
   Bind it to the current projection revision, verify reconstruction, and refuse
   `review`/stale state. Keep direct table access closed.
2. [ ] **Independent commands.** Add idempotent child-field commands using exact
   root generation, child incarnation/revision and request identity. Preserve
   current root/team validation, unknown-field custody and completion rules.
   Serialize bridge writes with legacy JSON; use a structural baseline for
   insertion, deletion, moves and sibling order. A changed incarnation must never
   receive a stale queued edit. Test disjoint edits, same-field conflicts,
   completion cycles, request retries, deletion/restore and concurrent legacy edits.
3. [ ] **Client adoption.** Both apps need independent child read models, offline
   commands, conflict review and certified Undo, then existing editor/navigation,
   hierarchy filters, exports, widgets and cold-return acceptance. Preserve the
   current premium UI and avoid leaking private child content on account changes.
4. [ ] **Custody and lifecycle.** Verify project moves, archived/read-only access,
   role revocation, account removal, team deletion, partial backfills, malformed
   review tools and retry/recovery against the complete current schema. Bound
   retention and maintenance work before large-scale adoption.
5. [ ] **Rollout.** Deployment/backfill, old-client transition and release
   verification remain deferred by the user. Keep legacy JSON authoritative until
   the independently verified migration can safely make records authoritative.

A private projection is not independent editing. Neither rank 6 nor the broader
Px goal is complete from this checkpoint.

## Reproduction

From this repository, run:

```sh
node Scripts/Database/test-child-task-records.mjs /tmp/child-records.json
TASKFOLD_CHILD_RECORDS_REGRESSION=1 \
TASKFOLD_TEAM_LIFECYCLE_REGRESSION=1 \
TASKFOLD_TEAM_CONVERSATION_REGRESSION=1 \
TASKFOLD_TEAM_BATCH_REGRESSION=1 \
TASKFOLD_TEAM_PLANNING_REGRESSION=1 \
TASKFOLD_TEAM_CHECKLIST_REGRESSION=1 \
node Scripts/Database/test-team-task-edits.mjs /tmp/child-records-team.json
```

The final team regression passes 227 checks in this repo. Source/migration hashes
and exact accepted reports are recorded in `verification.json`. Early raw logs
were overwritten during iteration; `attempts.json` is a transcription of observed
failures, not a preserved raw log.

Both commands use uniquely labelled disposable containers with synthetic records;
they remove their own containers in `finally`. Advisors use an ephemeral
loopback-only port. No credentials or user files are mounted.

Documentation reviewed: [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security),
[explicit API grants](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically),
[PostgreSQL Unicode normalization](https://www.postgresql.org/docs/17/functions-string.html)
and the [September PostgreSQL changelog](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes).
The cited index/extension changes do not change this private JSON/text design.
