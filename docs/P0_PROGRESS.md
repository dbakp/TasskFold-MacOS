# P0 progress snapshot — 12 October 2026

**Feature implementation is largely complete. Release acceptance is incomplete.**
This short view summarizes `P0_RELEASE_STATUS.md`; its dated entries and JSON evidence remain authoritative for exact scope. A passing build is not native workflow acceptance. No percentage is assigned because remaining gates have very different risk and effort.

| Area | Proven progress | Remaining gate |
| --- | --- | --- |
| Productive widgets | Twelve kinds implemented; many installed phone/tablet routes, completion/account/privacy checks; iPhone Today empty/sign-out/relaunch; Mac medium Today install and app edit/Complete/Undo/relaunch refresh | Mac capture/task actions and other hosts/sizes/conditions; system privacy redaction |
| Todoist import | Real read-only multi-page import and replay; native imported-workspace handoff; iPhone lost first-import and replay-response recovery; Mac lost replay-response Retry and relaunch | Named native import/retry gate closed; evidence retains exact scope |
| Recovery | Native portable export/restore, encrypted Mac safety copy, cloud and cross-account restore/replay/relaunch; native Mac shared-access loss, encrypted recovery/apply and durable notice | External provider-backed file transfer and remaining failure boundaries |
| Device continuity | Native Mac ↔ phone tasks/notes/planning/organization round trips, offline edits and relaunches; paired name/photo and native Mac attachment handoffs | Remaining concurrency/legacy-client variants |
| Core usability | Capture/editor/subtasks/completion/Undo fixes; Mac calendar keyboard navigation; scoped phone/tablet normal and largest-text calendar routes; four clipping reports classified with scoped evidence | Spoken VoiceOver; remaining critical landscape/sidebar flows |
| Notifications | Mac Focus authorization, scheduling, pause/resume, background banner and terminated-app Notification Center delivery evidence; real iPhone Move to tomorrow/Complete and relaunch, including terminated-process Complete; native local workspace-exit retirement | Mac Open/actions; iPhone account-transition journeys; real APNs delivery and rollout proof |
| Distribution | Independent repositories and development builds | Mac app provisioning blocked by current Personal Team’s Push Notifications limit; enrolled team, Developer ID/notarization and distribution signing |

## How to interpret recent activity

Recent work includes actual user-visible calendar/accessibility fixes, native workflow verification, test-driver corrections, signing/Simulator problems and evidence maintenance. These are different kinds of progress and should not be combined into a claim that all P0 is done. Calendar coverage is bounded; additional combinations are not automatically new release requirements.

## Next execution order

1. Compact landscape task-editor insertion/visible input/caret, keyboard-visible Save and exact persisted values after relaunch now pass normal and largest text (`landscape-editor-evidence.json`). This named journey is closed; do not expand into another calendar/layout matrix.
2. Verify installed Mac widgets in the isolated signed host, then the outstanding real notification Open/actions. The isolated app and extension now sign independently of the production Push entitlement blocker.
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
