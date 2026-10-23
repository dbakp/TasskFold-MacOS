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

If an unfinished request never reached the service, Continue setup first, then
revoke. There is no local Forget button that could strand an untracked active key.
Ordinary sign-out keeps recovery. Confirmed account-removal cleanup erases only
that account’s matching-original-server enrollment item, after remote key
revocation/removal is established. Another server’s unfinished enrollment is preserved.

Copy uses iOS local-only/expiration options. Mac uses
[the current-device pasteboard option](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly),
concealed/transient markers and an ownership-checked one-minute cleanup while the
app is running. Mac cannot promise timed cleanup after process termination.
Revealed text has no ordinary selection-copy route that bypasses these options.

## Verification boundaries

`swift test --filter 'AutomationEnrollmentTests|AutomationAccessTests|AccountTransportTests'`
runs 63 independent checks per repo, including lost replies, secure write/remove
failure, close/account fences, origin isolation, stale-window retirement, corrupt
storage and pagination. Native fixture UI checks use actual OS Keychain and the
actual Backend management transport through an owned URLProtocol; no hosted
request, real key, real account or task data is used. That protocol fixture is
not live Auth, quota, revocation, SQL or concurrency acceptance.

Both iPhone and iPad Simulator pass the two native scenarios (four passes, no
failures/skips) with actual Keychain recovery, relaunch, reveal/hide, acknowledgement,
revocation/history and largest-text Delete-switch activation/cancellation. The
masked and dark layouts are visually inspected. Mac has its independent Core
pass and unsigned build; Mac native interaction is not claimed.

See `p2-automation-native-management-evidence.json` for exact native results.
Remaining work includes hosted signed-in management and lifecycle acceptance,
native clipboard lifecycle, independent-process secure-write coordination, safe
cancellation of a never-created uncertain request, broader accessibility and Mac
native interaction, project/section discovery,
portable advanced-reminder authoring, rejected-traffic controls and real backend
races/timeouts. The complete automation/Px goal remains active. User-deferred
release, remote reminders, old-client policy and physical location remain deferred.

The isolated iOS XCTest entry points are
`TaskfoldUITests/testAutomationKeyLostReplyRecoveryAndRevocation` and
`TaskfoldUITests/testAutomationPermissionReviewAtLargestText`. Prepare the owned
Simulator host with `Scripts/prepare_workflow_ui_test.py` and the
`workflowtestsp1` namespace, build its Taskfold scheme, then select these tests
on iPhone/iPad Simulator. Tests set the exact local-only fixture arguments and
close the app afterward. Other bundles skip these fixtures. This does not enable
the normal release entry or contact the hosted service.
