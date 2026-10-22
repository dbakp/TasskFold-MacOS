# Automation task API — inactive candidate

The feature is not enabled or deployed. This document describes the owned
candidate, not a public availability promise. All five capabilities remain the
product target: read, create, update, complete and delete. Only the get/list read
path has a production candidate wrapper/HTTP handler so far. The write journal
has tested private helpers, not a production mutation endpoint.

## Reads

The candidate `automation-tasks` Edge Function accepts POST, a Taskfold task-key
Bearer token and `X-Taskfold-Automation: 1`. It hashes the exact canonical
`tfk_v1_<32 lowercase key UUID hex>_<43 base64url entropy>` secret and forwards
only its SHA-256/key ID to the fixed service-only `taskfold_automation_read` RPC.
It never forwards the secret to Auth or a data-table endpoint. Custom keys are
independent of ordinary native sign-out; SQL still checks the current Auth
account, removal status, key expiry, revocation, read scope and request budgets.
Those checks and the task/project/membership locks share one transaction.
Current SQL budgets count successful transactions; rejected traffic still needs
verified gateway/IP rate controls before public enablement.

Bodies are exactly `{ "action": "get", "body": { "id": "<task UUID>" } }` or
`{ "action": "list", "body": { ... } }`. List accepts `limit` 1–50 (default 25),
optional `project_id` (null means Inbox), optional Boolean `completed`, and an
`after` task UUID. Omitted filters include all accessible matching tasks,
including archived projects, as permitted by the existing read policy. Results
sort by task UUID, with `next_cursor` equal to the last returned ID when another
page exists. The cursor must still be accessible and match the filters; after
its deletion, loss of access or filter changes, restart the listing. This is
current data, not a frozen cross-page snapshot.

Project owners and accepted collaborators have project-task access. Ownership of
a task alone does not bypass lost shared-project access. Pending invitations,
foreign Inbox tasks and unavailable resources produce the same unavailable
response. Read results explicitly project existing task fields; new future
columns do not become API fields automatically. The handler checks returned
identities, filters, page size/order/cursor and safe-integer completion revisions.

Requests are capped at 8,192 bytes with a two-second input deadline. Server
responses are capped at 256,000 bytes; the overall handler deadline is 15 seconds.
Redirects are refused. Responses are no-store. Private SQL/upstream details never
become client errors. Statuses distinguish input (400), unavailable key (401),
missing scope (403), unavailable task/page (404), conflict (409), size (413),
quota (429) and temporary service failure (503). Protocol absence is 428.
The management endpoint retains native-JWT gateway checks; this custom-key
endpoint would require `verify_jwt:false` and its own SQL key authorization when
ready for deployment. Neither endpoint is changed/deployed by these candidates.

## Atomic write-journal contract

Each future private write RPC must call `automation_request_begin`, apply the
actual guarded native effects, then call `automation_request_finish` in the same
SQL transaction. These helpers have no client or service-role EXECUTE grants.
There is no standalone claim/finish endpoint. Authorization cannot be separated
from effects or replay into another RPC.

The journal is keyed by account plus client request UUID, across key rotation.
It permanently binds operation, target ID, generation, canonical JSONB-text
SHA-256 payload hash and original access context. Changed reuse conflicts; it
cannot become a new task creation or a later completion. Exact applied replay
reauthorizes the current key/scope and recorded resource before comparing the
request or returning a minimal historical receipt. A new incarnation conflicts.
A deleted task may yield its historical receipt only while its saved Inbox or
project access remains authorized. Receipts do not imply the task still exists
or that its current completion state equals the historical result; read current
state separately when permitted.

The journal stores no task text, request body, prior full task response or key
hash/secret. It deliberately has no task/generation FK and no retention-pruning
job. Task deletion and recurrence cycles cannot remove old claims. Auth-account
deletion cascades only that account's journal. Its account-prefix primary key and
indexed key FK support owner cleanup. A deferred trigger refuses a pending claim
at COMMIT, rolling back both the claim and actual task effect. The finisher checks
the originating transaction, current generation/revision, creation ownership,
completion/deletion and optional successor identity/access before recording the
immutable result. Private definer triggers support checks/cascades after the
calling wrapper has returned and under the Auth/service role.

Future wrappers must derive the native edit actor from verified begin results,
restore any temporary claim context, validate destination/section/assignment
access, apply default reminders, create/reset recurring successor data and honor
native guarded baselines. The journal cannot replace those operations. Tests use
a harness-only privileged pipeline with the real native patch/delete/generation
routines; that harness is not shipped as an API function.

## Verification and remaining gates

Each repo independently runs `npm run --prefix Scripts/Database test:automation-tasks`
and `deno test supabase/functions/automation-tasks/handler_test.ts`, plus Deno lint.
The local database runner uses pinned PGlite/pgcrypto and a minimal dependency
schema extended with actual native migrations. Its pre-managed merge helper is a
reviewed read-only snapshot of the existing live definition. It creates only
reserved `f093cafe-*` local fixture identities and example.invalid addresses;
all are removed, and the previous credential fixture passes/rolls back afterward.

89 local assertions cover access/RLS/ACL, paging/projection/size, actual native
edit/delete guards, deferred atomic rollback, immutable replay after completion
cycles/deletion/recreation, current authorization on changed retries, correct
creation ownership, cross-account nonce isolation and Auth cascades. Nine mocked
handler cases cover token/hash binding, input/response bounds and deadline,
metadata projection, confirmed result identity/pages and private-safe errors.

These are not real hosted Auth/PostgREST/HTTP, lock-race, email/webhook, native
management UI, Simulator user-flow or release acceptance. Native guarded-effect
tests are scoped local SQL checks. No current app runtime source changed, so no
new app build/runtime pass is claimed. Production create/update/complete/delete
wrappers, full successor/reminder semantics, explicit write-lock/time budgets,
real concurrency/quota acceptance, project/section discovery and premium native
key management/recovery/revoke review remain before enablement. See
`p2-automation-task-access-evidence.json`. The full Px goal remains active.


## Write-semantics checkpoint — 23 October

The unapplied `20261022222726_automation_task_writes.sql` is a helper/normalizer
candidate, not a production mutation endpoint. Full successor/checklist/reminder
data and defaults match 49 shared native goldens. Native direct/widget/bulk
completion creates for the acting workspace, preserving its source creator and
project. The corrected local INSERT predicate verifies that distinction.

Clock resolution chooses the first fold or first valid minute on the same day,
retains a valid explicit instant, and handles half-hour gaps. The candidate
normalizer uses that rule rather than PostgreSQL's different default. Its existing
invoker trigger has narrow EXECUTE on the pure wall/civil-time helpers for native
DML roles; those helpers read only supplied data and time-zone catalogs. Other
successor/default helpers remain private. No new schema USAGE or task access is
granted, and the hosted normalizer is unchanged.

Successor construction retains estimates, attachments, labels and unknown fields;
clears occurrence-only comments/deadline/sent state; resets nested IDs, completion,
dates and reminders; preserves metadata; and records a new action. Valid one-shot
absolute reminders are removed while opaque rows survive. If none remain, a
disabled planned-time row prevents accidentally reviving a default. Manual,
placeholder, disabled and duplicate choices retain native behavior. The future
RPC must read preferences atomically: absence means legacy zero-minute behavior;
unsupported documents stay opaque and skip implicit replacement. That read is not
implemented by the pure helper.

The existing deletion self-FK cascades to later occurrences. A production delete
RPC must review/lock a complete set of descendant baselines, current generations
and access before invoking native guarded deletion; missing/new/changed members
conflict. Preserve native/backup link contracts. No FK or backup behavior changed
here. Full write/reopen wrappers, real service/races and native key UI remain
required before feature enablement. See `p2-automation-write-semantics-evidence.json`.
