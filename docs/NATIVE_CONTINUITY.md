# Authenticated native continuity — 9 October 2026

The online phone → tablet → phone task round trip passes against the real TaskFold backend using one disposable account. This closes a specific acceptance gap, not the complete cross-platform P0 gate.

## Verified

- Native password login and Keychain persistence across app relaunch: one passing UI test on each isolated iPhone 17 Pro and iPad Pro 11-inch M5 Simulator (iOS 26.5).
- Phone creates a task through the normal UI and retains it after relaunch.
- Tablet loads that task through normal authenticated sync and edits its title through the editor.
- Phone relaunches and receives the tablet's edit. An authenticated server read after each step proves exactly one task and the same record ID throughout.
- Three round-trip UI cases passed, with zero skips, failures or reported runtime warnings. All three actual captures were inspected; the task title and primary navigation are readable in these standard-text captures.
- The Mac-owned Backend signs in independently and reads the resulting task, checking owner, title, completion and generation. Its focused live test passed once with zero skips/failures. It injects a no-op session persistence closure and never opens the Mac app or accesses its Keychain.

## Failure found and corrected

The first native login test failed because the unsigned Simulator build had no simulated application entitlement: Keychain returned `-34018` and the UI correctly stayed at sign-in with a session-save error. The server had accepted the credentials. Rebuilding with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` restored normal Keychain behavior; both login/relaunch cases then passed without app-code changes. An unsigned build is insufficient evidence for authenticated acceptance.

The Debug Simulator app/widget build with the new UI cases passes. Production application sources are unchanged in this checkpoint; the preceding build/Core evidence still describes them. The test changes received targeted execution, not another redundant full build matrix.

## Boundaries and cleanup

This proves one online task title round trip between two iOS Simulators and read-only decoding through the Mac transport. It does not prove Mac GUI interaction, offline reconnection, concurrent conflicts, rich task fields, organization/settings continuity, restoration, membership revocation, mixed versions, physical devices, installed widget behavior, remote delivery, or distribution. Those remain open P0 acceptance work.

Only the disposable `taskfold-continuity-…@example.invalid` account was used. Its sessions were deleted before the account; subsequent queries showed zero account, session, profile and task rows. The private credentials and scoped account caches were removed, and the isolated apps' session reset was run. Raw authentication diagnostics remain private because XCTest may log a password prefix. No credentials or authentication logs are committed. The existing Mac installation was not launched or modified.

See `native-continuity-evidence.json` for the scoped receipt.

## Repeat the Mac transport check

After the iOS native walk and before removing its disposable account, run the Mac-owned companion:

```sh
TASKFOLD_CONTINUITY_FIXTURE=/private/tmp/taskfold-live-verification.json swift test --filter NativeContinuityTests
```

Require one executed passing test with zero skips. Without the opt-in fixture the test skips; that is not acceptance evidence. The private JSON has `userID`, `email`, `password`, `url`, and public `key`. Only the disposable continuity namespace is accepted. This test reads the live task and does not seed or mutate it. The iOS UI driver remains in the independent iOS repository; this repository has no build dependency on it.

## Controlled outage and conflict recovery — 9 October

A second disposable account completed two native login/relaunch cases, then seven ordered phone/tablet UI cases: the original online round trip, an offline phone title edit, a competing tablet title/notes edit, review deferral/relaunch and Keep my edit, and receipt of the reviewed title on the tablet. Every case passed with zero skips/failures/reported runtime warnings. Authenticated reads checked the same single server record between phases. After the offline process relaunched, its on-disk queue contained the expected edit and baseline while the server still held the earlier title. After review, the chosen phone title and independent tablet notes were present on the server and visible on both devices.

The outage is deliberate fault injection: only the isolated Debug Simulator bundle, with a loaded disposable continuity account and `--continuity-offline`, gets a URLSession whose URLProtocol fails HTTP with `notConnectedToInternet`. It leaves the normal Store, cache, queue and conflict machinery in use. Removing the argument on relaunch restores normal HTTP. The hook is excluded from Release and physical-device builds and does not change Mac production transport. This is not an OS network-disconnection or physical reconnect test.

The first offline screenshot exposed raw `NSURLErrorDomain -1009` feedback and “1 changes”. Both apps now explain offline, interrupted-connection and timeout failures in plain language and use a singular count for one pending change. Unrelated errors retain their explanation. Two focused Core tests pass in each repo; the Mac run also passes its live read-only check of the reviewed title and preserved notes (three total, zero skips). Both final Debug native app/widget builds pass. The signed final iOS build passes a focused offline feedback/relaunch case, again confirming an unchanged server record and the pending local edit; its actual screenshot is inspected. The preceding seven-case run was before this feedback polish, not a claim that it was rerun afterward.

The iOS repository retains four inspected captures: before/after offline feedback, the real conflict review and the tablet's resulting task details. The review comparison and actions are readable; explanatory text below the comparison requires scrolling. No full-surface or VoiceOver acceptance is inferred.

The disposable account's sessions were deleted before the account. Subsequent queries found zero account/session/profile/task rows, the credentials and scoped cache were removed, and the isolated clients' session reset ran. See `offline-continuity-evidence.json` for the scoped receipts and final owned input hashes.

Still open: the paired native Use synced choice, multiple later queued edits, rich task and organization data, actual network loss/recovery on physical devices, Mac GUI, membership revocation, restore/mixed-version acceptance and the other full P0 gates.

After the iOS conflict run and before its cleanup, execute `TASKFOLD_OFFLINE_CONTINUITY_FIXTURE=/private/tmp/taskfold-live-verification.json swift test --filter NativeContinuityTests/testMacTransportReadsReviewedOfflineEdit`. Require one actual passing test and no skip. This reads the real reviewed task and notes through Mac-owned transport without launching the Mac app.
