# Automation access — native management candidate

The Account screen owns a native Automation access entry in each app. It stays
hidden until the matching service is enabled by the app's deployment configuration
(`TaskfoldAutomationEnabled`). Exact isolated DEBUG hosts can exercise the same
screens with synthetic local protocol interception. The service remains undeployed.

## User flow

Give each trusted tool its own name, expiry and selected permissions. Read access
is the default; write, completion and deletion require explicit choices. The
review explains shared-project access and destructive deletion. An empty name
or empty permission set cannot submit. Keys are listed with permissions, expiry,
status and last use; inactive history has bounded Load more pagination.

A confirmed key is hidden initially. Reveal and Copy are explicit. “I’ve saved my
key” finishes the one-time review. The screen covers content when inactive and
hides the revealed value on activation changes. Account/workspace/session changes
invalidate the view and late responses. Revoke requires confirmation and a valid
server receipt; a failed or lost response is not presented as a confirmed revoke.

## Interrupted setup

Before the first request, an app-only device Keychain item durably stores the
exact draft. Only this dedicated private envelope is Codable; task snapshots,
widgets, portable backups, UserDefaults and ordinary diagnostics never receive
the secret. The item uses non-synchronizing WhenUnlockedThisDeviceOnly storage
under a bundle-specific service. Each account has at most one unfinished setup;
its original HTTPS server is required to resume it.

A reply loss or crash retains the same ID/hash/name/scopes/expiry. Reopening shows
Continue setup and must reconfirm the registration before revealing the secret.
Closing the screen clears its view state while keeping recovery. Explicit save
acknowledgement clears private recovery; confirmed revocation clears it too.
Unconfirmed revoke or Keychain failures retain recovery. Corrupt records are
refused without overwrite. A stale window cannot erase a newer setup, and saving
or revoking in one window removes another window's reveal permission. A competing
setup or replacement requires its current name/permissions to be reviewed before
any registration request; a stale window cannot silently authorize different scopes.

Discard setup works even when creation never reached the service or issuance is
limited. A version-2 private envelope records that intent before the request.
After a lost reply or crash, recovery offers Retry discard and never creates the
key again. A prior version-1 private reader refuses the new state without
overwriting it. A stale Save acknowledgement cannot erase the discard intent.
Only a confirmed owner/ID cancellation receipt clears it.

The service revokes an already-created owned key; otherwise it permanently blocks
that account/ID from late creation. The response never reveals another account’s
key. Unknown cancellations have a separate 100-new-tombstones-per-UTC-day budget;
existing retries and owned-key revocation bypass that new-row limit. Cancellation
does not consume key issuance. No raw secret or task text enters this history.
Ordinary sign-out retains recovery; confirmed account removal erases only the
matching account/original server’s private item.

A stable empty lock file in private app support serializes each account’s reads,
prepare, write, acknowledgement and cleanup across independent processes. Never
unlink these files during normal operation. Lock waits are bounded to two seconds
and check cancellation. A process crash releases the kernel lock. Foreground
reactivation and registration receipts recheck current recovery before revealing.
Reveal/copy UI state is tied to the key ID, so a new key starts hidden.

Copy uses iOS local-only/expiration options. Mac uses
[the current-device pasteboard option](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly),
concealed/transient markers and an ownership-checked one-minute cleanup while the
app is running. Mac cannot promise timed cleanup after process termination.
Revealed text has no ordinary selection-copy route that bypasses these options.

## Verification boundaries

`swift test --filter 'AutomationEnrollment|AutomationAccessTests|AccountTransportTests'`
runs 74 independent checks per repo, including lost replies, secure write/remove
failure, close/account fences, origin isolation, stale-window retirement, corrupt
storage and pagination. Native fixture UI checks use actual OS Keychain and the
actual Backend management transport through an owned URLProtocol; no hosted
request, real key, real account or task data is used. That protocol fixture is
not live Auth, quota, revocation, SQL or concurrency acceptance.

The current three-scenario proof covers Keychain recovery, relaunch, reveal/hide,
acknowledgement, revocation/history, largest-text Delete-switch activation and
Cancel, plus never-created setup discard across a deliberately lost cancellation
reply and relaunch. The final discard fixture records one attempted creation,
two cancellation calls and zero issued keys. Masked, dark and discard-recovery
layouts are visually inspected. Mac has its independent Core pass and unsigned
build; Mac native interaction is not claimed.

See `p2-automation-enrollment-cancellation-evidence.json` for current results and
`p2-automation-native-management-evidence.json` for the historical checkpoint.
Remaining work includes hosted signed-in management and lifecycle acceptance,
native clipboard lifecycle, actual multi-process Mac Keychain acceptance, broader
accessibility and Mac native interaction, project/section discovery,
portable advanced-reminder authoring, rejected-traffic controls and real backend
races/timeouts. The complete automation/Px goal remains active. User-deferred
release, remote reminders, old-client policy and physical location remain deferred.

The isolated iOS XCTest entry points are
`TaskfoldUITests/testAutomationKeyLostReplyRecoveryAndRevocation`,
`TaskfoldUITests/testAutomationPermissionReviewAtLargestText` and
`TaskfoldUITests/testAutomationUnsentKeyDiscardSurvivesLostReply`. Prepare the owned
Simulator host with `Scripts/prepare_workflow_ui_test.py` and the
`workflowtestsp1` namespace, build its Taskfold scheme, then select these tests
on iPhone/iPad Simulator. Tests set the exact local-only fixture arguments and
close the app afterward. Other bundles skip these fixtures. This does not enable
the normal release entry or contact the hosted service.

Run `npm run --prefix Scripts/Database test:automation-cancellation` for 55 actual
local SQL assertions, and `deno test supabase/functions/automation-keys/handler_test.ts`
for ten handler checks. The existing credential fixture and 101 mutation/18 loopback
HTTP checks run with the new migration loaded. The two process cases launch real
independent xctest workers against a test-only synthetic atomic-item adapter;
they cover competing writes, bounded lock failure, process death and symlink
refusal. They do not prove actual multi-process Mac Keychain or SQL races.


The inactive key-management handler now uses the shared admission gate before
body parsing or its live Auth call. Its 600 global / 60 IP / 60 credential attempts
per UTC minute are independent of task-route limits and of successful key issuance
or permanent cancellation-history budgets. A rejection preserves the native private
recovery state for an explicit retry. The server returns a safe `429`/Retry-After or
fail-closed `503`. Gateway JWT rejections that occur before Edge invocation remain
provider behavior. The matching client-header mode is now verified on the project but remains unset;
see `AUTOMATION_API.md` and `p2-automation-ingress-evidence.json`. No deployment or
normal entry enablement occurred.


## Independent key-review actions — 23 October

Four scoped cases pass on the corrected source: two each on iPhone/iPad
Simulator. The unchanged baseline failed before the button-style correction.

The API-key review row now gives Reveal/Hide and Copy independent borderless
button targets in each app. The unchanged iOS baseline failed the strengthened
regression: tapping Reveal started the clipboard probe. This confirmed that the
Form row could invoke Copy as well. The fix changes only that row's button style;
it preserves enrollment, permissions, secret storage and clipboard policy.

The native regression now requires Reveal to leave the clipboard probe untouched,
backgrounding to conceal the raw value after an actual background/suspended state,
and Copy to leave every accessible label/value free of the raw key prefix. It
rechecks masking after the real one-minute pasteboard expiry or preservation of
newer clipboard content. Acknowledgement and normal relaunch still check actual
private OS Keychain cleanup. The API peer is synthetic and exact-host guarded;
these runs issue no hosted credential and modify no real task or account.

The earlier clipboard milestone did not assert action independence or masking
immediately after Copy. Its historical green results therefore do not prove those
properties. This round's scoped outcomes and baseline failure are recorded in
`p2-automation-review-controls-evidence.json`. Mac source builds independently;
Mac gesture/pasteboard/Keychain runtime acceptance remains open.
Normal feature entry and main API enablement remain unchanged and disabled.
The full Px objective and its existing user deferrals remain in force.


## Concealed review after an unconfirmed action — 23 October

Both apps now remove the previous secret-review confirmation when a connection
operation reports an error. The exact private enrollment stays in its existing
account/server-bound vault; an uncertain webhook control keeps its original
retry intent. Successful control retry alone does not reveal the secret again.
Continuing enrollment can reconfirm the same setup, and its native Reveal/Copy
state resets so the raw value requires another deliberate Reveal tap.

Connection requests still attempt one automatic credential renewal. A repeated
401 on the two management routes, or a documented invalid/expired refresh-session
code, now produces a fixed sign-in message instead of server details. The notice
says a private setup was kept only when one exists. Rate limiting, server failures
and unknown refresh errors are not treated as confirmed session expiry. A rejected
refresh from a superseded account/session becomes cancellation, so it cannot
request sign-in for the newly active account. This does not log out the user,
remove tasks or erase recovery.

The regression failed on the unchanged iOS key and webhook models (two cases,
five failed assertions). Both full Core suites now pass (iOS-owned: 1,365 cases,
13 optional skips; Mac-owned: 1,397 cases, 33 optional skips; no failures).
Four iPhone/iPad native checks pass, with no skips, and their normal/largest-text
screenshots are visually inspected. Exact results and the verification limits are
recorded in `p2-connection-review-failure-evidence.json`. Native cases use the
production view/model with an exact isolated Debug-only, in-memory service refusal;
transport cases separately exercise real URLSession through a synthetic peer on
the Mac-hosted Core test target.
They do not claim hosted native expiry/refresh acceptance or an in-place sign-in
sheet. That end-to-end recovery walkthrough, wider consent/history speech, Mac
runtime, email intake, advanced teams and wearables remain open. Normal automation
entries and main services stay disabled, and all user deferrals remain unchanged.

The refresh classifications use the provider's structured `code` field, following
the [Supabase Auth error-code reference](https://supabase.com/docs/guides/auth/debugging/error-codes). No matching against server message text is used.


## In-place connection sign-in recovery — 23 October

Automation keys and task connections now offer **Sign in again** after a confirmed
session refusal. The native sheet renews only the current account, on the same
server and session incarnation. A response for a different account is rejected
before credentials are saved. Stale contexts and late cancelled requests cannot
replace the active session; cancelling an older sheet cannot cancel a newer sign-in.
Cancel remains available while the request is pending and is disabled only during
the serialized credential save. Password errors stay visible above the form,
including at the largest accessibility text size.

Successful renewal rebuilds the connection manager against the new session and
its existing private enrollment vault. It deliberately avoids the full account-entry
Store reset, preserving the current workspace and Undo state by construction.
Continuing setup retries the original enrollment; it returns to a masked review
and never reveals a secret automatically. The native synthetic peer rejects any
changed enrollment body, including changed private material. Delivery-history
notices also offer the same recovery action after dismissing history.

Both independent Core suites pass (iOS-owned: 1,372 executed, 13 optional skips;
Mac-owned: 1,404 executed, 33 optional skips; no failures). Subsequent focused runs
cover the final concise feedback copy and an additional foreign-origin/signup guard.
iPhone/iPad native results and reviewed screenshots are recorded in
`p2-connection-reauthentication-evidence.json`. Each app owns its source and project
inputs; the Mac app compiles independently.

The native fixture uses the production Backend and real URLSession through a
synthetic HTTP peer, with memory-only credentials and enrollment storage. It does
not establish genuine hosted Auth, Keychain persistence, Google account-selection,
cached/queued-work or Undo runtime acceptance. Those remain separate acceptance
work, alongside Mac runtime and wider consent/history speech. Normal feature
entries and main services remain disabled. Email intake, advanced teams and
wearables remain open; full Px is not complete. Remote reminders, older-client
rollout safeguards, distribution verification, OAuth registration/provider
acceptance and physical location-reminder delivery remain deferred by the user.


## Hosted sign-in recovery and profile continuity — 23 October

A real no-data preview Auth response exposed a wire-format gap: a refused refresh
returned HTTP 400 with numeric `code: 400`, `error_code: "session_expired"` and a
message. The client previously checked only string `code`, which classified that
response as a generic failure and omitted **Sign in again**. Both apps now prefer
a nonempty `error_code`, falling back to the normalized string `code` format.
Only the existing four recognized session reasons and allowed error statuses
request sign-in; unknown reasons, throttling and server failures retain their
separate classification. Message text never determines session expiry.

Optional profile hydration now saves updated user details without entering the
full sign-in acceptance path. It keeps the current account/session incarnation,
open connection leases and pending explicit authentication attempt. After awaiting
persistence it rechecks the account incarnation and updates only profile metadata
on the latest live credentials, preserving tokens renewed during the save.
Full sign-in, sign-out and account changes retain their original invalidation.

The old profile path failed a regression with three assertions. The old raw Auth
parser failed five assertions, including a conflicting-field case. Both independent
transport suites now pass 55 cases. The full suites passed after the profile fix
(iOS-owned: 1,376 executed, 13 optional skips; Mac-owned: 1,408 executed, 33 optional
skips; zero failures); the final localized wire-parser change is covered by the
subsequent full transport suites. Both native app targets compile independently.

The iOS repo owns `--native-reauthentication` in its guarded hosted controller and
`testHostedWebhookReauthenticationPreservesSetupWorkAndUndo`. It uses actual
password Auth, HTTPS management, OS Keychain, native task capture, Undo/Redo and
normal relaunch. The controller expires only disposable users' server sessions via
`not_after`; it does not mint or edit JWTs, advance device clocks, or claim natural
wall-clock access-token expiry. It compares the complete original connection and
saved-task fingerprints, verifies a new real server session, and checks persisted
Undo/Redo. Its app-specific lost-reply flag discards one actual successful setup
response; all subsequent replies are real. The mode leaves the webhook scheduler
inactive. Exact runs, corrections, cleanup and acceptance limits are recorded in
`p2-hosted-connection-reauthentication-evidence.json`.

This does not close the full advanced backlog. Native API-key hosted renewal,
queued-edit recovery across renewal, real Google selection, Mac runtime/Keychain
and wider spoken consent/history remain separate checks. Email intake, advanced
teams and wearables remain open. Normal feature entries and main services remain
disabled; all existing user deferrals remain unchanged.


## Queued task sync after sign-in renewal — 23 October

Both apps now offer **Sign in again** directly beside a confirmed expired-session
sync warning, explaining that edits remain saved on the device. The action uses
the existing same-account sheet and avoids the full workspace-entry reset. Success
retries the saved queue; a workspace-bound deferred retry also handles renewal
finishing during an older sync. Account changes, sign-out and account removal
invalidate recovery. Renewal in connection settings also retries task sync.

Actual hosted iPhone and iPad Simulator checks pass without skips: a native create
stays queued through refused refresh, restart, wrong password and Cancel, then
automatically syncs with its original ID/generation after renewal. The original
saved task's complete server fingerprint stays unchanged, the server contains
only one matching queued task, and normal relaunch uses renewed Keychain
credentials. Only the local Debug refresh-due timestamp is controlled; this does
not claim natural JWT expiry or exactly one network invocation. Both independent
Core suites pass (iOS: 1,378 executed, 13 optional skips; Mac: 1,410 executed,
33 optional skips; zero failures), and both app targets compile.

See `p2-queued-sync-recovery-evidence.json` for exact runs, reviewed images, the
diagnostic-only startup-log correction, cleanup and limits. The temporary branch,
credentials and installed test apps are removed. Mac runtime, queued edit/delete
and held-sync variants, API-key-specific hosted renewal, Google selection and
wider spoken checks remain open. The advanced backlog is not complete; all user
deferrals remain unchanged. Normal automation/webhook feature entries stay gated.


## Hosted API-key sign-in recovery — 23 October

The remaining API-key-specific native renewal check now passes on iPhone and
iPad Simulator (one test each, no failures or skips). Actual Auth, HTTPS and OS
Keychain are used. After synthetic server-session expiry, wrong password and
Cancel preserve setup; same-account renewal and Continue return to the original
concealed key. Server comparisons verify one key with unchanged ID, secret hash,
permissions, expiry and counters, plus an unchanged complete saved-task
fingerprint. Normal relaunch recovers that setup with renewed credentials; native
acknowledgement and revocation persist through another relaunch.

No product defect was found, and Release behavior is unchanged. The iOS repo
extends its exact Debug host allowlists and owns the native test/controller; both
repos retain independent unchanged production services. This does not claim Mac
runtime, Google selection, natural JWT expiry, all queued-edit variants or wider
spoken acceptance. Exact runs, reviewed masked screenshots, source fingerprints
and verified test-app/preview cleanup are in
`p2-hosted-api-key-reauthentication-evidence.json`. Core and Mac app code are
unchanged; their previous committed suite/build evidence remains applicable.

Next feature implementation: idempotent email-to-task intake, followed by advanced
teams and wearable clients. Provider/domain configuration remains undecided; live
mail delivery must stay gated until configured and verified. Full Px remains
active, and all existing user deferrals stay unchanged.
