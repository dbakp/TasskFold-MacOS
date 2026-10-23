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
