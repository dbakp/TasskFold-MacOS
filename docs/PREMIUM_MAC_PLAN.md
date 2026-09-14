# Taskfold macOS polish plan

The goal is a calm, fast native Mac app: daily actions should take few steps, navigation should preserve context, and motion should explain changes without disrupting work.

## Delivery rules

- Build and validate each milestone, install the verified app locally, then commit and push all changes to this repository.
- Preserve local iOS work. Shared Core comes from the iOS repository; use `TASKFOLD_IOS_ROOT` to build against a clean checkout when needed.
- Use native controls and the existing Store/Workspace undo paths. No backend or data model changes are required for the first milestone.
- Test changes with isolated fixtures. Never use real tasks as disposable test data.

## 1. Everyday editing — implemented and verified

- [x] Remove competing sidebar/calendar layout transitions.
- [x] Move focus into Calendar so its sidebar highlight matches the other destinations.
- [x] Remember unfinished quick-entry text, search text, and selected tasks for each destination during the session.
- [x] Keep the inspector out of the layout when nothing is selected; preserve the user's inspector preference.
- [x] Make existing date and project metadata actionable and add priority and task-action menus to rows.
- [x] Add a date popover with shortcuts, arbitrary dates, cancel, and one undoable commit.
- [x] Validate navigation restoration, date changes, completion/undo, and drag-and-drop; build and install Release.

Acceptance: navigating Today → Inbox → Today restores draft and selection; row edits do not require opening the inspector; rescheduling can be undone; no empty inspector occupies space.

## 2. Navigation — implemented

- [x] Introduce app-wide search for open/completed tasks and projects, with keyboard result navigation and clear empty states.
- [x] Add a command finder and recent destinations; keep filtering within a list available separately.
- [x] Restore scroll position per destination, including when the visible task disappears after sync.
- [x] Keep view options scoped to their destination instead of surprising users with inherited filters.
- [x] Validate navigation with long lists, deleted records, and switching between Calendar and tasks.

Acceptance: locate a task outside the current list without changing filters; Return opens it, Escape returns focus; revisiting a long list returns to the previous position.

## Requested account and comment improvements

- [x] Make account management, sign-in, settings, Todoist import, and invitations reachable from the sidebar and menu bar.
- [x] Paste clipboard images into comments as immediately saved attachments, preserving the text draft.
- [x] Verify selected-row text, priority, and action-button contrast.
- [x] Compare against the original apps and record remaining work in [the feature parity plan](FEATURE_PARITY.md).

## 3. Capture from anywhere

- [ ] Add a compact quick-entry panel using the shared parser and undo/save behavior.
- [ ] Register a configurable global shortcut, detect shortcut conflicts, and provide a menu entry.
- [ ] Preserve unfinished capture input on dismissal and restore focus to the previous app after saving.
- [ ] Include destination/date previews without requiring the main window.

Acceptance: capture from another app, save once, verify the task appears in the intended destination, and return to the previous app without focus surprises.

## 4. Visual and interaction refinement

- [ ] Simplify inspector sections with progressive disclosure while keeping populated details visible.
- [ ] Refine typography, metadata density, and empty states across Today, Inbox, projects, and search.
- [ ] Maintain predictable keyboard selection after completion/deletion and reliable undo feedback.
- [ ] Audit animations for Reduce Motion, unnecessary relayout, and interruptibility.
- [ ] Profile scrolling, search, sidebar counts, and Calendar with thousands of fixture tasks; optimize measured bottlenecks.
- [ ] Validate light/dark appearance, narrow/wide windows, keyboard access, and VoiceOver labels.

Acceptance: common actions remain responsive with large datasets, keyboard navigation never unexpectedly edits or completes another task, and no animation causes repeated layout shifts.

## Verification — 9 September 2026

- Debug UI suite: four tests passed, zero failures. The optional screenshot report test was skipped.
- Covered draft/selection restoration, inline date change with undo, keyboard completion with undo, and day-to-day drag with persistence across relaunch.
- Release build succeeded; installed `/Applications/Taskfold.app` and verified its code signature and launch.
- Confirmed the empty inspector is absent and Calendar navigation works in the installed build.
- Shared iOS checkout: `9419eb230c7cd91bce0a213206ae84c2dc5deb70`.
- Navigation memory is session-only. Global capture remains in a subsequent milestone; see the newer verification entry below for navigation work.

## Verification — 10 September 2026

- Global search covers completed tasks without changing the current list filter; keyboard result selection, command execution, Escape, and caret restoration are covered by UI tests.
- Long-list checks compare the rendered viewport across Calendar navigation and after deletion. NSTableView accessibility can return stale/estimated row coordinates, so screenshots verify the visible result.
- Account, native login, and Todoist import entry points are covered in local mode. Live email/Google authentication, profile uploads, invitations, and confirmed Todoist imports still need a dedicated account-based integration check.
- Clipboard-image tests verify immediate persistence across relaunch, preservation of unfinished comment text, and ordinary text paste after image paste. The test restores the user's clipboard unless it changed independently.
- Selected-row contrast fixes remove a drag fade that left rows at 45% opacity and reset drag state after release; native selection and drag/drop remain in use.
- Calendar toolbar items are scoped to their destination, and one window-level title/subtitle follows navigation.
- Navigation memory is session-only; view options are saved per destination. Shared sources remain pinned to the clean iOS checkout above.

Commands (set the shared-source path to your clean iOS checkout):

```sh
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/taskfold-polish-build \
  TASKFOLD_IOS_ROOT=/absolute/path/to/TaskFold-iOS -allowProvisioningUpdates test
xcodebuild -project Taskfold.xcodeproj -scheme Taskfold -configuration Release \
  -derivedDataPath /tmp/taskfold-polish-release \
  TASKFOLD_IOS_ROOT=/absolute/path/to/TaskFold-iOS -allowProvisioningUpdates build
```

## Delivery verification — 11 September 2026

- The full regression run on 10 September passed ten functional tests; the optional screenshot report was skipped. Its drag regression exposed a cleanup race, fixed by handling release after AppKit's event processing instead of polling mouse-button state.
- The final targeted run passed day-to-day dragging with persistence and keyboard completion/undo: two tests, zero failures. An initial Xcode automation initialization timeout was resolved by restarting the test service.
- The final Release build succeeded and passed strict code-signature verification. Installed it at `/Applications/Taskfold.app`, preserving the prior app bundle at `/tmp/Taskfold-before-september11.app`.
- Verified the installed release opens, switches Calendar → Today with the correct title and toolbar, opens global search, and exposes General/Account/Import/Invitations. Import's sign-in action opens the native email/create-account/Google login sheet.
- Live provider sign-in and account-backed import remain unverified, as described in the parity plan. No real task data was changed during verification.

## Layout follow-up — 11 September 2026

- Moved the current-list text filter and view-options menu into the upper-right corner of the task content. Global search stays in the sidebar; ⇧⌘F focuses the content filter.
- Task-list and Calendar quick-add fields start hidden. The toolbar plus, ⌘N, or New Task command reveals entry. Escape hides it without discarding the draft; successful submission clears and hides it. Returning to a destination keeps entry hidden until reopened.
- Verified four UI regressions: scoped completed filters, finder focus/project navigation, per-destination draft restoration, and explicit quick entry with filtering. The new test initially queried a task's accessibility label instead of its value; the corrected query passed.
- Release build and strict signature verification passed. Installed `/Applications/Taskfold.app` and visually checked the content-corner controls and plus/Escape behavior without changing real tasks.

## Parity pass — 11 September 2026

Shared iOS checkout: `d7a8bec` (`TASKFOLD_IOS_ROOT`, default `../taskfold-ios`). Seven milestones, each committed and pushed:

1. Band ordering and constrained drops, group reordering, Priority sort removed.
2. Quick-entry chips in the quick-add bar (lists, Calendar) and the inspector title.
3. Links by page title with hover previews, context menu, inspector Links section, selection-safe clicks.
4. Account security actions and actionable reminders.
5. Plan Your Day and Review This Week.
6. Accent colours, date-line subtitle, recent searches.
7. Shortcuts intents and the Today widget extension (App Group on both targets).

Verification notes:

- New UI tests: `testDropStaysInsidePriorityBand`, `testDeclinedChipKeepsWordsInTitle`, `testLinkClickDoesNotSelectRow`, `testPlanSheetCompletesTask`.
- Results: all 16 functional UI tests pass (11 in the full run once the screen unlocked, the 6 that had hit the lock in an immediate rerun), plus the screenshot capture test; shared Core `swift test` passes 31 tests with 1 live-fixture skip. Full-suite runs that start while the screen is locked fail every test with "has not loaded accessibility"; that is the lock, not the app.
- Fixture launches register `ApplePersistenceIgnoreState`: force-quit runs left window-restoration state that restored an app with no windows, which made every fixture test fail before the fix.
- Table-backed lists claim clicks before forwarding them, so link clicks are intercepted by a local event monitor ahead of the table (`Views/Links.swift`). Arrow keys reach `onMoveCommand`, not `onKeyPress`, in the planning sheet.
- The planning sheet snapshots its queue when it opens; recomputing it from the live store skipped a card after a completion.
- Shared Core compiled unchanged. `canImport(ActivityKit)` is true on macOS, so a no-op `LiveActivityManager` stub in the Mac target satisfies the persist hook.
- Live account actions (email/password change, reset, delete), Shortcuts phrases in Siri, and widget rendering in Notification Center need a signed-in account and a manual check; the bundle carries `Metadata.appintents`, the embedded `.appex`, and the App Group entitlement, and code signing verifies.

## Distribution and onboarding — 11 September 2026

- `Scripts/make_dmg.sh` produces `dist/Taskfold-<version>.dmg` (UDZO, HFS+, Applications shortcut, hidden readme), signs the image with the Apple Development identity, and verifies it. Mounted the image and verified the embedded app's signature. Developer ID and notarization remain out of reach on the personal team, so first launch on other Macs needs right-click ▸ Open.
- Welcome tour (`Views/OnboardingView.swift`): five pages, skippable, keyboard-driven, Reduce Motion aware, built from live components (`QuickEntryChips`, `CheckMark`, `InsertionIndicator`, the accent swatches). Shown once on first launch (`onboardingSeen`), reopenable from Help and Settings. Fixture launches show it only with `--onboarding`.
- UI test `testOnboardingPagesAndDismisses` passes; tour pages are captured as `Screenshots/onboarding-1…5.png`.

## Distribution signing — 11 September 2026

- The first v1.0.0 image was a team-signed development build: its embedded profile listed one device and expired in seven days, so another Mac reported "can't be opened". Replaced it with a distribution build: ad hoc signature (`CODE_SIGN_IDENTITY=-`), no profile, `Taskfold-Distribution.entitlements` (sandbox, network, user-selected files), no base entitlements injected, widget extension omitted (`TASKFOLD_WIDGETS=0` during the build; the checked-in project is regenerated afterwards).
- Verified: `Signature=adhoc`, no `embedded.provisionprofile`, no `PlugIns`, the app launches locally, and the image verifies. First launch on other Macs needs Privacy & Security ▸ Open Anyway; the release notes and the in-image "How to install" say so.
- `--development` keeps the team-signed variant for local use.

## Calendar, drag-and-drop, and capture follow-up — 11 September 2026

- Started from a fresh clone at `b760615`, preserving the newer release, widget, onboarding, accent, and priority-band work. Built against a separate clean iOS clone at `d7a8bec3f686679095092bcd03839e06866a8186`.
- Replaced the month grid's ambiguous trailing Divider with explicit vertical/horizontal cell borders. Verified the installed Calendar has no mid-cell horizontal lines.
- Connected native List move/insert handlers in day, Inbox/scope, project-section, and overdue groups. Added overdue groups to drag ordering, with separate placement keys so reordering does not change due dates. Dropping onto a date still reschedules.
- Prevented late drag callbacks from restoring an ended drag's indicator and reset header/end targets on drag completion. Screenshots taken immediately after Inbox and Upcoming drops show no remaining indicator.
- Overdue groups have explicit disclosure buttons and per-destination collapse preferences in task views, including Inbox, projects, labels, and All Tasks. Empty Inbox lists retain a drop target.
- Replaced inline capture with a native modal panel for task lists and Calendar: prominent focused input, destination, parsing chips, close action, and Add Task button. Escape preserves the draft; successful submission clears it. Removed the unused inline entry component.
- Five targeted UI tests passed: capture open/dismiss/save, day-to-day drag, priority-band behavior, Inbox order with persistence and multi-view collapse, and overdue reorder/reschedule. Final Release build and strict signature verification passed; installed `/Applications/Taskfold.app` and visually verified Calendar and capture without modifying real tasks.
- Additional modal compatibility checks passed for per-destination draft/selection restoration and finder/project navigation. These tests dismiss capture before navigating, then reopen its preserved draft.
- Parsed-chip rejection also passed in the modal. Its initial run could not activate the test app while another installed instance was open; the isolated retry passed. Eight relevant UI tests passed across the targeted runs.

## Expandable subtasks — 11 September 2026

- Added chevrons and indented rows for task → subtask → sub-subtask in task lists and the Calendar day panel. Expansion is remembered during the session; existing deeper data is preserved without offering deeper nesting.
- Nested rows use normal native list selection and the existing inspector. Checkbox/Space completion, reopening, inline metadata actions, edits, and undo save through the parent task's embedded JSON rather than creating duplicate backend task records.
- Subtask creation in the inspector opens the parent's disclosure. Sub-subtasks cannot create another level. Completing a child does not complete its parent or siblings, and completed children remain visible inside an expanded parent.
- Native drag index mapping accounts for expanded descendants, keeping the parent subtree together. Child rows cannot be reparented by dragging, so dragging cannot create deeper nesting.
- Fixed a native hit-testing issue by keeping indentation inside the accessible row's layout rather than wrapping its accessibility container in padding.
- UI checks passed for nested creation/depth limits, grandchild editing and persistence, completion/undo, and existing day-to-day dragging. Additional regression results and installation are recorded below.
- Six targeted UI checks passed across the final runs: hierarchy edit/completion/undo/persistence, nested creation with depth limit, expanded-parent drag/undo, day-to-day drag, Inbox reorder/overdue collapse, and inline date/undo. Visually verified the expanded tree with a selected grandchild in its inspector.
- Release build and strict code-signature verification passed. Installed and launched `/Applications/Taskfold.app`; its binary matches the verified release. Previous app bundle retained at `/tmp/Taskfold-before-subtasks.app`. No real tasks were created or changed for verification.

## Collaboration foundation — 11 September 2026

- [x] Verify shared access with isolated owner, member, outsider, and newly registered account identities.
- [x] Fix native project insertion, invitation acceptance, case-normalized recipient linking, ownership protection, and access after leaving.
- [x] Add task and nested-task assignments, member lookup, row reassignment, and Assigned to Me with parent context.
- [x] Persist per-field edit baselines; merge independent comments and nested edits atomically; present same-field conflicts for review.
- [x] Preserve teammates' independent comments when resolving conflicts or undoing local changes.
- [x] Clear obsolete assignments on project moves and membership removal.
- [x] Build, verify, install, and push this milestone.

Verification:

- Database fixtures passed inside rolled-back transactions. Covered pending/accepted access, outsiders, ownership, invalid assignees, concurrent stale edits, retry idempotence, nested edits, revocation, project moves, and signup invitation linking. No real task data was changed and no emails were sent.
- Shared Core: 35 tests, one optional live-account test skipped, zero failures. Added checks for RPC baseline transport and conflict propagation, older queue decoding, nested merge resolution, and undo preserving a remote comment.
- Mac UI: assignments through both nested levels, relaunch persistence, completion/undo, and conflict resolution passed. Clipboard image paste, expandable hierarchy editing, and day-to-day drag regressions passed.
- The assignment test caught an inspector project-change observer that cleared assignments on initial load. It now acts only on user changes, and the corrected persistence test passed.
- Release build and strict deep signature verification passed. Installed `/Applications/Taskfold.app`, verified its binary matches the release output, and checked Assigned to Me in the installed application. Previous app retained at `/tmp/Taskfold-before-collaboration.app`.
- Shared Core revision: `1c5290f614c5c594731ba2815eb52850de59fe64`, committed and pushed to TaskFold-iOS. Unrelated sibling iOS work was untouched.

The new merge transport is enabled on macOS. Existing web/iOS clients and old queued mutations still need adoption; do not claim cross-client conflict safety until that rollout is complete. Email delivery and two interactive signed-in sessions remain an integration follow-up. Permissions, mentions, activity notifications, recovery, and advisor follow-ups are prioritized in [COLLABORATION.md](COLLABORATION.md).

## Current parity milestone — 14 September 2026 (in progress)

- Implemented resolved account/member names and photos, persistent isolated identity caches, incremental refresh and retry/offline presentation.
- Added Appearance settings with Roomy/Compact, native custom color selection/save, bounded saved accents, and contrast-aware filled controls.
- Added shared persistent project-section collapse state and an optional native board with section-aware capture, moves, assignment, completion/undo and keyboard selection. Kept list default and grouped contextual view options.
- Added persistent invitation-link routing through sign-in; preserved existing invitation management.
- Pinned clean iOS Core `9960d97`; release scripts enforce the exact revision and reject local dependency changes. Prepared 1.1.0/build 2 consistently for app/widget generation.

Evidence so far:

- Shared Core: 42 tests, one optional live test skipped, zero failures.
- Rollback backend checks: existing collaboration coverage plus Google fallback/custom identity precedence passed. No migration redeployed and no emails sent.
- Debug compilation passed. Added targeted UI tests for density measurements/persistence, accent-page retention, collapse/board creation/moves, invitation intent, real remote avatar rendering/cache relaunch, and Upcoming viewport behavior; updated assignee/filter selectors while retaining assignment/conflict tests.
- XCTest execution still blocks **before tests start** on local UI Automation authentication. Fresh testmanagerd and widget-free test runs reproduced the authentication timeout. Keychain authentication is now working; it is no longer a blocker.
- `Scripts/test_mac.sh` builds Debug fixtures with distribution-style entitlements and no widget. This avoids the shared App Group snapshot stall in the widget-enabled fixture. Final test-target compilation passed.

Manual runtime evidence on isolated `--uitesting` fixtures:

- Real HTTPS image decoding/rendering passed, with Morgan Lee's photo and known name retained after relaunch. The assignee button reports “Photo loaded” and opens the accepted-member picker. Parent account/button accessibility identifiers remain stable after image loading.
- Actual native project row rectangles measured 57 → 51 points for Roomy → Compact; rows with notes measured 75 → 69. Both modes, wide/narrow windows, and light/dark screenshots were reviewed.
- Native Colors panel opened through the explicit Choose… button. RGB hex `FFD95A` saved and selected without leaving Appearance. This exposed faint accent text and incorrect selected-row foregrounds: accent shades now adapt locally for contrast, while native table selections use AppKit's selected text color. Light/dark bright-accent screenshots passed. System/Rose/Roomy were restored after checks.
- Board section-aware creation, move to Planning, undo back to Ready, completion/undo, and collapse/layout persistence passed manually. A selected column was obscured when the inspector resized the board; responding to actual viewport width changes now keeps it visible, verified in a narrow window.
- Upcoming's active Today header remained pinned while scrolling, then Tomorrow replaced it. Completion/undo preserved Task 019 at visible Y=20; switching Calendar → Upcoming preserved Task 062 at Y=25. Empty dates and a narrow window were reviewed. These checks did not justify changes to the existing sticky-date or scroll-memory implementation.
- Invitation fixture opened the signed-out Invitations destination, and the pending destination survived relaunch. Actual sign-in/email delivery and two-client interaction were not exercised.
- Computer Use drag attempts did not initiate a usable native drag session. No drop pass/failure conclusion is drawn from them; the XCTest press-and-drag regressions still need execution after authentication is resolved.

Still required before publishing: execute targeted/regression XCTest checks, verify overdue/date native drops and project last-row/move viewport cases, then complete distribution launch verification and publish the immutable release. Existing earlier milestone test results above are historical, not results for this dependency update. Do not claim this milestone complete from compilation alone.

Packaging: the latest 1.1.0/build 2 distribution was rebuilt with the runtime fixes. Strict app signature and `hdiutil verify` passed, with no provisioning profile/widget extension. DMG SHA-256: `8bb25d1f6a69e33b58df2e485195edb626348c2407cff7641074d3137b1394b4`. Installed this candidate at `/Applications/Taskfold.app`, retaining the prior app at `/tmp/Taskfold-before-parity-1.1.0.app`. The installed process launched but waits in `SecItemCopyMatching` for its own Keychain authorization; the Debug fixture authorization does not complete this separate distribution launch. No successful installed-window verification is claimed. Output lives under `~/Library/Caches/TaskfoldBuild`; publishing checks a fingerprint of build inputs to reject stale packages. No 1.1.0 release has been published.
