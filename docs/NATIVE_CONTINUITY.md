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

At that checkpoint, Use synced and later queued edits were still open; the follow-up below covers one such sequence. Still open: broader rich task and organization data, actual network loss/recovery on physical devices, Mac GUI, membership revocation, restore/mixed-version acceptance and the other full P0 gates.

After the iOS conflict run and before its cleanup, execute `TASKFOLD_OFFLINE_CONTINUITY_FIXTURE=/private/tmp/taskfold-live-verification.json swift test --filter NativeContinuityTests/testMacTransportReadsReviewedOfflineEdit`. Require one actual passing test and no skip. This reads the real reviewed task and notes through Mac-owned transport without launching the Mac app.

## Use synced preserves later offline work — 9 October

A fresh disposable account now proves the second conflict choice. The phone queues a title edit and, in a separate save, a 30-minute estimate on the same task while its transport is deliberately offline. Both mutations and their original baselines survive relaunch; the server still has the prior title and no estimate. The tablet then edits the title and adds independent notes. Choosing Use synced on the phone accepts the tablet title/notes while replaying the later estimate. Both devices display all three final values; authenticated reads confirm the same single task ID and both durable task queues are empty. The Mac-owned transport independently reads the resulting title, notes and estimate in one passing live test without accessing the Mac app or its Keychain.

Evidence: two native login/relaunch passes, three initial online phases, and five passes after correcting a test switch tap (one repeated online observation plus the four new conflict phases). Passing results have zero failures/skips/reported runtime warnings. The first offline attempt stopped before saving its estimate because a center-row tap left the switch off; the corrected test taps the control and asserts its value. Only that disposable phone draft cache was removed, then the phone reloaded the previously verified server record before the resumed sequence. No task data was seeded or edited through HTTP. Final iOS Debug test build passes; unchanged production code did not require repeated full Core/native matrices. Three actual phone/tablet screenshots were inspected and retained in the iOS repository.

The shared backend fixture account, sessions, profile and task were deleted and verified absent. Private credentials and scoped device caches were removed, and isolated client session resets ran. See `use-synced-continuity-evidence.json`. These results cover one title conflict plus a later independent estimate; deletion/recurrence, many-record queues, organization/settings, restore/mixed versions, physical network recovery, Mac GUI and full P0 remain open.

To repeat from a fresh disposable account, run the existing two native login checks, then use the continuity driver with `--use-synced` and a fresh output directory. It runs all seven phases and checks server identity, field preservation and durable queue state. This flag is mutually exclusive with the other continuity modes.


## Saved-filter continuity — 9 October

A fresh disposable account now passes native phone creation of two tasks and one search filter, receipt on the tablet, tablet rename and rule edit from search to No date, and receipt/persistence after phone relaunch. Authenticated read-only server checks confirm the same single filter ID, changed query AST/name, both unchanged task IDs and drained task/filter queues. Both login/relaunch cases and all three filter phases pass with no failures/skips/reported runtime warnings. The Mac-owned transport independently signs into the fixture without using Keychain, reads the edited filter/tasks and evaluates the rule to the same two task titles in one passing focused test. This does not establish Mac GUI behavior.

Three actual screenshots were inspected and retained in the iOS repository. Only test/driver/evidence changes were required; production logic is unchanged. The final iOS Debug test build and Mac test build pass. Fixture sessions were deleted before its account; subsequent checks found zero users/sessions/profiles/tasks/saved views. Scoped device caches and credentials were removed and both isolated clients reset. [Exact receipt](saved-filter-continuity-evidence.json). Saved-filter offline conflicts, restored/mixed-version data, membership changes, broader organization/settings and full P0 remain open.

To repeat, prepare a fresh private continuity account as described above, build/sign the isolated iOS test products, then run `Scripts/test_saved_filter_continuity.py --xctestrun PATH --phone UUID --tablet UUID --output NEW_DIRECTORY` in the iOS repo. It includes both native sign-ins and all three ordered filter phases. Run the Mac focused test with `TASKFOLD_FILTER_CONTINUITY_FIXTURE` pointing to that same private fixture before cleanup. Do not run other continuity drivers against the resulting nonempty workspace; revoke/delete the fixture and reset clients afterward.


## Cross-device deletion and empty-filter feedback — 9 October

A fresh signed-in phone creates two tasks and a saved search filter. The tablet deletes the matching task through its native swipe action; the unrelated task remains. The phone receives the deletion and retains it after relaunch. Authenticated server reads and each client’s durable cache agree on the surviving task ID; the saved filter ID/query remains unchanged and task/filter queues are empty. The Mac-owned transport reads only the surviving task and evaluates the saved filter to an empty result in one passing focused live test.

The initial five UI cases pass with zero failures/skips/reported runtime warnings. Their empty-filter screenshot exposed misleading “All clear” wording despite other work remaining. Both native list views now say “No matching tasks” with guidance to edit the filter or add a matching task. Two additional final phone/tablet relaunch cases pass and assert the new wording. Final iOS/Mac Debug arm64 app/widget builds pass. Three before/after screenshots were individually inspected and retained in iOS. No Mac GUI was launched. [Exact evidence](deletion-continuity-evidence.json).

Fixture sessions were revoked before deleting the account; final account/session/profile/task/filter counts are zero. Both device sessions were reset, scoped caches removed and private credentials deleted. Repeat with `Scripts/test_saved_filter_continuity.py --delete-task` and the existing required arguments on a fresh disposable account. Before cleanup, the Mac check accepts `TASKFOLD_DELETE_CONTINUITY_FIXTURE`. Offline/concurrent deletion, restoration, Mac runtime, physical devices and full P0 remain open.


## Offline deletion versus concurrent edit — 9 October

A fresh disposable account passes two native login/relaunch cases and seven ordered continuity phases. The phone queues a deletion during the controlled transport outage, then relaunches: its durable DELETE retains the original whole-task baseline while the server still contains the same task. The tablet changes its title and notes. Reconnecting the phone presents deletion review, which survives Later and another process restart. Keep task cancels the deletion and retains the concurrent title/notes after relaunch. Both clients’ caches match the same server task ID and both task queues are empty. All nine iOS cases pass with no failures, skips or reported runtime warnings. One Mac-owned read-only transport test passes against that resulting account without Keychain or Mac GUI access.

Three actual screenshots were inspected and retained in iOS. They expose an outstanding usability issue: deletion review sorts fields alphabetically, placing empty Assigned to/Attachments sections before the changed notes. Prioritize changed contents in the next review UI update. This run proves the Keep task data-safety path, not polished review ordering or the explicit Delete task choice under live concurrency.

No production code changes were needed for this sequence. The iOS test build and Mac test build pass. The fixture sessions were revoked before deleting the account; users/sessions/profiles/tasks/saved views all verified zero. Both isolated app sessions, scoped caches and private credentials were reset/removed. Repeat with the existing two login checks, then Scripts/test_native_continuity.py --offline-delete and its required arguments. Before cleanup, run the Mac test with TASKFOLD_OFFLINE_DELETE_FIXTURE pointing to the private fixture. See offline-deletion-continuity-evidence.json. Physical network outages, explicit destructive review, restore/recurrence, Mac GUI and the full P0 goal remain open.


## Deletion review prioritizes changes — 9 October

Both native apps now show fields changed since the queued deletion before unchanged fields, with notes/title/comments/subtasks ahead of less descriptive metadata within each group. Changed fields are labeled “Changed since deletion”; all previously reviewable fields remain available. Reviews without an old baseline do not claim a field changed. The deletion screen is titled “Review task deletion”; ordinary edit review keeps its existing behavior.

The iPhone fixture includes changed notes and verifies they are visible before scrolling. Both Keep task and explicit Delete task pass deferral, resolution and relaunch checks with zero failures/skips/reported runtime warnings in the final result. The first run’s Delete check raced sheet dismissal; it now waits for the review button to become hittable and for the resolved review to disappear. Final screenshot inspected and retained in iOS. iOS Debug app/widget/test and Mac Debug app/widget builds pass. This closes the ordering issue discovered in the preceding live test, not the still-open live concurrent explicit-deletion or Mac GUI acceptance. See deletion-review-evidence.json.


## Explicit deletion after concurrent editing — 9 October

The second live deletion choice now passes with a fresh disposable account. The phone queues deletion offline; the tablet changes the title and adds notes. Reconnection shows the changed notes immediately in the improved deletion review. After Later and relaunch, the phone explicitly chooses Delete task. The same reviewed task disappears from the server and both clients’ durable caches, both task queues are empty, and tablet relaunch does not resurrect it. Two native login/relaunch checks and seven ordered UI phases pass with zero failures/skips/reported runtime warnings. A Mac-owned authenticated transport check independently reads the empty task set in one passing test. This verifies one task with one concurrent edit, not all deletion races or Mac interaction.

Two actual screenshots were inspected and retained in iOS. No further production changes were necessary. Final iOS test build and Mac test build pass. Sessions were revoked before the disposable account was deleted; user/session/profile/task/filter counts verified zero. Both isolated app sessions were reset, scoped caches and private credentials removed. Repeat using the two native login checks followed by Scripts/test_native_continuity.py --confirm-delete with its existing required arguments. Before cleanup, the Mac check accepts TASKFOLD_CONFIRMED_DELETE_FIXTURE. See confirmed-deletion-continuity-evidence.json. Recurrence, organization/settings, restore, revocation/mixed versions, physical network loss and actual Mac user flows remain open.


## Recurring completion across native clients — 9 October

A phone creates a daily task planned for 3 January 2028, ending 5 January, limited to three occurrences, with a 25-minute estimate. Completing it retains the completed original and creates exactly one open next occurrence on 4 January with the same rule and estimate, except the remaining count becomes two. Phone relaunch and tablet receipt/relaunch show the same next date, repeat summary and completed history. Authenticated reads and each client’s durable cache agree on both stable IDs and relevant fields, with empty task queues. One Mac-owned transport test independently reads the same pair.

Evidence comprises four passing phases from v2 (two logins, creation, completion) and the final tablet phase from v5, all with zero failures/skips/reported runtime warnings. The first creation attempt used Daily in the title alongside every day, triggering the existing multiple-rule warning before saving; the title was corrected. Tablet attempts v2–v4 tested a non-interactive text label or scrolled past it; the final test uses the actual estimate stepper, short form-scoped gestures and navigation-bar-aware bounds. Only the tablet phase was resumed after the successful phone completion. No production behavior changed. Final iOS test build and Mac test build pass. Two screenshots were inspected and retained; the tablet Repeat sheet is a partial scroll viewport.

Sessions were revoked before deleting the disposable account. Final users/sessions/profiles/tasks/saved views counts are zero, both clients reset, scoped caches and private credentials removed. Repeat with Scripts/test_recurrence_continuity.py and its required xctestrun/phone/tablet/output arguments; --resume-tablet verifies an existing completed original/next pair without creating or completing again. Before cleanup, the Mac test accepts TASKFOLD_RECURRENCE_CONTINUITY_FIXTURE. See recurrence-continuity-evidence.json. Concurrent completion, other rule families, physical/offline recovery and actual Mac user flows remain open; this is not full P0 acceptance.


## 9 October — offline recovery restore across native clients

Seven native iOS cases pass on one disposable account: both sign-ins/relaunches, phone task creation and manual encrypted backup, tablet edit, offline phone recovery restore, phone reconnection and tablet receipt/relaunch. The native restore preview shows one update and Use backup values. Before restore creates its own recovery copy. After an offline process restart, the restored title and one queued task PATCH remain durable, while the server still has the tablet edit; the queued baseline retains that edit. Reconnection drains the task queue and both devices agree with the server on one original task ID/generation, restored title, completion, notes and priority. No duplicate task is created.

One Mac-owned transport test independently reads the restored task without accessing Mac Keychain or launching the app. All eight cases pass with zero failures/skips; the seven native results report no runtime warnings. Three actual screenshots were inspected and retained in the iOS repository. No production logic change was necessary. Fixture sessions were revoked before account deletion; account/session/profile/task/filter counts verified zero. Both device sessions, scoped caches/recovery vaults and private credentials were cleared. See restore-continuity-evidence.json.

Repeat using Scripts/test_restore_continuity.py with the existing private disposable-account contract and required --xctestrun, --phone, --tablet and --output arguments. Before cleanup, the Mac test reads TASKFOLD_RESTORE_CONTINUITY_FIXTURE. This establishes one same-account existing-task recovery path with controlled offline transport. Broader data, missing-task and external file-provider restore, concurrent edits during restore, actual Mac flows and physical devices remain open.


## 9 October — working-week settings across native clients

Six accepted native iOS cases pass: both sign-ins, phone working-week save/relaunch, tablet receipt and offline edit/relaunch, tablet reconnection, and phone receipt/relaunch. Sunday is enabled on the phone; the tablet adds Saturday offline. The offline cache retains all seven days and exactly one planner PATCH while the server still has six days. Reconnection drains that queue and both caches agree with the server on the same account-owned planner record, all weekdays and unchanged 09:00–17:00 hours. One Mac-owned transport test independently decodes the same WorkingHours without GUI or Keychain access.

The initial phone test failed before editing because it looked for planner settings in Week mode; the corrected helper selects Day through native controls. The offline native phase passed, but the driver initially expected a task-style conflict baseline. Planner settings use a PATCH without that baseline. The corrected driver verifies the actual method/fields and provides a guarded resume that checks server/cache/queue before continuing. These results do not establish concurrent-settings conflict handling.

All seven accepted cases pass with zero failures/skips, and the native results report no runtime warnings. Three actual screenshots were inspected and retained in iOS. Final iOS Debug and Mac test builds pass; production logic is unchanged. Fixture sessions were revoked before account deletion; user/session/profile/task/preference counts verified zero. Both device sessions, scoped caches/recovery vaults and private credentials were cleared. See settings-continuity-evidence.json.

Repeat with Scripts/test_settings_continuity.py and the existing private disposable-account contract (--xctestrun, --phone, --tablet, --output). Mac verification uses TASKFOLD_SETTINGS_CONTINUITY_FIXTURE. Other settings, organization, concurrent/account/mixed-version behavior, actual Mac GUI and physical-device acceptance remain open.


## 9 October — preserve newer planner settings when editing

Both apps previously rebuilt working_hours from four known fields when saving. This dropped any unknown nested fields and allowed an unsupported document to be overwritten by editable defaults. Both independently owned models now merge validated known fields into the existing supported document, preserving extensions. Unsupported or malformed documents cannot be saved; the settings form explains that Taskfold must be updated and disables Save. Missing preferences still initialize normally. The Store also requires the account/workspace binding captured when the form opened.

Each repository passes all 12 focused planner tests, including preservation through edit, durable cache and portable backup. Two actual isolated iPhone UI cases pass with zero failures/skips/reported warnings: unsupported settings stay read-only after relaunch, and supported extension settings retain a changed weekday. Independent saved-state inspection confirms the extra nested data, hours, weekdays and empty queue. The actual unsupported-state screenshot was inspected. iOS/Mac Debug arm64 app/widget builds pass; no Mac GUI ran. See planner-version-safety-evidence.json.

This fixes a specific mixed-version overwrite risk. It does not establish a live mixed-version pair or account-switch UI flow; the planner capacity display still uses its existing default fallback for unreadable hours outside this settings form. Other settings and full native acceptance remain open.


## 9 October — unavailable capacity for unreadable working hours

This closes the default-capacity fallback limitation recorded in the previous planner-settings checkpoint. Both stores distinguish an absent preference (normal defaults) from an unreadable document (no working hours). Native planners retain task estimates and the timeline, but show Capacity unavailable with update guidance instead of a fabricated working-day budget. Both widget publishers emit an explicit settings state, empty capacity days and no hours. Capacity widgets explain that Taskfold must be updated; other task data remains available.

Each repository passes 21 focused planner/capacity-widget tests, including today/tomorrow decoding without room calculations and retained task/workload data. One actual iPhone UI check passes the unavailable summary, 115 minutes of estimates and read-only settings across relaunch, with no failures/skips/reported warnings. Its screenshot was inspected. The actual App Group payload independently confirms the settings marker, empty days/hours and all four fixture tasks. Both Debug arm64 app/widget builds pass. See capacity-version-safety-evidence.json. Installed capacity-host rendering, Mac GUI, physical devices and a live mixed-version pair remain separate acceptance work.


## 9 October — recover a queued edit after shared-project access is revoked

A live disposable owner/member scenario exposed a production failure: a denied queued task edit aborted synchronization before refreshing project access, leaving the revoked project visible. Both apps now perform authenticated reads after a failed task PATCH/DELETE. Only confirmed absence of the project and its tasks permits recovery. The complete local snapshot is saved in the encrypted recovery vault before inaccessible project mutations are removed and remote state is merged. Unrelated pending edits remain queued; account changes, concurrent local edits, failed reads or failed backup writes prevent this recovery.

The original iPhone regression failed, then passed with the fix: reconnect removed the shared project/task; relaunch kept them absent; Backups & restore opened the Access removed copy in the native restore preview. Independent cache and App Group widget-payload inspection found no revoked content. The owner's server task remained Shared original with no membership. Mac authenticated transport also returned no project/task. Both repositories pass three focused queue/recovery tests and their Debug arm64 app builds. Both disposable accounts, sessions and fixture rows were deleted and verified absent; native fixture cache/vault and temporary credentials were removed. See revoked-project-evidence.json.

Scope: the installed regression covers an existing shared task title edit. Standalone queued task creation, project/section edits, locally moved-out tasks and other membership transitions remain acceptance work. Mac transport/build evidence does not establish the Mac GUI. The restore preview was opened, not applied. One empty-list screenshot was captured during navigation; it is functional evidence, not final visual acceptance.


## 9 October — generalize revoked-project queue recovery

The recovery decision now covers pending shared-task creation, section creation/editing, project edits and collaborator changes in addition to existing task edits. It derives project identity from the full queued history of the blocked record, so a title edit followed by an offline move to Inbox still retains the original project context. New local projects with unacknowledged POSTs are excluded. Authenticated reads must include all project-dependent tables; any still-visible affected record prevents recovery. The existing encrypted-backup, account-generation, concurrent-edit and persistence guards remain in place.

Six focused tests pass independently in each repository: existing-task recovery with unrelated work retained; missing/contradictory evidence; task/section/project/collaborator mutation cases; title edit followed by move-out; a genuinely new offline project; and remotely moved visible records/partial reads. These are model tests; the preceding native/server checkpoint remains evidence for the existing-task scenario only. Broader native membership flows remain open.

Both Debug arm64 app builds pass for this follow-up (iOS build-for-testing and macOS build). No Mac GUI was launched.
