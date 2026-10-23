# Automation task API — inactive candidate

The owned candidate implements scoped reads and create, update, complete, reopen
and reviewed delete operations. It is not deployed or enabled. Native management screens and device-private setup recovery are implemented
as a gated candidate; hosted acceptance remains required before availability.

## Authentication and transport

POST to `automation-tasks` for reads or `automation-tasks/write` for mutations,
with a task-key Bearer token and `X-Taskfold-Automation: 1`. Both routes use the
exact envelope `{ "action": "...", "body": { ... } }`. The token is
`tfk_v1_<32 lowercase key UUID hex>_<43 base64url entropy>`. Only its SHA-256
and key ID reach a fixed service-only RPC; the raw token never reaches Auth or
a task table. Management uses native Auth JWTs; task-key deployment would use
`verify_jwt:false` and the SQL authorization below. Neither is deployed.

SQL checks current Auth account/removal state, key expiry/revocation, capability
and budgets in the same transaction as resource access and effects. Sign-out
does not revoke delegated tools. Account removal permanently revokes their keys.
Capabilities are `tasks:read`, `tasks:create`, `tasks:update`, `tasks:complete`
(including reopen) and `tasks:delete`. Checklist progress also requires complete.
Keys last 7/30/90/365 days; issuance allows 20 active keys and 10 new keys per
UTC day. Successful-operation budgets are 60/key/minute, 1,000/key/day and
2,000/account/day. Rejected traffic still needs gateway/IP controls.

Reads allow 8,192 input bytes; writes and responses allow 1,048,576 bytes.
Input has a two-second deadline and the handler a 15-second overall deadline.
The public RPCs configure ten-second statement budgets; private operations use
three-second lock waits. Actual hosted enforcement remains unverified: see
[Supabase timeouts](https://supabase.com/docs/guides/database/postgres/timeouts)
and [PostgREST transaction settings](https://docs.postgrest.org/en/stable/references/transactions.html).
Redirects are refused, responses are no-store, and explicit Bearer requests have
CORS preflight support without credentialed cookies. Errors project no private
SQL details: 400 input, 401 key unavailable, 403 capability, 404 resource,
409 conflict, 413 size, 429 quota, 503 temporary failure; missing protocol is 428.

## Reads and review tokens

`get` takes `{ "id": "<UUID>" }`. `list` accepts optional `limit` 1–50 (default25),
`project_id` (null means Inbox), Boolean `completed`, and `after` task UUID.
Omitted filters include all accessible matching tasks, including archived
projects. UUID ordering and `next_cursor` support current-data pagination, not
a frozen snapshot. If a cursor becomes unavailable or no longer matches,
restart listing. A large projected page can exceed the response bound; reduce
its limit. A single supported formatted note fits the bound.

Access is own Inbox or project owner/accepted collaborator. Task authorship
does not bypass lost project access. Pending invitations and foreign resources
are unavailable. Explicit projection excludes future columns automatically.
Each task includes `task_generation`, `completion_version` and a 64-hex `revision`.
The revision is an opaque HMAC of the complete canonical row using a private
server secret, including unprojected fields; do not compute or interpret it.

## Project and section discovery

On the read route, `projects` accepts optional `limit` (1–50, default 25) and
`after` project UUID. It returns `projects`, `next_cursor`, and the account’s
`inbox: { "name": "Inbox", "project_id": null, "section_id": null }` destination.
Each project includes only `id`, `name`, `color`, nullable `order_index`, nullable
`parent_id`, `parent_unavailable`, `is_archived`, `ancestor_archived` and
`accepts_tasks`. A shared child never discloses an inaccessible parent’s UUID;
that case returns null parent plus `parent_unavailable: true`.

`sections` requires `project_id` and accepts optional `limit`/`after` section UUID.
It returns `project_id`, `sections`, and `next_cursor`. Each section includes only
`id`, `project_id`, `name`, and nullable `order_index`. Inbox has no sections;
use null project and section IDs when creating an Inbox task. An unsectioned
project task uses the selected project UUID and null section ID.

Both actions require `tasks:read`, recheck current owner/accepted membership,
and share quota/authorization and resource locks in one transaction. Pending
invitations are excluded. Cursors are reauthorized and section cursors must still
belong to the selected project. Pages use ascending UUIDs; after collecting pages,
use `order_index` within the project hierarchy or section list to reproduce the
native order. Pagination reads current data, not a frozen snapshot: restart if a
cursor is deleted or becomes unavailable.

Archived projects/sections remain readable. `accepts_tasks` describes archive
state, not the key’s create permission or a reservation: a subsequent write still
requires its own capability and current destination validation. Future/unknown
columns, owner identities, membership details and source metadata are never
projected. These actions use the existing read input/response bounds, deadlines,
no-store handling and safe errors. No project/section mutations are exposed.

## Mutation contract

Every body includes a fresh `request_id`, target `id`, `task_generation` and
named `time_zone`. Create supplies a non-null new generation. Existing legacy
tasks may have a null generation; use exactly the value read from the server.

| Action | Additional body fields | Effect |
| --- | --- | --- |
| create | `fields` | Creates for the verified account in Inbox or an accessible active project. |
| update | `base`, `fields` | Native guarded field merge; disjoint changes survive, stale edited fields conflict. |
| complete / reopen | `base` | Reviews completed state, timestamp and completion version; changes one current cycle. |
| delete | `revision`, `descendants` | Reviews the entire linked recurrence family before native cascade deletion. |

Use the returned task projection as `base`; update planning requires the reviewed
`due_date`, `due_time`, `time_zone`, `scheduled_at` and `reminder_specs` values.
Writable details include title, description, priority, dates/planning, project,
section, labels, assignment, checklist, recurrence, deadline and estimate.
Server identity, creator, completion history, comments, attachments, provenance
and unknown fields are not freely writable. Description capacity is 512,000
UTF-8 bytes. Strict bounds/types and destination/member checks apply.

Project moves clear old section and recursive assignees before reviewing any
explicit replacements. Checklist updates preserve omitted nested children and
opaque/read-only data; authoring completion progress requires complete scope.
Simple relative/absolute reminder authoring is supported. Existing advanced or
future rows are preserved exactly; portable advanced-reminder authoring remains
a feature gap. Private location markers require native private-place review.

Timed defaults read and lock the actor's preferences atomically; unsupported
future documents remain opaque. Recurring completion uses native-compatible
clock/rule/default/checklist semantics, creates successors for the actor, retains
source creator/project, resets occurrence-only data and suppresses duplicates.
Unsupported recurring rules refuse rather than silently dropping a successor.

Delete descendants are `[{ "id": "<UUID>", "task_generation": "<UUID or null>",
"revision": "<64 hex>" }]`, excluding the root. Enumerate the full current
recurrence-parent family through accessible reads (maximum 1,000 descendants).
Missing/new/changed or inaccessible members refuse deletion. Root and family
locks plus generation/revision checks protect the existing cascade contract;
no FK or portable-backup link behavior changes.

## Retry and security boundaries

The private begin/effect/finish pipeline runs inside one SQL transaction. The
verified account supplies the native actor temporarily; prior request context
is restored on success or failure. Clients cannot call private helpers directly.
Deferred checks refuse pending journal rows at commit, rolling back all effects.

An account/request UUID permanently binds operation, target generation and
canonical payload hash. Retry the exact same body after an uncertain response;
changed reuse conflicts. Applied replay reauthorizes the current key, root and
recorded successor before returning a minimal immutable receipt. It does not
return historical task text. A new incarnation conflicts. Deleted resources
require the saved access context. Read current data separately: a historical
receipt does not mean the task still exists or remains completed.

The journal stores no body, task text or raw secret. It survives deletion and
completion cycles, has no pruning job, and cascades only with its Auth account.
Private tables use RLS and deny direct client/service table access. A read
revision secret is generated server-side and never projected.

## Verification and remaining work

Each repo independently passes 101 real local PostgreSQL/PGlite mutation
assertions, 18 loopback HTTP → real Deno handler → SQL assertions, 17 mocked
handler tests, lint, 49 selected native transport tests and its app build.
The local schema includes actual guarded native migrations and minimal owned
dependencies; it does not reproduce every hosted trigger. Reserved `f095cafe-*`
fixtures and example.invalid accounts are removed; local servers close afterward.
No app host is launched by these backend checks.

Remaining before enablement: hosted native create/review/recovery/revoke acceptance
(see `AUTOMATION_ACCESS.md`); project/section discovery; portable advanced reminder authoring; rejected-request
controls; real hosted Auth/TLS/PostgREST, timeout, concurrency, quota and revocation
acceptance; then signed-in native flows and coherent deployment. Email intake,
webhooks and advanced teams remain separate unfinished work. See
`p2-automation-task-mutations-evidence.json`. The full Px objective remains active;
user-deferred physical-location, release, old-client and remote-reminder work stays deferred.


## Cancelling unfinished native enrollment

The native-JWT `automation-keys` candidate also accepts `cancel` with exactly
`{ "id": "<UUID>" }`. It verifies the current Auth subject/session and calls only
`taskfold_automation_cancel_key`. A confirmed reply is exactly
`{ "account": "<verified UUID>", "id": "<requested UUID>", "cancelled": true }`.
False, missing, mismatched or malformed receipts do not finish local recovery.

Cancellation and creation use the same account transaction mutex. If a key already
exists for this account, cancellation permanently revokes it; otherwise a private
owner/ID tombstone rejects any later INSERT. Foreign IDs yield the same minimal
receipt without exposing or changing foreign keys. Tombstones contain no raw key,
hash, name, scopes or task data, have RLS and no client/service table grants, and
cascade only with their Auth account. There is no retention pruning that could
revive a late request. An owner/date index bounds the 100-new-tombstones/day check;
existing cancellation retries and owned-key revocation remain available at that
limit. This history is independent of the ten-key issuance budget.

The candidate migration `20261023002825_automation_enrollment_cancellation.sql`
remains unapplied. Local tests cover both operation orders and authorization;
real cross-connection Auth/PostgREST races and gateway/IP controls remain open.
