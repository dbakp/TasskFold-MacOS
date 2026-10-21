# Row gestures

## iPhone and iPad

Settings → Swipe actions configures each swipe direction independently: Complete / Reopen, Tomorrow, Edit or None. Defaults are Complete / Reopen on the leading edge and Tomorrow on the trailing edge. A separate device-only preference enables full-swipe execution. Choosing None removes that edge's gesture actions; task menus, checkboxes and accessibility actions remain available. Direction labels and the custom card pan mirror with right-to-left layouts. Invalid future preference values disable the affected edge without changing stored tasks.

Regular lists and day cards use the same choices. Full swipes can only complete/reopen or reschedule an open task to tomorrow. Edit and Delete require a button activation. Delete is a secondary trailing action, never the full-swipe action. Tomorrow is disabled for completed list rows. Existing durable task mutations, child selection checks and Undo continue to own changes.

Day-card gestures capture a workspace incarnation and task snapshot when the pan begins. Delayed actions must still own the active gesture; cancellation, another gesture, scrolling, navigation, selection mode, preference changes and leaving the screen revoke delivery. A revealed button can dispatch only once. Immediately before dispatch, the current accessible task must equal the captured record, including task generation, project/section and child path/content. Native list and accessibility callbacks capture the displayed task/workspace rather than looking up a possibly different task when activated. A remote completion cannot turn a stale Complete into Reopen.

The custom row respects Reduce Motion, retains named accessibility actions and wraps button captions. These implementation details do not establish a full VoiceOver or physical-device acceptance claim.

## macOS

Native Mac trackpad gestures remain a separate implementation and acceptance item. The current Mac list uses SwiftUI List; it has no app-owned NSTableView delegate. Do not replace private SwiftUI delegates or attach iOS recognizers. Preserve native vertical scrolling, mouse selection, keyboard completion/Undo and drag reordering. Mac preferences must remain local to that app and default to deliberate button activation rather than full-swipe execution. No Mac gesture controls are advertised before the corresponding interactions exist.

## Verification

- `swift test --filter RowGestureTests`: action eligibility, unavailable/replaced/edited tasks, signed-out state, account switch and return.
- `Scripts/test_row_swipe_controller.py --device SIMULATOR_UDID --output OUTPUT_JSON`: compiles the production UIKit controller/row and real action enum into a disposable simulator app. Tests cancellation, superseding gestures, once-only dispatch, disabled full swipes, Edit/None, mirrored directions and explicit deletion. Animation and haptic adapters are inert; it does not prove touch recognition or visual rendering. The harness is uninstalled afterward.
- Isolated native UI tests: preferences/Edit/cancel/relaunch; day-card Tomorrow plus persisted date; list Complete plus persisted state and Undo; invalid preference plus dark/largest-text settings.

Exact runs and remaining acceptance limits are recorded in `p2-row-gestures-evidence.json`. This milestone does not complete all view controls, the full rank-3 backlog or the user's deferred distribution/provider/push/older-client rollout work.
