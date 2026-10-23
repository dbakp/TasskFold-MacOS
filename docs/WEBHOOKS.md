# Task-change webhooks — inactive implementation

Updated 23 October 2026. Rank 6 remains in progress. The delivery transport, receiver-secret envelope,
private subscription schema, receiver-proof protocol and management handler are
implemented in each repo independently as inactive candidates. There is no
native webhook screen, task-change outbox or scheduled dispatcher yet. No real task data was sent and nothing was enabled on
main. This milestone is a necessary part of automatic task-change delivery, not a
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
The current transport accepts at most 256 KiB of UTF-8 payload. Final event
projection and large-task handling must be resolved with the outbox contract;
do not silently truncate supported task content or treat this provisional bound
as proof that every API task fits a webhook event.

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
