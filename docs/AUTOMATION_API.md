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
2,000/account/day. A separate admission budget covers rejected traffic; its checked client-header pair is now verified on this project.
The feature remains disabled pending the remaining hosted lifecycle acceptance.

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

## Portable reminder authoring

`reminder_specs` uses the native versioned array, at most 20 rows with distinct
UUIDs. New supported schedules can be added, edited or explicitly removed under
the create/update capability. Apply the existing full planning/reminder baseline
and normal conflict-review contract. Independent reminder schedules never create
successor tasks; task recurrence remains a separate setting.

| Version | Schedule fields | Validation |
| --- | --- | --- |
| 1 | `kind: relative`, `anchor: planned`, integer `offset_minutes`; or `kind: absolute`, explicit ISO `at`, named `time_zone` | Existing native relative/fixed contract; offsets −10080…10080. |
| 2 | `kind: recurring`, `start_day`, minute-only `time`, named `time_zone`, `recurrence` | Daily/custom/weekly/monthly/yearly native calendar rules; first selected anchor; optional count 1…999 and civil end. No from-completion clock. |
| 3 | `kind: interval`, `interval_schedule` | Whole `start_ms`, `every_minutes` 5…10080, nullable count 1…999 and nullable inclusive `until_ms` not before start. Milliseconds must be within Gregorian years 1…9999. |
| 5 | Version-2 fields plus `holiday_policy` | Explicit finite holiday-year snapshot; skip or next-day mode. |
| 4 | Supported base row with `version: 4`, `schedule_version: 1/2/3/5`, `presentation: time-sensitive` | Explicit local-only wrapper; no nested wrapper and no reserved planned identity. |

Versions 2/3/5 and wrappers require exactly `["local"]` channels. They accept an
optional Boolean `enabled`; native default is true. The reserved planned reminder
UUID remains relative-at-plan only. Calendar clocks must be `HH:mm`, use a named
source zone (no GMT offset-style name), and begin on a valid selected civil day;
a completely skipped day is refused. The app's scheduler handles daylight-saving
folds/gaps and queue admission. No delivery permission or guarantee is implied.

Holiday policies contain `version: 1`, `year`, sorted unique same-year `dates`
(up to 366), `source`, `region`, lowercase 64-hex `digest`, `mode: skip/next-day`
and Boolean `avoid_weekends`. API-authored source/region labels are nonblank and
bounded to 160 Unicode code points each. Optional `origin` is `nager-v4` with an
uppercase two-letter `country` and optional matching subdivision (e.g. `US-CA`).
The caller supplies a reviewed snapshot: the API neither fetches a country
calendar nor verifies that an asserted provider digest proves provenance. Native
country-calendar review and updates remain the source for automatic calendars.

Unrecognized/future or private location rows can only be carried forward exactly;
tools cannot add, rearm, disable, alter or remove them. Supported rows may also
carry extension fields. When editing a supported row, retain extension values from
the baseline, including recurrence, interval, holiday-policy and origin extensions.
Dropping/changing those unknown values is refused. Explicitly removing an entire
supported row is allowed. This preserves newer-reader data while permitting edits
to all implemented portable schedule kinds, including child checklist reminders.

Time Sensitive remains a presentation request, subject to the device/workspace
allowance, OS settings and normal fallback. This API does not enable Critical
Alerts or remote delivery, expose private places, or modify task planning dates
to accommodate a reminder's holiday policy.

## Busy transactions and safe retries

PostgreSQL deadlock (`40P01`), serialization (`40001`) and unavailable-lock
(`55P03`) responses now project a safe `503`, `Retry-After: 1`, no-store and a
browser-readable retry header. Private SQL diagnostics never reach the caller.
Writes explicitly say to retry with the **same request ID**. Keep the original
body/generation/baseline for that retry: a transient rollback can be followed by
a real `409` if another client changed or replaced the task. At that point fetch
the current task and review a new intent instead of forcing the old edit.

The native identity mutex remains intact. An atomic native delete/recreate can
form a lock cycle with a waiting automation edit. The verified actual PostgreSQL
case rolls the edit back, leaves the replacement intact and returns the retry
hint; an exact HTTP retry then refuses the old generation with `409`. Successful
operation quota and the retry journal remain unchanged by both failures, while
the separately committed admission budget counts both attempts.

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
Portable relative, absolute, calendar, elapsed-interval and holiday-aware reminders
can be authored and edited, including Time Sensitive wrappers. Future/private rows
are preserved exactly; private location markers require native private-place review.
See the schedule contract below.

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
(see `AUTOMATION_ACCESS.md`); verify the admission proxy-header contract and budgets;
real hosted Auth/TLS/PostgREST, timeout, concurrency, quota and revocation
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


23 October portable-reminder checkpoint: 131 synthetic native-reader cases match
SQL classification in both independently owned repositories. Each repo additionally
passes 221 portable SQL assertions (including those cases), the existing 101
mutation checks and 31 actual loopback HTTP assertions, plus 170 selected Core
tests. The SQL runner loads all eight automation candidates in order. Source
fingerprints and exact scope are in `p2-automation-portable-reminders-evidence.json`.
Hosted delivery/races, native UI acceptance for this permission-copy change, abuse
controls and coherent deployment remain open. The API stays disabled/undeployed.


## Admission limits — inactive candidate

Both production handler factories now admit every non-OPTIONS request before
reading its body, checking task credentials or invoking live Auth/task operations.
The service-only admission RPC commits separately from task effects, so later
input/Auth/access/conflict failures do not erase this admission charge. Existing
successful account/key quotas and immutable retry claims remain independent.

| Per fixed UTC minute | Task route | Key management route |
| --- | ---: | ---: |
| Route-wide admission attempts | 1200 | 600 |
| Canonical client IP | 120 | 60 |
| Complete credential fingerprint | 120 | 60 |

Management and task budgets are independent; exhausting the task route cannot
consume management/revocation capacity. Every admission RPC first consumes its
global allowance, then its IP allowance, then its credential allowance. A denial
returns a minimal `429` with `Retry-After` (1–60 seconds), no-store headers and no
private budget dimension. Invalid credentials share these same budgets. A failed
limiter/configuration returns `503` and never authorizes work. Admission has a
two-second network/stream deadline and 2048-byte response bound; this time is
included in the handlers' existing total time budget. Hosted DB timeout
propagation and concurrent lock behavior still require actual acceptance.

The private counter table stores route/dimension, HMAC fingerprint, minute,
count and expiry only. It contains no raw IP, token, account or task payload.
HMAC-SHA256 uses the server service credential with distinct IP/credential domains;
raw values never reach the admission RPC. Key rotation resets these transient
fingerprints, not durable account/key usage. There are no direct client/service
table grants; RLS is enabled. A route-local transaction lock makes its three
budgets atomic. Expired non-global counters are pruned in batches of at most 128
on allowed admission calls, with a three-minute expiry and global allocation cap.
Idle stale rows remain bounded until later traffic; there is no task/history
retention change. The owner-only explicit-clock helper enables deterministic
rollover tests; the service entry always selects the server clock after its lock.

Workers cache only negative decisions, at most 1024 entries for at most the
reported minute remainder. Positive grants always consult the shared store.
Cached denials avoid repeat database work and cancel the unconsumed body. This
is function-level admission protection; it cannot prevent provider invocation
charges or substitute for upstream network/DDoS controls.

**Verified project-specific proxy contract:** the hosted probe found three
forwarding hops. The first matched the stable `CF-Connecting-IP` identity; the last
changed between otherwise identical requests. The previously unenabled
`supabase-append-v1` assumption was rejected and is now refused by the code.
The supported mode is `supabase-cloudflare-v1`: require a canonical first
`X-Forwarded-For` address and an identical canonical `CF-Connecting-IP`. Missing,
malformed, duplicate/comma-separated confirmation, mismatched pair, unknown mode
or unsafe server configuration fails closed. Other claimed client-IP headers and
later proxy hops do not choose the budget. IPv4/IPv6 spelling is canonicalized.

A short-lived signature-authenticated diagnostic endpoint verified the actual
production extractor from the Mac's request and a relayed Edge-server request,
with distinct identities. Forged single/multiple XFF values and six alternate
headers did not replace the first identity; the CF override request received a
403 before the diagnostic handler. The production pair stayed matched in all
successful cases. This is evidence for this project and these paths, not a
universal rule about arbitrary reverse proxies. Re-probe after changing ingress.
Cloudflare documents special Worker/stacked-proxy behavior; requests whose pair
disagrees are refused rather than silently selecting an unconfirmed address.

All diagnostic functions were deleted and the original six deployed functions
kept their versions. The mode is still **unset**, all nine automation migrations
remain unapplied, and neither automation endpoint is deployed. Header identity
is admission input; it never replaces task-key/Auth account authorization.
Only complete credential HMACs select a credential budget, so a public key UUID
cannot consume a different secret's credential allowance.

Local verification per repo: 157 actual admission SQL assertions, 221 portable
reminder and 101 mutation assertions, 140 loopback HTTP assertions, 40 Deno tests
and lint. The HTTP run uses the actual default gate and real SQL; its controlled
loopback proxy is not evidence about Supabase's hosted header trust. The older
31 operation-specific handler unit tests explicitly bypass admission so their
transport/projection checks remain isolated; nine additional admission tests cover
both default factory entry points, fail-closed behavior, HMAC projection, caches
and body cancellation/deadlines. See `p2-automation-ingress-evidence.json`.

Sources checked: [Supabase rate limiting](https://supabase.com/docs/guides/functions/examples/rate-limiting),
[Data API security](https://supabase.com/docs/guides/api/securing-your-api), and
[Supabase client-IP discussion](https://github.com/orgs/supabase/discussions/7884).
The published IP discussion identifies the header; it does not prove this project's
current overwrite/append trust behavior. No new external limiter provider or
client-facing API is enabled by this checkpoint.


### Hosted header and independent-connection checkpoint

The actual hosted parser check passes 13 assertions. Its P-256 private signing
key stays in the runner's memory; requests expire after 60 seconds, the endpoint
expires after 15 minutes, and final deletion is positively checked. Responses use
keyed fingerprints and coarse booleans only. Raw addresses, tokens and task data
are not persisted in the evidence. The relay is restricted to the same temporary
endpoint and a signed direct child, so it cannot become an arbitrary proxy.

Each repository independently passes 20 real PostgreSQL 17.6 assertions in a
network-isolated container: three batches of 12 distinct backend connections
race for the final global, IP or credential slot; exactly one wins and 11 are
denied. Counts never overshoot, task exhaustion leaves management capacity, and
an actual advisory-lock wait raises 55P03 within the configured bound, allocates
no rows, and recovers after release. These are actual independent PostgreSQL
connections, not PGlite's serialized queue. The image is digest-pinned, no host
port/user file is mounted, data uses tmpfs, and the owned container is removed.
This is local PostgreSQL concurrency, not hosted PostgREST/task-effect acceptance.

Both repositories also pass the 221 portable/101 mutation/140 loopback checks,
46 Deno tests (including six diagnostic tests) and lint. The HTTP fixture now
models the matching header pair. See `p2-automation-hosted-ingress-evidence.json`.
Next: task mutation/revocation/membership races, hosted Auth/session/key lifecycle,
timeout behavior and native management acceptance before coherent deployment.
The full Px goal and all user-deferred work remain active/unchanged.

[Cloudflare header reference](https://developers.cloudflare.com/fundamentals/reference/http-headers/)
provides the header and Worker context; the project-specific probe supplies the
actual behavior evidence. The old last-hop assumption was never enabled.


### Independent task-operation concurrency checkpoint

Both repos now pass 99 real PostgreSQL 17.6 assertions. Controlled transactions
hold a real account/task/membership lock until `pg_stat_activity` and
`pg_blocking_pids` show the workers waiting on that exact holder; separate backend
PIDs are recorded before release. These cases verify duplicate retries, competing
request bodies, disjoint and overlapping edits, one recurring successor, both
revocation/write orders, new-key exact retries, membership withdrawal, generation
replacement, newly linked descendants in a deletion review and concurrent
minute/day/account quotas. Failed work leaves no stranded journal claim.

The generation-replacement case also exercises the actual Deno handler and actual
admission/task SQL through an owned loopback adapter. Its observed `40P01` becomes
HTTP `503`/Retry-After 1, and the identical request then yields `409`; the new row
survives. The local schema includes tracked native guards and all nine automation
candidates with minimal dependency tables, not every hosted trigger. These results
do not replace hosted Auth/PostgREST/native-account acceptance. Evidence and exact
barriers: `p2-automation-task-concurrency-evidence.json`.

Hosted acceptance is being prepared in a separate branch with production data
excluded. Its historical setup replay stopped after 28 older migrations, before
any automation candidate; that staging reproducibility issue must be diagnosed
before using it for account tests. The main database and deployed functions have
not been changed by the task-race work. No automation candidate is enabled.


### Hosted lifecycle acceptance — 23 October

`Scripts/Diagnostics/test-automation-hosted.mjs` now owns a real hosted runner in
each repo. It refuses main, persistent, data-bearing and unrelated branches; reads
credentials only from an owner-private CLI JSON export; uses unique temporary
endpoints and two synthetic confirmed accounts; and removes its users/endpoints/
local stage in `finally`. Summary output contains named booleans and statuses,
never tokens, hashes, passwords or response bodies.

Both platform-source runs pass 42 checks through Auth, Edge and PostgREST,
including denied scope/account access, private RPC protection, one-time enrollment
retry, permanent discarded-setup refusal, paging, task mutations, exact replay,
real session revocation and delegated-key revocation. The empty branch required
a historical policy/grant replay repair before its 82 baseline plus nine candidate
migrations passed. That repair and candidate deployment never touched main.

See `p2-automation-hosted-lifecycle-evidence.json` for exact proof and cleanup.
This closes the basic hosted lifecycle gate. Native app management/Keychain/
clipboard testing and hosted timeout/cancellation acceptance remain separate.
