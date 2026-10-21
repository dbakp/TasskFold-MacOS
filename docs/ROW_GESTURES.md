# Row gestures

## iPhone and iPad

Settings → Swipe actions configures each swipe direction independently: Complete / Reopen, Tomorrow, Edit or None. Defaults are Complete / Reopen on the leading edge and Tomorrow on the trailing edge. A separate device-only preference enables full-swipe execution. Choosing None removes that edge's gesture actions; task menus, checkboxes and accessibility actions remain available. Direction labels and the custom card pan mirror with right-to-left layouts. Invalid future preference values disable the affected edge without changing stored tasks.

Regular lists and day cards use the same choices. Full swipes can only complete/reopen or reschedule an open task to tomorrow. Edit and Delete require a button activation. Delete is a secondary trailing action, never the full-swipe action. Tomorrow is disabled for completed list rows. Existing durable task mutations, child selection checks and Undo continue to own changes.

Day-card gestures capture a workspace incarnation and task snapshot when the pan begins. Delayed actions must still own the active gesture; cancellation, another gesture, scrolling, navigation, selection mode, preference changes and leaving the screen revoke delivery. A revealed button can dispatch only once. Immediately before dispatch, the current accessible task must equal the captured record, including task generation, project/section and child path/content. Native list and accessibility callbacks capture the displayed task/workspace rather than looking up a possibly different task when activated. A remote completion cannot turn a stale Complete into Reopen.

The custom row respects Reduce Motion, retains named accessibility actions and wraps button captions. These implementation details do not establish a full VoiceOver or physical-device acceptance claim.

## macOS

Settings → Swipes now configures each direction independently with the same four primary choices. The Mac owns its source, tests and preferences (`mac.rowGesture.*`), with full-swipe execution off by default. These are task-list controls; boards retain their existing menus and keyboard actions.

An app-local AppKit event monitor accepts only precise, phased, unmodified trackpad scrolling over a visible task row in its own key window. It discriminates horizontal movement from normal vertical/diagonal scrolling, and never replaces SwiftUI's table delegate. Ordinary mouse wheels, modifier gestures, mouse drags and other windows keep their existing event handling. Owned momentum is consumed without delivering another action. Cancelled/interrupted sequences cannot finish a task. Leaving the window/list, changing scope, searching, multi-selecting, dragging, changing preferences or removing the row revokes its action. A first click on shifted row content closes the actions without retargeting the restored checkbox.

Every rendered surface has its own identity, including repeated results in separate saved-query groups. Targets intersect the row's bounds with AppKit's visible rectangle; the visible rectangle alone can extend outside the row. Teardown revokes callbacks immediately and defers observable presentation changes with a gesture lease, so a stale teardown cannot cancel a new gesture. Revealed buttons deliver once. Task actions revalidate the workspace incarnation, current accessible root and displayed task; the root comparison also protects legacy positional child identities. Changes use existing Workspace commands and native Undo. Tomorrow cannot execute for completed rows. Full swipes require fresh, deliberate movement even if the actions were already revealed.

SwiftUI mirrors logical row offsets itself. Both apps now avoid an extra reversal that previously moved RTL content the wrong way. Render checks verify the painted action edge, rather than only checking the controller's signed displacement. The AppKit adapter compensates for the scroll preference using [Apple's event-direction API](https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice); both physical scrolling preferences remain live acceptance checks.

Mac action surfaces use readable darker colors with white labels. Selected row content retains the native active/inactive selection background while displaced. The custom presentation respects Reduce Motion. Offscreen views validate routing/rendering and light/dark settings previews; they do not establish full-app interaction, physical trackpad, keyboard/drag interoperability, screen-reader or release acceptance. The Mac is locked, so those native UI checks remain open without repeated requests to the user.

## Verification

- `swift test --filter RowGestureTests`: action eligibility, unavailable/replaced/edited tasks, signed-out state, account switch and return.
- `Scripts/test_row_swipe_controller.py --device SIMULATOR_UDID --output OUTPUT_JSON`: compiles the production UIKit controller/row and real action enum into a disposable simulator app. Tests cancellation, superseding gestures, once-only dispatch, disabled full swipes, Edit/None, mirrored directions and explicit deletion. Animation and haptic adapters are inert; it does not prove touch recognition or visual rendering. The harness is uninstalled afterward.
- Isolated native UI tests: preferences/Edit/cancel/relaunch; day-card Tomorrow plus persisted date; list Complete plus persisted state and Undo; invalid preference plus dark/largest-text settings.

The iOS controller harness also renders an RTL row and checks which edge actually contains the action. `Scripts/test_mac_row_swipe.py --output OUTPUT_JSON --previews PREVIEW_DIRECTORY` compiles the production Mac adapter/row, real motion model and task-list focus environment into a disposable offscreen AppKit harness. It checks routing, lifetime/cancellation and actual painted action edges; no events are posted or system permissions changed.

Exact runs and remaining acceptance limits are recorded in `p2-row-gestures-evidence.json` and `p2-mac-row-gestures-evidence.json`. This milestone does not complete all view controls, the full rank-3 backlog or the user's deferred distribution/provider/push/older-client rollout work.
