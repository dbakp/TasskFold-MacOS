# P0 progress snapshot — 12 October 2026

**Feature implementation is largely complete. Release acceptance is incomplete.**
This short view summarizes `P0_RELEASE_STATUS.md`; its dated entries and JSON evidence remain authoritative for exact scope. A passing build is not native workflow acceptance. No percentage is assigned because remaining gates have very different risk and effort.

| Area | Proven progress | Remaining gate |
| --- | --- | --- |
| Productive widgets | Twelve kinds implemented; many installed iPhone/iPad configurations, cold/warm routes, completion, account switches and app privacy controls verified | Installed Mac hosts; remaining supported sizes/conditions; system privacy redaction |
| Todoist import | Real read-only multi-page import and replay; native imported-workspace handoff; iPhone lost first-import and replay-response recovery; Mac lost replay-response Retry and relaunch | Named native import/retry gate closed; evidence retains exact scope |
| Recovery | Native portable export/restore, encrypted Mac safety copy, cloud and cross-account restore/replay/relaunch; native Mac shared-access loss, encrypted recovery/apply and durable notice | External provider-backed file transfer and remaining failure boundaries |
| Device continuity | Native Mac ↔ phone tasks/notes/planning/organization round trips, offline edits and relaunches; paired name/photo and native Mac attachment handoffs | Remaining concurrency/legacy-client variants |
| Core usability | Capture/editor/subtasks/completion/Undo fixes; Mac calendar keyboard navigation; scoped phone/tablet normal and largest-text calendar routes; four clipping reports classified with scoped evidence | Spoken VoiceOver; remaining critical landscape/sidebar flows |
| Notifications | Mac Focus authorization, scheduling, pause/resume, background banner and terminated-app Notification Center delivery evidence; real iPhone Move to tomorrow/Complete and relaunch; native local workspace-exit retirement | Mac Open/actions; iPhone cold Complete and account-transition journeys; real APNs delivery and rollout proof |
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
