# Task-change webhooks — inactive implementation

Updated 23 October 2026. Rank 6 remains in progress. The delivery transport, receiver-secret envelope,
private subscription schema, receiver-proof protocol, management handler,
transactional task-change outbox and leased dispatcher are implemented in each repo
independently as inactive candidates. Gated native screens are implemented; hosted
queue/delivery and signed scheduled invocation now pass. Scoped phone/tablet native
hosted flows and clipboard/spoken secret checks now pass. Native fault variants
and wider speech coverage remain open. No real task data was sent and nothing
was enabled on main. This milestone is a necessary part of automatic task-change delivery, not a
replacement for that feature.

## Delivery implemented

`supabase/functions/automation-webhooks/transport.ts` accepts a checked HTTPS
URL and one immutable signed message. Userinfo, fragments, whitespace/control
characters, malformed hosts, local names and private/special IP destinations are
refused. Public DNS names and public IPv4/IPv6 endpoints are supported without a
provider allowlist. Query strings are retained and must be treated as private
configuration by future management/history code.

Each attempt resolves anew, rejects an answer set containing a nonpublic address,
and dials one checked numeric IP. `socket.ts` upgrades that existing TCP connection
using the original hostname and platform certificate verification. The explicit
TLS handshake finishes before any payload is written. HTTP Host retains the same
original authority. There is no second DNS lookup, redirect, pooled connection,
cookie, native session or API credential. Unsupported/mapped/NAT64/6to4 and
non-global IPv6 routes are refused. The address policy follows the linked IANA
registries and must be maintained as allocations change.

The whole attempt, including signing, DNS, connection, handshake, write and
challenge response, has a ten-second budget; caller cancellation also closes the
owned socket. A late DNS/connection result cannot send data after cancellation.
The transport accepts at most 256 KiB of UTF-8 payload per request. The outbox
uses complete multipart events for larger supported snapshots; see the protocol
and explicit capture limits below.

The bounded HTTP/1 parser accepts HTTP/1.0 or 1.1, at most four interim responses,
16 KiB cumulative headers, 8 KiB lines and 64 KiB total response wire data.
Verification bodies are limited to 8 KiB, with Content-Length, chunked or
connection-close framing and strict UTF-8. Conflicting framing, folded/invalid
headers, malformed chunks and excessive trailers are refused or retried safely.
Compressed challenges are refused; requests ask for identity encoding. Ordinary
delivery reads only the final status and closes the connection without returning
receiver content.

2xx acknowledges delivery. 408, 425, 429 and 5xx can retry; Retry-After is parsed
as seconds or an HTTP date and capped at one day. 410 marks a removed receiver.
Redirects and other failures are refused. These are attempt outcomes only: the
durable retry schedule and user-visible failure states still need implementation.
A disconnected or timed-out request may already have reached the receiver.
Delivery is at least once; retry the same event ID/body and require receiver-side
deduplication. Never promise exactly-once remote effects.

## Signed message protocol

A distinct random 32-byte receiver secret signs each attempt with HMAC-SHA256.
The signed UTF-8 bytes are exactly:

`v1.<unix-seconds>.<subscription-uuid>.<event-uuid>.<unchanged-json-body>`

Headers are `X-Taskfold-Webhook-Id`, `X-Taskfold-Event-Id`,
`X-Taskfold-Timestamp` and `X-Taskfold-Signature: v1=<lowercase-hex>`.
Receivers must verify the original bytes, use a constant-time signature check,
reject stale attempt timestamps and durably deduplicate event IDs. Attempt
timestamps/signatures refresh on retry; event IDs and bodies do not.

Unlike task API keys, the dispatcher needs to recover a webhook signing secret.
`secret.ts` seals it with AES-256-GCM, a fresh random 96-bit nonce and a 128-bit
authentication tag. The associated data binds its versioned server master key,
owner and subscription. Swapping owner/subscription/key version or changing the
ciphertext fails authentication. Only the encrypted envelope belongs in a
private server table. Versioned master keys belong in server secret configuration,
never in SQL, native app resources, logs or exports. Production key provisioning,
rotation and recovery remain required; acceptance used disposable fixture keys.

## Subscription and receiver-proof implementation

`20261023050732_webhook_subscriptions.sql` adds only private subscription,
verification, cancellation, command-receipt and removal-marker tables. All enable
RLS and deny direct access, including to the service role. A fixed service-only
RPC checks the account and live Auth session within every transaction, using the
existing account mutex and Auth locks. The public SQL wrapper is invoker-only;
its private implementation owns the narrowly required privileges, has an empty
search path and a three-second lock budget. The RPC has a ten-second statement
budget. No client receives access to an internal verification-result action.

Scopes are all readable work, Inbox, or one exact readable project; events are
created, updated, completed, reopened and deleted. Scope selection does not grant
project access. Project ownership/accepted membership is checked at create,
begin/finish verification and new Resume actions. The dispatcher will also need
to check current task/project access before every send. A successfully verified
subscription alone does not implement task delivery.

Lifecycle states are Pending, Active, Paused, Revoked and derived Expired. Setup
IDs/settings are immutable. Retrying the same creation preserves its first secret
envelope, expiry and current state, even when the service re-encrypts the same
secret with a fresh nonce. A conflicting intent is refused. Discard-before-create
writes an account-bound permanent tombstone; a late creation cannot resurrect it.
Revocation erases the encrypted secret and stays terminal. Only deleting the Auth
account can remove setup/command/cancellation history. Starting account removal
also writes a permanent private block for a surviving Auth row; pruning an older
removal receipt cannot allow it to enroll a new webhook or resume an old one.
Physical Auth deletion cascades every private record, including that marker.

Management metadata contains the destination origin, never its path/query or
secret. The separate owned Details action permits explicit destination review.
Historical metadata remains revocable if an address becomes nonpublic; network
address authorization still runs before any verification request.

| Application limit | Budget |
| --- | --- |
| Live setups, including pending/paused | 5 per account |
| New setup identities | 10 per UTC day |
| New verification attempts | 6 per rolling minute, 60 per UTC day |
| New Pause/Resume command receipts | 200 per UTC day |
| Unknown setup cancellation tombstones | 100 per UTC day |
| Setup lifetime | 30, 90 or 365 days |

Exact retries are free of new-identity budgets. Existing revoke/discard remains
available at these issuance/control limits. HTTP ingress shares the independently
bounded key-management admission budget; it is separate from application limits.

Pause/Resume requires `{id, request_id, revision}`. Each state transition advances
the subscription revision. A new command with an old baseline needs review;
retrying an already applied command returns its durable acknowledgement and the
CURRENT metadata. An old Pause retry after a newer Resume cannot pause the
connection again. Command identity/result history is immutable for the Auth
account lifetime; it cannot be pruned into a new actionable request. Revocation
is inherently terminal and continues to require only the setup ID.

### Receiver verification protocol

The native-generated receiver secret is `tfwh_v1_<43 canonical base64url chars>`.
Decode the suffix to its 32 entropy bytes before HMAC use. Creation sends it only
to the authenticated Edge service, which hashes it for immutable-intent comparison
and encrypts it before SQL; raw secret text never reaches SQL or the response.
The server owns a versioned master catalog, configured only with
`TASKFOLD_WEBHOOK_MASTER_KEYS` (a JSON map of up to three version names to 64
lowercase hex characters encoding 32 master-key bytes) and `TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION`.
Keep old versions while their envelopes remain in use. Missing/invalid masters
fail creation/verification closed while authenticated list/revoke/discard remains
available. Production provisioning, rotation and recovery still require acceptance.

Verify takes `{id, attempt_id}`. SQL creates a random 256-bit nonce valid for at
most five minutes. Retrying that same attempt retains its nonce/expiry; a new
attempt cancels older outstanding callbacks. The service decrypts the owned
secret and sends a signed, content-free request:

```json
{"version":1,"type":"taskfold.webhook.verify","subscription_id":"<UUID>","attempt_id":"<UUID>","challenge":"<64 hex nonce>"}
```

The receiver must return exactly `challenge` and `proof`. Proof is lowercase hex
HMAC-SHA256 over the UTF-8 bytes `verify.v1.<subscription-uuid>.<attempt-uuid>.<nonce>`,
using the decoded receiver secret. The expected proof is never sent in the
request. Ordinary echo endpoints, wrong keys/nonces/attempts, malformed JSON and
extra response fields fail verification. WebCrypto verifies the signature rather
than comparing secret-derived strings. The transport's original signed-message
protocol and bounded challenge reader still apply.

Only the service can submit the validated result. SQL rechecks the live session,
current project access, pending state, attempt identity and expiry before
activation. Superseded/revoked/expired attempts stay terminal. A caller can never
supply `finish_verify` or a trusted `outcome` through the HTTP envelope. The
handler has a 25-second total budget, an 8 KiB/two-second input bound, bounded
upstream reads, request cancellation and safe status/retry projection. Unknown
writes preserve the same setup/attempt/command identities for recovery. This
service is an undeployed candidate, not a new public intake endpoint.

### Current verification and limits

Each repo independently passes 83 local SQL checks and 43 real PostgreSQL 17.6
checks. Eight observed lock barriers cover concurrent exact/conflicting enrollment,
12 workers competing for the last five slots, both revoke/proof orders, sign-out,
expiry, membership removal and account removal. Actual command retries confirm
that an old Pause cannot override a newer Resume. Immutable histories reject
pruning/rewrite while Auth exists and cascade cleanly after physical removal.

The current Deno suite passes 26 tests (15 handler tests and 11 transport/wire
regressions, including seven actual TLS/HTTP substeps), plus format/lint/type
checks. Handler tests inject owned Auth/RPC/receiver responses; SQL tests execute
the actual candidate against the recorded minimal dependency schema. They do not
prove hosted Auth/PostgREST/receiver integration, native secret recovery, spoken
accessibility, master-key operations or distribution. The earlier nine-per-source
hosted transport proof remains separate; it does not enable this management API.

All owned database containers and generated TLS fixtures are removed. Docker was
started from Off; other-project containers are now running, so Docker stays on
and those containers are untouched. No cloud test branch, account or credential
export was created for this milestone. Main readback confirms the new migration,
subscription table and webhook endpoint remain absent. No native app launched.
Exact source hashes, scope, checks and cleanup: `p2-webhook-subscriptions-evidence.json`.

## Remaining implementation and acceptance

1. Subscription/enrollment authorization, scopes, quotas and removal cleanup are
   implemented above. Add the durable task-change outbox with its own bounded
   capture/delivery quotas. Capture actual native and API task changes, including
   completion/reopen, recurrence, nested changes and deletion; define the complete
   event payload and large-task behavior. Do not silently drop events or break
   ordinary task editing when a receiver stops working.
2. Secret-possession verification is implemented above. Complete actual hosted
   Auth/PostgREST/receiver and native private-setup/retry acceptance; the historical
   synthetic signed echo remains transport proof, not this enrollment acceptance.
3. Implement a leased dispatcher with immutable event/attempt identities,
   transactional claims/acknowledgements, bounded backoff, retry history and
   recovery after worker interruption. Recheck current ownership, project access,
   subscription generation, account-removal state and revocation immediately
   before sending. Define deletion-event authorization explicitly. Revocation
   cancels pending work; an already transmitted event cannot be recalled.
4. Add independent premium native controls: destination/content review, private
   one-time secret setup and recovery, verify, pause/resume, revoke, last-delivery
   status and a clear failure/retry view. Retain the existing typography, spacing,
   keyboard/VoiceOver behavior and cross-account boundaries. Protect query-string
   secrets and never display internal diagnostics as user-facing errors.
5. Verify actual committed changes, lost acknowledgements, duplicate delivery,
   concurrency, expired leases, quotas, access removal, sign-out/account switching,
   account deletion, receiver failure/recovery and ordinary relaunch on an empty
   hosted branch. Then perform native acceptance and coherent enablement. Mac
   private-Keychain/runtime and distribution remain deferred with signing.

These requirements retain the full webhook feature. Verified email intake,
advanced team roles/folders/admin and wearable clients follow separately; existing
remote-reminder, older-client rollout, provider OAuth and physical-location
checks remain deferred as agreed.

## Evidence and reproduction

The earlier transport-only checkpoint passed 11 local tests per repo (seven
actual TLS/HTTP substeps), formatting,
lint, type checking and runner syntax. Its own deployed source independently
passes nine hosted checks: sender/receiver authentication refusal, encrypted
secret round trip, signed delivery, challenge readback, redirect refusal, gone,
backoff and oversized challenge handling. Local TLS tests use a generated CA and
map a checked public fixture IP to their own loopback server at the I/O boundary;
production has no test CA, insecure TLS flag or environment bypass. Certificates,
private fixture tokens and the disposable cloud branch are removed afterward.

The first Node HTTPS version passed local tests but failed hosted TLS handshakes:
the hosted shim rebuilt a numeric-IP fetch URL. It was replaced by the verified
TCP → TLS path. The initial service-JWT string comparison also rejected a valid
but different runtime credential; the temporary harness now uses a separate
random acceptance token. Neither diagnostic approach is production authentication.
The branch's historical migration replay stopped, but no database feature was
under test and no replay repair was needed. Its task/user counts stayed zero.

`Scripts/Diagnostics/webhook-transport-probe.ts` is only a temporary branch probe.
Deploy an entry that passes the branch URL, its private
`TASKFOLD_WEBHOOK_ACCEPTANCE_TOKEN` and the exact owned project reference to
`createProbe`, with that source and its relative transport/socket/secret modules.
The probe authenticates its sender itself; its receiver accepts only the fixed
synthetic signed fixture. Never deploy it on main. Keep the random token in an
owner-private env file and set it only on the owned branch. Run
`test-webhook-transport-hosted.mjs <branch-id> <sanitized-output> <private-env-file>`;
the runner refuses main, persistent, data-copying and unowned branches. Remove
the branch and private token after verification. Local test permissions are
limited to the test hosts, `/private/tmp` and the certificate generator.

Exact current source hashes, hosted outcomes, rejected iterations and cleanup:
`p2-webhook-transport-evidence.json`.

References: [Deno TLS upgrade](https://docs.deno.com/api/deno/network/),
[IANA IPv4 special addresses](https://www.iana.org/assignments/iana-ipv4-special-registry/),
[IANA IPv6 special addresses](https://www.iana.org/assignments/iana-ipv6-special-registry/).

## Durable queue and worker candidate — 23 October

Committed task changes now capture immutable events in the same transaction.
Rollback leaves no event. Only verified subscriptions capture content; Pending
setups never do. Paused subscriptions retain bounded changes but cannot deliver.
Task projection is explicit, includes full notes and nested subtasks, and excludes
internal reminder markers. Completion/reopening emits both an update and the
corresponding completion/reopening event when subscribed. Nested edits update
the root. Deletes and exits from a selected scope carry only the old task ID,
generation and project ID; they do not disclose the new private location.

The service-only dispatcher claims a 45-second lease, with at most one message
in flight per subscription. It skips busy queues. It prepares the immutable packet,
then rechecks account, removal state, project membership, current task identity/location,
subscription revision, expiry and budgets after the receiver TLS handshake and
before any HTTP bytes. No database lock spans receiver I/O. A change after that
last authorization cannot recall an already transmitted request. Delivery is
at least once: receiver acceptance followed by a lost acknowledgement may repeat
that same event/part. Receivers must deduplicate, not assume exactly-once delivery.
The queue does not promise global transaction-commit order.

Events expire after 24 hours. Delivered/cancelled/expired payloads are erased and
release retained capacity; failed payloads remain available until expiry or revoke.
Terminal metadata is pruned after seven days. Revocation and account removal
prevent sending; physical Auth deletion cascades private queue data. Lease recovery
keeps the immutable body and stable message identity; stale acknowledgements cannot
consume a replacement lease.

### Complete large-task protocol

A JSON event of at most 250,000 UTF-8 bytes is sent unchanged, signed with its
logical event ID. Larger events, up to 16 MiB, split encoded bytes into 180,000-byte
chunks. Each request remains below the transport's 262,144-byte ceiling. The frame
contains `version: 1`, `type: taskfold.event.part`, logical `event_id`, `part_id`,
zero-based `part_index`, `part_count`, `encoding: base64`, full-event `sha256`
and chunk `data`. The stable part ID uses the first 128 bits of SHA-256 of
`event_id + ":" + part_index`, formatted as a UUID. The request signature and event
header use that part ID. Retries preserve body and part ID, with a fresh signing
timestamp. Advance to the next part requires durable acknowledgement.

Receivers must verify each request signature, deduplicate by subscription and
message/part ID, store bounded parts under their logical event ID, join decoded
bytes in order, verify the full SHA-256 and only then decode/parse/apply the event.
Partial snapshots must never be applied. SQL tests reconstruct Unicode notes from
three real generated parts without loss; worker tests separately preserve exact
part bytes and reject mismatched identities. This is not yet a hosted end-to-end
receiver acceptance or a receiver SDK.

### Bounded delivery and recovery

Per subscription: 500 captured events and 32 MiB captured per UTC day; 256 pending
events and 32 MiB retained payload; 60 authorized HTTP sends per minute and 1,000
per UTC day. Each part has 12 authorized attempts, exponential backoff and bounded
Retry-After guidance. Pre-authorization TLS/DNS failures do not charge an authorized
send, but all work remains bounded by event expiry and worker execution limits.
Failed events permit at most three explicit manual retries. A durable retry command
keeps event/part IDs and cannot resubmit an old successful command.

Capture overflow or a legacy snapshot above 16 MiB leaves a cumulative warning
with cause and times rather than truncating content or deliberately failing a task
save. Native delivery summaries include these warnings, pending/retained totals,
blocked state, safe last error and cumulative delivered/failed totals. History is
paged at 1–50 redacted metadata records. It never returns event bodies, encrypted
secrets or endpoint paths/query strings. Receiver refusal/gone blocks further sends
until a deliberate Resume; replaying an older Resume cannot clear a newer block.
Missing/corrupt master keys defer delivery for five minutes without sending.

The worker uses a separate private 64-hex credential and a server enable flag
(default off), accepts no caller-chosen recipient or event, and caps execution at
55 seconds/eight claims. Its response contains counters only; its delivered count
counts acknowledged messages/parts, while the subscription delivered total counts
complete logical events. Master configuration is shared with enrollment and pinned
to validated versions. Never put service, master or worker credentials in native apps.

### Remaining enablement gates

No scheduler is installed, no new remote schema/endpoint was deployed, and the
ordinary app entry remains disabled. Native setup, secret review/copy, delivery warnings, reconciliation guidance and
recovery controls now have a gated implementation; their full acceptance is open.
In particular, quota gaps need a clear user-facing recovery path before enablement;
a delivery-history API alone does not finish that UX. Secure scheduled invocation,
hosted Auth/PostgREST-to-receiver acceptance, key/configuration recovery and account
switch/relaunch checks remain open. These local results do not complete webhooks
or the remaining Px backlog. Exact scoped proof: `p2-webhook-outbox-evidence.json`.


## Native task connections — 23 October (acceptance in progress)

Each app independently owns a gated **Task connections** screen in Account.
Setup reviews a receiver name/address, Inbox/one-project/all-accessible reach,
event choices and expiry, with explicit trust consent before creating a setup.
The review explains full-note/checklist delivery, shared work included in broad
scope, and bounded paused capture. The receiver secret starts hidden, can be
revealed/copied with device-only clipboard options, and is retired after explicit
save acknowledgement. Receiver verification is a separate action; setup alone
never means connected. Pause/Resume and Revoke have their own controls, with
revocation confirmation explaining the in-flight request boundary.

Interrupted setup is retained exclusively in an app-private secure-item envelope,
coordinated across processes. Exact settings/ID/secret retry, durable discard
before cancellation, original-server binding and account-removal cleanup are
implemented. View/workspace/backend-session leases fence late results; inactive
root and modal screens cover private content. One unfinished setup per account
prevents competing windows from silently replacing a secret.

Delivery history pages only redacted metadata. It shows status, part progress,
attempts, last issue, optional event/task references and reviewed manual retry.
Uncertain state/retry actions preserve their command identity until retry or an
explicit reload of server state. Queue-gap warnings explain that missing changes
require fresh task reconciliation by the receiver; Resume cannot replay them.
Counts are cumulative. There is no automatic resync or warning-dismissal claim.

The native client uses its fixed account server, authenticated session fence,
no cookies/redirects, no-store policy, a 25-second request timeout and a 256,000-byte
response bound. No native app receives service/master/worker credentials. Both
ordinary entries remain off behind a separate `TaskfoldWebhooksEnabled` gate.
The earlier in-memory view checks did not prove native private storage. Signed
iOS Keychain recovery now has scoped acceptance below; hosted receiver integration
and Mac runtime remain unaccepted. Secure scheduling and
hosted/native end-to-end acceptance remain required before enablement; full
webhooks and the remaining Px backlog stay active. Exact verification is recorded
in `p2-webhook-native-evidence.json` after this milestone’s checks.


Native checkpoint verification: 44 focused Core tests pass per owned repository;
11 webhook cases were rechecked after the final wording change. Both complete app
inputs build. Four scoped UI tests pass on iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator: reviewed setup/secret/verification and failed-delivery retry,
plus largest-text dark Cancel. The phone now scrolls from secret acknowledgement
to its connection. Final screenshots are visually reviewed; toolbar labels fit
ordinary phone width. These are synthetic in-memory service/storage checks, not
hosted or OS Keychain acceptance. An unrelated recovery banner in the unsigned
Store host remains outside this accepted scope. Clipboard expiry, spoken checks,
live account/relaunch/Keychain and native Mac runtime remain open.

Both disposable Simulator apps and runners are closed and uninstalled. About
1.05 GB of redundant artifacts from these attempts is removed; current useful
build caches, final accepted results, screenshots and text logs are retained.
No real tasks or hosted services changed. Main webhooks stays disabled. Next:
genuine private-storage/native service acceptance and secure hosted scheduling/
delivery checks, then email intake, advanced teams and wearables. Evidence:
`p2-webhook-native-evidence.json`; full Px stays active.


## Signed private-storage recovery — 23 October

The opt-in native check now uses the production `Backend.webhookReceipt`,
URLSession and `Store.webhookEnrollmentVault` with the actual private OS Keychain.
The synthetic HTTP peer intercepts only the fixed owned test URL; its persistent
file contains metadata and one-way intent hashes, never receiver secrets. This
extends the earlier in-memory view check rather than substituting a mock vault
for recovery. The ordinary feature entry remains disabled.

Eight scoped checks pass across signed iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator. Lost-create recovery keeps the same setup ID, settings and
secret across a process restart and creates one connection. Saved acknowledgement
and revocation clear the private draft across a fresh successful read. A durable
discard survives a lost cancellation reply; another fixed account cannot see it,
and returning to the first account restores Retry discard. A final restart after
retry has no setup. Signatures and embedded Simulator application/App Group
identities are verified with the existing development certificate.

The correctly signed host also has no account-removal recovery banner. The banner
visible in the historical unsigned screenshots is not a product-state acceptance
finding. Both independent app inputs build; no Mac runtime or hardware Keychain
security is inferred from Simulator tests. Live Auth account changes and hosted
receiver integration are still unaccepted. Exact proof and limits:
`p2-webhook-keychain-evidence.json`.

The disposable Simulator apps/runners are closed and removed. Superseded owned
source/results are pruned; useful current caches and accepted results are kept.
No real tasks, hosted services, release signing or device privacy settings changed.
Next: secure hosted scheduling and end-to-end native Auth/webhook delivery, plus
remaining clipboard/spoken checks. Full webhooks/Px and the email/team/wearable
backlog remain open; user release/provider/reminder deferrals stay in force.


## Hosted delivery acceptance — 23 October

All 61 checks pass independently for each repository’s service source. Format,
Node syntax and receiver Deno type checks pass. No native app build was needed
for these diagnostic-only additions.

The owned diagnostics now exercise actual password Auth, scoped task writes,
Edge management, PostgREST, private outbox capture and pinned TLS delivery on a
no-data disposable preview branch. Both repositories own their runner, receiver
and SQL fixtures. The receiver checks exact HMAC bytes, stable message IDs,
immutable retries and absence of native Authorization/API-key/cookie headers.

The runner covers create/update/complete/reopen/delete, full Unicode multipart
notes and checksum reassembly, pause/resume replay, retry/backoff, sign-out,
receiver refusal and explicit recovery, pending versus accepted project access,
membership removal, retained owner access and account-removal cancellation.
Project memberships are service-seeded synthetic fixtures: invitation acceptance
through the native app is outside this milestone. Branch history lacks the
main database's independently installed native base, so a guarded fixture bridge
supplies inspected base fields/grants/helpers. Common feature migrations from
6 October onward are hashed unchanged; earlier platform histories differ.

Run `prepare-webhook-hosted.mjs <owner-private-connection-json> <schema-receipt>`,
then `test-webhook-delivery-hosted.mjs <connection> <receipt> <result>` from this
repository's Scripts/Diagnostics. Setup checks API and database hosts against the
same owned, nonpersistent, no-data branch and refuses main. The runner deploys
only the five test functions, uses random ephemeral secrets and synthetic users,
and removes them in finally. Delete the owned preview branch afterward and remove
the private connection file. Do not run overlapping tests on the same branch.
The private JSON uses Supabase branch connection fields SUPABASE_URL,
SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY and POSTGRES_URL; never commit it.

This is hosted service acceptance, not an app-native UI walkthrough or secure
scheduled invocation. Main schema, endpoints and ordinary app feature gates stay
disabled. Secure scheduling, native hosted account/relaunch acceptance and the
remaining clipboard/spoken checks are next. Remote-reminder, old-client and release
signing/distribution deferrals are unchanged. Full webhooks/Px remains unfinished.
Exact results and limitations: `p2-webhook-hosted-delivery-evidence.json`.


## Signed automatic dispatch — 23 October

Both repo-owned service copies pass 73 hosted checks, including actual minute
dispatch, one-use proof admission, transport health and no delivery on the next
tick after disable. Each also passes 42 local SQL checks and 45 worker/transport
tests (8 real TLS steps). Main remains unchanged.

The candidate `20261023074744_webhook_scheduler.sql` owns a disabled minute
job and operator-only configuration/state. No migration enables delivery.
The scheduler resolves `taskfold_webhook_worker_token` from Vault at each tick,
binds its HMAC to the project, timestamp and random nonce, and enqueues only a
90-second signed proof. The Edge worker verifies it before service-only atomic
admission; a consumed nonce cannot start another run. Disable/reconfigure clears
pending proofs. An already admitted worker may finish its bounded run; use
subscription pause/revoke for the existing per-delivery authorization fence.
The existing private bearer path remains for trusted operator
invocation, but the cron request never contains that reusable credential.

This design accounts for a hosted platform constraint: pg_net's queue/result
objects have PUBLIC grants owned by supabase_admin. A postgres REVOKE reports
success with a warning but cannot remove those grants. They are not exposed by
the Data API by default; do not expose the net schema or grant untrusted database
login access. A copied signed tick cannot change the destination, extend its
validity or bypass its one-use admission. SQL login roles remain a trusted
infrastructure boundary. See Supabase's [pg_net permission guidance](https://supabase.com/docs/guides/troubleshooting/revoking-access-to-pg_net-objects-has-no-effect-0bbc16).

Only the database operator can call configure_webhook_scheduler(project_ref,
true/false). Enabling requires the matching dedicated 64-character lowercase hex
worker credential in Vault and the Edge worker environment. Disable requires no
credential. The job uses a fixed HTTPS Supabase dispatch path, a 60-second network
timeout and a 55-second enqueue interval floor; durable outbox leases protect
actual delivery. State retains request ID, queue time and prior transport status,
never response bodies or task content. A network timeout is not a delivery receipt:
inspect per-event history for confirmation. Health is refreshed on the next tick;
it can lag by a minute, and pg_net response retention is finite.

Use the existing hosted runner's fourth argument `--scheduler` to test actual
minute dispatch and the next disabled tick, in addition to the full delivery
suite. It generates its credential inside Vault without a secret SQL literal,
arms only the owned no-data branch, then disables cron and removes the credential
in finally. Clean the branch afterward even if a run is interrupted. Ordinary
native feature entries and the main service remain disabled pending native
hosted acceptance. No reminder scheduler or deferred release capability is armed.
Exact results and limits: `p2-webhook-scheduler-evidence.json`.


## Native hosted receiver acceptance — 23 October

The signed iPhone/iPad Simulator app now exercises real password Auth, the
production Store/Backend transport and private OS Keychain, the hosted receiver
proof, native task capture, signed minute dispatch and the real history response.
The controller configures the app-generated receiver secret through an owner-only
local channel. It never supplies a mock UI response or intercepts app HTTP.
Normal relaunch keeps the same unfinished setup; acknowledgement, verification,
delivery history and revocation complete through the actual service. Switching
A → B → A hides A's unfinished setup in B and recovers it only in A.

Four scoped native cases pass across iPhone 18 Pro and iPad Pro 13-inch (M5),
iOS 27 Simulator: one delivery/relaunch and one account-isolation case per device.
The controller confirms both exact native-created task titles at the HMAC-checked
receiver. Phone and tablet runs are sequential because this disposable receiver
uses one configured secret at a time. The final tablet screen also confirms the
wording fix: “1 of 1 part · 1 attempt”. Both independent app inputs build.

This round uses the iOS app and iOS-owned service source. It is not Mac AppKit
runtime or hardware Keychain acceptance; that remains deferred with signing.
Nor does ordinary successful-create relaunch prove genuine native HTTP-loss,
offline, token-expiry or master-key recovery. Earlier lost-reply Keychain checks
used a synthetic HTTP peer and remain separately scoped. Those native fault
variants and clipboard/spoken checks remain open before normal enablement.
Email intake, advanced teams and wearables remain on the full Px backlog.
Main schema, endpoints and ordinary feature gates stay disabled; no real tasks
or deferred reminder/distribution capabilities changed.

The no-data branch's recorded web base omits native table grants. The fixture
bridge now mirrors the inspected main CRUD grants on tasks/projects/memberships,
sections/profiles/labels; it changes no RLS policies and never runs on main.
The temporary apps/runners, accounts, functions, Vault worker credential and
preview branch are removed after proof. Typed-password action logs are redacted;
raw Xcode result archives are pruned after exporting summaries and safe images.
Exact scope, versioned runs, source hashes and cleanup:
`p2-webhook-native-hosted-evidence.json`.


## Native clipboard and spoken secret review — 23 October

Six scoped cases pass: three each on iPhone and iPad Simulator.

The receiver-secret Reveal and Copy controls now use independent button targets
inside the Form. Previously, tapping Copy could also activate Reveal and expose
the raw value in the accessibility tree. The regression checks both directions:
Reveal must leave the clipboard untouched, and Copy must keep the value masked.
Backgrounding conceals a revealed value; continuing setup requires another
explicit Reveal.

The local acceptance host uses a synthetic in-memory service and enrollment
vault. Clipboard and VoiceOver observations use the real Simulator OS services,
not substitute clipboard or speech implementations. The Debug-only probe is
restricted to exact isolated bundle IDs and explicit test arguments. It observes
the real one-minute expiry, preserves newer clipboard content, and reports only
fixed outcome strings. It never exports a receiver secret.

The spoken check traverses the masked value and Reveal/Copy buttons with the
actual VoiceOver service, activates Copy, and revisits the updated Copied control.
This verifies its spoken label; it does not claim an automatic announcement on
label change. The test restores VoiceOver's original state afterward.

This is separate from the earlier hosted Auth/receiver/Keychain acceptance.
Mac source has the same button fix and compiles independently; Mac pasteboard
and spoken runtime acceptance remain open. Hardware clipboard handoff, native
HTTP-loss/offline/token-expiry/master-key recovery, and the wider consent/history
spoken walkthrough remain outside this round. Normal feature entries and main
webhook schema/endpoints remain disabled. Exact results and cleanup:
`p2-webhook-clipboard-speech-evidence.json`.


## Hosted native recovery acceptance — 23 October

Two scoped native cases pass, one per device. The tablet retry keeps the exact
saved intent after an interrupted UI run; the hosted fingerprint stays unchanged.

This runtime/controller round uses iOS-owned app and diagnostic inputs. The
commands below describe that iOS verification; Mac runtime remains unaccepted.

The isolated native recovery runner now covers a committed create whose reply
never reaches the enrollment model, a retry during a controlled webhook-service
outage, and normal recovery after terminating/relaunching the app. The successful
create is real HTTPS through Auth, Edge and PostgREST; the Debug-only hook throws
`networkConnectionLost` after decoding that actual account-bound receipt. It does
not replace the API with a fixture peer. The outage hook refuses webhook calls
locally before sending; ordinary Auth and task sync still use their real service.
These are controlled client fault injections, not physical radio loss or a TCP
reset at the server. Both hooks require an exact isolated bundle, explicit flags,
a disposable UUID email account and a non-main Supabase origin. They are absent
from Release. The fault proof contains only account/setup UUIDs and a boolean.

A private controller inspects the hosted subscription at commit, after the
outage and after normal retry. There must be exactly one subscription for the
disposable account, with the same ID, revision, settings, encrypted secret,
creation time and expiry. Receiver proof and an actual native-created task then
exercise the recovered secret through scheduled delivery, native history and
revocation. The Mac app owns its matching hook source and builds independently;
Mac Keychain/AppKit runtime acceptance is still deferred.

The existing `--native` mode continues to require its four normal delivery and
account-isolation cases. `--native-recovery` instead requires the recovery case
on both phone and tablet, using the same guarded no-data branch setup, private
controller files, signing helper and cleanup procedure. Run
`testHostedWebhookLostCreateResponseRecoversAcrossRelaunch` sequentially on both
devices before finishing that controller.

The walkthrough also exposed a presentation follow-up: an error notice can sit
above the automatically scrolled pending setup. Bring new failures into view
before enabling this feature; the current test explicitly scrolls to inspect it.
Session-expiry recovery, server master-key failure/recovery and the wider
consent/history spoken walkthrough remain open before normal enablement.
Email intake, advanced teams and wearables remain on the full Px backlog.
Remote reminders, older-client safeguards, distribution/OAuth registration and
physical location acceptance remain deferred. Main schema/endpoints and normal
feature entries remain disabled. Exact outcomes and cleanup:
`p2-webhook-native-recovery-evidence.json`.
