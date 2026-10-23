# Email-to-task intake

Updated 23 October 2026. The user has no inbound provider/domain yet and explicitly
authorized preparation for later configuration. Build the intake feature now; do
not enable live delivery or imply that a working address exists before provider
configuration and real signed-delivery acceptance.

## Delivery order and current evidence

| Stage | Required result | Current state |
| --- | --- | --- |
| Content and retry contract | Bounded plain text; transparent attachment omissions; a stable provider-delivery/route identity separate from content fingerprint | Implemented independently in each repo; ten Deno tests and lint pass per repo |
| Atomic intake journal and routes | One committed task per verified delivery; changed-content replays conflict; paused/revoked or unauthorized destinations refuse delivery; quotas and account-removal fencing | Implemented as a disabled local candidate; current protocol-2 evidence includes 119 intake and 40 real PostgreSQL concurrency checks per repo; hosted/provider/native acceptance remains open |
| Provider adapter and management gateway | Verify signed provider requests before trusting normalized sender/receipt data; authorize current native sessions; bounded body/read/deadlines and admission; no raw credentials in receipts | Hosted management/session recovery now passes; verified provider adapter and native UI acceptance remain open; configuration follows later |
| Native setup and recovery | Clear address/destination review, trusted senders, pause/rotate/revoke, account-bound private setup/retry, understandable delivery status and accessible controls | Native candidate implemented; scoped Simulator walkthrough and recovery tests recorded below; scoped real Simulator Keychain now passes; hosted/Mac/spoken acceptance remains open |
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
bounded per-account cleanup. The inactive-account scheduler below now prepares bounded automatic cleanup;
hosted scheduling acceptance remains required. This is not a promise of exact
automatic 30-day deletion. Seven-day
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

Still required: native UI recovery acceptance of the management gateway, signed provider/MIME
adapter with attested sender and original receipt time, native alias generation
and private vault/recovery/UI, additional sender verification, source links,
hosted scheduling and hosted/native/provider acceptance. Provider/domain
configuration stays deferred by the user. Full email intake and Px remain open.

## Native-management gateway — local candidate

`supabase/functions/email-routes` now implements the native management HTTP
boundary. It is not deployed to main. Disposable preview acceptance is recorded below;
it is not an inbound-mail/provider endpoint.
Keep the platform's default JWT verification enabled. The handler verifies the
bearer through live Auth, matches its subject, extracts its native session, and
calls only `taskfold_email_routes` with service credentials. SQL rechecks the
session/account under locks. Anonymous accounts and client-supplied owner/sender
claims are refused. No privileged credential is included in a response or client.

The request is POST with `X-Taskfold-Email: 2` and a strict JSON envelope
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
advertises a usable domain only when that configuration agrees with the database
domain and the database enable flag is true. New setup, rotation and resume require
`X-Taskfold-Email-Domain` to match the domain reviewed by the native caller. A
configuration change returns a conflict instead of silently changing the reviewed
address. Missing configuration still allows authenticated list, pause and revoke.
The native vault retains and compares the address's original domain with the
server route. The durable binding section below defines the configuration rule;
real hosted migration/re-enrollment acceptance remains open. Merely setting
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
senders and source links remain open; inactive-account maintenance is prepared
locally below and still needs hosted scheduling acceptance.

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
real Auth, email delivery or the production private Keychain path. At that milestone, native Keychain relaunch/error acceptance was open; the scoped
Simulator pass is recorded below. Hosted end-to-end Auth/recovery, Mac runtime, wider
project/account variants and spoken accessibility remain gates. The durable binding section below now implements explicit retirement and
re-enrollment before domain changes. Hosted migration acceptance stays open;
changing the environment variable alone is not a rollout procedure.

Next work remains trusted provider/MIME/sender/receipt integration, source links,
hosted scheduling and the remaining native/hosted acceptance.
Additional verified senders remain unfinished. The user will configure the provider
and domain later; keep delivery and the native release flag disabled until the
required integration and acceptance are ready. Rank 6 and the full Px goal remain
active, followed by advanced teams and wearable clients as ranked in `P2_PLAN.md`.

## Durable domain binding — protocol 2 candidate

The migration `20261023162006_email_domain_binding.sql` makes the database domain
and each route's `alias_domain` authoritative. A reviewed domain is mandatory in
create and resume bodies and in a rotation's replacement setup. The native header
is now `X-Taskfold-Email: 2`; management success receipts declare numeric `protocol: 2`.
The gateway and both native clients reject old/unbound receipts rather than
inferring a domain. Native private-address reveal requires the saved address,
route receipt and currently available configured domain to agree.

The function's `TASKFOLD_EMAIL_INBOUND_DOMAIN` remains a fail-closed deployment
cross-check. List advertises capture only when it agrees with the database domain.
A stale worker still permits authenticated pause/revoke, but cannot enroll or
resume an address for its old domain. SQL checks the reviewed domain under the
same configuration-row lock used for task capture; checking the header alone
would leave a configuration race between HTTP validation and the database write.

`taskfold_email_configure(provider, domain, enabled)` is an operator-only,
service-role RPC. Native/anonymous roles have no EXECUTE, and the app-facing
handler cannot dispatch configuration actions. Domain syntax is canonical ASCII
DNS with the same mailbox length bounds; format validation does not prove DNS,
provider ownership or real delivery. No provider secret is stored in these fields.
Service clients use the privileged configuration helper; ordinary Data API
clients still have no direct table access. Database-owner administrative writes
remain guarded by the trigger described below.

Changing domain or provider requires explicit revocation of every live address,
including paused addresses. Disabling capture alone cannot bypass this guard.
Changing the enable flag while retaining domain/provider is allowed, so operators
can stop capture without erasing saved tasks or route metadata. A database trigger
also guards direct administrative UPDATE. Configuration must run in a normal
read-committed transaction; snapshot-isolated operator transactions are refused
instead of potentially missing a concurrent enrollment. A partial live-route index
keeps this check separate from retained history.

Delivery now uses the service-only `taskfold_email_deliver_v2` RPC, requiring the
verified original recipient domain as well as the alias hash. The domain must
match both the stored route and current configuration before any receipt/task
write. This prevents a reused opaque hash from admitting old-domain mail. The
provider adapter must attest the SMTP envelope recipient; a sender-controlled To
header is not proof. The old delivery RPC loses its service-role grant and its
private implementation refuses callers instead of guessing a domain. Native roles
cannot call the new endpoint even with plausible sender/domain claims. No inbound
provider endpoint is deployed or enabled by this candidate.

The migration disables the old configuration and retires pre-binding addresses
whose domains cannot be recovered from hashes. It never guesses their domain or
changes an existing task/delivery receipt. Known retired routes retain their old
domain; unknown retired rows expose explicit null. Legacy pending setup can be
reviewed and discarded, without showing an unbound capability or silently creating
another address. The private native envelope stays version 1 because it already
stored the original domain; the wire contract changes to version 2.

Configuration and enrollment share the config-row lock. Actual PostgreSQL tests
prove both orders: a domain change committed first refuses stale setup; enrollment
committed first prevents configuration from missing that newly committed live
address. The trigger is volatile, consistent with PostgreSQL's
[fresh-query snapshot behavior](https://www.postgresql.org/docs/17/xfunc-volatility.html),
and rejects unsupported snapshot isolation. Other task/account locks retain their
existing order; the configuration guard never acquires account or task locks.

Each repo passes 57 migration/configuration checks, the existing 119 intake checks,
43 actual PostgreSQL concurrency checks with 12 observed blocking barriers, 26
HTTP-to-PostgreSQL checks, 40 Edge cases and 28 focused native Core cases. Official
local advisors report no email-object findings; five existing minimal-fixture
findings remain. Phone and largest-text dark tablet synthetic-peer workflows also
pass with protocol 2; they do not prove real Keychain/hosted/provider acceptance.
Exact source hashes, results and remaining gates are recorded in
`p2-email-domain-evidence.json`.

Rollout remains disabled. After the remaining acceptance, apply the migration,
configure the privileged database values while capture is disabled, deploy the
matching protocol-2 gateway/environment and native client, and verify the actual
provider/DNS/authenticated delivery before enabling capture or the native feature
flag. Changing an environment variable alone is never a domain migration. This
candidate's explicit retire-and-re-enroll rule is now implemented; real hosted
migration/re-enrollment acceptance remains open. It does not close the user's
separately deferred general old-client editing/upgrade safeguards.


## Simulator private recovery — 23 October 2026

The signed isolated iPhone and iPad hosts now exercise the production email vault
and actual Simulator Data Protection Keychain, using the production Backend with
intercepted synthetic HTTP. A lost response and an injected second-write failure
after a successful response both preserve the pending operation through process
termination. Retry submits the identical original body and creates no second
address. Confirmed private setup survives another relaunch. Two synthetic account
sessions keep separate private copies; returning to the first preserves its setup.
The tests query actual item attributes for unlocked-this-device-only protection
and no synchronization, then remove both owned test records and verify absence.

The phone run exposed off-screen recovery actions in the lazy Form. The message
and Retry/Discard controls now remain in a persistent top panel, adapting their
layout to text size. Final acceptance is three UI cases with zero failures on each
device, including the existing review/cancel/conceal/pause/resume regression. The
phone is normal light; the tablet uses largest accessibility text and dark mode.
Both recovery screenshots were visually reviewed; their secure-storage diagnostic
section exists only in the exact isolated Debug host. Both independent apps build.

This is not hosted Auth/account switching or provider delivery acceptance. The
confirmation error is an injected IO fault around the real Keychain, not an observed
OS denial. The plaintext check covers only the owned fixture metadata directory,
not the entire device. Mac runtime/Keychain, actual locked/denied storage, hosted
reauthentication, wider network/concurrency, clipboard and human spoken checks
remain open. No live configuration or native release flag is enabled. Exact safe
proofs and source fingerprints are in `p2-email-keychain-recovery-evidence.json`.


## Inactive-account retention — 23 October 2026

`20261023182542_email_inactive_maintenance.sql` prepares an operator-only cron job
for accounts that do not reopen Taskfold. Applying it installs
`taskfold-email-maintenance` on a five-minute schedule **inactive**, with private
state protected by RLS and no native, anonymous or service-role privileges. It
needs no provider, network request, credentials or active email delivery.

Each run visits at most 20 eligible accounts using a durable UUID cursor that
wraps. Busy accounts are skipped and revisited instead of blocking every account
after them. The transaction uses the same account advisory lock as delivery, route
management and account removal. An overlapping run returns busy. Per account it
deletes at most 500 records from each of three metadata tables: deliveries older
than 30 days by **both** creation and original receipt time; revoked routes older
than 30 days with no retained deliveries; and old setup-cancellation tombstones.
Active/paused routes, recent metadata and task content are untouched. A row lock
is skipped; a later deletion lock timeout rolls back that account's entire batch,
including its counters, without preventing other accounts from progressing.

This is eventual bounded maintenance, not a guarantee of deletion exactly at
30 days. A large backlog or busy account can require more runs. Unchanged ancient
delivery/setup requests still fail the existing seven-day admission windows after
pruning; cleanup cannot recreate a deleted task or cancelled setup. Health retains
only aggregate counts and timestamps, plus the private continuation cursor.

### Operator configuration, after hosted acceptance

Enable the pg_cron extension before applying this migration. Inspect the installed
inactive job and private state before enabling it. Use a database-operator session:

```sql
select taskfold_private.configure_email_maintenance(true);
-- To stop it, without erasing retained metadata:
select taskfold_private.configure_email_maintenance(false);
-- Inspect aggregate health:
select enabled, last_run_at, last_counts from taskfold_private.email_maintenance;
```

The supported engine mode is pg_cron's libpq connection mode. Its command sets a
20-second statement deadline **before** the cleanup SELECT; a timeout inside a
function alone would not bound the outer statement. Upstream pg_cron's background-
worker executor arms its deadline before executing that command, so configuration
explicitly refuses `cron.use_background_workers=on`. A later mode change also
refuses cleanup and publishes `unsupported_scheduler` health. Disabling always
works. This migration never changes global scheduler settings or other jobs.
Do not switch an existing project's scheduler mode without reviewing its other
jobs; background-worker support with a separately bounded worker identity remains
future work if the hosted environment requires that mode. Manual calls should
also set their statement deadline before invoking the function.

### Acceptance

Each independently owned repo passes 70 actual PostgreSQL checks: retention clocks,
metadata limits, cursor wrap, unchanged task snapshots, ancient replay rejection,
account fencing, overlapping runs, row locks, rollback after partial deletion and
atomic configuration failure. Official local advisors report no email findings;
five existing minimal-fixture findings remain. Fourteen additional checks per repo
use actual upstream pg_cron 1.6.8, compiled from a pinned commit/archive, with no
new Docker image or build cache. A temporary one-second fixture schedule runs
the unchanged cleanup command, proves deletion/preservation and disablement, then
a deliberately sleeping fixture query proves the SET-before-SELECT deadline. A
separate actual background-worker fixture proves configuration and runtime refusal.
The ordinary intake concurrency regression still passes 43 checks per repo.

All owned build/database containers and temporary extension files are removed.
No hosted migration, job enablement, provider configuration or real task mutation
occurred. App sources are unchanged in this milestone; earlier native build/UI
evidence remains scoped as recorded. Exact sources/results and limits are in
`p2-email-maintenance-evidence.json`. Next work is genuine hosted native recovery
and verified provider/MIME/sender integration, source links and additional verified
senders. Provider/domain configuration stays deferred; email and full Px remain open.


## Hosted management and session recovery — 23 October 2026

The unchanged production gateway and email SQL now pass 36 checks against a
disposable, nonpersistent Supabase preview branch created **without copied data**.
Each repository's own gateway source is deployed for its run, with platform JWT
verification enabled and the real forwarded-IP admission boundary. Two actual
confirmed synthetic Auth accounts and one saved synthetic task exercise the real
Auth → HTTPS gateway → PostgREST → database path. No mock HTTP, minted JWT or
replacement handler is used. The preview alone uses `mail.example.invalid` and
`synthetic-adapter`; these settings are not a usable email service.

The walkthrough verifies concealed metadata projection/no-store, exact setup
retry with an unchanged complete route row, changed-body conflict, and refusal of
another account's list/mutation/replay access. It expires the original actual
server session through its `auth.sessions.not_after`, verifies that its unchanged
bearer cannot mutate, refuses a wrong password, and signs in again through actual
password Auth. The new session retries the original setup with the same complete
route fingerprint. Pause and retry, reviewed resume, rotation and retry, terminal
revocation and cancel-before-create all persist. Old sessions remain refused.
Native roles cannot bypass management or attest provider delivery through direct
RPC calls. The full pre-existing synthetic task snapshot remains unchanged.

This is controlled server-session expiry, not natural wall-clock JWT expiry. It
proves hosted service recovery, not the native model's sign-in sheet, process
relaunch, clipboard, VoiceOver or Mac runtime. Those native gates remain open.
Real provider signatures/MIME, sender and original-recipient/receipt attestation,
source links, additional verified senders and hosted retention enablement remain
separate work. Email intake and the full Px objective are not complete.

Official hosted advisors report no findings for email objects; existing preview
advisories are retained in the evidence rather than described as a clean whole-
project audit. The harness disables preview capture, removes both synthetic users
and their data, removes its function/environment values and private staging files.
The owned preview branch and local connection file are then removed and absence
verified. No main deployment, production feature flag or real mail delivery is
enabled. Exact source hashes, checks and cleanup are recorded in
`p2-email-hosted-management-evidence.json`. The reusable guarded harness is
`Scripts/Diagnostics/test-email-routes-hosted.mjs`; it refuses main, persistent,
data-bearing and unrelated branches.
