# Independent child field commands — disabled server candidate

29 October 2026. Both repos now own the same server command contract and their own
synthetic acceptance. The normal server edit gate defaults Off; native app writes
are not connected or enabled. No hosted migration or real task/account changed.
Full child migration, rank 6 and Px remain unfinished.

## Implemented

- [x] Protocol-1 commands bind a request UUID, intended account, root ID/generation/project, canonical
  child key, incarnation and captured child revision to explicit field changes.
  There is no caller-supplied root tree. Non-completion fields use existing
  validation; completion/history, IDs, child structure, headings, attachments,
  comments and unknown fields require separate actions and cannot be smuggled in.
- [x] Private `field_versions` tracks the last own-row revision for each changed
  field, including removed fields. Disjoint edits can coexist on one child;
  a touched field changed since capture is refused even when its value returned.
  Existing records conservatively fence all current fields at their current
  revision. Moves can retain identity; deletion/recreation gets a fresh incarnation.
- [x] Actor/session validation and current personal or team writer permission
  checks precede the mutation. Archived projects, paused/missing team gates,
  viewers, outsiders, revoked grants and stale project/generation/incarnation
  cannot authorize a new write. Natural session expiry after waiting is rechecked.
- [x] A public invoker calls a private preparation helper, then the existing
  personal `taskfold_patch_task` or team `taskfold_edit_team_task` under the caller,
  then private receipt finalization. Actual task RLS/guards and team scopes remain
  in the write path. Private helpers cannot directly write task content.
- [x] Auth/recipient locks precede team/project and root locks. Revalidate a
  prospective recipient set after waiting; newly appearing recipients require
  a fresh preparation. Actor budgets are serialized before content locks, and
  the existing team request advisory lock is acquired before its root lock too.
  Root/legacy writes and separate records stay atomic within one transaction.
- [x] Exact durable UUID/hash receipts acknowledge lost replies without reapplying
  old fields. Changed intent cannot reuse the same request. Two identical
  simultaneous requests execute once. A failed final receipt rolls back the root,
  derived field fences and upstream team receipt together.
- [x] Preparations bind the actor, command hash and transaction ID to the expected
  resulting tree hash. A direct finish cannot invent a receipt or use a preparation
  committed in another transaction. Normal public calls finish/remove their
  preparation; failed public statements roll it back. Preparation and receipt
  tables deny direct customer/service reads and writes, with RLS enabled.
- [x] Bound command JSON to 128,000 bytes and source hierarchy to 2,000,000 bytes
  before expansion (and after a root wait). Existing decoding bounds remain.
  Preparations have a per-actor 64-row cap, stale own preparations can be reclaimed
  after ten minutes, and new receipts have a per-actor 2,000 per rolling 24 hours admission limit.
  Recorded retries bypass the new-operation limit; receipts are not expired into
  fresh operations. Boundary/load/retention acceptance remains open below.
- [x] Keep internal field fences out of read protocol 1. Its strict existing
  client reader reconstructs each repo's actual post-edit database response.

The SQL is `supabase/migrations/20261029005723_child_task_field_edits.sql`.
The public RPC is `taskfold_edit_child_task(_body jsonb)`. Required body members:
`protocol`, `account`, `request_id`, `task_id`, `task_generation` (nullable legacy value),
`project_id`, `node_key`, `incarnation`, `revision`, and `changes`. The receipt
returns those identities with the account, resulting node revision and `replayed`;
it returns no old task/child plaintext. A receipt is not a fresh task snapshot.

## Verified scope

Each repo passes **95 real PostgreSQL checks**, including:

- An explicit intended-account binding refuses a saved command under another
  live account, even when both accounts can edit the same shared project.
- Personal edits and two different fields from one captured child revision;
  unrelated siblings, nested nodes, root fields and opaque history survive.
- Stale same-field and changed/returned or removed/restored field values refuse;
  old incarnations cannot target recreated keys. No-ops preserve field revisions.
- Real lock contention for disjoint commands, competing same-field commands and
  duplicate request IDs. `database.json` records the actual contention graph,
  rather than treating a sleeping task as evidence of a database lock.
- Distinct team actors preserve disjoint changes, while a viewer/outsider/revoked
  editor cannot write or replay under lost write permission. Existing writer gates
  still apply. Personal and team receipt failures roll back all affected rows.
- Invalid values/fields, wrong targets, missing sessions, expiry while waiting,
  direct finish/preparation misuse, archived writes and oversized source refusal.

Each repo also passes **94 selected Core/transport cases**: 20 child-read cases,
19 existing tree cases and 55 existing account-transport cases. The new case reads
`TaskfoldTests/Fixtures/child-task-field-edit-read.json`, exported from that repo's
actual final database response, and verifies strict protocol compatibility and
exact reconstruction. No new native app source changed in this stage, so no
repeat app build or native runtime claim is made. Core logs contain other existing
test warnings; the edited child test has no warning in the final runs.

`database.json`, `core.log.gz` and `verification.json` bind the results and source
hashes. Official before/after advisors add no findings over seven known minimal
fixture findings. Containers are removed in `finally`. The fixture deliberately
commits one private preparation to prove it cannot be finished by another
transaction; it is synthetic and disappears with that owned container.

## Boundaries and remaining work

- [ ] **Native commands.** Typed command/receipt decoding, durable offline intent,
  retry/auth/recovery state, stale response refusal, Store/editor integration,
  user-facing conflict/retry states and real native/accessibility acceptance.
  The current read layer alone cannot authorize an independent edit.
- [ ] **Other actions.** Completion epochs/history, insert/delete/move/reorder,
  structural baselines, restore and certified Undo. The field endpoint explicitly
  refuses these actions. Full migration remains legacy-tree authoritative.
- [ ] **Full schema and lifecycle.** The fixture uses
  `loadWorkflowRunSchema({taskTypes:true})` plus the real child-record/read SQL;
  it includes task-heading contracts but is not every current hosted trigger,
  network policy or genuine Auth delivery. Project/role/account departure, history
  policy, quota boundary/load acceptance and full custody remain open.
- [ ] **Larger/legacy hierarchies.** The existing team adapter retains its 128 KB
  root-edit envelope cap. Normalization of legacy absent/null child containers may
  differ from the exact prepared result; finalization refuses/rolls back rather
  than silently normalizing saved work. Internal adapter work, reviewed legacy
  recovery and performance/load acceptance are needed before broad exposure.
- [ ] **Rollout.** No hosted schema, ordinary client gate or old-client safeguards
  are changed. User-deferred deployment, old-client transition and distribution
  stay deferred; validation of this candidate is not rollout acceptance.

The draft was exercised by direct SQL and official advisors before CLI 2.109.0
created the canonical filename independently in each repo. A final bounded-source
guard was then verified with the complete canonical query/advisor suite in both.
The full local Supabase stack is stopped, so `migration list --local` cannot
connect and full-stack migration-history parity is not claimed. No hosted
`apply_migration` or deployment call occurred. Early lock-wait harness failures and
corrections are transcribed in `attempts.json`; overwritten raw draft logs are not
represented as preserved evidence.

Reproduce from this repository:

```sh
SUPABASE_TELEMETRY_DISABLED=1 node Scripts/Database/test-child-task-field-edits.mjs /tmp/child-edits.json
swift test --scratch-path /tmp/taskfold-audio-recovery-core-mac --jobs 2 --filter 'ChildTaskRecordReadTests|SubtaskTreeTests|AccountTransportTests'
```

The tests use synthetic users/sessions/tasks in uniquely labelled disposable
PostgreSQL 17.6 containers and an ephemeral loopback-only advisor port. No real
token, task, account, provider, microphone or device is used.
