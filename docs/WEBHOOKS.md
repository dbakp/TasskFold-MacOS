# Task-change webhooks — inactive implementation

Updated 23 October 2026. Rank 6 remains in progress. The delivery transport and
receiver-secret envelope are implemented in each repo independently. There is no
public webhook handler, native webhook screen, subscription schema, outbox or
scheduled dispatcher yet. No real task data was sent and nothing was enabled on
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

## Remaining implementation and acceptance

1. Add private subscription/enrollment and durable outbox migrations with server
   authorization, fresh account/session checks, scopes, bounded quotas and
   account-removal cleanup. Capture actual native and API task changes, including
   completion/reopen, recurrence, nested changes and deletion; define the complete
   event payload and large-task behavior. Do not silently drop events or break
   ordinary task editing when a receiver stops working.
2. Require recipient verification before sending task content. Persist a bounded,
   expiring challenge and verify the receiver's response; the current probe's
   synthetic signed echo is transport acceptance, not production enrollment or
   proof that a user owns an arbitrary endpoint.
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

Each repo passes 11 local tests (seven actual TLS/HTTP substeps), formatting,
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
