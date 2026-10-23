# Email-to-task intake

Updated 23 October 2026. The user has no inbound provider/domain yet and explicitly
authorized preparation for later configuration. Build the intake feature now; do
not enable live delivery or imply that a working address exists before provider
configuration and real signed-delivery acceptance.

## Delivery order and current evidence

| Stage | Required result | Current state |
| --- | --- | --- |
| Content and retry contract | Bounded plain text; transparent attachment omissions; a stable provider-delivery/route identity separate from content fingerprint | Implemented independently in each repo; ten Deno tests and lint pass per repo |
| Atomic intake journal and routes | One committed task per verified delivery; changed-content replays conflict; paused/revoked or unauthorized destinations refuse delivery; quotas and account-removal fencing | Implemented as a disabled local candidate; 119 functional and 32 real PostgreSQL concurrency checks per repo pass; hosted/provider/native acceptance remains open |
| Provider adapter and management gateway | Verify signed provider requests before trusting normalized sender/receipt data; authorize current native sessions; bounded body/read/deadlines and admission; no raw credentials in receipts | Native management gateway locally implemented; verified provider adapter and hosted/native acceptance remain open; configuration follows later |
| Native setup and recovery | Clear address/destination review, trusted senders, pause/rotate/revoke, account-bound private setup/retry, understandable delivery status and accessible controls | Native candidate implemented; scoped Simulator walkthrough and recovery tests recorded below; real Keychain/hosted/Mac/spoken acceptance remains open |
| Real delivery acceptance | Actual provider retries, sender spoof refusal, current membership changes, native relaunch/account isolation and recovery | Open; requires later provider/domain configuration |

## Implemented internal contract

`supabase/functions/_shared/email-content.ts` is an internal component, not an
HTTP endpoint, authentication mechanism or task writer. Version 1 accepts exactly
`subject`, `text`, `attachmentCount` and `version`. The subject is at most 512
UTF-8 bytes; plain text is at most 60,000 bytes. Oversize input fails instead of
being silently truncated. Binary controls, header line breaks, ill-formed Unicode,
unknown fields/versions and mail without readable subject/body fail explicitly.
A verified adapter must decode MIME and unfold subject headers before calling it.
HTML-only mail must not become a silent empty task; adapter handling remains open.

The subject becomes a trimmed title, falling back to “Email task” only when a
readable body exists. The complete plain-text body preserves whitespace and
Unicode, normalizing CRLF/CR to LF. Attachments are not fetched/imported; a note
explicitly reports their number. Subject/body instructions remain text and never
set scheduling, priority, assignment or destination. The returned content does
not contain sender addresses, recipient aliases, provider tokens or file URLs.
Rendering through the app’s existing safe note renderer remains a native gate.

`prepareEmailDelivery` additionally accepts a canonical internal route UUID, a
configured provider namespace and the verified provider’s stable delivery receipt
ID. Header `Message-ID` is sender-controlled and must not substitute for that
receipt. The SHA-256 delivery key has a versioned namespace and does not include
content. A separate content fingerprint covers normalized title/note and omitted
attachment count. Identical receipt/route retries retain the delivery key; changed
content retains that key but changes the fingerprint. The candidate journal enforces
this distinction atomically without overwriting a task or creating another one.
Different provider namespaces or routes cannot share a delivery key.

## Boundaries the next stages must enforce

- Authenticate the provider event before accepting sender or receipt metadata. A
  payload’s `senderVerified` flag, display name or unverified From header is not
  proof; unknown fields are already refused by the content contract. Choose the
  actual provider adapter after configuration is available.
- Bind routes to the authenticated owner and approved sender addresses. Recheck
  current destination access and archived state at delivery, including shared
  project membership. Unavailable destinations must not silently become Inbox.
- Store alias secrets separately from task content, widgets, exports and logs.
  Native management must use live account/session guards and durable, scoped
  recovery. Address rotation/revocation must invalidate the old route capability.
- Commit journal identity and task creation in one transaction, preserving the
  original task ID/generation after retries, user edits or deletion. Do not recreate
  a user-deleted task on late delivery. Bound retention, payload size, attempts and
  per-provider/account/sender/recipient admission. State limits and retention before
  implementing cleanup; deleting receipts must not silently re-enable old replay.
- Integrate account-removal locks and erase route/private receipt state without
  deleting another account’s tasks or shared work. Reject late deliveries after
  account removal or membership loss. Expired native sessions must block route
  management; provider capture may continue while the native app is signed out.
- Show configuration/unsupported-mail failures clearly. Only a real configured
  address may be copied as usable; preparation must never claim delivery works.

The first content milestone is recorded in `p2-email-content-evidence.json`.
Existing remote-reminder, older-client rollout, distribution, calendar-provider
and physical-location deferrals remain unchanged.

## Atomic routes and delivery journal — local candidate

The independently owned migration `20261023150729_email_intake_journal.sql` now
implements private routes, setup-cancellation tombstones and atomic task/receipt
creation. Delivery is disabled by default. No hosted migration or endpoint has
been deployed. Service-only functions are an internal trusted boundary; they do
not themselves verify a provider signature or make sender claims trustworthy.

Route management requires a current native Auth session and confirmed account
email. The initial approved sender is only that current confirmed email; additional
verified sender enrollment remains open. Addresses use hashed aliases, strict
account ownership and revision-checked pause/resume, rotation and terminal
revocation. Cancel-before-create is durable. Destination access, membership and
archive state are rechecked; a deleted destination cannot fall back to Inbox.
Expired native sessions block management. Provider capture can continue while the
app is signed out/offline, until route, account, sender or destination access is
invalidated. Account-removal, Auth, session and project changes are fenced with
transaction locks.

A verified future adapter must supply the original provider receipt and received
timestamp, not sender-controlled Message-ID/Date/From or a `senderVerified` flag.
PostgreSQL recomputes the versioned delivery key and content fingerprint. Task and
receipt commit together. Exact retries return an opaque acknowledgement, without
IDs or task content. Changed content/timestamps conflict. User edits, moves,
deletion and restored task incarnations are preserved. Resume refuses new mail
from its paused interval; known committed retries can still be acknowledged.

Initial limits are five live routes including paused routes, ten new routes per
rolling day, 100 setup-cancellation tombstones per day, 100 accepted captures per
account/day, 50 per route/hour and 6,000 retained receipts per account. Gateway
budgets for rejected requests, provider and IP admission remain open. Revisit
these limits against provider costs before enabling delivery.

Receipts become eligible for pruning after both creation and original receipt
are older than 30 days; revoked routes require no remaining receipts. Old setup
cancellations are also prunable. Activity and an administrative RPC perform
bounded per-account cleanup. Scheduled maintenance for inactive accounts remains
required; this is not a promise of exact automatic 30-day deletion. Seven-day
input/setup windows prevent unchanged ancient requests recreating work after
pruning. The journal stores identity hashes, timestamps and task generation, not
another email body, raw alias or provider payload.

Each repo passes 119 functional checks and 32 actual PostgreSQL 17.6 concurrency
checks, including ten observed blocking barriers, twelve simultaneous identical
deliveries, injected transaction failure and quota contention. Existing webhook
concurrency checks pass 43 cases per repo after the fixture extension. Official
Supabase advisors ran against each local fixture: no email-object findings; five
pre-existing minimal-fixture findings remain. This is not a production database
audit. All owned containers were removed. Exact checks, source hashes, candidate
corrections and limits are in `p2-email-intake-journal-evidence.json`.

Still required: hosted/native acceptance of the management gateway, signed provider/MIME
adapter with attested sender and original receipt time, native alias generation
and private vault/recovery/UI, additional sender verification, source links,
scheduled maintenance and hosted/native/provider acceptance. Provider/domain
configuration stays deferred by the user. Full email intake and Px remain open.

## Native-management gateway — local candidate

`supabase/functions/email-routes` now implements the native management HTTP
boundary. It is not deployed and is not an inbound-mail/provider endpoint.
Keep the platform's default JWT verification enabled. The handler verifies the
bearer through live Auth, matches its subject, extracts its native session, and
calls only `taskfold_email_routes` with service credentials. SQL rechecks the
session/account under locks. Anonymous accounts and client-supplied owner/sender
claims are refused. No privileged credential is included in a response or client.

The request is POST with `X-Taskfold-Email: 1` and a strict JSON envelope
`{action, body}`. Actions are list, create, pause, resume, revoke and rotate.
Bodies use the journal's exact schemas; revoke with revision zero is the durable
cancel-before-create path. Native code must persist the same setup ID, alias hash,
original requested time and reviewed settings before sending. Repeating an
uncertain request must retain its setup and revision, rather than generating a new
address or assuming success. Rotation validates both returned identities.

Raw address secrets never enter this management request. Only `alias_hash` is
forwarded to SQL. The native milestone below now implements generation, the versioned alias/hash
convention, private storage, account-bound recovery and address presentation;
real Keychain/hosted acceptance remains open. Delivery metadata is projected through a
bounded allowlist so hashes, aliases, private/future SQL fields and diagnostics
cannot escape. Responses are `Cache-Control: no-store`.

`TASKFOLD_EMAIL_INBOUND_DOMAIN` is a canonical bare lowercase DNS name. List
advertises a usable domain only when that configuration and the database enable
flag are both present. New setup, rotation and resume require
`X-Taskfold-Email-Domain` to match the domain reviewed by the native caller. A
configuration change returns a conflict instead of silently changing the reviewed
address. Missing configuration still allows authenticated list, pause and revoke.
The native vault must retain and compare the address's original domain; domain
migration/re-enrollment remains part of native/provider acceptance. Merely setting
this variable is not proof that mail delivery works.

Management shares the existing durable `keys` admission bucket with API-key and
webhook management: 600 global requests, 60 per IP and 60 per credential per
minute. Independent cold workers cannot multiply the allowance. Verified gateway
forwarding is required; raw IPs/bearers are HMAC-fingerprinted before admission.
Missing forwarding configuration fails closed. This is separate from the future
provider/rejected-mail admission policy. Input is limited to 8 KiB and two seconds;
upstream responses are limited to 512,000 bytes and the overall request to 15
seconds including admission time. Caller cancellation/deadlines stop reads and
upstream work without claiming an uncertain mutation succeeded. Retries retain
explicit identity instructions; lock/deadlock failures include a retry hint.

Each repo passes 22 gateway cases and nine existing admission cases, plus 20
HTTP-to-actual-PostgreSQL 17.6 integration checks. Integration uses a synthetic Auth
adapter and loopback-only bridge, while exercising unchanged production handler,
shared durable admission and service-role SQL. It does not prove hosted Auth,
platform forwarding, a deployed function or native UI acceptance. Owned gateway,
bridge and database processes are stopped after each run. Exact results and
source hashes are in `p2-email-routes-gateway-evidence.json`.

The native candidate below now implements address setup and private recovery.
Next: its remaining acceptance, the verified provider adapter and later
domain/provider configuration. Extra verified
senders, source links and scheduled inactive-account maintenance remain open.

## Native address setup and private recovery — candidate

Both apps now independently own `EmailCapture.swift` and `EmailCaptureView.swift`.
Account settings presents **Email to Taskfold** only when the bundle metadata
`TaskfoldEmailCaptureEnabled` is explicitly true. That flag remains absent in both
production inputs; no live feature or server deployment is enabled here.

The native form reviews the name, Inbox/project destination and current account
sender before explicit Create. Its controls cover concealed/revealed addresses,
local-only expiring Copy, pause/resume, replacement and terminal revocation.
Destructive actions explain their effects and require confirmation. Cancel before
Create performs no request. A paused address keeps its status visible; an address
whose private copy is unavailable on another device can still be paused, revoked
or replaced. Resume requires the current device's matching private address/domain.
Large-text controls wrap vertically when horizontal space is insufficient. Multiple
buttons in one Form row explicitly use independent borderless actions.

Version-1 addresses use 32 cryptographically random bytes rendered as 64 lowercase
hex digits, then `@` and the configured canonical domain. Domain length is bounded
to 189 ASCII bytes, preserving the 254-byte mailbox limit. The shared adapter
helper and Swift compute SHA-256 over compact UTF-8 JSON
`["taskfold-email-alias",1,address]`. Only that digest enters management requests.
A Swift/Python/Web Crypto vector agrees. The helper is a recipient-format contract,
not provider/sender attestation or an inbound endpoint.

The app-only `EmailAddressVault` uses the existing device-only, unlocked Keychain
IO and a process file lock. Its bounded versioned envelope checks account, original
server, identities and draft integrity. One pending action is saved before each
network mutation; setup/replacement keeps the exact original time, identity and
hash. Retries recover that action after a lost reply or private-save failure,
without generating another address. Discard first durably records revision-zero
revocation of the new address, then sends it. A delayed setup cannot override the
server's cancellation tombstone. An interrupted rotation may already have retired
the old address; the confirmation states that explicitly.

Only confirmed receipts enter the local address catalogue. Foreign/wrong receipts
cannot confirm an address or clear recovery. Auth, workspace and session-incarnation
guards reject late results, and cancellation leases protect vault writes. Closing
or changing account clears the model's private in-memory state while preserving
unfinished recovery for the original account/server. A fresh snapshot can resolve
a superseded control without falsely reporting it applied or erasing a still-live
address. Retry also refreshes when another window has already finished the action.
Confirmed revocations prune local aliases, and account-removal cleanup includes
the email vault without touching another account's copy.

The native Backend uses the fixed email-routes path with streamed response bounds
of 512,000 bytes, a 25-second request limit, no cache/cookies and redirect refusal.
It retains expected-account checks across Auth refresh/retry. Private addresses
never enter task snapshots, widgets, exports or Taskfold backups. Reveal is explicit,
conceals on inactivity, and does not read the capability through accessibility.
iOS Copy is local-only and expires after one minute; Mac Copy uses the current
host only plus concealed/transient clipboard types and clears after one minute
only if the clipboard has not since changed. Sender review exposes an explicit
accessible name and value; this is not a human VoiceOver listening acceptance.

Verification and screenshots are recorded in `p2-email-native-setup-evidence.json`.
The Simulator walkthrough uses a strictly gated synthetic peer/memory vault, not
real Auth, email delivery or the production private Keychain path. Native Keychain
relaunch/error acceptance, hosted end-to-end Auth/recovery, Mac runtime, wider
project/account variants and spoken accessibility remain gates. Domain changes
with active routes need a migration/re-enrollment rule and hosted acceptance;
changing the environment variable alone is not an accepted rollout procedure.

Next work remains trusted provider/MIME/sender/receipt integration, source links,
scheduled inactive-account maintenance and the remaining native/hosted acceptance.
Additional verified senders remain unfinished. The user will configure the provider
and domain later; keep delivery and the native release flag disabled until the
required integration and acceptance are ready. Rank 6 and the full Px goal remain
active, followed by advanced teams and wearable clients as ranked in `P2_PLAN.md`.
