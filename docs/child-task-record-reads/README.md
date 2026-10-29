# Authorized child-record reads — server candidate

29 October 2026. Both repos own this disabled-by-default SQL read contract.
No hosted schema or normal app exposure changed. This completes the local server
read scope; independent child editing, client adoption and the full Px goal remain
unfinished. The [first migration stage](../child-task-records/README.md) remains
legacy-tree authoritative.

## Accepted scope

- [x] Public invoker `taskfold_read_child_tasks(uuid,uuid)` first checks the actual
  root task SELECT policies. Its private fixed-path definer helper independently
  requires a live verified actor/session and current personal/project/team read
  admission, including the existing separate team-read gate. The helper's direct
  execution cannot grant an outsider or revoked collaborator/viewer access.
- [x] Lock the candidate config, Auth actor/session and root during the accepted
  read. Use the exact root generation, including legacy null. Recheck session
  expiry and current access after assembling the response. A real test waits on
  a concurrent root edit and returns its committed winning child content.
- [x] Require explicitly adopted, ready, current projections. Independently decode
  the current source and compare every stored child key, parent, order, path,
  container shape and full non-child fields. A wrongly marked ready row, stale
  snapshot or mismatched stored child is refused without returning child content.
- [x] Return protocol 1, account, project, task ID/generation, projection revision,
  root container kind and the records' incarnation/revision/structure/fields.
  `records` has deterministic identity-path ordering; consumers reconstruct sibling
  order from parent and `sibling_order`, not response array order. The raw duplicate
  source snapshot is not returned. The inherited decoder caps at 1,000 nodes and
  24 levels; responses above 2,000,000 UTF-8 bytes are refused.
- [x] No direct table grant to authenticated, anonymous or service roles. Only the
  authenticated role gets the public entry and independently authorizing private
  read helper. Configuration starts Off and cannot be changed by customer roles.
- [x] Each repo passes 43 checks against its own canonical migration: owner,
  accepted collaborator, archived team viewer, ungranted guest, forged metadata,
  missing/wrong/expired/deleted sessions, ban, revocation, missing/wrong-generation
  roots, malformed/stale/corrupt projections, oversized data and real lock waiting.

`database.json` contains the assertions and official before/after advisors.
There are no added findings over the seven known minimal-fixture baseline findings.
Both owned containers were removed. `verification.json` binds the canonical SQL
and test sources. No app source changed, so no new app build, native UI or spoken
acceptance is claimed.

## Boundaries

The fixture loads inspected minimal dependencies plus actual repository migrations
through team task lifecycle/checklists and the first child-record migration.
It does not reproduce every current hosted trigger/policy or the entire auth and
network stack. The private helper uses the existing personal/team admission
helpers; the public invoker additionally checks root SELECT RLS. Full current
schema/security review, network delivery and revocation after a response has left
Postgres remain part of client/full-lifecycle acceptance. Clients must discard a
response if account/session/task/project context changes before it is applied.

Source is `supabase/migrations/20261029001127_child_task_record_reads.sql`.
The draft was iterated through direct SQL in a disposable PostgreSQL 17.6 fixture,
then official advisors ran. Supabase CLI 2.109.0 generated the filename separately
in each repo (both calls happened within the same second). Each canonical file
was then tested independently. The full local Supabase stack is stopped:
`supabase migration list --local` cannot connect, so local-history parity and
hosted deployment are not claimed. No hosted apply/deploy call occurred.

Early fixture/CLI failures and corrections are transcribed in `attempts.json`;
raw draft logs were overwritten during iteration. Failed attempts are not counted
as passes. The documented
[per-command telemetry opt-out](https://supabase.com/docs/guides/local-development/cli/getting-started)
avoids an observed CLI telemetry shutdown failure without changing global settings.

## Next work

1. [ ] Both apps: strict bounded envelope decoding and lossless reconstruction,
   exact account/server/session/root/project binding, stale-response refusal and
   current gate availability. Keep existing child UI behavior polished during adoption.
2. [ ] Per-child idempotent conflict-safe commands with root generation,
   incarnation/revision, structural baselines, certified completion/Undo and atomic
   legacy bridging; preserve current team scopes and unknown-field custody.
3. [ ] Offline queues, source/record divergence recovery, project/account lifecycle,
   full current-schema security review and native/widget/export acceptance.
4. [ ] Hosted rollout and older-client transition stay deferred by the user.

Reproduce from this repository:

```sh
SUPABASE_TELEMETRY_DISABLED=1 node Scripts/Database/test-child-task-record-reads.mjs /tmp/child-reads.json
```

This uses synthetic Auth/session/task data in one uniquely labelled owned
PostgreSQL container, plus official advisors on an ephemeral loopback port. No
real account credentials, tasks or user files are used or mounted.
