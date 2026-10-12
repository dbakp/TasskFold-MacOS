# P0 progress snapshot — 12 October 2026

**Feature implementation is largely complete. Release acceptance is incomplete.**
This short view summarizes `P0_RELEASE_STATUS.md`; its dated entries and JSON evidence remain authoritative for exact scope. A passing build is not native workflow acceptance. No percentage is assigned because remaining gates have very different risk and effort.

| Area | Proven progress | Remaining gate |
| --- | --- | --- |
| Productive widgets | Twelve kinds implemented; many installed phone/tablet routes, completion/account/privacy checks; iPhone Today empty/sign-out/relaunch; Mac medium Today local exit/return/normal signed-out relaunch, install, app edit/Complete/Undo refresh and widget Capture/Inbox/save/relaunch | Remaining Mac task actions and other hosts/sizes/conditions; system privacy redaction |
| Todoist import | Real read-only multi-page import and replay; native imported-workspace handoff; iPhone lost first-import and replay-response recovery; Mac lost replay-response Retry and relaunch | Named native import/retry gate closed; evidence retains exact scope |
| Recovery | Native portable export/restore, encrypted Mac safety copy, cloud and cross-account restore/replay/relaunch; native Mac shared-access loss, encrypted recovery/apply and durable notice | External provider-backed file transfer and remaining failure boundaries |
| Device continuity | Native Mac ↔ phone tasks/notes/planning/organization round trips, offline edits and relaunches; paired name/photo and native Mac attachment handoffs | Remaining concurrency/legacy-client variants |
| Core usability | Capture/editor/subtasks/completion/Undo fixes; Mac calendar keyboard navigation; scoped phone/tablet normal and largest-text calendar routes; four clipping reports classified with scoped evidence | Spoken VoiceOver; remaining critical landscape/sidebar flows |
| Notifications | Mac Focus authorization, scheduling, pause/resume, background banner and terminated-app Notification Center delivery evidence; real iPhone Move to tomorrow/Complete and relaunch, including terminated-process Complete; native local/authenticated sign-out and actual Complete callback across A → B → A | Named Mac local/authenticated actions and delayed Complete isolation pass; real APNs delivery and rollout remain open |
| Distribution | Independent repositories and development builds | Mac app provisioning blocked by current Personal Team’s Push Notifications limit; enrolled team, Developer ID/notarization and distribution signing |

## How to interpret recent activity

Recent work includes actual user-visible calendar/accessibility fixes, native workflow verification, test-driver corrections, signing/Simulator problems and evidence maintenance. These are different kinds of progress and should not be combined into a claim that all P0 is done. Calendar coverage is bounded; additional combinations are not automatically new release requirements.

## Next execution order

1. Compact landscape task-editor insertion/visible input/caret, keyboard-visible Save and exact persisted values after relaunch now pass normal and largest text (`landscape-editor-evidence.json`). This named journey is closed; do not expand into another calendar/layout matrix.
2. Finish remaining installed Mac widget routes/configuration/privacy in the isolated signed host. Named local/authenticated notification Open/actions, sign-out/reentry and delayed Complete isolation now pass; physical APNs remains separate.
3. Resolve the named accessibility, external file-provider and conflict/failure gaps above. Keep acceptance scoped to critical user journeys; additional combinations are not automatically P0 requirements.
4. Close APNs and distribution with actual signing/provider/delivery evidence. The current Personal Team cannot provision the production Mac Push capability.

The named Todoist import/retry goal is closed. Completed work is committed and pushed separately in each repo; the task-editor fix now has scoped native acceptance. Test-driver/signing work is tracked separately from product fixes and release acceptance.

Ordinary iPhone/iPad acceptance uses Xcode Simulators as requested. Actual remote delivery and distribution remain separate gates. Todoist source data must remain unchanged. Each repo owns its code and release inputs; completed work is committed and pushed separately.

## Latest closed gate

12 October: native Mac → iPhone → Mac profile name/photo handoff now passes, including both normal process relaunches. Exact server baseline and original profile are restored; primary phone/iPad data are unchanged. See `profile-pair-evidence.json`. No new production fix was needed.

12 October: named native Mac replay response-loss/Retry now also passes, including actual quit/relaunch and exact preservation. Fresh stable development signing removes the preceding import-launch approval friction. The initial NSTableView warning remains open.

12 October: authenticated native Mac attachment handoff now passes through iPhone preview/relaunch, a phone notes edit and Mac foreground sync/relaunch/preview. The small PNG remains byte-for-byte and metadata-identical. Native cleanup restores all 14 non-activity server tables; two synthetic creation/deletion ledger entries remain. See `attachment-handoff-evidence.json`. External file-provider transfer remains open.

12 October: fixed the visibly clipped largest-text landscape capture draft. Compact focused capture now keeps one complete editing line with its end caret visible. Two native normal/largest Save/More/relaunch cases pass without runtime warnings. Exact title/estimate persist; authenticated cache, all 15 server tables and protected devices are unchanged. See `keyboard-capture-evidence.json`.

## Current external prerequisite

12 October: automatic provisioning now obtains a Mac widget-extension profile, but Xcode rejects the containing app because the configured Personal Team does not support Push Notifications. An enrolled team is needed for the current app capabilities. No production entitlement was removed and no app installed. See `release-environment-check.json`. The named Todoist retry gate and Mac attachment handoff remain accepted; old launch approvals are not current blockers.

12 October: native Mac shared-access loss now preserves offline edits, unblocks unrelated personal sync and restores owned copies through the native encrypted preview. Fixed the disappearing recovery notice in both apps and its sidebar/large-text layout. Broader recovery variants remain open; see `access-recovery-evidence.json`.

12 October: temporary native Mac VoiceOver enable/restore is verified, but the output surface timed out in computer use. Spoken output/traversal acceptance remains open; native accessibility labels alone are insufficient. Original off setting is restored. See `critical-accessibility-evidence.json`.

12 October: corrected misleading sync captions and success icons in both apps. Initial/failed/pending states are distinct from confirmed success; see `sync-status-evidence.json`.

12 October: resolved the retained midnight publishing warning in both apps by scheduling system calendar notifications before SwiftUI receives them. The new iPhone background-event case reproduces it before the fix; afterward it and the affected largest capture pass without structured warnings. Native Mac day/zone refresh also passes. Debug/Release builds pass; broader release gates remain open. See `background-calendar-evidence.json`.

12 October: real Mac Focus delivery after normal Quit reaches Notification Center history while the app stays stopped; fixture-preserving relaunch retains the finished session and open task. Existing DND suppresses banner/sound. Actual Open/actions remain unaccepted; see `mac-focus-terminated-evidence.json`.

12 October: fixed native Mac Focus chooser keyboard selection: Up/Down and Return now choose the correct filtered task/context. Empty-result Return and Escape are safe; mouse selection and paused-session normal relaunch pass. Debug/Release builds and test compilation pass; the automated Mac runner fails initialization before executing tests, so no XCTest runtime pass is claimed. Both cloud caches and all non-Focus fixture tables are unchanged. See `focus-keyboard-evidence.json`. iOS code is unchanged.

12 October: the new isolated Mac app **and embedded widget extension** now provision/build/sign successfully with a separate App Group and URL scheme. This removes production Push provisioning as a prerequisite for isolated desktop-host testing. The native launch was live but the Mac was locked at setup; the current host is now accessible, while installed-host acceptance remains open. Production APNs/distribution gates remain open. See `mac-widget-host-setup-evidence.json`.

12 October: fixed compact landscape task-editor input visibility and the keyboard-dismiss target. Two normal/largest native insertion/Save/relaunch cases pass without runtime warnings; screenshots were inspected, planned fields are retained and protected caches/devices are unchanged. Text-selection gestures remain unaccepted. See `landscape-editor-evidence.json`.

12 October: classified the four retained clipping reports against original captures, source layout and already passing native actions/persistence. No diagnostic reports suppressed and no broad audit/VoiceOver pass claimed. See `accessibility-clipping-classification.json`.


### 12 October — medium Focus recommendation widget

Fixed a real installed-host defect: long medium Focus titles were truncated. The final layout keeps the complete tested title, header, status, project and action inside the card. Native iPhone installation, overdue ranking, both exact terminated-app task routes, completion refresh, relaunch and cleanup pass (one test, zero failures/skips/reported runtime warnings). Earlier functional passes with truncation/overflow were rejected. Both independently owned widget implementations build in Debug/Release; no installed Mac pass is claimed. Authenticated caches and protected phone/tablet files are unchanged, and the test marker is reset. See `medium-focus-host-evidence.json`. Remaining P0 gates are unchanged.


### 12 October — Today and original Focus privacy redaction

Fixed missing `privacySensitive` annotations in both owned widget implementations. A before-render reproduces visible task title/time/project under explicit SwiftUI privacy redaction; the corrected small/medium Today and Focus renders conceal those details while retaining public headings and actions. Normal before/after images are byte-identical, and both repos produce identical normal/private outputs. Unsigned iOS Simulator/macOS widget targets build in Debug/Release. See `widget-privacy-redaction-evidence.json` and the independently owned `Scripts/render_privacy_widget_previews.py --output <directory>`. This is source-render acceptance only: actual system-selected locked-device redaction, native Mac hosts and other P0 gates remain open.


### 12 October — notification Move to tomorrow

Fixed both independently owned action handlers: undated work now receives tomorrow’s plan, and future work moves to the receiving device’s actual tomorrow rather than one day after its old plan. Existing date-placement rules retain local clock/DST behavior and unrelated fields. Fifteen planner tests pass per repo; both Debug/Release app builds pass. An actual iPhone system alert reproduces the old undated no-op, then the corrected native action/relaunch/editor/cleanup passes with no reported runtime warnings. Only `due_date` changes in the retained task; reminder specs and identity remain exact. Protected devices and authenticated caches are unchanged. See `notification-tomorrow-evidence.json`. Two earlier fixture/helper failures are retained and excluded as product reproduction. Mac action runtime, account changes, other notification actions and broader P0 gates remain open.


### 12 October — real notification Complete action

An actual background-delivered local iPhone alert now has scoped Complete acceptance: the original undated task completes, survives normal relaunch and opens from Completed; its future reminder is absent from the real pending registry before reminders are disabled. One native test passes with no skips/failures/reported runtime warnings. Only `completed`, `completed_at` and `completion_version` change; reminder rule, original ID and plan are exact, with no successor or pending edits. Authenticated caches and protected phone/tablet files are unchanged. See `notification-complete-evidence.json`. This is test/evidence work; production code is unchanged. Cold-process/account-switch variants, cancellation timing before foreground inspection, Mac actions and other P0 gates remain open.


### 12 October — native notification workspace exit

Fixed an iOS usability defect: Account settings remained presented over the sign-in screen after leaving the workspace. The settings sheet now dismisses when sign-in ends. One corrected native iPhone case passes without failures/skips/reported runtime warnings: real local alert delivery, actual workspace exit, empty pending and delivered system registries, signed-out normal relaunch and exact full fixture snapshot preservation on reopening. Debug test build and Release app build pass. Authenticated caches and all 69 protected device files are unchanged. The first failed native run retains the stale-sheet evidence and does not establish alert retirement. See `notification-signout-evidence.json`. This closes local workspace exit only; account A → B/callback races, cold Complete, Mac actions/APNs and the other named P0 gates remain open. Mac production code is unchanged. The isolated Mac host is now responsive after manual unlock; opening the desktop widget gallery remains a computer-use boundary, not an installed-host pass.


### 12 October — native Mac failed pin save and retry

The retained inspector pin-save fix now has native Mac acceptance. A simulated persistent write failure reports an error, keeps the requested pin on in the open inspector and leaves the complete saved snapshot unchanged. After allowing saves again, Return in the unchanged title saves that original pin request without toggling it again. Only the intended `view_orders` pin entry is added; all three task records and previous pins remain exact. Normal Quit/relaunch shows the same task pinned. Native unpin cleanup returns the complete seeded snapshot, and all seven pre-session isolated caches are restored/equal after final Quit; protected phone/iPad files are unchanged. See `mac-pin-retry-evidence.json`. The misleading Debug “Fail next save” control now accurately says “Fail saves” and offers “Allow saves” in both independently owned apps. Both Debug builds pass; this is manual native Mac acceptance, not a Mac XCTest runtime pass or a new release-code fix. Installed Mac widgets, spoken VoiceOver, provider, notification/account/APNs and distribution gates remain open.


### 12 October — terminated-process iPhone notification Complete

The actual local Complete action now passes with the app terminated before delivery. Delivery leaves the app stopped; tapping the system action starts a different process without test launch arguments. The original undated task completes, its future reminder is absent before reminders are disabled, and normal relaunch/Completed/editor retain the exact task and rule. One native test passes with zero failures/skips/structured runtime warnings; both selected captures were inspected. Only task completion fields change, plus the expected completion activity/receipt; five protected app containers retain their exact file sets/hashes. See `notification-cold-complete-evidence.json`. Production code is unchanged. The independently isolated fixture App Group and signing allowlist are strengthened in the iOS-owned scripts. Mac host/Open/actions, account transitions, spoken VoiceOver, external providers, APNs/distribution and other named gates remain open. The unlocked retained Mac Focus app currently shows Today; the earlier notification click is not accepted as Open evidence.


### 12 October — Mac desktop widget installation exposes App Group rejection

The user-opened native gallery now exposes the isolated Mac catalogue separately from iPhone widgets; medium Today installs on the desktop. The host initially showed a fallback while its shared file contained seven tasks. Actual macOS logs identify rejected App Group access: the development profile omits group authorization and the non-team-prefixed identifier is rejected. The real staged decoder can read that payload outside the sandbox. The Mac-owned preparation script now requires `--team` for widget fixtures and uses the supported macOS team-prefixed group in copied sources and both entitlements. The rebuilt app/extension pass strict signature checks, the extension runs, and the installed widget footer changes from fallback to TASKFOLD. All isolated cache JSON files and seven projected tasks remain unchanged. See `mac-widget-host-access-evidence.json`.

This is partial installed-host/data-access evidence, not full Mac widget acceptance. Computer-use Capture clicks have no verified route; a manual click request remains pending. A subsequent app capture attempt hit ScreenCaptureKit -3812, so edit/refresh is unaccepted. Finder screenshots omit widget layers; no rendered desktop visual pass is claimed. The corrected test host and medium widget remain live for continuation. Production capabilities, APNs/distribution and other P0 gates remain open.


### 12 October — honest Today fallback and native Mac live refresh

Fixed the independently owned Today views in both apps: missing shared data now shows an unavailable count and “Open Taskfold / Refresh your tasks”, instead of claiming zero tasks and “All clear”. iOS accessory wording follows the same state. Debug/Release widget target builds pass for each platform. Actual owned SwiftUI light/dark previews fit all three home sizes; all eight loaded-empty/populated before/after images across both platforms are byte-identical. This is preview/build evidence, not installed-host fallback or accessory visual acceptance. See `today-widget-unavailable-evidence.json`. Inactive generated products are pruned (598,642,167 logical bytes); source, logs and captures remain.

Separately, the retained development-signed Mac host now passes native app capture → installed medium Today refresh, inspector Complete → zero, Undo → original title, and Quit/new-process relaunch → retained task/widget. Original eight tasks remain exact; only the synthetic task, expected activity and activity epoch change, with zero pending edits. After normal menu Quit, both original isolated cache JSON files are restored exactly; relaunch shows Today zero in app and desktop widget and retains the exact baseline. See `mac-widget-live-refresh-evidence.json`. This host predates the fallback fix. Desktop screenshot layers remain unavailable, so AX and saved data establish only the stated behavior.

The user’s first Capture click is followed by a New Task sheet labeled Today, rather than expected Inbox; prior sheet state makes attribution uncertain. Capture routing is not accepted. The sheet is closed and a clean-state manual click is requested. Other Mac widget actions/configurations, system privacy, account boundaries and remaining notification/provider/accessibility/distribution gates remain open.


### 12 October — provider preflight and fixture count correction

The native signed isolated Mac app exports its synthetic workspace through the save panel to a local temporary JSON file, then reads it through Restore from file and shows eight tasks plus one project. Review is canceled without applying; both original cache JSON files remain exact. iCloud Drive is available in both native pickers, but approval to upload this reviewed synthetic file is pending; no provider transfer is accepted yet. See `provider-transfer-preflight-evidence.json`. Seed rows use non-UUID IDs and intentionally remap on restore (Add 9); this is a file-read preflight, not same-workspace replay proof.

Rechecking the previous widget preservation receipt corrects its wording: there are eight saved baseline tasks, seven open. All eight original records match the post-Undo snapshot exactly, and only the one native-created synthetic task is added. The count correction changes documentation, not the verified preservation outcome. The clean-state automated desktop Capture click still has no observed app route; browser custom-URL dispatch is policy-blocked and is not used as a workaround. Manual widget click, native Mac notification actions and remaining P0 gates stay open.


### 12 October — installed iPhone Today empty versus signed-out state

The owned unavailable-state fix now passes one actual installed medium Today workflow on an independently namespaced iPhone Simulator app: valid empty data shows 0 / All clear, actual workspace exit changes the widget to a dash / Open Taskfold / Refresh your tasks, and normal signed-out relaunch retains that state. The unavailable count has its expected accessibility label. All four gallery/installed captures are inspected; the temporary widget is removed and the disposable Simulator returns to shutdown. Six protected app containers retain all 100 file sets/hashes exactly. See `today-widget-host-evidence.json`.

The native case passes in 195.235 seconds with no failures/skips/reported runtime warnings. Two SpringBoard animation-notification waits, one recovered hit-point attempt and eighteen ignored remote-hierarchy diagnostics remain disclosed. Debug test build, real team signing and catalogue checks pass. An initial universal Simulator build passes but is rejected by the single-slice signing inspector; the arm64 device build resolves that test-input boundary before native execution. Existing build warnings are retained in the receipt. This run adds iOS-owned fixture/test inputs; no production code changes are needed. Mac receipt mirrors the scoped iOS result. Other Today families/conditions, native Mac routes/privacy, authenticated account transitions, provider/VoiceOver/notification/APNs/distribution gates remain open.


### 12 October — current Mac widget host ready for native unavailable-state test

Rebuilt and development-signed a fresh independently staged Mac app and extension with the committed Today unavailable-state fix. Strict signatures, actual team/group prefix and exact widget source namespace transformation pass. The isolated v2 process is stopped by targeted SIGTERM for build replacement (not native Quit acceptance), v3 app/extension are running, and only the v3 plugin remains registered. Both fixture cache JSON files remain exact. Inactive v2 products are pruned (356,114,427 logical bytes), retaining both staged sources, logs/signatures and the active v3 products. See `mac-widget-current-build-evidence.json`.

Computer use confirms the Mac is locked on the new handle. Native current-build/signed-out widget inspection awaits manual unlock; no visual, route or new native state pass is claimed. Earlier v2 edit/Complete/Undo/relaunch refresh evidence remains historical and scoped. Provider upload approval and other named P0 gates remain open.


### 12 October — authenticated iPhone reminder sign-out and reentry

The retained disposable cloud account now passes actual local notification delivery → native Sign out → empty pending/delivered registries → sign-in → unchanged inspected task/reminder fields and only the remaining future occurrence → native task deletion and final sign-out. A separate native normal-relaunch case uses no workspace/seed/session override and retains the sign-in screen with empty alert registries. Both final tests pass without failures/skips/structured runtime warnings; five selected captures are inspected. See `notification-authenticated-signout-evidence.json`.

The first full run fails only at its cleanup selector (task-details Button queried as StaticText); corrected native cleanup passes before the final full run. Across both synthetic create/delete walks, only `task_activity` changes; all other 13 checked server tables and all 100 files in six protected containers are exact. The isolated queue is empty, both temporary tasks are absent, reminders are off, persisted localMode is false, and the disposable Simulator returns to shutdown. Inactive generated products are pruned (417,338,197 logical bytes), retaining source/results/logs/signatures.

This adds iOS-owned DEBUG inspection/tests and scoped evidence; release behavior and Mac code are unchanged. The inspection controls crowd the toolbar, so these captures are not a production toolbar visual pass. Authenticated A → B/delayed-callback journeys, Mac Open/actions/widgets, external provider/VoiceOver/APNs/distribution and the other named gates remain open. The current Mac widget app is checked again but native computer use still reports the Mac locked; no widget Capture route is accepted.


### 12 October — Mac capture request survives the Inbox view transition

Found and fixed a concrete Mac presentation race: external capture switches to Inbox and increments its request counter together, while the section-keyed Inbox view mounts with the new value and an ordinary change listener misses it. A real SwiftUI listener-pattern probe reproduces the lost presentation, then proves the corrected transition, already-mounted request and no reopening after a consumed request/remount. The app now retains a request bound to its destination and workspace incarnation, consumes it once on initial/subsequent listener execution, and cancels it on navigation/account reset. Both task-list and Calendar listeners use the handoff; signed-out capture is rejected.

Four independently owned Mac core tests and unsigned Debug/Release app builds pass. See `capture-view-handoff-evidence.json` and `Scripts/verify_capture_view_handoff.py --output <new-directory>` in the Mac repo. iOS already retains its external Inbox request and consumes it on appearance/change; its earlier native external-capture acceptance remains scoped and its code is unchanged. Inactive compile products are pruned (1,024,402,922 logical bytes); source, probe receipts and build/test logs remain.

This is framework/model/build proof, not an installed widget or full native capture pass. The existing v3 Mac widget process/window is preserved for inspection and predates this fix; computer use still reports the Mac locked. No blocked browser protocol route is dispatched. Actual widget click → Inbox capture/save/relaunch, Mac notification actions, authenticated A → B/callbacks, external providers/VoiceOver/APNs/distribution and other named P0 gates remain open.


### 12 October — signed Mac capture-fix build prepared

A fresh isolated Mac app and widget extension now build with the committed capture handoff fix. Strict app, extension and deep signature checks pass with the actual development team, sandbox and isolated team-prefixed App Group; the staged capture queue source is byte-identical to the committed source. See `mac-capture-signed-build-evidence.json`. The preserved v3 window is inspected as Today with no sheet; a later manual click opens Inbox in an older cold-launched binary. v4 then exposes repeated new-window/fixture reset. Both old builds are retired; the subsequent v5 fix and native acceptance are recorded below. This historical preparation alone establishes no native route pass.


### 12 October — real reminder callback across authenticated account switch

One native iPhone Simulator test now passes the actual system Complete response held across A → B, released under B, and followed by return to A. B remains empty; A’s original task stays open with identical inspected planning/reminder fields and only the future occurrence pending. Native cleanup/sign-out/normal relaunch retain empty alert registries. The final run passes in 321.165 seconds with no failures/skips/structured runtime warnings; four behavioral captures are inspected. See `notification-account-switch-evidence.json`.

The first run fails at overlapping DEBUG inspection controls; a corrected layout and native cleanup pass precede the accepted rerun. B’s 14 checked server tables are exact, A’s other 13 tables and original activity are exact, and all 100 protected files in six containers match. Only four synthetic task create/delete activity rows are added. B sessions are globally revoked before narrowly guarded account deletion; scoped checks show zero remaining records, and its private credentials/cache are removed. The disposable Simulator is shut down and 420,849,427 logical bytes of inactive products are pruned. This adds iOS-owned DEBUG harness/tests, with no release behavior change; DEBUG controls still overlap headings and are not a production visual pass. Mac actions/account switching, other named conditions and full P0 release acceptance remain open.


### 12 October — installed Mac widget capture stays open and survives relaunch

The user’s report exposes a second concrete issue: widget URLs create new windows in the same process, and per-window DEBUG fixture setup renews the shared workspace and resets navigation to Today, dismissing capture. The main scene now prefers its existing window for external events; fixture setup is guarded once on the shared Workspace. Native medium Today “+” now opens a stable Inbox sheet, accepts input and saves the intended undated task. The Window menu lists only one window. Native menu Quit is verified by process exit; same-fixture relaunch without reseeding retains all nine exact task records and the native Inbox row. See `mac-widget-capture-native-evidence.json`.

Native cleanup deletes only the synthetic task; all eight original tasks and every non-activity table remain exact, with zero pending edits. Expected create/delete activity and epoch changes remain. All 100 protected files match. Two inspected app captures show the Inbox sheet and saved task; desktop widget layers remain outside visual acceptance. Development-signed Debug and production unsigned Release builds pass, as do strict app/extension/deep signatures and team/catalogue checks. Old v3/v4 and inactive Release products are pruned, retaining stages/logs/receipts and the active v5 app. This closes this named installed Mac capture/save/relaunch journey; other widget conditions, Mac notification/account actions, external providers/spoken VoiceOver/APNs/distribution remain open.


### 12 October — installed Mac Today workspace exit and normal relaunch

Native Leave Local Workspace reaches the auth screen and clears the shared projection. After normal Quit/no-argument relaunch, installed medium Today shows Task count unavailable / Open Taskfold / Refresh your tasks. A same-build retained-fixture return (no reseeding) restores the original Inbox and valid 0 / All clear widget. Repeating native exit changes that same installed widget back to unavailable, and a final normal signed-out relaunch preserves it. See `mac-widget-signout-evidence.json`. No product or test-harness source change is needed.

The first exit initially leaves stale All clear despite a correct cleared projection; chronod records extension creation/Unknown extension process failures. This immediate refresh attempt is not accepted. The later repeat passes without rebuilding or changing registration. Taskfold-only desktop accessibility establishes the stated host behavior; desktop pixel/privacy/all-family acceptance remains open. The complete saved fixture snapshot and all eight tasks are exact, the six-file isolated set is unchanged (only JSON encoding differs in one file), and all 100 protected files in six containers match. The isolated app is left normally signed out; saved work and current products remain available.


### 12 October — fresh Mac Focus notification Open preflight

One fresh actual Focus alert is scheduled in the retained isolated Mac process, with native pending count one. The Focus panel is closed before delivery. Owned system logs confirm delivery at 09:29:24, Notification Center storage and reported banner/sound presentation without DND suppression. Notification pixels are uninspected. Only the Focus snapshot table changes; tasks, queue and completion metadata remain exact. Snapshot/widget publication files change; four other files retain exact hashes. See `mac-focus-open-preflight-evidence.json`.

Notification Center observation times out twice with successful inventory recovery between attempts. The app stays running without replacement. A manual click of the newest alert is pending; actual Open is unaccepted. This reuses the historical Focus binary, not a fresh current-source build. Other P0 gates remain open.


### 12 October — actual Mac Focus notification Open accepted

The user clicks the newest 09:29 alert. Owned macOS logs record the exact request's foreground response at 09:31:55.393 and bring the existing PID 47062 forward. Without restart or manual Focus activation, the native Focus sheet opens with the original task, “Time well spent” and 00:00; the app capture is inspected and pending Focus alerts are zero. Tasks remain exact. See `mac-focus-open-native-evidence.json`.

This closes the warm-process local Focus Open journey in the retained historical isolated binary. Cold-process Open without fixture launch overrides, task-reminder actions/account transitions, current-source release validation and the other named P0 gates remain open.


### 12 October — normal local Mac cold Focus delivery

The retained isolated Focus app is normally quit, then launched with no arguments. Its normal local workspace is empty. Native Inbox capture creates one synthetic task; the regular Focus chooser and one-minute duration controls start a real session with finish alerts. Native menu Quit stops PID 12154 before the end. Actual delivery at 09:36:51.119 and Notification Center storage occur with no app process running. The scheduled local snapshot remains exact after delivery and the existing ui-testing cache retains its hash. See `mac-focus-cold-open-evidence.json`.

A manual click of this newest alert is pending; no app has been relaunched after delivery, and cold Open is unaccepted. This normal local journey avoids fixture launch arguments on both scheduling and the future OS launch; the binary is still the historical isolated Focus build. Cleanup of the one test task/session follows action inspection. Other P0 gates remain open.


### 12 October — actual cold Mac Focus Open and native cleanup accepted

The newest alert's actual foreground response is recorded at 09:38:21.564. macOS starts a different process, PID 12570, with no arguments. Without manual Focus activation, its native sheet shows the correct task, “Time well spent” and 00:00. The full scheduled local snapshot is exact after Open, and the app capture is inspected. See `mac-focus-cold-open-evidence.json`.

Native cleanup ends the session, restores this local account's finish-alert preference off and reversibly deletes only the one synthetic task. The local task list and queue are empty. Its stopped session, two expected create/delete activity rows and epoch remain. Normal daily backup creation adds one encrypted copy and updates the index; those are retained. The earlier ui-testing cache hash and all 100 protected files in six Simulator containers remain exact. This closes normal local cold Focus Open in the retained historical binary; Mac task-reminder/account actions, current-source/distribution validation and the other P0 gates remain open.


### 12 October — native Mac task-reminder delivery and fresh action build

Normal native local capture saves one undated task with an independent two-minute fixed reminder. The real reminder editor shows one upcoming alert. Native Quit stops PID12570 before actual09:44:45.111 delivery and Notification Center storage; the process remains absent and the full scheduled snapshot is exact. Actual system Complete is pending, not accepted. See `mac-task-reminder-preflight-evidence.json`. The retained historical build's delegate/Complete path matches current source; its older Move to tomorrow branch is explicitly outside acceptance.

The Mac-owned preparation script now supports `p0notificationtests`: a separate bundle/keychain/widget namespace, no production URL/file registrations or embedded extension, and normal launches without fixture arguments. A fresh current-source staged Debug app builds and passes strict deep development signatures. Five behavior source files match after only namespace transformation. It remains unlaunched, and the old pending alert/app is untouched. See `mac-notification-current-build-evidence.json`. This is preparation/build proof, not actual action, APNs or distribution acceptance.


### 12 October — actual terminated Mac reminder Complete accepted

The exact reminder request receives system `taskfold.complete` at09:48:36.444 with foregroundfalse. macOS launches newPID14048 without arguments, saves completionversion1 and changes only completed/completed_at/completion_version. Native Completed verifies the correct undated task. Native Quit and a separate normal relaunchPID14180 retain the entire completed snapshot; the reminder editor retains its original fixed instant and shows0upcoming. Its captured Completed/editor result is inspected. See `mac-notification-complete-evidence.json`.

Native cleanup restores delivery off and reversibly deletes only this synthetic task. All non-activity local tables match the fresh baseline, prior activity is retained with three expected create/complete/delete rows, the existing ui-testing cache hash is exact, and all100protected files in six Simulator containers match. This accepts terminated-process Complete for this local one-shot reminder in the historical build's current Complete path. Scheduler status is not independent pending/delivered-registry inspection; future-occurrence cancellation is unproven. Mac Snooze/Move to tomorrow/Open/account transitions, fresh-build runtime and other named P0 gates remain open.


### 12 October — current-source Mac notification harness storage fixed

The new notification bundle's normal native local entry creates the standard four-task/one-project starter workspace, but exposes a widget storage permission error. The widget-free test bundle was omitted from the existing DEBUG sandbox-local disk allowlist. Adding just that bundle fixes native first launch: Today retains all four tasks, displays Saved on this device and has no permission/Retry warning. The complete parsed snapshot and both backup file hashes remain exact; local JSON encoding changes only. The private projection now publishes four tasks under local inside the sandbox. See `mac-notification-disk-fix-evidence.json`.

Corrected v2 Debug build and strict deep team signatures pass. v1 native Quit is verified before replacement; its registration and 108,895,377 logical bytes of inactive Build products are removed, retaining stages/logs and v2. Normal v2 native settings sends an actual notification permission request at09:56:51.990; user approval is pending. No current-source reminder action is accepted yet. This fix is DEBUG-only and does not alter production permissions or behavior.


### 12 October — task-reminder Settings explains pending system approval

The actual current Mac permission request remains pending while General Settings shows Task reminders off with no progress. Both apps now show “Requesting permission…” while the existing observable request is active and disable repeated toggles during task/Focus authorization. This matches the task reminder editor and changes no delivery, account or persistence contract. Independently staged Mac development-signed Debug and arm64 iOS Simulator Debug builds pass; changed view sources are exact in their stages. See `settings-permission-progress-evidence.json`.

The active Mac v2 process and its pending prompt are preserved; v3 is built but unlaunched. No Simulator is booted/installed/launched, and transient pending-state pixels are not accepted. The Mac starter snapshot and all 100 protected files in six Simulator containers remain exact. Inactive iOS compile products are pruned, retaining source/log evidence; Mac products remain for the next native test. Notification approval and other named P0 gates remain open.


### 12 October — current-source Mac reminder permission and cold delivery

The approved system request now resolves: native Task reminders is on. A normal native Inbox capture creates one disposable undated task with an independent fixed reminder; the editor confirms one upcoming alert. Native Quit stops PID15247 before the actual 10:11:41 delivery, which leaves the complete saved snapshot unchanged and the process stopped. All100protected files remain exact. See `mac-notification-tomorrow-preflight-evidence.json`. Actual Move to tomorrow is pending a manual Notification Center action; no action/relaunch pass is claimed. The four starter tasks/project are retained. Earlier approval-pending notes are historical; the newer Settings-progress build remains unlaunched.


### 12 October — native Mac Move to tomorrow and system registry inspection

The actual 10:18:23 system `taskfold.tomorrow` action starts a new no-argument process after terminated delivery. The originally undated task gains only `due_date = 2026-10-13`; identity, completion and every reminder rule remain exact. Native Inbox/editor show 13 October with no time, and normal Quit/relaunch retains the complete applied snapshot. This accepts the named current-handler local Move to tomorrow journey; see `mac-notification-tomorrow-evidence.json`.

Native cleanup turns delivery off and reversibly deletes only the synthetic task. All four starter tasks/project and non-activity tables are exact, prior activity is retained with three expected create/update/delete entries, and all100protected files match. A Mac-owned read-only inspector, restricted to DEBUG and the exact isolated notification bundle, now reads actual macOS pending/delivered requests and action identifiers. Its signed Debug build and strict signatures pass; normal v4 native inspection after cleanup reports both registries empty. This is post-cleanup registry evidence, not cancellation timing before disabling delivery. iOS already owns independent registry inspection and receives the shared acceptance receipt. Inactive v2/v3 Build products are pruned (217,843,318 logical bytes), retaining staged sources/logs and active v4. Snooze/task Open/account transitions, other widget/provider/VoiceOver/APNs/distribution gates and full P0 acceptance remain open.

Next native action prepared: the isolated v4 app has an actual five-minute Snooze category and one fixed alert, verified directly in the macOS registry. Native Quit precedes actual 10:33:14 delivery. Manual Snooze action remains pending; see `mac-notification-snooze-preflight-evidence.json`.


### 12 October — native Mac Snooze, redelivery and cold task Open

Actual `Remind me in 5 minutes` cold-starts the isolated app. Direct macOS inspection shows one snoozed request, preserving task/spec/signature/original instant and scheduling five minutes after the handler runs. Normal Quit/relaunch retains that exact request and the full task snapshot. After another native Quit, the snoozed alert actually redelivers at10:45:28. Its body click cold-launches v5 without arguments and selects the exact undated task with its inspector open. See `mac-notification-snooze-evidence.json`. These named local Snooze/redelivery/Open journeys pass.

The walk exposes transient stale status: Settings initially says zero upcoming despite the real snooze; an ordinary later refresh corrects it. Both independently owned action handlers now publish the successful Snooze report count immediately. Mac signed Debug/strict signature and iOS arm64 Simulator Debug builds pass. The new status branch is source/build verified; v5 Open does not constitute a repeated Snooze callback.

Native cleanup restores delivery off and the original one-hour Snooze preference, deletes only the synthetic task, and verifies empty actual pending/delivered registries. All four starter tasks/project, prior activity and100protected files remain exact; only two expected create/delete activity rows and the explicit restored preference row remain. Inactive v4 and iOS compile products are pruned (273,072,459 logical bytes); sources/logs and active v5 remain. Mac account-transition acceptance, other named P0 gates and full release acceptance remain open.


### 12 October — Mac local notification retirement and Settings recovery

Native local exit with one delivered and one future alert clears both actual macOS registries. Normal signed-out relaunch stays empty; local return restores only the exact future request. Cleanup disables delivery before its fire time and reversibly removes only the synthetic task. All non-activity tables, prior activity and 100 protected files remain exact. See `mac-notification-local-exit-evidence.json`.

Mac Settings now reports “No workspace open”, disables the signed-out reminder toggle and rebuilds date/reminder preferences after reentry. Native v6 verifies corrected signed-out copy and enabled controls, including opening Snooze without changing its value. The full clean snapshot remains exact. Both independent Debug builds pass; iOS receives its own toggle guard (compile verification only). Inactive v5/iOS compile products are pruned; active v6 and logs remain. Authenticated Mac account-switch/delayed-response and other named release gates remain open.


### 12 October — authenticated Mac notification sign-out and return

Native cloud-account sign-out now retires one delivered and four pending system alerts. A normal signed-out relaunch preserves empty registries; signing into the same account restores the exact four future requests without resurrecting the delivered occurrence. The complete saved account snapshot remains exact across sign-out and return. See `mac-notification-authenticated-exit-evidence.json`.

Native cleanup restores delivery off and deletes only the disposable task with Undo available. All 13 non-activity server tables are exactly restored, all 24 prior activity rows remain, and only the two expected create/delete records are added. All 100 protected files remain exact. This closes authenticated Mac sign-out/reentry; Mac A → B delayed-callback isolation and the other named P0 gates remain open. No source changes or new builds were required.


### 12 October — Mac delayed notification callback preflight

Mac now owns opt-in DEBUG support to hold one actual system response before its unchanged production handler, then release it after a native account switch. It requires the exact isolated bundle and an explicit launch flag. Signed v7 Debug/strict signature pass; native controls reach Armed and two disposable reminder occurrences are genuinely scheduled. See `mac-notification-hold-preflight-evidence.json`. Both reserved accounts and protected files have private baselines. Actual callback/account-switch acceptance remains pending; this is test preparation, not a pass. Inactive v6 products are pruned; active v7, logs and sources remain. iOS retains its independent existing harness.


### 12 October — actual Mac delayed Complete across A → B → A

The actual Notification Center Complete response is held for A, then released after native sign-out/sign-in to B with delivery enabled. The unchanged production handler returns under B; B tasks, pending edits and both notification registries remain empty. Returning to A preserves its complete scheduled snapshot, still-open task and exact four future requests. See `mac-notification-account-switch-evidence.json`. This closes the named Mac delayed Complete isolation journey; it does not expand acceptance to every action/timing permutation.

Native cleanup restores delivery off in both accounts and reversibly deletes only the synthetic A task. Cloud comparison proves A non-activity tables and prior activity exact, B all 14 tables exact, and 100 protected files exact. The empty reserved B account/0600 credentials remain for final fixture cleanup. Other named P0 release gates remain open. The earlier callback preflight is superseded by this actual result.


### 12 October — installed Mac task route exposes stale list context

A real Today widget title click cold-launches PID29369 without arguments and opens the exact task inspector, preserving the full snapshot. Native AX and inspected pixels expose an inconsistent background: Completed / 0 completed. Mac external task URLs and reminder opens now select the task’s Inbox/project/Completed context and clear a stale list search before selecting the task. iOS already uses a separate task sheet and needs no sidebar fix. See `mac-widget-task-context-evidence.json`.

Isolated v6 app/extension Debug build and strict deep signatures pass. Normal launch preserves the snapshot; native Quit is confirmed. The corrected installed cold route awaits a manual widget click. Inactive v5 products are pruned (125,670,357 logical bytes); v6 and logs remain. No corrected-runtime or broad widget pass is claimed yet.


### 12 October — fixed installed Today task cold route accepted

The second real desktop title click starts v6 PID30403 without arguments and opens Inbox / 1 task, the exact selected row and its inspector. Native AX and inspected pixels agree; the full saved task snapshot is unchanged. See `mac-widget-task-context-evidence.json`. Native reversible deletion restores the empty local task list and zero pending edits. Five original fixture files and all 100 protected files are hash-exact; local activity retains the two synthetic create/delete records. This closes the named Today task cold route to Inbox; other widget families/actions and the untested helper branches remain scoped separately.


12 October: installed large Mac My list initially remains a skeleton. Logs identify a stale v5 extension process whose bundle had been pruned; configuration lookup fails. Stopping that extension, registering current v6 and normally relaunching the host restores successful timeline generation. The earlier Inbox instruction was incorrect: My list accepts projects, labels and saved filters. A temporary native project now contains the same test task, with a matching App Group list and zero pending edits. Actual list selection/rendering/completion remains pending; see `mac-mylist-preflight-evidence.json`. Future build pruning must check both app and extension processes before removing a bundle.


12 October: installed large Mac My list completion now saves the exact task, changes only completion fields and survives normal relaunch with a durable receipt and no pending edits. The user identified missing feedback. Both owned implementations now show a brief, privacy-aware Completed row after durable save, scoped to the workspace/list; its eight-second timeline window does not promise exact OS timing. Eleven focused tests per repo, both Debug builds, Mac strict signatures and inspected small/medium/large source renders pass. Installed feedback transition remains pending on v7; direct widget Undo is not included. See `widget-completion-feedback-evidence.json`.
