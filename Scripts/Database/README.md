# Assignment provenance SQL checks

From this repository, run:

```sh
npm ci --prefix Scripts/Database --ignore-scripts
npm run --prefix Scripts/Database test:assignment
```

This optional development tool uses a pinned PGlite PostgreSQL runtime in memory. It reads no app configuration, credentials, network endpoint or user container. Its dependency schema is deliberately minimal; the test checks the actual migration's PL/pgSQL, triggers, foreign keys, privileges and RLS, but does not reproduce all Taskfold Auth/project/task policies or HTTP behavior. The fixture rolls back, and the runner verifies the accounts are gone. This tooling is not an app build or release dependency.

`supabase/tests/assignment_provenance.sql` is also independently runnable as postgres against the complete Taskfold schema after the migration. It uses only its reserved synthetic UUIDs and `example.invalid` addresses inside one rolled-back transaction. Do not remove the transaction or use existing user/task IDs. Hosted acceptance must run that fixture against the actual policies; the local bootstrap alone does not prove it.

Migration `20261021122959_assignment_provenance.sql` matches the applied shared-backend migration history. Both platform repos own identical copies, with no sibling build dependency. Apply it once per backend, not once per app.

The SQL fixture tests the recording foundation separately from saved-filter integration. New assignment changes are server-recorded; missing legacy history, system actions without an account, removed actors and unverified recurring successors remain unknown. The immutable client catalog receives current-workspace rows through an optional account-fenced read; local actions use explicitly scoped cache evidence. Saved predicates, query cache/preview/grouping, native controls and widget membership are connected. Exact acceptance and remaining Mac/accessibility/concurrent gates are recorded in `docs/p2-assigned-by-filters-evidence.json`.


# Private location handoff SQL checks

From this repository, run:

```sh
npm ci --prefix Scripts/Database --ignore-scripts
npm run --prefix Scripts/Database test:location-handoff
```

This uses the same pinned in-memory PGlite runtime with an independent minimal bootstrap. It reads no credentials, app configuration or network endpoint and creates no app/release dependency. The actual migration and 28-assertion fixture cover strict input, owner/device isolation, immutable retries, expiry/retention, revoked access, completion/incarnation and lifecycle replay. All synthetic accounts/tasks/drafts roll back; the runner checks rollback. `--write-golden` is an explicit maintainer-only runner option for regenerating the four synthetic RPC fixtures from actual PostgreSQL output; ordinary test runs never rewrite fixtures.

`supabase/tests/private_location_handoffs.sql` is separately runnable as postgres against the full Taskfold schema after `20261022145128_private_location_handoffs.sql`. Preserve its single transaction, reserved `f083cafe-*` UUIDs and `example.invalid` identities. It follows the genuine owner-invites/member-accepts lifecycle instead of disabling production triggers. Do not substitute existing IDs or commit the fixture. The hosted fixture is SQL-role/JWT-claim simulation, not real Auth/PostgREST transport or mobile delivery acceptance.

Both repos own identical migration copies; apply once to the shared backend. Its hourly `taskfold-location-handoff-retention` job is specific to these drafts. It does not modify other jobs or backfill real tasks. Native handoff integration remains gated as documented in `docs/PRIVATE_LOCATION_HANDOFF.md`.


The account-removal runner also loads the status-proof migration and fixture using
PGlite's real pgcrypto extension. It checks client privilege denial, retained-key
rotation/revocation, and Auth/canonical/legacy file absence without printing keys.
These are local schema/role tests; live expiration/relaunch evidence is separate.


# Automation credential candidate checks

Run `npm run --prefix Scripts/Database test:automation` from this repository. The
owned runner uses the pinned PostgreSQL/PGlite runtime and an isolated minimal
Auth/removal bootstrap, then the actual candidate migration and rollback fixture.
It checks private privileges, live-session/account fences, immutable registration,
expiry/revocation, successful-operation quotas, metadata paging, permanent removal
revocation and Auth cascades. It reads no app configuration or credentials and
contacts no live service. This does not prove task operations, real concurrent
HTTP, a deployed migration or native management screens.


# Automation recurring-task planner candidate

Run `npm run --prefix Scripts/Database test:automation-recurrence` from this repo.
It applies the actual private planner migration to an isolated pinned PGlite
PostgreSQL runtime with pgcrypto, then compares all 316 shared golden cases.
`swift test --filter 'AutomationRecurrenceParityTests|TaskCompletionTests|RecurrenceTests'`
independently compares the same fixture with this app's actual native completion
implementation and runs its existing recurrence/completion regressions. The
runner also checks all helper execute grants, invoker/empty-search-path settings,
invalid clocks and independence from the connection's TimeZone. It never rewrites
the fixture. The credential suite loads both candidates together as well.

These are local planner/privilege checks, not task-write, concurrency, native
management UI, real HTTP or Simulator acceptance. The new migration remains
unapplied; no gateway or live task is changed. Both repos own their full inputs.


# Automation task-read and atomic-journal candidate

Run `npm run --prefix Scripts/Database test:automation-tasks`. This owned runner
uses the same pinned PGlite/pgcrypto runtime, minimal dependency schema and actual
native generation/completion/patch/delete migrations. The pre-managed merge
helper in its local bootstrap is a reviewed snapshot of the live definition.
It checks 89 task-read/journal/actual-native-effect assertions, including genuine
local authenticated/service roles and deferred COMMIT rollback, then runs the
previous credential fixture and verifies Auth cleanup/rollback. No endpoint,
credential or app configuration is read. All fixture identities are local only.

Run `deno test supabase/functions/automation-tasks/handler_test.ts` and
`deno lint supabase/functions/automation-tasks` for the nine mocked handler cases.
The HTTP candidate supports get/list; production mutation wrappers and native
management UI are still missing. No hosted deployment, real HTTP, lock race,
Simulator user flow or full task-write acceptance is claimed. See
`docs/AUTOMATION_API.md` and `docs/p2-automation-task-access-evidence.json`.


# Native/automation write-semantics parity

Run `npm run --prefix Scripts/Database test:automation-write-semantics` for 84
local assertions over 49 shared goldens, native-role INSERT ownership/normalizer
grants and fixture cleanup. This is a minimal owned dependency schema plus actual
native migrations, not full hosted-trigger or HTTP acceptance. The prior
`test:automation-tasks` still passes 89 checks after matching the distinct live
INSERT policy.

`AutomationWriteSemanticsTests` uses the same data through native planning,
default and completion code. Only explicit `TASKFOLD_WRITE_SEMANTICS_EXPORT`
maintainer mode exports synthetic deterministic goldens to a chosen file;
ordinary tests never rewrite inputs. Generation/action UUIDs and timestamp
spellings are normalized. Eleven wall-time expectations are independently
specified; other full expected outputs come from actual native algorithms.
The helper/normalizer candidate is unapplied; no full write gateway is claimed.
See `docs/p2-automation-write-semantics-evidence.json`.


# Automation task-mutation candidate

Run `npm run --prefix Scripts/Database test:automation-mutations`. Node and Deno
must be installed. The runner applies actual candidate/native guarded migrations
to pinned PGlite/pgcrypto with minimal owned dependencies. It checks 101 SQL
assertions, then 18 loopback HTTP assertions through the real Deno handler and
SQL (11 RPC calls). Deno is restricted to loopback network access. No hosted
configuration, real credentials or task data are read. Synthetic `f095cafe-*`
accounts are removed and both temporary servers close in finally cleanup.

Run `deno test supabase/functions/automation-tasks/handler_test.ts` separately
for 17 mocked handler cases. These checks do not prove hosted Auth/TLS/PostgREST,
all production triggers, independent-connection races or native key screens.
The mutation migration remains unapplied. See `docs/AUTOMATION_API.md`.
